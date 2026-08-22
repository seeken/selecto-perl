package Selecto::SQL;

use Mojo::Base 'Selecto::Adapter';
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();
use Selecto::Statement ();
use Selecto::Write ();

our @FEATURE_INVENTORY = qw(
    cte recursive_cte window_functions transactions returning rollup stream
    schema_introspection text_search json_rowset lateral_join
);
our %WRITE_CAPABILITIES = map { $_ => 1 } qw(insert update upsert delete transactions atomic_batch);

sub feature_inventory { return [@FEATURE_INVENTORY]; }
sub write_capabilities { return { %WRITE_CAPABILITIES }; }

sub quote_identifier {
    my ($self, $identifier) = @_;
    my $quoted = defined($identifier) ? "$identifier" : '';
    $quoted =~ s/"/""/g;
    return qq{"$quoted"};
}

sub compile {
    my ($self, $domain, $query) = @_;
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    my @params;
    my @joins;
    my $associations = $domain->associations;
    my $predicate = Selecto::QueryEnforcement::combine(
        $domain->required_predicate, $query->predicate);
    for my $name ($self->_referenced_associations($query, $predicate)) {
        my $association = $associations->{$name};
        Selecto::Error->throw('unknown_association', "unknown association $name") unless $association;
        my $keyword = $association->join_type eq 'inner' ? 'INNER JOIN' : 'LEFT JOIN';
        push @joins,
            $keyword . ' ' . $self->quote_identifier($association->table) .
            ' AS ' . $self->quote_identifier($self->_join_alias($name)) .
            ' ON ' . $self->quote_identifier('s0') . '.' . $self->quote_identifier($association->owner_key) .
            ' = ' . $self->quote_identifier($self->_join_alias($name)) . '.' . $self->quote_identifier($association->related_key);
    }
    my %compiled_selections;
    my %selection_positions;
    my $selection_position = 0;
    my @selection_sql = map {
        $selection_position++;
        my $expression_sql = $self->_compile_expression(
            $domain, $_, \@params, \%compiled_selections,
        );
        $compiled_selections{_expression_key($_)} //= $expression_sql;
        $selection_positions{_expression_key($_)} //= $selection_position;
        defined($_->alias_name)
            ? $expression_sql . ' AS ' . $self->quote_identifier($_->alias_name)
            : $expression_sql
    } @$selections;
    my @columns = map { $self->_selection_name($_) } @$selections;
    my $sql = 'SELECT ' . join(', ', @selection_sql) .
        ' FROM ' . $self->quote_identifier($domain->table) . ' AS ' . $self->quote_identifier('s0');
    $sql .= ' ' . join(' ', @joins) if @joins;
    $sql .= ' WHERE ' . $self->_compile_expression($domain, $predicate, \@params) if $predicate;
    my $groups = $query->groups;
    my $group_sql = join(', ', map {
        my $key = _expression_key($_);
        exists($compiled_selections{$key})
            ? $compiled_selections{$key}
            : $self->_compile_expression($domain, $_, \@params)
    } @$groups);
    if (@$groups) {
        $sql .= $query->grouping_mode eq 'rollup'
            ? ' GROUP BY ROLLUP (' . $group_sql . ')'
            : ' GROUP BY ' . $group_sql;
    }
    my $orders = $query->orders;
    if ($query->grouping_mode eq 'rollup' && @$orders) {
        my $single_grouping_position = _single_rollup_grouping_position(
            $selections, $groups, \%selection_positions,
        );
        my @outer_orders = map {
            my $position = $selection_positions{_expression_key($_->[0])};
            Selecto::Error->throw(
                'invalid_query',
                'rollup ordering expressions must also be selected',
            ) unless defined $position;
            $position . ' ' . uc($_->[1]) .
                (defined($single_grouping_position) ? ' NULLS LAST' : ' NULLS FIRST');
        } @$orders;
        unshift @outer_orders, $single_grouping_position . ' DESC'
            if defined $single_grouping_position;
        my $order_sql = join(', ', @outer_orders);
        $sql = $self->_rollup_sort_fix_enabled
            ? 'SELECT * FROM (' . $sql . ') AS rollupfix ORDER BY ' . $order_sql
            : $sql . ' ORDER BY ' . $order_sql;
    } elsif (@$orders) {
        $sql .= ' ORDER BY ' . join(', ', map {
            $self->_compile_expression($domain, $_->[0], \@params) . ' ' . uc($_->[1])
        } @$orders);
    }
    $sql .= $self->_compile_pagination(
        $query->limit_value,
        $query->offset_value,
        @$orders ? 1 : 0,
    );
    return Selecto::Statement->new(
        sql => $sql,
        params => \@params,
        columns => \@columns,
        adapter_name => $self->name,
    );
}

