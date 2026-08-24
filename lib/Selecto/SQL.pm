package Selecto::SQL;

use Mojo::Base 'Selecto::Adapter';
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();
use Selecto::Statement ();
use Selecto::Stream ();
use Selecto::Write ();
use Selecto::Write::Expression ();

our @FEATURE_INVENTORY = qw(
    cte recursive_cte window_functions set_operations transactions returning rollup stream
    schema_introspection text_search json_rowset lateral_join
);
our %WRITE_CAPABILITIES = map { $_ => 1 } qw(
    insert update upsert delete transactions atomic_batch mutation_expressions
);

has transaction_mode => 'managed';

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
    my $operations = $query->set_operations;
    return $self->_compile_single($domain, $query) unless @$operations;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support set operations')
        unless $self->supports('set_operations');

    my $left = $self->_compile_single($domain, $query->_set_base_query);
    my $sql = $left->sql;
    my @params = @{$left->params};
    my $columns = $left->columns;
    for my $index (0 .. $#$operations) {
        my $operation = $operations->[$index];
        # SQL dialects disagree about compound-query precedence (notably when
        # INTERSECT is mixed with UNION or EXCEPT). Preserve the immutable
        # builder's left-to-right operation order by making each completed
        # compound an explicit derived-table operand before the next edge.
        if ($index > 0) {
            $sql = 'SELECT * FROM (' . $sql . ') AS ' .
                $self->quote_identifier('__selecto_set_left_' . ($index + 1));
        }
        my $right = $self->compile($domain, $operation->{query});
        Selecto::Error->throw(
            'invalid_query',
            'set operation operands must select the same number of columns',
        ) unless @{$right->columns} == @$columns;
        my $right_sql = $self->_shift_placeholders($right->sql, scalar @params);
        if (@{$operation->{query}->set_operations}) {
            $right_sql = 'SELECT * FROM (' . $right_sql . ') AS ' .
                $self->quote_identifier('__selecto_set_right_' . ($index + 1));
        }
        my $keyword = uc($operation->{operation}) . ($operation->{all} ? ' ALL' : '');
        $sql .= " $keyword " . $right_sql;
        push @params, @{$right->params};
    }

    my $orders = $query->orders;
    if (@$orders) {
        my $selections = $query->selections;
        my %positions;
        for my $index (0 .. $#$selections) {
            $positions{_expression_key($selections->[$index])} //= $index + 1;
            $positions{$self->_selection_name($selections->[$index])} //= $index + 1;
        }
        $sql .= ' ORDER BY ' . join(', ', map {
            my $position = $positions{_expression_key($_->[0])};
            $position //= $positions{$self->_selection_name($_->[0])};
            Selecto::Error->throw(
                'invalid_query',
                'set result ordering must reference a selected output column',
            ) unless defined $position;
            $position . ' ' . uc($_->[1]);
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
        columns => $columns,
        adapter_name => $self->name,
    );
}

sub _compile_single {
    my ($self, $domain, $query, %options) = @_;
    local $self->{_root_alias} = $options{root_alias} // 's0';
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    my $sources = $self->_query_sources($domain, $query);
    local $self->{_query_sources} = $sources;
    my ($with_sql, $cte_params) = $self->_compile_cte_prefix($query);
    my @params = @$cte_params;
    my @joins;
    my $predicate = Selecto::QueryEnforcement::combine(
        $domain->required_predicate, $query->predicate);
    my @association_paths = $self->_referenced_associations($query, $predicate);
    my ($join_aliases, $through_aliases) = _association_alias_maps(@association_paths);
    local $self->{_join_aliases} = $join_aliases;
    local $self->{_through_aliases} = $through_aliases;
    $self->_validate_query_aliases($sources, @association_paths);
    for my $path (@association_paths) {
        my $resolved = $domain->resolve_association($path);
        my $association = $resolved->{association};
        my $keyword = $association->join_type eq 'inner' ? 'INNER JOIN' : 'LEFT JOIN';
        my @segments = split /\./, $path;
        pop @segments;
        my $parent_alias = @segments ? $self->_join_alias(join('.', @segments)) : $self->_root_alias;
        my $target_alias = $self->_join_alias($path);
        if (my $through = $association->through) {
            my $bridge_alias = $self->_through_alias($path);
            my @bridge_on = (
                $self->_qualified($parent_alias, $association->owner_key) . ' = ' .
                    $self->_qualified($bridge_alias, $through->{owner_key}),
            );
            my @target_on = (
                $self->_qualified($bridge_alias, $through->{related_key}) . ' = ' .
                    $self->_join_target_key(
                        $self->_qualified($target_alias, $association->related_key),
                        $through->{target_key_cast},
                    ),
            );
            push @bridge_on, $self->_constant_join_predicates(
                $bridge_alias, $through->{where}, \@params
            );
            push @target_on, $self->_constant_join_predicates(
                $target_alias, $association->where, \@params
            );
            if (defined $through->{source_scope_key}) {
                push @bridge_on,
                    $self->_qualified($parent_alias, $through->{source_scope_key}) . ' = ' .
                    $self->_qualified($bridge_alias, $through->{through_scope_key});
                push @target_on,
                    $self->_qualified($bridge_alias, $through->{through_scope_key}) . ' = ' .
                    $self->_qualified($target_alias, $through->{target_scope_key});
            }
            push @joins,
                $keyword . ' (' . $self->quote_identifier($through->{table}) .
                ' AS ' . $self->quote_identifier($bridge_alias) .
                ' INNER JOIN ' . $self->quote_identifier($association->table) .
                ' AS ' . $self->quote_identifier($target_alias) .
                ' ON ' . join(' AND ', @target_on) . ')' .
                ' ON ' . join(' AND ', @bridge_on);
        } else {
            my @target_on = (
                $self->_qualified($parent_alias, $association->owner_key) . ' = ' .
                    $self->_qualified($target_alias, $association->related_key),
            );
            push @target_on, $self->_constant_join_predicates(
                $target_alias, $association->where, \@params
            );
            if (defined $association->source_scope_key) {
                push @target_on,
                    $self->_qualified($parent_alias, $association->source_scope_key) . ' = ' .
                    $self->_qualified($target_alias, $association->target_scope_key);
            }
            push @joins,
                $keyword . ' ' . $self->quote_identifier($association->table) .
                ' AS ' . $self->quote_identifier($target_alias) .
                ' ON ' . join(' AND ', @target_on);
        }
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
    push @joins, @{$self->_compile_cte_joins($domain, $query)};
    push @joins, @{$self->_compile_lateral_joins($domain, $query, \@params)};
    push @joins, @{$self->_compile_json_rowsets($domain, $query, \@params)};
    push @joins, @{$options{extra_joins} // []};
    my $sql = 'SELECT ' . join(', ', @selection_sql) .
        ' FROM ' . $self->quote_identifier($domain->table) . ' AS ' . $self->quote_identifier($self->_root_alias);
    $sql .= ' ' . join(' ', @joins) if @joins;
    my @predicates;
    push @predicates, $self->_compile_expression($domain, $predicate, \@params) if $predicate;
    push @predicates, @{$options{extra_predicates} // []};
    if (@predicates) {
        $sql .= ' WHERE ' . (@predicates == 1
            ? $predicates[0]
            : join(' AND ', map { "($_)" } @predicates));
    }
    my $groups = $query->groups;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support rollups')
        if $query->grouping_mode eq 'rollup' && !$self->supports('rollup');
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
        sql => $with_sql . $sql,
        params => \@params,
        columns => \@columns,
        adapter_name => $self->name,
    );
}

sub _shift_placeholders {
    my ($self, $sql, $offset) = @_;
    return $sql unless $offset && $self->name eq 'postgresql';
    $sql =~ s/\$(\d+)/q{$} . ($1 + $offset)/ge;
    return $sql;
}

sub _query_sources {
    my ($self, $domain, $query) = @_;
    my %sources;
    my $domain_associations = $domain->associations;
    for my $spec (@{$query->ctes}, @{$query->lateral_joins}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $sources{$spec->{name}} = {map { $_ => 1 } @{$spec->{columns}}};
    }
    for my $spec (@{$query->json_rowsets}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $sources{$spec->{name}} = {map { $_ => 1 } keys %{$spec->{columns}}};
    }
    return \%sources;
}

sub _validate_query_aliases {
    my ($self, $sources, @association_paths) = @_;
    my %internal = ($self->_root_alias => 1);
    for my $path (@association_paths) {
        $internal{$self->_join_alias($path)} = 1;
        $internal{$self->_through_alias($path)} = 1;
    }
    for my $name (sort keys %$sources) {
        Selecto::Error->throw(
            'invalid_query',
            "query source $name conflicts with an internal relation alias",
        ) if $internal{$name};
    }
}

sub _compile_cte_prefix {
    my ($self, $query) = @_;
    my $ctes = $query->ctes;
    return ('', []) unless @$ctes;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support CTEs')
        unless $self->supports('cte');
    my (@entries, @params);
    my $recursive = 0;
    for my $spec (@$ctes) {
        my $columns = $spec->{columns};
        my @statements;
        if ($spec->{recursive}) {
            Selecto::Error->throw('unsupported_feature', 'adapter does not support recursive CTEs')
                unless $self->supports('recursive_cte');
            $recursive = 1;
            my $anchor = $self->compile($spec->{domain}, $spec->{anchor});
            my $root_alias = 'r_' . $spec->{name};
            my $join = $spec->{recursive_join};
            $spec->{domain}->resolve($join->{owner_key});
            my $recursive_join = 'INNER JOIN ' . $self->quote_identifier($spec->{name}) .
                ' AS ' . $self->quote_identifier('p_' . $spec->{name}) .
                ' ON ' . $self->_qualified($root_alias, $join->{owner_key}) . ' = ' .
                $self->_qualified('p_' . $spec->{name}, $join->{related_key});
            my $member = $self->_compile_single(
                $spec->{domain}, $spec->{recursive_query},
                root_alias => $root_alias,
                extra_joins => [$recursive_join],
            );
            push @statements, $anchor, $member;
        } else {
            push @statements, $self->compile($spec->{domain}, $spec->{query});
        }
        for my $statement (@statements) {
            Selecto::Error->throw('invalid_query', 'CTE projection width does not match declared columns')
                unless @{$statement->columns} == @$columns;
        }
        my @parts;
        for my $statement (@statements) {
            push @parts, $self->_shift_placeholders($statement->sql, scalar @params);
            push @params, @{$statement->params};
        }
        my $body = join(' UNION ALL ', @parts);
        push @entries,
            $self->quote_identifier($spec->{name}) . ' (' .
            join(', ', map { $self->quote_identifier($_) } @$columns) .
            ") AS ($body)";
    }
    return (
        'WITH ' . ($recursive ? 'RECURSIVE ' : '') . join(', ', @entries) . ' ',
        \@params,
    );
}

sub _compile_cte_joins {
    my ($self, $domain, $query) = @_;
    my @joins;
    for my $spec (@{$query->ctes}) {
        my $join = $spec->{join};
        my $owner = $domain->resolve($join->{owner_key});
        Selecto::Error->throw('invalid_query', 'CTE owner key must be a root field')
            if $owner->{association};
        my $keyword = $join->{type} eq 'inner' ? 'INNER JOIN' : 'LEFT JOIN';
        push @joins,
            $keyword . ' ' . $self->quote_identifier($spec->{name}) .
            ' AS ' . $self->quote_identifier($spec->{name}) .
            ' ON ' . $self->_qualified($self->_root_alias, $join->{owner_key}) . ' = ' .
            $self->_qualified($spec->{name}, $join->{related_key});
    }
    return \@joins;
}

sub _compile_lateral_joins {
    my ($self, $domain, $query, $params) = @_;
    my $laterals = $query->lateral_joins;
    return [] unless @$laterals;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support lateral joins')
        unless $self->supports('lateral_join');
    my @joins;
    for my $spec (@$laterals) {
        my $child_alias = 'l_' . $spec->{name};
        my @correlations;
        for my $child (sort keys %{$spec->{correlations}}) {
            my $parent = $spec->{correlations}{$child};
            my $child_field = $spec->{domain}->resolve($child);
            my $parent_field = $domain->resolve($parent);
            Selecto::Error->throw('invalid_query', 'lateral correlations require root fields')
                if $child_field->{association} || $parent_field->{association};
            push @correlations,
                $self->_qualified($child_alias, $child) . ' = ' .
                $self->_qualified($self->_root_alias, $parent);
        }
        my $statement = $self->_compile_single(
            $spec->{domain}, $spec->{query},
            root_alias => $child_alias,
            extra_predicates => \@correlations,
        );
        Selecto::Error->throw('invalid_query', 'lateral projection width does not match declared columns')
            unless @{$statement->columns} == @{$spec->{columns}};
        my $sql = $self->_shift_placeholders($statement->sql, scalar @$params);
        push @$params, @{$statement->params};
        my $keyword = $spec->{type} eq 'cross' ? 'CROSS JOIN LATERAL'
            : $spec->{type} eq 'inner' ? 'INNER JOIN LATERAL' : 'LEFT JOIN LATERAL';
        push @joins,
            $keyword . ' (' . $sql . ') AS ' . $self->quote_identifier($spec->{name}) .
            ($spec->{type} eq 'cross' ? '' : ' ON TRUE');
    }
    return \@joins;
}

sub _compile_json_rowsets {
    my ($self, $domain, $query, $params) = @_;
    my $rowsets = $query->json_rowsets;
    return [] unless @$rowsets;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support JSON rowsets')
        unless $self->supports('json_rowset');
    return [map {
        $self->_compile_json_rowset_join($domain, $_, $params)
    } @$rowsets];
}

sub _compile_json_rowset_join {
    my ($self, $domain, $spec, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'JSON rowsets are not supported by this SQL dialect');
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

sub stream_query {
    my ($self, $statement, %options) = @_;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support streaming')
        unless $self->supports('stream');
    Selecto::Error->throw('invalid_stream', 'stream_query requires a Selecto statement')
        unless blessed($statement) && $statement->isa('Selecto::Statement');
    my $fetch_size = $options{fetch_size} // 500;
    Selecto::Error->throw('invalid_stream', 'fetch_size must be a positive integer')
        unless defined($fetch_size) && !ref($fetch_size) && "$fetch_size" =~ /\A[1-9]\d*\z/;
    my ($sth, @types);
    my $ok = eval {
        $sth = $self->{dbh}->prepare($statement->sql);
        eval { $sth->{RowCacheSize} = int($fetch_size) };
        $sth->execute(@{$statement->params});
        @types = $self->_column_types($sth);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return Selecto::Stream->new(
        sth => $sth,
        columns => $statement->columns,
        types => \@types,
        decode => sub { return $self->_decode(@_); },
        normalize_error => sub { return $self->normalize_error($_[0]); },
    );
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
    return $self->_field_sql($domain, $arguments->[0], $params) if $kind eq 'field';
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
    return $self->_compile_related_collection($domain, $expression, $params)
        if $kind eq 'related_collection';
    return $self->_compile_window($domain, $expression, $params)
        if $kind eq 'window';
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
            || $kind eq 'epoch_datetime' || $kind eq 'text_search' || $kind eq 'text_rank';
    if ($kind eq 'avg' || $kind eq 'sum' || $kind eq 'min' || $kind eq 'max') {
        return uc($kind) . '(' . $self->_compile_expression($domain, $arguments->[0], $params) . ')';
    }
    if ($kind eq 'sum_zero') {
        return 'SUM(COALESCE(' . $self->_compile_expression($domain, $arguments->[0], $params) . ', 0))';
    }
    Selecto::Error->throw('invalid_query', "unsupported expression $kind");
}

sub _compile_window {
    my ($self, $domain, $expression, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support window functions')
        unless $self->supports('window_functions');
    my ($function, $arguments, $over) = @{$expression->arguments};
    my %functions = map { $_ => 1 } qw(
        row_number rank dense_rank percent_rank cume_dist ntile
        lag lead first_value last_value nth_value
        count sum avg min max
    );
    Selecto::Error->throw('invalid_query', 'window function is not available')
        unless defined($function) && $functions{$function};
    Selecto::Error->throw('invalid_query', 'window arguments must be an array')
        unless ref($arguments) eq 'ARRAY';
    Selecto::Error->throw('invalid_query', 'window specification must be an object')
        unless ref($over) eq 'HASH';
    _validate_window_arity($function, scalar @$arguments);
    my $argument_sql = join(', ', map {
        $self->_compile_expression($domain, $_, $params)
    } @$arguments);
    $argument_sql = '*' if $function eq 'count' && !@$arguments;
    my $call = uc($function) . '(' . $argument_sql . ')';
    my @clauses;
    my $partitions = $over->{partition_by} // [];
    Selecto::Error->throw('invalid_query', 'window partition_by must be an array')
        unless ref($partitions) eq 'ARRAY';
    push @clauses, 'PARTITION BY ' . join(', ', map {
        $self->_compile_expression($domain, $_, $params)
    } @$partitions) if @$partitions;
    my $orders = $over->{order_by} // [];
    Selecto::Error->throw('invalid_query', 'window order_by must be an array')
        unless ref($orders) eq 'ARRAY';
    if (@$orders) {
        push @clauses, 'ORDER BY ' . join(', ', map {
            Selecto::Error->throw('invalid_query', 'window order entry is invalid')
                unless ref($_) eq 'ARRAY' && @$_ == 2
                    && ($_->[1] eq 'asc' || $_->[1] eq 'desc');
            $self->_compile_expression($domain, $_->[0], $params) . ' ' . uc($_->[1]);
        } @$orders);
    }
    push @clauses, $self->_compile_window_frame($over->{frame})
        if exists($over->{frame});
    return $call . ' OVER (' . join(' ', @clauses) . ')';
}

sub _compile_window_frame {
    my ($self, $frame) = @_;
    Selecto::Error->throw('invalid_query', 'window frame must be an object')
        unless ref($frame) eq 'HASH';
    my $type = uc($frame->{type} // 'rows');
    Selecto::Error->throw('invalid_query', 'window frame type must be rows, range, or groups')
        unless $type eq 'ROWS' || $type eq 'RANGE' || $type eq 'GROUPS';
    Selecto::Error->throw('invalid_query', 'window frame requires start and end boundaries')
        unless exists($frame->{start}) && exists($frame->{end});
    my ($start_sql, $start_position) = _window_boundary($frame->{start});
    my ($end_sql, $end_position) = _window_boundary($frame->{end});
    Selecto::Error->throw('invalid_query', 'window frame start must not follow its end')
        if $start_position > $end_position;
    return "$type BETWEEN $start_sql AND $end_sql";
}

sub _validate_window_arity {
    my ($function, $count) = @_;
    my ($minimum, $maximum) = {
        row_number => [0, 0], rank => [0, 0], dense_rank => [0, 0],
        percent_rank => [0, 0], cume_dist => [0, 0], ntile => [1, 1],
        lag => [1, 3], lead => [1, 3], first_value => [1, 1],
        last_value => [1, 1], nth_value => [2, 2], count => [0, 1],
        sum => [1, 1], avg => [1, 1], min => [1, 1], max => [1, 1],
    }->{$function}->@*;
    Selecto::Error->throw(
        'invalid_query',
        "window function $function has an invalid number of arguments",
    ) if $count < $minimum || $count > $maximum;
}

sub _window_boundary {
    my ($boundary) = @_;
    if (!ref($boundary)) {
        my %named = (
            unbounded_preceding => 'UNBOUNDED PRECEDING',
            current_row => 'CURRENT ROW',
            unbounded_following => 'UNBOUNDED FOLLOWING',
        );
        if (defined($boundary) && exists($named{$boundary})) {
            my %positions = (
                unbounded_preceding => -9e99,
                current_row => 0,
                unbounded_following => 9e99,
            );
            return ($named{$boundary}, $positions{$boundary});
        }
    }
    if (ref($boundary) eq 'HASH' && keys(%$boundary) == 1) {
        for my $direction (qw(preceding following)) {
            next unless exists $boundary->{$direction};
            my $count = $boundary->{$direction};
            Selecto::Error->throw('invalid_query', 'window frame offset must be a non-negative integer')
                unless defined($count) && !ref($count) && "$count" =~ /\A\d+\z/;
            my $position = $direction eq 'preceding' ? -int($count) : int($count);
            return (int($count) . ' ' . uc($direction), $position);
        }
    }
    Selecto::Error->throw('invalid_query', 'window frame boundary is invalid');
}

sub _compile_related_collection {
    my ($self, $domain, $expression, $params) = @_;
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
    my $owner_key = $self->quote_identifier($self->_root_alias) . '.' .
        $self->quote_identifier($association->owner_key);
    my $from = "$table AS $quoted_alias";
    my @predicates = ("$related_key = $owner_key");
    if (defined $association->source_scope_key) {
        push @predicates,
            $quoted_alias . '.' . $self->quote_identifier($association->target_scope_key) .
            ' = ' . $self->_qualified($self->_root_alias, $association->source_scope_key);
    }
    push @predicates, $self->_constant_join_predicates(
        $alias, $association->where, $params
    );
    if (my $through = $association->through) {
        my $bridge_alias = 'ct_' . $association_name;
        my $quoted_bridge_alias = $self->quote_identifier($bridge_alias);
        my $bridge_table = $self->quote_identifier($through->{table});
        my @target_on = (
            $quoted_bridge_alias . '.' . $self->quote_identifier($through->{related_key}) .
            ' = ' . $self->_join_target_key($related_key, $through->{target_key_cast}),
        );
        @predicates = (
            $quoted_bridge_alias . '.' . $self->quote_identifier($through->{owner_key}) .
            ' = ' . $owner_key,
        );
        if (defined $through->{source_scope_key}) {
            push @predicates,
                $quoted_bridge_alias . '.' . $self->quote_identifier($through->{through_scope_key}) .
                ' = ' . $self->_qualified($self->_root_alias, $through->{source_scope_key});
            push @target_on,
                $quoted_bridge_alias . '.' . $self->quote_identifier($through->{through_scope_key}) .
                ' = ' . $quoted_alias . '.' . $self->quote_identifier($through->{target_scope_key});
        }
        push @predicates, $self->_constant_join_predicates(
            $bridge_alias, $through->{where}, $params
        );
        push @target_on, $self->_constant_join_predicates(
            $alias, $association->where, $params
        );
        $from = "$bridge_table AS $quoted_bridge_alias INNER JOIN $table AS $quoted_alias ON " .
            join(' AND ', @target_on);
    }
    my $where = join(' AND ', @predicates);
    my $order = defined($association->target_primary_key)
        ? $quoted_alias . '.' . $self->quote_identifier($association->target_primary_key)
        : undef;
    my $adapter = $self->name;

    if ($adapter eq 'mssql') {
        my $projection = join(', ', map {
            $quoted_alias . '.' . $self->quote_identifier($_) . ' AS ' .
                $self->quote_identifier($_)
        } @$fields);
        return "COALESCE((SELECT $projection FROM $from " .
            "WHERE $where" .
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
    return "COALESCE((SELECT $aggregate FROM $from " .
        "WHERE $where), $empty)";
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
    my ($self, $domain, $path, $params) = @_;
    my @segments = split /\./, "$path", -1;
    if (@segments == 2 && ref($self->{_query_sources}) eq 'HASH'
        && exists($self->{_query_sources}{$segments[0]})) {
        Selecto::Error->throw('unknown_field', "unknown query-source field $path")
            unless $self->{_query_sources}{$segments[0]}{$segments[1]};
        return $self->_qualified($segments[0], $segments[1]);
    }
    my $resolved = $domain->resolve($path);
    if (!$resolved->{association}) {
        my $metadata = $domain->field_metadata($path);
        if (ref($metadata->{computed}) eq 'HASH') {
            return $self->_compile_computed_field(
                $domain, $path, $metadata->{computed}, $params
            );
        }
    }
    my $table_alias = $resolved->{association}
        ? $self->_join_alias($resolved->{association_path})
        : $self->_root_alias;
    return $self->quote_identifier($table_alias) . '.' . $self->quote_identifier($resolved->{field});
}

sub _compile_computed_field {
    my ($self, $domain, $path, $computed, $params) = @_;
    Selecto::Error->throw('invalid_domain', 'unsupported computed field')
        unless $computed->{kind} eq 'association_exists';
    my $association_name = $computed->{association};
    my $association = $domain->associations->{$association_name};
    Selecto::Error->throw('invalid_domain', 'computed field association is unavailable', {
        field => $path, association => $association_name,
    }) unless $association && !$association->through;
    my $alias = 'e_' . $association_name;
    my @predicates = (
        $self->_qualified($alias, $association->related_key) . ' = ' .
            $self->_qualified($self->_root_alias, $association->owner_key),
    );
    if (defined $association->source_scope_key) {
        push @predicates,
            $self->_qualified($alias, $association->target_scope_key) . ' = ' .
            $self->_qualified($self->_root_alias, $association->source_scope_key);
    }
    push @predicates, $self->_constant_join_predicates(
        $alias, $association->where, $params
    );
    return 'EXISTS (SELECT 1 FROM ' . $self->quote_identifier($association->table) .
        ' AS ' . $self->quote_identifier($alias) . ' WHERE ' .
        join(' AND ', @predicates) . ')';
}

sub _referenced_associations {
    my ($self, $query, $predicate) = @_;
    my @expressions = (@{$query->selections});
    push @expressions, $predicate if $predicate;
    push @expressions, @{$query->groups};
    push @expressions, map { $_->[0] } @{$query->orders};
    push @expressions, map {
        Selecto::Expression->field($_->{source_field})
    } @{$query->json_rowsets};
    my %names;
    $names{$_} = 1 for map { $self->_expression_associations($_) } @expressions;
    return sort {
        scalar(split(/\./, $a)) <=> scalar(split(/\./, $b)) || $a cmp $b
    } keys %names;
}

sub _expression_associations {
    my ($self, $expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    if ($expression->kind eq 'field') {
        my @segments = split /\./, $arguments->[0];
        return () if @segments == 2 && ref($self->{_query_sources}) eq 'HASH'
            && exists($self->{_query_sources}{$segments[0]});
        pop @segments;
        my @paths;
        for my $index (0 .. $#segments) {
            push @paths, join('.', @segments[0 .. $index]);
        }
        return @paths;
    }
    my @names;
    for my $argument (@$arguments) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            push @names, $self->_expression_associations($argument);
        } elsif (ref($argument) eq 'ARRAY') {
            push @names, map { $self->_expression_associations($_) } @$argument;
        } elsif (ref($argument) eq 'HASH') {
            push @names, map { $self->_expression_associations($argument->{$_}) }
                sort keys %$argument;
        }
    }
    return @names;
}

sub _association_alias_maps {
    my @paths = @_;
    my %groups;
    for my $path (@paths) {
        (my $base = $path) =~ s/\./__/g;
        push @{$groups{$base}}, $path;
    }
    my (%joins, %through);
    for my $base (keys %groups) {
        my $collides = @{$groups{$base}} > 1;
        for my $path (@{$groups{$base}}) {
            my $suffix = $collides ? _encoded_association_path($path) : $base;
            $joins{$path} = 'j_' . $suffix;
            $through{$path} = 't_' . $suffix;
        }
    }
    return (\%joins, \%through);
}

sub _encoded_association_path {
    my ($path) = @_;
    return 'path' . join('', map { '_' . length($_) . '_' . $_ } split /\./, $path);
}

sub _join_alias {
    my ($self, $path) = @_;
    return $self->{_join_aliases}{$path} if exists($self->{_join_aliases}{$path});
    $path =~ s/\./__/g;
    return 'j_' . $path;
}
sub _through_alias {
    my ($self, $path) = @_;
    return $self->{_through_aliases}{$path} if exists($self->{_through_aliases}{$path});
    $path =~ s/\./__/g;
    return 't_' . $path;
}
sub _root_alias { return $_[0]->{_root_alias} // 's0'; }
sub _join_target_key {
    my ($self, $sql, $cast) = @_;
    return $sql unless defined($cast);
    Selecto::Error->throw('invalid_domain', 'unsupported join target key cast')
        unless $cast eq 'string';
    return "CAST($sql AS VARCHAR)";
}
sub _constant_join_predicates {
    my ($self, $alias, $where, $params) = @_;
    return () unless ref($where) eq 'HASH' && keys %$where;
    my @predicates;
    for my $field (sort keys %$where) {
        my $column = $self->_qualified($alias, $field);
        if (!defined($where->{$field})) {
            push @predicates, "$column IS NULL";
            next;
        }
        push @$params, $where->{$field};
        push @predicates, $column . ' = ' . $self->placeholder(scalar @$params);
    }
    return @predicates;
}
sub _qualified {
    my ($self, $alias, $field) = @_;
    return $self->quote_identifier($alias) . '.' . $self->quote_identifier($field);
}

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
        my $insert_predicate = Selecto::QueryEnforcement::combine(
            $command->predicate,
            $command->scope_predicate,
            defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
        );
        if ($insert_predicate) {
            my $truth = Selecto::QueryEnforcement::evaluate(
                $insert_predicate,
                $self->_insert_candidate($assignments),
            );
            Selecto::Error->throw(
                'query_rule_violation',
                'insert candidate does not satisfy the enforced query',
                { truth_value => $truth },
            ) unless $truth eq 'true';
        }
        my @params;
        my @values = map {
            $self->_compile_assignment_value($assignments->{$_}, \@params, $operation, 1)
        } @fields;
        my $sql = 'INSERT INTO ' . $self->quote_identifier($relation) .
            ' (' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @fields) . ')' .
            ' VALUES (' . join(', ', @values) . ')';
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
            $self->quote_identifier(_checked_identifier($_)) . ' = ' .
                $self->_compile_assignment_value($assignments->{$_}, \@params, $operation, 1)
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

sub _insert_candidate {
    my ($self, $assignments) = @_;
    my %candidate;
    for my $field (keys %$assignments) {
        my $value = $assignments->{$field};
        if (blessed($value) && $value->isa('Selecto::Write::Expression')) {
            next unless $value->kind eq 'literal';
            $candidate{$field} = $value->arguments->[0];
        } else {
            $candidate{$field} = $value;
        }
    }
    return \%candidate;
}

sub _compile_assignment_value {
    my ($self, $value, $params, $operation, $top_level) = @_;
    unless (blessed($value) && $value->isa('Selecto::Write::Expression')) {
        push @$params, $value;
        return $self->placeholder(scalar @$params);
    }
    return $self->_compile_mutation_expression($value, $params, $operation, $top_level);
}

sub _compile_mutation_expression {
    my ($self, $expression, $params, $operation, $top_level) = @_;
    Selecto::Error->throw('invalid_write', 'invalid mutation expression')
        unless blessed($expression) && $expression->isa('Selecto::Write::Expression');
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind eq 'literal') {
        push @$params, $arguments->[0];
        return $self->placeholder(scalar @$params);
    }
    return 'CURRENT_TIMESTAMP' if $kind eq 'current_timestamp';
    if ($kind eq 'default') {
        Selecto::Error->throw('invalid_write', 'DEFAULT must be a complete assignment value')
            unless $top_level;
        return $self->_compile_mutation_default($operation);
    }
    if ($kind eq 'field') {
        Selecto::Error->throw(
            'invalid_write',
            'mutation field references are supported only by update assignments',
        ) unless $operation eq 'update';
        return $self->quote_identifier(_checked_identifier($arguments->[0]));
    }
    if ($kind =~ /\A(?:add|subtract|multiply|divide)\z/) {
        my $operator = {
            add => '+', subtract => '-', multiply => '*', divide => '/',
        }->{$kind};
        return '(' . $self->_compile_mutation_expression($arguments->[0], $params, $operation, 0) .
            " $operator " . $self->_compile_mutation_expression($arguments->[1], $params, $operation, 0) . ')';
    }
    if ($kind eq 'coalesce') {
        return 'COALESCE(' . join(', ', map {
            $self->_compile_mutation_expression($_, $params, $operation, 0)
        } @{$arguments->[0]}) . ')';
    }
    Selecto::Error->throw('invalid_write', "unsupported mutation expression $kind");
}

sub _compile_mutation_default {
    my ($self, $operation) = @_;
    Selecto::Error->throw('invalid_write', 'DEFAULT is not valid for this write operation')
        unless $operation eq 'insert' || $operation eq 'upsert' || $operation eq 'update';
    return 'DEFAULT';
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
    my $mode = $self->transaction_mode;
    Selecto::Error->throw('invalid_adapter', 'transaction_mode must be managed or external')
        unless defined($mode) && ($mode eq 'managed' || $mode eq 'external');
    if ($mode eq 'external') {
        my $auto_commit = eval { $self->{dbh}{AutoCommit} };
        Selecto::Error->throw(
            'invalid_adapter',
            'external transaction mode requires AutoCommit to be disabled',
        ) unless defined($auto_commit) && !$auto_commit;
        return $operation->();
    }
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
