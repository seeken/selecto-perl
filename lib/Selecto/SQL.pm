package Selecto::SQL;

use Mojo::Base 'Selecto::Adapter';
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();
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
    for my $name ($self->_referenced_associations($query)) {
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
    my @selection_sql = map {
        my $expression_sql = $self->_compile_expression($domain, $_, \@params);
        $compiled_selections{_expression_key($_)} //= $expression_sql;
        defined($_->alias_name)
            ? $expression_sql . ' AS ' . $self->quote_identifier($_->alias_name)
            : $expression_sql
    } @$selections;
    my @columns = map { $self->_selection_name($_) } @$selections;
    my $sql = 'SELECT ' . join(', ', @selection_sql) .
        ' FROM ' . $self->quote_identifier($domain->table) . ' AS ' . $self->quote_identifier('s0');
    $sql .= ' ' . join(' ', @joins) if @joins;
    $sql .= ' WHERE ' . $self->_compile_expression($domain, $query->predicate, \@params) if $query->predicate;
    my $groups = $query->groups;
    $sql .= ' GROUP BY ' . join(', ', map {
        my $key = _expression_key($_);
        exists($compiled_selections{$key})
            ? $compiled_selections{$key}
            : $self->_compile_expression($domain, $_, \@params)
    } @$groups) if @$groups;
    my $orders = $query->orders;
    $sql .= ' ORDER BY ' . join(', ', map {
        $self->_compile_expression($domain, $_->[0], \@params) . ' ' . uc($_->[1])
    } @$orders) if @$orders;
    $sql .= ' LIMIT ' . $query->limit_value if defined $query->limit_value;
    $sql .= ' OFFSET ' . $query->offset_value if defined $query->offset_value;
    return Selecto::Statement->new(
        sql => $sql,
        params => \@params,
        columns => \@columns,
        adapter_name => $self->name,
    );
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
    return $self->_transaction(sub { return $self->_execute_write_in_transaction($command); });
}

sub execute_batch {
    my ($self, $batch) = @_;
    return $self->_transaction(sub {
        my @results = map { $self->_execute_write_in_transaction($_) } @{$batch->commands};
        return \@results;
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
    my ($self, $domain, $expression, $params) = @_;
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
    if ($kind eq 'and') {
        my $expressions = $arguments->[0];
        Selecto::Error->throw('invalid_query', 'AND requires expressions')
            unless ref($expressions) eq 'ARRAY' && @$expressions;
        return join(' AND ', map { '(' . $self->_compile_expression($domain, $_, $params) . ')' } @$expressions);
    }
    return 'COUNT(*)' if $kind eq 'count';
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
        if $kind eq 'count_bucket' || $kind eq 'bucket' || $kind eq 'datetime_format';
    if ($kind eq 'avg' || $kind eq 'sum' || $kind eq 'min' || $kind eq 'max') {
        return uc($kind) . '(' . $self->_compile_expression($domain, $arguments->[0], $params) . ')';
    }
    if ($kind eq 'sum_zero') {
        return 'SUM(COALESCE(' . $self->_compile_expression($domain, $arguments->[0], $params) . ', 0))';
    }
    Selecto::Error->throw('invalid_query', "unsupported expression $kind");
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
    my ($self, $query) = @_;
    my @expressions = (@{$query->selections});
    push @expressions, $query->predicate if $query->predicate;
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
        my @fields = sort keys %$assignments;
        Selecto::Error->throw('invalid_write', 'insert requires assignments') unless @fields;
        my @params = map { $assignments->{$_} } @fields;
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
            $sql .= ' ON CONFLICT (' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @$conflict) .
                ') DO UPDATE SET ' . join(', ', map {
                    my $field = _checked_identifier($_);
                    $self->quote_identifier($field) . ' = EXCLUDED.' . $self->quote_identifier($field)
                } @$updates);
        }
        return { sql => $sql, params => \@params };
    }
    if ($operation eq 'update') {
        my @fields = sort keys %$assignments;
        Selecto::Error->throw('invalid_write', 'update requires assignments') unless @fields;
        my @params;
        my @set = map {
            push @params, $assignments->{$_};
            $self->quote_identifier(_checked_identifier($_)) . ' = ' . $self->placeholder(scalar @params)
        } @fields;
        my $predicate = $self->_compile_write_predicate($command->predicate, \@params);
        return { sql => 'UPDATE ' . $self->quote_identifier($relation) . ' SET ' . join(', ', @set) . " WHERE $predicate", params => \@params };
    }
    if ($operation eq 'delete') {
        my @params;
        my $predicate = $self->_compile_write_predicate($command->predicate, \@params);
        return { sql => 'DELETE FROM ' . $self->quote_identifier($relation) . " WHERE $predicate", params => \@params };
    }
    Selecto::Error->throw('invalid_write', "unsupported operation $operation");
}

sub _compile_write_predicate {
    my ($self, $expression, $params) = @_;
    Selecto::Error->throw('invalid_write', 'write predicate is required')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    Selecto::Error->throw('invalid_write', 'only equality write predicates are portable in protocol v1')
        unless $expression->kind eq 'eq'
        && blessed($arguments->[0]) && $arguments->[0]->kind eq 'field'
        && blessed($arguments->[1]) && $arguments->[1]->kind eq 'literal';
    my $field_args = $arguments->[0]->arguments;
    my $literal_args = $arguments->[1]->arguments;
    my $field = _checked_identifier($field_args->[0]);
    push @$params, $literal_args->[0];
    return $self->quote_identifier($field) . ' = ' . $self->placeholder(scalar @$params);
}

sub _execute_write_in_transaction {
    my ($self, $command) = @_;
    my $compiled = $self->_compile_write($command);
    my ($sth, $affected);
    my $ok = eval {
        $sth = $self->{dbh}->prepare($compiled->{sql});
        $sth->execute(@{$compiled->{params}});
        $affected = 0 + $sth->rows;
        1;
    };
    die $self->normalize_error($@) unless $ok;
    if (defined($command->expected_count) && $affected != $command->expected_count) {
        Selecto::Error->throw('cardinality_mismatch', 'write affected an unexpected number of rows', {
            expected => $command->expected_count,
            actual => $affected,
        });
    }
    return Selecto::Write::Result->new(operation => $command->operation, affected_rows => $affected);
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