sub _single_rollup_grouping_position {
    my ($selections, $groups, $positions) = @_;
    return undef unless @$groups == 1;
    my $group_key = _expression_key($groups->[0]);
    for my $selection (@$selections) {
        next unless $selection->kind eq 'grouping';
        my $arguments = $selection->arguments->[0];
        next unless ref($arguments) eq 'ARRAY' && @$arguments == 1;
        next unless _expression_key($arguments->[0]) eq $group_key;
        return $positions->{_expression_key($selection)};
    }
    return undef;
}

sub execute_query {
    my ($self, $statement) = @_;
    my ($sth, @rows);
    my $ok = eval {
        $sth = $self->{dbh}->prepare($statement->sql);
        $sth->execute(@{$statement->params});
        my @types = $self->_column_types($sth);
        while (my @row = $sth->fetchrow_array) {
            push @rows, [map { $self->_decode($row[$_], $types[$_]) } 0 .. $#row];
        }
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return { columns => $statement->columns, rows => \@rows };
}

sub preview_write {
    my ($self, $command) = @_;
    my $statement = $self->_compile_write($command);
    return { sql => $statement->{sql}, params => [@{$statement->{params}}] };
}

sub execute_write {
    my ($self, $command) = @_;
    my $compiled = $self->_compile_write($command);
    return $self->_transaction(sub { return $self->_execute_compiled_write_in_transaction($command, $compiled); });
}

sub execute_batch {
    my ($self, $batch) = @_;
    my @commands = @{$batch->commands};
    my @compiled = map { $self->_compile_write($_) } @commands;
    return $self->_transaction(sub {
        my @results = map { $self->_execute_compiled_write_in_transaction($commands[$_], $compiled[$_]) } 0 .. $#commands;
        return \@results;
    });
}

sub execute_graph {
    my ($self, $graph) = @_;
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    Selecto::Error->throw('write_capability_missing', 'adapter does not support write graphs')
        unless $self->write_capabilities->{write_graph};

    return $self->_transaction(sub {
        my %results;
        for my $node (@{$graph->nodes}) {
            my $assignments = $node->{command}->assignments;
            my @scopes = grep { defined } ($node->{command}->scope_predicate);
            for my $binding (@{$node->{bindings}}) {
                my $source = $results{$binding->{from}};
                Selecto::Error->throw('invalid_write_graph', "graph binding source $binding->{from} is unavailable")
                    unless $source;
                my $values = $source->values;
                Selecto::Error->throw('invalid_write_graph', "graph binding value $binding->{from}.$binding->{key} is unavailable")
                    unless exists $values->{$binding->{key}};
                $assignments->{$binding->{field}} = $values->{$binding->{key}};
                push @scopes, Selecto::Expression->eq(
                    Selecto::Expression->field($binding->{scope_field}),
                    Selecto::Expression->literal($values->{$binding->{key}}),
                ) if defined $binding->{scope_field};
            }
            my $command = $node->{command}->with_assignments($assignments);
            $command = $command->with_scope_predicate(
                @scopes == 1 ? $scopes[0] : Selecto::Expression->all(@scopes)
            ) if @scopes;
            my $compiled = $self->_compile_write($command);
            $results{$node->{id}} = $self->_execute_compiled_write_in_transaction($command, $compiled);
        }
        my $root = $graph->nodes->[0]{id};
        return Selecto::Write::Graph::Result->new(nodes => \%results, root => $results{$root});
    });
}

sub _compile_selection {
    my ($self, $domain, $expression, $params) = @_;
    my $sql = $self->_compile_expression($domain, $expression, $params);
    return defined($expression->alias_name)
        ? $sql . ' AS ' . $self->quote_identifier($expression->alias_name)
        : $sql;
}

sub _expression_key {
    my ($expression) = @_;
    return _value_key($expression);
}

sub _value_key {
    my ($value) = @_;
    return 'u' unless defined $value;
    if (blessed($value) && $value->isa('Selecto::Expression')) {
        return 'e:' . $value->kind . ':' . _value_key($value->arguments);
    }
    return 'a:[' . join(',', map { _value_key($_) } @$value) . ']'
        if ref($value) eq 'ARRAY';
    return 'h:{' . join(',', map { _value_key($_) . '=' . _value_key($value->{$_}) } sort keys %$value) . '}'
        if ref($value) eq 'HASH';
    return 's:' . length("$value") . ':' . "$value" unless ref($value);
    return 'r:' . ref($value);
}

sub _selection_name {
    my ($self, $expression) = @_;
    return $expression->alias_name if defined $expression->alias_name;
    if ($expression->kind eq 'field') {
        my ($field) = @{$expression->arguments};
        my @segments = split /\./, $field;
        return $segments[-1];
    }
    return $expression->kind;
}

sub _compile_expression {
    my ($self, $domain, $expression, $params, $compiled_selections) = @_;
    Selecto::Error->throw('invalid_query', 'expected an expression')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $self->_field_sql($domain, $arguments->[0]) if $kind eq 'field';
    if ($kind eq 'literal') {
        push @$params, $arguments->[0];
        return $self->placeholder(scalar @$params);
    }
    if ($kind eq 'eq' || $kind eq 'ne' || $kind eq 'gt' || $kind eq 'gte'
        || $kind eq 'lt' || $kind eq 'lte') {
        my $operator = {
            eq => '=', ne => '<>', gt => '>', gte => '>=', lt => '<', lte => '<=',
        }->{$kind};
        return $self->_compile_expression($domain, $arguments->[0], $params) . " $operator " .
            $self->_compile_expression($domain, $arguments->[1], $params);
    }
    if ($kind eq 'between') {
        return $self->_compile_expression($domain, $arguments->[0], $params) . ' BETWEEN ' .
            $self->_compile_expression($domain, $arguments->[1], $params) . ' AND ' .
            $self->_compile_expression($domain, $arguments->[2], $params);
    }
    return $self->_compile_expression($domain, $arguments->[0], $params) . ' IS NULL' if $kind eq 'is_null';
    return $self->_compile_expression($domain, $arguments->[0], $params) . ' IS NOT NULL' if $kind eq 'not_null';
    if ($kind eq 'in') {
        my $values = $arguments->[1];
        Selecto::Error->throw('invalid_query', 'IN requires at least one value') unless ref($values) eq 'ARRAY' && @$values;
        my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
        return $self->_compile_expression($domain, $arguments->[0], $params) . ' IN (' . join(', ', @markers) . ')';
    }
    if ($kind eq 'and' || $kind eq 'or') {
        my $expressions = $arguments->[0];
        Selecto::Error->throw('invalid_query', uc($kind) . ' requires expressions')
            unless ref($expressions) eq 'ARRAY' && @$expressions;
        my $operator = $kind eq 'and' ? ' AND ' : ' OR ';
        return join($operator, map { '(' . $self->_compile_expression($domain, $_, $params) . ')' } @$expressions);
    }
    return 'NOT (' . $self->_compile_expression($domain, $arguments->[0], $params) . ')' if $kind eq 'not';
    return 'COUNT(*)' if $kind eq 'count';
    if ($kind eq 'grouping') {
        my $fields = $arguments->[0];
        Selecto::Error->throw('invalid_query', 'GROUPING requires fields')
            unless ref($fields) eq 'ARRAY' && @$fields;
        return 'GROUPING(' . join(', ', map {
            my $key = _expression_key($_);
            defined($compiled_selections) && exists($compiled_selections->{$key})
                ? $compiled_selections->{$key}
                : $self->_compile_expression($domain, $_, $params)
        } @$fields) . ')';
    }
    if ($kind eq 'dimension_display') {
        my $display_sql = $self->_compile_expression($domain, $arguments->[0], $params);
        my $key_sql = $self->_compile_expression($domain, $arguments->[1], $params);
        return "CASE WHEN GROUPING($key_sql) = 1 THEN NULL ELSE MIN($display_sql) END";
    }
    return $self->_compile_related_collection($domain, $expression)
        if $kind eq 'related_collection';
    return 'COUNT(' . $self->_compile_expression($domain, $arguments->[0], $params) . ')'
        if $kind eq 'count_field';
    return 'COUNT(DISTINCT ' . $self->_compile_expression($domain, $arguments->[0], $params) . ')'
        if $kind eq 'count_distinct';
    if ($kind eq 'true_count' || $kind eq 'false_count') {
        my $value = $kind eq 'true_count' ? 'TRUE' : 'FALSE';
        return 'COUNT(CASE WHEN ' . $self->_compile_expression($domain, $arguments->[0], $params) .
            " = $value THEN 1 END)";
    }
    return $self->_compile_dialect_expression($domain, $expression, $params)
        if $kind eq 'count_bucket' || $kind eq 'bucket' || $kind eq 'datetime_format'
            || $kind eq 'epoch_datetime';
    if ($kind eq 'avg' || $kind eq 'sum' || $kind eq 'min' || $kind eq 'max') {
        return uc($kind) . '(' . $self->_compile_expression($domain, $arguments->[0], $params) . ')';
    }
    if ($kind eq 'sum_zero') {
        return 'SUM(COALESCE(' . $self->_compile_expression($domain, $arguments->[0], $params) . ', 0))';
    }
    Selecto::Error->throw('invalid_query', "unsupported expression $kind");
}

sub _compile_related_collection {
    my ($self, $domain, $expression) = @_;
    my ($association_name, $fields) = @{$expression->arguments};
    Selecto::Error->throw('invalid_query', 'related collection association is invalid')
        unless defined($association_name) && !ref($association_name)
            && "$association_name" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    Selecto::Error->throw('invalid_query', 'related collection fields are required')
        unless ref($fields) eq 'ARRAY' && @$fields;
    my $association = $domain->associations->{$association_name};
    Selecto::Error->throw('unknown_association', "unknown association $association_name")
        unless $association;
    Selecto::Error->throw('invalid_query', 'related collections require a to-many association')
        unless $association->cardinality eq 'many';
    my $association_fields = $association->fields;
    for my $field (@$fields) {
        Selecto::Error->throw('invalid_query', 'related collection field is invalid')
            unless defined($field) && !ref($field)
                && "$field" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
                && exists $association_fields->{$field};
    }

    my $alias = 'c_' . $association_name;
    my $quoted_alias = $self->quote_identifier($alias);
    my $table = $self->quote_identifier($association->table);
    my $related_key = $quoted_alias . '.' . $self->quote_identifier($association->related_key);
    my $owner_key = $self->quote_identifier('s0') . '.' .
        $self->quote_identifier($association->owner_key);
    my $order = defined($association->target_primary_key)
        ? $quoted_alias . '.' . $self->quote_identifier($association->target_primary_key)
        : undef;
    my $adapter = $self->name;

    if ($adapter eq 'mssql') {
        my $projection = join(', ', map {
            $quoted_alias . '.' . $self->quote_identifier($_) . ' AS ' .
                $self->quote_identifier($_)
        } @$fields);
        return "COALESCE((SELECT $projection FROM $table AS $quoted_alias " .
            "WHERE $related_key = $owner_key" .
            (defined($order) ? " ORDER BY $order" : '') . " FOR JSON PATH), '[]')";
    }

    my @pairs = map {
        my $key = "$_";
        $key =~ s/'/''/g;
        "'$key', " . $quoted_alias . '.' . $self->quote_identifier($_)
    } @$fields;
    my ($aggregate, $empty);
    if ($adapter eq 'postgresql') {
        $aggregate = 'JSON_AGG(JSON_BUILD_OBJECT(' . join(', ', @pairs) . ')' .
            (defined($order) ? " ORDER BY $order" : '') . ')';
        $empty = q{'[]'::json};
    } elsif ($adapter eq 'mysql' || $adapter eq 'mariadb') {
        $aggregate = 'JSON_ARRAYAGG(JSON_OBJECT(' . join(', ', @pairs) . '))';
        $empty = 'JSON_ARRAY()';
    } elsif ($adapter eq 'sqlite' || $adapter eq 'duckdb') {
        $aggregate = 'JSON_GROUP_ARRAY(JSON_OBJECT(' . join(', ', @pairs) . '))';
        $empty = q{'[]'};
    } else {
        Selecto::Error->throw(
            'unsupported_feature',
            "related collections are not supported by adapter $adapter",
        );
    }
    return "COALESCE((SELECT $aggregate FROM $table AS $quoted_alias " .
        "WHERE $related_key = $owner_key), $empty)";
}

sub _compile_count_bucket {
    my ($self, $domain, $field, $specification, $params) = @_;
    Selecto::Error->throw('invalid_query', 'bucket count specification must be an object')
        unless ref($specification) eq 'HASH';
    my $mode = $specification->{mode} // 'numeric';
    Selecto::Error->throw('invalid_query', 'bucket count mode is not available')
        unless $mode eq 'numeric' || $mode eq 'elapsed_days';
    my $field_sql = $self->_compile_expression($domain, $field, $params);
    my $value_sql = $mode eq 'elapsed_days'
        ? "CURRENT_DATE - DATE($field_sql)"
        : $field_sql;
    my ($minimum, $maximum) = @{$specification}{qw(minimum maximum)};
    Selecto::Error->throw('invalid_query', 'bucket count requires at least one boundary')
        unless defined($minimum) || defined($maximum);
    Selecto::Error->throw('invalid_query', 'bucket count boundaries must be integers')
        if (defined($minimum) && "$minimum" !~ /\A\d+\z/)
        || (defined($maximum) && "$maximum" !~ /\A\d+\z/);
    my @predicates;
    if (defined($minimum)) {
        push @$params, int($minimum);
        push @predicates, $value_sql . ' >= ' . $self->placeholder(scalar @$params);
    }
    if (defined($maximum)) {
        push @$params, int($maximum);
        push @predicates, $value_sql . ' <= ' . $self->placeholder(scalar @$params);
    }
    return 'COUNT(CASE WHEN ' . join(' AND ', @predicates) . ' THEN 1 END)';
}

sub _compile_bucket {
    my ($self, $domain, $field, $specification, $params) = @_;
    Selecto::Error->throw('invalid_query', 'bucket specification must be an object')
        unless ref($specification) eq 'HASH';
    my $kind = $specification->{kind} // '';
    my $field_sql = $self->_compile_expression($domain, $field, $params);
    my ($path) = @{$field->arguments};
    my $resolved = $domain->resolve($path);

    if ($kind eq 'numeric_increment' || $kind eq 'year_increment') {
        Selecto::Error->throw('invalid_query', 'bucket increment must be a positive integer')
            unless defined($specification->{increment})
            && "$specification->{increment}" =~ /\A[1-9]\d*\z/;
        Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
            if $kind eq 'numeric_increment' && $resolved->{type} !~ /(?:int|decimal|number|numeric|float|double|real)/i;
        Selecto::Error->throw('invalid_query', 'year buckets require a date or time field')
            if $kind eq 'year_increment' && $resolved->{type} !~ /(?:date|time)/i;
        my $value_sql = $kind eq 'year_increment' ? "EXTRACT(YEAR FROM $field_sql)" : $field_sql;
        my $increment = int($specification->{increment});
        my $start = "CAST(FLOOR(CAST($value_sql AS NUMERIC) / $increment) AS BIGINT) * $increment";
        return "CASE WHEN $field_sql IS NULL THEN 'Other' ELSE CAST(($start) AS TEXT) || '-' || " .
            'CAST(((' . $start . ') + ' . ($increment - 1) . ') AS TEXT) END';
    }

    if ($kind eq 'text_prefix') {
        Selecto::Error->throw('invalid_query', 'text prefix bucket requires a text field')
            unless $resolved->{type} =~ /(?:string|text|char|citext)/i;
        my $length = $specification->{prefix_length} // 2;
        Selecto::Error->throw('invalid_query', 'text prefix length must be between 1 and 10')
            unless "$length" =~ /\A\d+\z/ && $length >= 1 && $length <= 10;
        my $normalized = "BTRIM(COALESCE(CAST($field_sql AS TEXT), ''))";
        if ($specification->{exclude_articles}) {
            $normalized = "REGEXP_REPLACE($normalized, '^(a|an|the)([[:space:]]+|$)', '', 'i')";
        }
        $normalized = "LOWER($normalized)" unless exists($specification->{ignore_case}) && !$specification->{ignore_case};
        return "CASE WHEN $normalized = '' THEN 'Other' ELSE UPPER(LEFT($normalized, " . int($length) . ')) END';
    }

    my %range_kinds = map { $_ => 1 } qw(
        numeric_ranges elapsed_days_ranges date_relative_ranges year_ranges
    );
    Selecto::Error->throw('invalid_query', 'bucket kind is not available') unless $range_kinds{$kind};
    Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
        if $kind eq 'numeric_ranges' && $resolved->{type} !~ /(?:int|decimal|number|numeric|float|double|real)/i;
    Selecto::Error->throw('invalid_query', 'temporal buckets require a date or time field')
        if $kind ne 'numeric_ranges' && $resolved->{type} !~ /(?:date|time)/i;
    my $ranges = $specification->{ranges};
    Selecto::Error->throw('invalid_query', 'bucket ranges must be a non-empty array')
        unless ref($ranges) eq 'ARRAY' && @$ranges;
    my $value_sql = $kind eq 'elapsed_days_ranges' ? "CURRENT_DATE - DATE($field_sql)"
        : $kind eq 'year_ranges' ? "EXTRACT(YEAR FROM $field_sql)"
        : $kind eq 'date_relative_ranges' ? "DATE($field_sql)"
        : $field_sql;
    my @clauses;
    for my $range (@$ranges) {
        Selecto::Error->throw('invalid_query', 'bucket range must be an object')
            unless ref($range) eq 'HASH';
        my ($minimum, $maximum, $label) = @{$range}{qw(minimum maximum label)};
        Selecto::Error->throw('invalid_query', 'bucket range label is required')
            unless defined($label) && !ref($label) && length("$label") <= 80;
        my $predicate;
        if ($kind eq 'date_relative_ranges' && defined($minimum) && "$minimum" =~ /\A(?:today|yesterday|tomorrow)\z/) {
            Selecto::Error->throw('invalid_query', 'date keyword bucket boundaries must match')
                unless defined($maximum) && "$maximum" eq "$minimum";
            $predicate = $minimum eq 'today' ? "$value_sql = CURRENT_DATE"
                : $minimum eq 'yesterday' ? "$value_sql = CURRENT_DATE - INTERVAL '1 day'"
                : "$value_sql = CURRENT_DATE + INTERVAL '1 day'";
        } else {
            Selecto::Error->throw('invalid_query', 'bucket range requires at least one boundary')
                unless defined($minimum) || defined($maximum);
            Selecto::Error->throw('invalid_query', 'bucket range boundaries must be integers')
                if (defined($minimum) && "$minimum" !~ /\A\d+\z/)
                || (defined($maximum) && "$maximum" !~ /\A\d+\z/);
            my @predicates;
            if (defined($minimum)) {
                push @$params, int($minimum);
                my $marker = $self->placeholder(scalar @$params);
                push @predicates, $kind eq 'date_relative_ranges'
                    ? "$value_sql <= CURRENT_DATE - ($marker * INTERVAL '1 day')"
                    : "$value_sql >= $marker";
            }
            if (defined($maximum)) {
                push @$params, int($maximum);
                my $marker = $self->placeholder(scalar @$params);
                push @predicates, $kind eq 'date_relative_ranges'
                    ? "$value_sql >= CURRENT_DATE - ($marker * INTERVAL '1 day')"
                    : "$value_sql <= $marker";
            }
            $predicate = join(' AND ', @predicates);
        }
        push @$params, "$label";
        push @clauses, 'WHEN ' . $predicate . ' THEN ' . $self->placeholder(scalar @$params);
    }
    push @$params, 'Other';
    return 'CASE ' . join(' ', @clauses) . ' ELSE ' . $self->placeholder(scalar @$params) . ' END';
}

sub _field_sql {
    my ($self, $domain, $path) = @_;
    my $resolved = $domain->resolve($path);
    my $table_alias = $resolved->{association}
        ? $self->_join_alias($resolved->{association}->name)
        : 's0';
    return $self->quote_identifier($table_alias) . '.' . $self->quote_identifier($resolved->{field});
}

sub _referenced_associations {
    my ($self, $query, $predicate) = @_;
    my @expressions = (@{$query->selections});
    push @expressions, $predicate if $predicate;
    push @expressions, @{$query->groups};
    push @expressions, map { $_->[0] } @{$query->orders};
    my %names;
    $names{$_} = 1 for map { $self->_expression_associations($_) } @expressions;
    return sort keys %names;
}

sub _expression_associations {
    my ($self, $expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    if ($expression->kind eq 'field') {
        my @segments = split /\./, $arguments->[0];
        return @segments == 2 ? ($segments[0]) : ();
    }
    my @names;
    for my $argument (@$arguments) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            push @names, $self->_expression_associations($argument);
        } elsif (ref($argument) eq 'ARRAY') {
            push @names, map { $self->_expression_associations($_) } @$argument;
        }
    }
    return @names;
}

sub _join_alias { return 'j_' . $_[1]; }

sub _compile_write {
    my ($self, $command) = @_;
    my $relation = _checked_identifier($command->relation);
    my $operation = $command->operation;
    my $assignments = $command->assignments;
    if ($operation eq 'insert' || $operation eq 'upsert') {
        Selecto::Error->throw('query_enforcement_unsupported_operation', 'query-enforced upsert is not supported')
            if defined($command->query_enforcement) && $operation eq 'upsert';
        my @fields = sort keys %$assignments;
        Selecto::Error->throw('invalid_write', 'insert requires assignments') unless @fields;
        my @params = map { $assignments->{$_} } @fields;
        my $insert_predicate = Selecto::QueryEnforcement::combine(
            $command->predicate,
            $command->scope_predicate,
            defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
        );
        if ($insert_predicate) {
            my $truth = Selecto::QueryEnforcement::evaluate($insert_predicate, $assignments);
            Selecto::Error->throw(
                'query_rule_violation',
                'insert candidate does not satisfy the enforced query',
                { truth_value => $truth },
            ) unless $truth eq 'true';
        }
        my $sql = 'INSERT INTO ' . $self->quote_identifier($relation) .
            ' (' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @fields) . ')' .
            ' VALUES (' . join(', ', map { $self->placeholder($_ + 1) } 0 .. $#fields) . ')';
        if ($operation eq 'upsert') {
            my $metadata = $command->metadata;
            my $conflict = $metadata->{conflict_target};
            my $updates = $metadata->{upsert_update_fields};
            Selecto::Error->throw('invalid_write', 'upsert conflict target must be a non-empty string array')
                unless ref($conflict) eq 'ARRAY' && @$conflict && !grep { ref($_) } @$conflict;
            Selecto::Error->throw('invalid_write', 'upsert update fields must be a non-empty string array')
                unless ref($updates) eq 'ARRAY' && @$updates && !grep { ref($_) } @$updates;
            $sql .= $self->_compile_upsert_clause($conflict, $updates);
        }
        return $self->_append_returning($sql, \@params, $command);
    }
    if ($operation eq 'update') {
        my @fields = sort keys %$assignments;
        Selecto::Error->throw('invalid_write', 'update requires assignments') unless @fields;
        my @params;
        my @set = map {
            push @params, $assignments->{$_};
            $self->quote_identifier(_checked_identifier($_)) . ' = ' . $self->placeholder(scalar @params)
        } @fields;
        my $predicate = $self->_compile_write_predicate(
            Selecto::QueryEnforcement::combine(
                $command->predicate,
                $command->scope_predicate,
                defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
            ),
            \@params,
        );
        return $self->_append_returning('UPDATE ' . $self->quote_identifier($relation) . ' SET ' . join(', ', @set) . " WHERE $predicate", \@params, $command);
    }
    if ($operation eq 'delete') {
        my @params;
        my $predicate = $self->_compile_write_predicate(
            Selecto::QueryEnforcement::combine(
                $command->predicate,
                $command->scope_predicate,
                defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
            ),
            \@params,
        );
        return $self->_append_returning('DELETE FROM ' . $self->quote_identifier($relation) . " WHERE $predicate", \@params, $command);
    }
    Selecto::Error->throw('invalid_write', "unsupported operation $operation");
}

sub _append_returning {
    my ($self, $sql, $params, $command) = @_;
    my $returning = $command->metadata->{returning} // [];
    Selecto::Error->throw('invalid_write', 'returning must be an array of declared identifiers')
        unless ref($returning) eq 'ARRAY' && !grep { ref($_) || !defined($_) || !_checked_identifier($_) } @$returning;
    if (@$returning) {
        Selecto::Error->throw('write_capability_missing', 'adapter does not support returning')
            unless $self->write_capabilities->{returning};
        $sql .= ' RETURNING ' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @$returning);
    }
    return { sql => $sql, params => $params, returning => [@$returning] };
}

sub _compile_write_predicate {
    my ($self, $expression, $params) = @_;
    Selecto::Error->throw('invalid_write', 'write predicate is required')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/) {
        my $field = _write_field($arguments->[0]);
        push @$params, _write_literal($arguments->[1]);
        my $operator = { eq => '=', ne => '<>', gt => '>', gte => '>=', lt => '<', lte => '<=' }->{$kind};
        return $self->quote_identifier($field) . " $operator " . $self->placeholder(scalar @$params);
    }
    if ($kind eq 'is_null' || $kind eq 'not_null') {
        my $operator = $kind eq 'is_null' ? 'IS NULL' : 'IS NOT NULL';
        return $self->quote_identifier(_write_field($arguments->[0])) . " $operator";
    }
    if ($kind eq 'in') {
        my $values = $arguments->[1];
        Selecto::Error->throw('query_rule_unsupported_predicate', 'query-enforced IN requires values')
            unless ref($values) eq 'ARRAY' && @$values;
        my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
        return $self->quote_identifier(_write_field($arguments->[0])) . ' IN (' . join(', ', @markers) . ')';
    }
    if ($kind eq 'and' || $kind eq 'or') {
        my $nested = $arguments->[0];
        Selecto::Error->throw('query_rule_unsupported_predicate', 'boolean write predicate requires expressions')
            unless ref($nested) eq 'ARRAY' && @$nested;
        my $operator = $kind eq 'and' ? ' AND ' : ' OR ';
        return join($operator, map { '(' . $self->_compile_write_predicate($_, $params) . ')' } @$nested);
    }
    return 'NOT (' . $self->_compile_write_predicate($arguments->[0], $params) . ')' if $kind eq 'not';
    Selecto::Error->throw('query_rule_unsupported_predicate', 'predicate is outside the portable write subset');
}

sub _write_field {
    my ($expression) = @_;
    Selecto::Error->throw('query_rule_unsupported_predicate', 'portable write predicate requires a field')
        unless blessed($expression) && $expression->kind eq 'field';
    my $field = $expression->arguments->[0];
    Selecto::Error->throw('query_rule_unsupported_field', 'association fields are not portable write guards')
        if $field =~ /\./;
    return _checked_identifier($field);
}

sub _write_literal {
    my ($expression) = @_;
    Selecto::Error->throw('query_rule_unsupported_predicate', 'portable comparison requires a literal value')
        unless blessed($expression) && $expression->kind eq 'literal';
    return $expression->arguments->[0];
}

sub _execute_compiled_write_in_transaction {
    my ($self, $command, $compiled) = @_;
    my ($sth, $affected, %values);
    my $ok = eval {
        $sth = $self->{dbh}->prepare($compiled->{sql});
        $sth->execute(@{$compiled->{params}});
        $affected = $self->_logical_affected_rows($command->operation, 0 + $sth->rows);
        if (@{$compiled->{returning} // []}) {
            my @row = $sth->fetchrow_array;
            Selecto::Error->throw('write_returning_missing', 'write did not return the requested row') unless @row;
            @values{@{$compiled->{returning}}} = @row;
        }
        1;
    };
    die $self->normalize_error($@) unless $ok;
    if (defined($command->expected_count) && $affected != $command->expected_count) {
        Selecto::Error->throw('cardinality_mismatch', 'write affected an unexpected number of rows', {
            expected => $command->expected_count,
            actual => $affected,
        });
    }
    return Selecto::Write::Result->new(operation => $command->operation, affected_rows => $affected, values => \%values);
}

sub _transaction {
    my ($self, $operation) = @_;
    my $value;
    my $ok = eval {
        $self->{dbh}->begin_work;
        $value = $operation->();
        $self->{dbh}->commit;
        1;
    };
    if (!$ok) {
        my $error = $@;
        eval { $self->{dbh}->rollback };
        die $error;
    }
    return $value;
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    Selecto::Error->throw('invalid_query', 'expression is not supported by this SQL dialect');
}

sub _compile_upsert_clause {
    my ($self, $conflict, $updates) = @_;
    return ' ON CONFLICT (' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @$conflict) .
        ') DO UPDATE SET ' . join(', ', map {
            my $field = _checked_identifier($_);
            $self->quote_identifier($field) . ' = EXCLUDED.' . $self->quote_identifier($field)
        } @$updates);
}

sub _compile_pagination {
    my ($self, $limit, $offset, $ordered) = @_;
    my $sql = '';
    $sql .= ' LIMIT ' . int($limit) if defined $limit;
    $sql .= ' OFFSET ' . int($offset) if defined $offset;
    return $sql;
}

sub _rollup_sort_fix_enabled { return 1; }

sub _logical_affected_rows { return $_[2]; }

sub _column_types { return (); }

sub _decode { return $_[1]; }

sub _checked_identifier {
    my ($value) = @_;
    my $string = defined($value) ? "$value" : '';
    Selecto::Error->throw('invalid_identifier', 'invalid SQL identifier')
        unless $string =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return $string;
}

1;
