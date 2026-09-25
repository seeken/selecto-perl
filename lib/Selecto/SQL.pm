package Selecto::SQL;

use Mojo::Base 'Selecto::Adapter';
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::QueryEnforcement ();
use Selecto::Statement ();
use Selecto::Stream ();
use Selecto::Write ();
use Selecto::Write::Expression ();
use Selecto::Write::Authorization ();

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

# Anonymous DBI parameters are separate occurrences, even when their values
# happen to be equal. Dialects with reusable numbered parameters opt in.
sub _reuses_parameter_identity { return 0; }

sub quote_identifier {
    my ($self, $identifier) = @_;
    my $quoted = defined($identifier) ? "$identifier" : '';
    $quoted =~ s/"/""/g;
    return qq{"$quoted"};
}

sub compile {
    my ($self, $domain, $query) = @_;
    my $operations = $query->set_operations;
    Selecto::Error->throw('invalid_query', 'row locks cannot be combined with set operations')
        if @$operations && defined($query->row_lock);
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
    if (@{$query->members}) {
        require Selecto::QueryMember;
        $query = Selecto::QueryMember->expand($domain, $query);
    }
    local $self->{_root_alias} = $options{root_alias} // 's0';
    local $self->{_timezone} = $query->timezone;
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    my $sources = $self->_query_sources($domain, $query);
    local $self->{_query_sources} = $sources;
    my ($with_sql, $cte_params) = $self->_compile_cte_prefix($query);
    my @params = @$cte_params;
    my @joins;
    my $predicate = Selecto::QueryEnforcement::combine(
        $domain->required_predicate, $query->predicate);
    my @association_paths = $self->_referenced_associations($query, $predicate, $domain);
    my ($join_aliases, $through_aliases) = _association_alias_maps(@association_paths);
    local $self->{_join_aliases} = $join_aliases;
    local $self->{_through_aliases} = $through_aliases;
    $self->_validate_query_aliases($sources, @association_paths);
    $with_sql = $self->_append_values_ctes(
        $with_sql, \@params, $domain, $sources, @association_paths,
    );
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
            my $owner_sql = $self->_qualified(
                $parent_alias, $association->owner_key,
            );
            if (defined($association->values)) {
                my $owner_path = @segments
                    ? join('.', @segments, $association->owner_key)
                    : $association->owner_key;
                $owner_sql = _text_case_sql(
                    $owner_sql,
                    $domain->field_metadata($owner_path)->{text_case},
                );
            }
            my $lateral_lookup = ($association->join_strategy // '') eq 'lateral_lookup';
            Selecto::Error->throw(
                'unsupported_feature',
                'lateral lookup join strategy requires PostgreSQL',
            ) if $lateral_lookup && $self->name ne 'postgresql';
            my $lookup_alias = $lateral_lookup
                ? '__selecto_lookup_' . $target_alias : $target_alias;
            my @target_on = (
                $owner_sql . ' = ' .
                    $self->_qualified($lookup_alias, $association->related_key),
            );
            push @target_on, $self->_constant_join_predicates(
                $lookup_alias, $association->where, \@params
            );
            if (defined $association->source_scope_key) {
                push @target_on,
                    $self->_qualified($parent_alias, $association->source_scope_key) . ' = ' .
                    $self->_qualified($lookup_alias, $association->target_scope_key);
            }
            if ($lateral_lookup) {
                # OFFSET 0 keeps PostgreSQL from flattening this correlated
                # lookup into a join plan that repeatedly scans the relation.
                # It does not limit rows or change the association's cardinality.
                push @joins,
                    $keyword . ' LATERAL (SELECT * FROM ' .
                    $self->_association_source_sql($association) .
                    ' AS ' . $self->quote_identifier($lookup_alias) .
                    ' WHERE ' . join(' AND ', @target_on) .
                    ' OFFSET 0) AS ' . $self->quote_identifier($target_alias) .
                    ' ON TRUE';
            } else {
                push @joins,
                    $keyword . ' ' . $self->_association_source_sql($association) .
                    ' AS ' . $self->quote_identifier($target_alias) .
                    ' ON ' . join(' AND ', @target_on);
            }
        }
    }
    my @columns = map { $self->_selection_name($_) } @$selections;
    my %column_counts;
    $column_counts{$_}++ for @columns;
    my @duplicate_columns = sort grep { $column_counts{$_} > 1 } keys %column_counts;
    Selecto::Error->throw(
        'invalid_query',
        'query selections produce duplicate result column names; provide explicit aliases',
        {columns => \@duplicate_columns},
    ) if @duplicate_columns;

    my $groups = $query->groups;
    local $self->{_group_expression_sql} = {};
    local $self->{_group_expression_params} = \@params;
    if ($self->_reuses_parameter_identity) {
        # Compile governed group expressions before their consumers. This also
        # handles GROUPING before its dimension, unselected sort keys, and a
        # selected expression that contains a grouped expression.
        for my $group (@$groups) {
            my $group_sql = $self->_compile_expression($domain, $group, \@params);
            $self->{_group_expression_sql}{$self->_group_expression_key($domain, $group)} = $group_sql;
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
        my $needs_result_alias = defined($_->alias_name)
            || ($_->kind eq 'field' && $_->arguments->[0] =~ /\./)
            || ($_->kind eq 'field'
                && ref($domain->field_metadata($_->arguments->[0])->{computed}) eq 'HASH');
        $needs_result_alias
            ? $expression_sql . ' AS ' . $self->quote_identifier($columns[$selection_position - 1])
            : $expression_sql
    } @$selections;
    push @joins, @{$self->_compile_cte_joins($domain, $query)};
    push @joins, @{$self->_compile_lateral_joins($domain, $query, \@params)};
    push @joins, @{$self->_compile_json_rowsets($domain, $query, \@params)};
    push @joins, @{$self->_compile_array_rowsets($domain, $query, \@params)};
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
    Selecto::Error->throw('unsupported_feature', 'adapter does not support rollups')
        if $query->grouping_mode eq 'rollup' && !$self->supports('rollup');
    my $group_sql = join(', ', map {
        my $key = _expression_key($_);
        $self->_reuses_parameter_identity && exists($compiled_selections{$key})
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
            my $key = _expression_key($_->[0]);
            my $expression_sql = @$groups && $self->_reuses_parameter_identity && exists($compiled_selections{$key})
                ? $compiled_selections{$key}
                : $self->_compile_expression($domain, $_->[0], \@params);
            $expression_sql . ' ' . uc($_->[1])
        } @$orders);
    }
    $sql .= $self->_compile_pagination(
        $query->limit_value,
        $query->offset_value,
        @$orders ? 1 : 0,
    );
    if (defined($query->row_lock)) {
        Selecto::Error->throw('unsupported_feature', 'adapter does not support row locks')
            unless $self->supports('row_locks');
        Selecto::Error->throw('invalid_query', 'row locks require an ungrouped row query')
            if @$groups;
        $sql .= $self->_compile_row_lock($query->row_lock);
    }
    return Selecto::Statement->new(
        sql => $with_sql . $sql,
        params => \@params,
        columns => \@columns,
        adapter_name => $self->name,
    );
}

sub _association_source_sql {
    my ($self, $association) = @_;
    return $self->quote_identifier($association->table);
}

sub _append_values_ctes {
    my ($self, $with_sql, $params, $domain, $sources, @paths) = @_;
    my (@entries, %seen);
    for my $path (@paths) {
        my $association = $domain->resolve_association($path)->{association};
        my $rows = $association->values;
        next unless defined $rows;
        my $table = $association->table;
        next if $seen{$table}++;
        Selecto::Error->throw(
            'invalid_query',
            "query source $table conflicts with an inline values relation",
        ) if exists $sources->{$table};
        Selecto::Error->throw('unsupported_feature', 'adapter does not support values relations')
            unless $self->supports('cte');
        my $fields = $association->value_fields;
        Selecto::Error->throw('invalid_domain', 'values relation has no fields')
            unless ref($fields) eq 'ARRAY' && @$fields;
        # Bound cells have no type of their own; without a cast the database
        # infers one (PostgreSQL: text), so integers would sort as strings.
        my $field_types = $association->fields;
        my %casts = map {
            my $field = $_;
            my $cast = $self->_values_column_type_sql(
                $field_types->{$field}, [map { $_->{$field} } @$rows],
            );
            defined($cast) ? ($field => $cast) : ();
        } @$fields;
        my @selects;
        for my $row_index (0 .. $#$rows) {
            my $row = $rows->[$row_index];
            my @values;
            for my $field (@$fields) {
                push @$params, $row->{$field};
                my $value = $self->placeholder(scalar @$params);
                $value = 'CAST(' . $value . ' AS ' . $casts{$field} . ')'
                    if exists $casts{$field};
                $value .= ' AS ' . $self->quote_identifier($field)
                    if $row_index == 0;
                push @values, $value;
            }
            push @selects, 'SELECT ' . join(', ', @values);
        }
        push @entries,
            $self->quote_identifier($table) . ' AS (' .
            join(' UNION ALL ', @selects) . ')';
    }
    return $with_sql unless @entries;
    if (length $with_sql) {
        $with_sql =~ s/\s+\z//;
        return $with_sql . ', ' . join(', ', @entries) . ' ';
    }
    return 'WITH ' . join(', ', @entries) . ' ';
}

# Adapter-owned allowlist mapping a declared values column type to a SQL cast
# target. Types outside an adapter's allowlist stay untyped, as before.
sub _values_column_type_sql {
    my ($self, $type, $values) = @_;
    return undef unless defined $type;
    my $cast = $self->_values_cast_types->{lc "$type"};
    return undef unless defined $cast;
    return ref($cast) eq 'CODE' ? $self->$cast($values) : $cast;
}

sub _values_cast_types { return {}; }

# Exact DECIMAL(38, s) target wide enough for every value in the column, for
# dialects whose bare DECIMAL has a small default scale.
sub _values_decimal_sql {
    my ($self, $values) = @_;
    my ($digits, $scale) = (0, 0);
    for my $value (grep { defined } @$values) {
        Selecto::Error->throw('invalid_domain', 'decimal values must be exact base-10 text')
            if ref($value) || "$value" !~ /\A-?\d+(?:\.\d+)?\z/;
        my ($whole, $fraction) = split /\./, "$value", 2;
        $whole =~ s/\A-?0*//;
        $fraction //= '';
        $fraction =~ s/0+\z//;
        $digits = length($whole) if length($whole) > $digits;
        $scale = length($fraction) if length($fraction) > $scale;
    }
    Selecto::Error->throw('unsupported_precision', 'decimal values exceed 38 digits')
        if $digits + $scale > 38;
    return 'DECIMAL(38,' . $scale . ')';
}

sub _shift_placeholders {
    my ($self, $sql, $offset) = @_;
    return $sql unless $offset;
    return $self->_renumber_placeholders($sql, $offset);
}

sub _renumber_placeholders {
    my ($self, $sql, $offset) = @_;
    return $sql;
}

sub _renumber_dollar_placeholders {
    my ($self, $sql, $offset) = @_;
    # Generated identifiers and format literals may themselves contain $1.
    # Only parameter tokens outside quoted SQL are shifted for nested queries.
    $sql =~ s{('(?:''|[^'])*'|"(?:""|[^"])*")|\$(\d+)}{
        defined($1) ? $1 : q{$} . ($2 + $offset)
    }gex;
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
    for my $spec (@{$query->array_rowsets}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $sources{$spec->{name}} = {value => 1, (defined($spec->{ordinality}) ? ($spec->{ordinality} => 1) : ())};
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
            if (defined $spec->{max_depth}) {
                my $max_depth = "$spec->{max_depth}";
                Selecto::Error->throw('invalid_query', 'recursive CTE max_depth must be a positive integer')
                    unless $max_depth =~ /\A[1-9][0-9]*\z/;
                $recursive_join .= ' AND ' . $self->_qualified('p_' . $spec->{name}, $spec->{depth_column}) .
                    ' < ' . $max_depth;
            }
            # ['previous', column] in the member reads the previous level's row,
            # typed from the anchor's selection in the same position.
            local $self->{_previous} = {
                alias => 'p_' . $spec->{name},
                types => $self->_selection_types($spec->{domain}, $spec->{anchor}, $columns),
            };
            local $self->{_recursion_depth} = defined($spec->{max_depth})
                ? {alias => 'p_' . $spec->{name}, column => $spec->{depth_column}} : undef;
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

# Declared or inferred types of a query's selections, keyed by column name.
sub _selection_types {
    my ($self, $domain, $query, $columns) = @_;
    my $selections = $query->selections;
    my %types;
    for my $index (0 .. $#$selections) {
        my $selection = $selections->[$index];
        my $column = $columns->[$index] // next;
        my $kind = $selection->kind;
        if ($kind eq 'field') {
            my $resolved = eval { $domain->resolve($selection->arguments->[0]) };
            $types{$column} = $resolved->{type} if $resolved;
        } elsif ($kind eq 'value') {
            require Selecto::ValueExpression;
            $types{$column} = Selecto::ValueExpression->infer(
                $selection->arguments->[0],
                resolve => sub { return $self->_value_field_type($domain, $_[0]); },
            );
        } elsif ($kind eq 'count' || $kind eq 'count_field' || $kind eq 'count_distinct') {
            $types{$column} = 'integer';
        }
    }
    return \%types;
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
            ' (' . join(', ', map { $self->quote_identifier($_) } @{$spec->{columns}}) . ')' .
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

sub _compile_array_rowsets {
    my ($self, $domain, $query, $params) = @_;
    my $rowsets = $query->array_rowsets;
    return [] unless @$rowsets;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support array rowsets')
        unless $self->supports('array_rowset');
    return [map {
        my $spec = $_;
        $self->_array_element_type($domain, $spec->{source_field}, 'array rowset source');
        $self->_compile_array_rowset_join(
            $spec,
            $self->_compile_expression($domain, Selecto::Expression->field($spec->{source_field}), $params),
        );
    } @$rowsets];
}

sub _compile_array_rowset_join {
    Selecto::Error->throw('unsupported_feature', 'array rowsets are not supported by this SQL dialect');
}

my %ARRAY_ELEMENT_TYPE = map { $_ => 1 } qw(string integer decimal boolean date uuid);

# The declared element type of an array field; array SQL binds values with it.
sub _array_element_type {
    my ($self, $domain, $path, $label) = @_;
    my $resolved = $domain->resolve($path);
    Selecto::Error->throw('invalid_query', "$label must be an array field", {field => "$path"})
        unless lc($resolved->{type} // '') eq 'array';
    my $items = $domain->field_metadata($path)->{items};
    Selecto::Error->throw('invalid_query', "$label must declare its element type (items)", {field => "$path"})
        unless defined($items) && !ref($items) && $ARRAY_ELEMENT_TYPE{$items};
    return "$items";
}

sub _compile_array_predicate {
    Selecto::Error->throw('unsupported_feature', 'array predicates are not supported by this SQL dialect');
}

sub _compile_json_contains {
    Selecto::Error->throw('unsupported_feature', 'JSON containment is not supported by this SQL dialect');
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
        $sth = $self->{dbh}->prepare($self->_query_transport_sql($statement));
        $self->_execute_statement($sth, $statement->params);
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
        $sth = $self->{dbh}->prepare($self->_query_transport_sql($statement));
        eval { $sth->{RowCacheSize} = int($fetch_size) };
        $self->_execute_statement($sth, $statement->params);
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

sub _query_transport_sql { return $_[1]->sql; }
sub _execute_statement { return $_[1]->execute(@{$_[2]}); }

sub preview_write {
    my ($self, $command) = @_;
    my $statement = $self->_compile_write($command);
    return { sql => $statement->{sql}, params => [@{$statement->{params}}] };
}

# Execution requires the engine's authorization for the exact object; see
# Selecto::Write::Authorization. The *_unsafe variants skip domain governance
# and exist for trusted internal tooling and adapter tests only.
sub execute_write {
    my ($self, $command, $authorization) = @_;
    Selecto::Write::Authorization->require_for($command, $authorization);
    return $self->execute_write_unsafe($command);
}

sub execute_batch {
    my ($self, $batch, $authorization) = @_;
    Selecto::Write::Authorization->require_for($batch, $authorization);
    return $self->execute_batch_unsafe($batch);
}

sub execute_graph {
    my ($self, $graph, $authorization) = @_;
    Selecto::Write::Authorization->require_for($graph, $authorization);
    return $self->execute_graph_unsafe($graph);
}

sub execute_write_unsafe {
    my ($self, $command) = @_;
    my $compiled = $self->_compile_write($command);
    return $self->_transaction(sub { return $self->_execute_compiled_write_in_transaction($command, $compiled); });
}

sub execute_batch_unsafe {
    my ($self, $batch) = @_;
    my @commands = @{$batch->commands};
    my @compiled = map { $self->_compile_write($_) } @commands;
    return $self->_transaction(sub {
        my @results = map { $self->_execute_compiled_write_in_transaction($commands[$_], $compiled[$_]) } 0 .. $#commands;
        return \@results;
    });
}

sub execute_graph_unsafe {
    my ($self, $graph) = @_;
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    Selecto::Error->throw('write_capability_missing', 'adapter does not support write graphs')
        unless $self->write_capabilities->{write_graph};

    return $self->_transaction(sub {
        my %results;
        for my $node (@{$graph->nodes}) {
            my $operation = $node->{command}->operation;
            my $assignments = $node->{command}->assignments;
            my @scopes = grep { defined } ($node->{command}->scope_predicate);
            for my $binding (@{$node->{bindings}}) {
                my $source = $results{$binding->{from}};
                Selecto::Error->throw('invalid_write_graph', "graph binding source $binding->{from} is unavailable")
                    unless $source;
                my $values = $source->values;
                Selecto::Error->throw('invalid_write_graph', "graph binding value $binding->{from}.$binding->{key} is unavailable")
                    unless exists $values->{$binding->{key}};
                my $field = $binding->{field};
                my $parent_value = $values->{$binding->{key}};
                # A bound child row belongs to exactly one parent. Update and
                # delete children must address a row already under that
                # parent: the binding confines the WHERE clause and never
                # moves the row by assignment.
                if ($operation eq 'update' || $operation eq 'delete') {
                    Selecto::Error->throw(
                        'write_field_not_writable',
                        "graph child cannot reassign its parent binding field $field",
                        { field => $field, graph_node => $node->{id} },
                    ) if exists $assignments->{$field};
                    push @scopes, Selecto::Expression->eq(
                        Selecto::Expression->field($field),
                        Selecto::Expression->literal($parent_value),
                    );
                    next;
                }
                if ($operation eq 'upsert') {
                    # A conflict must only resolve to a row under the same
                    # parent, so the parent binding joins the conflict target.
                    my $metadata = $node->{command}->metadata;
                    my $conflict = $metadata->{conflict_target};
                    Selecto::Error->throw(
                        'invalid_write_graph',
                        "graph child upsert conflict target must include its parent binding field $field",
                        { field => $field, graph_node => $node->{id} },
                    ) unless ref($conflict) eq 'ARRAY' && grep { !ref($_) && $_ eq $field } @$conflict;
                    my $updates = $metadata->{upsert_update_fields};
                    Selecto::Error->throw(
                        'write_field_not_writable',
                        "graph child upsert cannot update its parent binding field $field",
                        { field => $field, graph_node => $node->{id} },
                    ) if ref($updates) eq 'ARRAY' && grep { !ref($_) && $_ eq $field } @$updates;
                }
                $assignments->{$field} = $parent_value;
                push @scopes, Selecto::Expression->eq(
                    Selecto::Expression->field($binding->{scope_field}),
                    Selecto::Expression->literal($parent_value),
                ) if defined $binding->{scope_field};
            }
            my $command = $node->{command}->with_assignments($assignments);
            $command = $command->with_scope_predicate(
                @scopes == 1 ? $scopes[0] : Selecto::Expression->all(@scopes)
            ) if @scopes;
            my $compiled = $self->_compile_write($command);
            my ($result, $ok);
            $ok = eval {
                $result = $self->_execute_compiled_write_in_transaction(
                    $command, $compiled,
                );
                1;
            };
            die _graph_node_error($self, $@, $node->{id}) unless $ok;
            $results{$node->{id}} = $result;
        }
        my $root = $graph->nodes->[0]{id};
        return Selecto::Write::Graph::Result->new(nodes => \%results, root => $results{$root});
    });
}

sub _graph_node_error {
    my ($self, $error, $node_id) = @_;
    $error = $self->normalize_error($error)
        unless blessed($error) && $error->isa('Selecto::Error');
    my $details = $error->details;
    $details->{graph_node} = "$node_id" unless exists $details->{graph_node};
    return Selecto::Error->new(
        code => $error->code,
        message => $error->message,
        details => $details,
    );
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

sub _group_expression_key {
    my ($self, $domain, $expression) = @_;
    # Formatter implementations temporarily suppress field localization or use
    # another zone. Those are different expressions, as are correlated roots.
    return _value_key([
        "$domain", $self->_root_alias, $self->{_timezone},
        $self->{_suppress_field_timezone} ? 1 : 0, $expression,
    ]);
}

sub _value_key {
    my ($value) = @_;
    return 'u' unless defined $value;
    if (blessed($value) && $value->isa('Selecto::Expression')) {
        return 'e:' . $value->kind . ':' . _value_key($value->arguments);
    }
    return 'b:' . ($value ? 1 : 0)
        if blessed($value) && $value->isa('JSON::PP::Boolean');
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
        return Selecto::Identifier::result_name($field);
    }
    return $expression->kind;
}

sub _compile_expression {
    my ($self, $domain, $expression, $params, $compiled_selections) = @_;
    Selecto::Error->throw('invalid_query', 'expected an expression')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    if (defined($self->{_group_expression_params}) && $self->{_group_expression_params} == $params) {
        my $key = $self->_group_expression_key($domain, $expression);
        return $self->{_group_expression_sql}{$key} if exists $self->{_group_expression_sql}{$key};
    }
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $self->_field_sql($domain, $arguments->[0], $params) if $kind eq 'field';
    if ($kind eq 'recursion_depth') {
        # Internal level counter of a depth-bounded recursive CTE.
        return '1' if $arguments->[0] eq 'seed';
        Selecto::Error->throw('invalid_query', 'recursion depth is available only in a recursive CTE step')
            unless $arguments->[0] eq 'step' && ref($self->{_recursion_depth}) eq 'HASH';
        return '(' . $self->_qualified($self->{_recursion_depth}{alias}, $self->{_recursion_depth}{column}) . ' + 1)';
    }
    if ($kind eq 'value') {
        require Selecto::ValueExpression;
        Selecto::ValueExpression->infer(
            $arguments->[0], resolve => sub { return $self->_value_field_type($domain, $_[0]); },
        );
        return '(' . $self->_compile_value_expression($domain, $arguments->[0], $params) . ')';
    }
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
    if ($kind =~ /\A(?:starts_with|starts_with_ci|text_contains|ends_with)\z/) {
        my $literal = $arguments->[1];
        Selecto::Error->throw('invalid_query', "$kind requires a literal string value")
            unless blessed($literal) && $literal->isa('Selecto::Expression')
            && $literal->kind eq 'literal';
        my $text = $literal->arguments->[0];
        Selecto::Error->throw('invalid_query', "$kind requires a literal string value")
            if !defined($text) || ref($text);
        $text =~ s/([!%_])/!$1/g;
        my $field_sql = $self->_compile_expression($domain, $arguments->[0], $params);
        push @$params, $kind eq 'text_contains' ? "%$text%"
            : $kind eq 'ends_with' ? "%$text" : "$text%";
        return 'LOWER(' . $field_sql . ') LIKE LOWER(' .
            $self->placeholder(scalar @$params) . q{) ESCAPE '!'}
            if $kind eq 'starts_with_ci';
        return $field_sql . ' LIKE ' . $self->placeholder(scalar @$params)
            . q{ ESCAPE '!'};
    }
    if ($kind eq 'between') {
        return $self->_compile_expression($domain, $arguments->[0], $params) . ' BETWEEN ' .
            $self->_compile_expression($domain, $arguments->[1], $params) . ' AND ' .
            $self->_compile_expression($domain, $arguments->[2], $params);
    }
    return $self->_compile_expression($domain, $arguments->[0], $params) . ' IS NULL' if $kind eq 'is_null';
    return $self->_compile_expression($domain, $arguments->[0], $params) . ' IS NOT NULL' if $kind eq 'not_null';
    if ($kind eq 'array_contains' || $kind eq 'array_contained' || $kind eq 'array_overlap') {
        Selecto::Error->throw('unsupported_feature', 'adapter does not support array predicates')
            unless $self->supports('array_predicates');
        my $operand = $arguments->[0];
        Selecto::Error->throw('invalid_query', "$kind requires an array field")
            unless blessed($operand) && $operand->kind eq 'field';
        my $element = $self->_array_element_type($domain, $operand->arguments->[0], "$kind field");
        return $self->_compile_array_predicate(
            $kind, $self->_compile_expression($domain, $operand, $params), $element, $arguments->[1], $params,
        );
    }
    if ($kind eq 'json_contains') {
        Selecto::Error->throw('unsupported_feature', 'adapter does not support JSON containment')
            unless $self->supports('json_contains');
        my $operand = $arguments->[0];
        Selecto::Error->throw('invalid_query', 'json_contains requires a JSON field')
            unless blessed($operand) && $operand->kind eq 'field'
                && ($domain->resolve($operand->arguments->[0])->{type} // '') =~ /\Ajsonb?\z/i;
        push @$params, JSON::PP->new->canonical(1)->encode($arguments->[1]);
        return $self->_compile_json_contains(
            $self->_compile_expression($domain, $operand, $params), $self->placeholder(scalar @$params),
        );
    }
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
            $self->_reuses_parameter_identity && defined($compiled_selections) && exists($compiled_selections->{$key})
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
    if ($kind eq 'true_percentage') {
        my $numerator = $self->_compile_expression($domain, $arguments->[0], $params);
        my $denominator = $self->_compile_expression($domain, $arguments->[0], $params);
        $numerator = "($numerator)" if $arguments->[0]->kind ne 'field';
        return "(100.0 * COUNT(CASE WHEN $numerator = TRUE THEN 1 END) / " .
            "NULLIF(COUNT($denominator), 0))";
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
    return $self->_compile_related_collection_at(
        $domain,
        $expression,
        $params,
        undef,
        $self->_root_alias,
    );
}

sub _compile_related_collection_at {
    my ($self, $domain, $expression, $params, $parent_path, $parent_alias) = @_;
    my ($association_name, $fields, $options) = @{$expression->arguments};
    $options //= {};
    Selecto::Error->throw('invalid_query', 'related collection options are invalid')
        unless ref($options) eq 'HASH'
        && !grep { $_ ne 'filters' && $_ ne 'order_by' && $_ ne 'limit' && $_ ne 'after' && $_ ne 'aggregate' } keys %$options;
    Selecto::Error->throw('invalid_query', 'related collection association is invalid')
        unless defined($association_name) && !ref($association_name)
            && "$association_name" =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
    if (defined $parent_path) {
        my $prefix = "$parent_path.";
        my $relative = index($association_name, $prefix) == 0
            ? substr($association_name, length($prefix)) : '';
        Selecto::Error->throw(
            'invalid_query', 'nested related collections must traverse one child association',
        ) unless $relative =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    }
    else {
        Selecto::Error->throw(
            'invalid_query', 'related collections must start at a direct association',
        ) if $association_name =~ /\./;
    }
    Selecto::Error->throw('invalid_query', 'related collection fields are required')
        unless ref($fields) eq 'ARRAY' && @$fields;
    my $resolved_association = $domain->resolve_association($association_name);
    my $association = $resolved_association->{association};
    Selecto::Error->throw('invalid_query', 'related collections require a to-many association')
        unless $association->cardinality eq 'many';
    my $alias_suffix = $association_name;
    $alias_suffix =~ s/\./_/g;
    my $alias = 'c_' . $alias_suffix;
    my $association_fields = $association->fields;
    my @collection_fields;
    for my $field (@$fields) {
        if (!ref($field)) {
            Selecto::Error->throw('invalid_query', 'related collection field is invalid')
                unless defined($field)
                    && "$field" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
                    && exists $association_fields->{$field};
            push @collection_fields, {
                key => "$field",
                sql => $self->_qualified($alias, $field),
                type => $association_fields->{$field},
            };
            next;
        }
        Selecto::Error->throw('invalid_query', 'related collection field is invalid')
            unless ref($field) eq 'HASH'
                && defined($field->{key}) && !ref($field->{key}) && length("$field->{key}")
                && blessed($field->{expression})
                && $field->{expression}->isa('Selecto::Expression');
        if ($field->{expression}->kind eq 'related_collection') {
            push @collection_fields, {
                key => "$field->{key}",
                sql => $self->_compile_related_collection_at(
                    $domain,
                    $field->{expression},
                    $params,
                    $association_name,
                    $alias,
                ),
            };
            next;
        }
        my @paths = $self->_expression_field_paths($field->{expression});
        Selecto::Error->throw(
            'invalid_query', 'related collection expressions must reference one child field',
        ) unless @paths == 1;
        my $resolved = $domain->resolve($paths[0]);
        Selecto::Error->throw(
            'invalid_query', 'related collection expression belongs to another association',
        ) unless ($resolved->{association_path} // '') eq $association_name;
        local $self->{_join_aliases} = {
            %{$self->{_join_aliases} // {}}, $association_name => $alias,
        };
        push @collection_fields, {
            key => "$field->{key}",
            sql => $self->_compile_expression($domain, $field->{expression}, $params),
            (exists($field->{stringify}) ? (stringify => $field->{stringify}) : ()),
        };
    }

    my $quoted_alias = $self->quote_identifier($alias);
    my $table = $self->quote_identifier($association->table);
    my $related_key = $quoted_alias . '.' . $self->quote_identifier($association->related_key);
    my $owner_key = $self->quote_identifier($parent_alias) . '.' .
        $self->quote_identifier($association->owner_key);
    my $from = "$table AS $quoted_alias";
    my @predicates = ("$related_key = $owner_key");
    if (defined $association->source_scope_key) {
        push @predicates,
            $quoted_alias . '.' . $self->quote_identifier($association->target_scope_key) .
            ' = ' . $self->_qualified($parent_alias, $association->source_scope_key);
    }
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
                ' = ' . $self->_qualified($parent_alias, $through->{source_scope_key});
            push @target_on,
                $quoted_bridge_alias . '.' . $self->quote_identifier($through->{through_scope_key}) .
                ' = ' . $quoted_alias . '.' . $self->quote_identifier($through->{target_scope_key});
        }
        # ON precedes WHERE in the emitted SQL, so bind target predicates first.
        # Do not bind the discarded direct-association predicate for this path.
        push @target_on, $self->_constant_join_predicates(
            $alias, $association->where, $params
        );
        push @predicates, $self->_constant_join_predicates(
            $bridge_alias, $through->{where}, $params
        );
        $from = "$bridge_table AS $quoted_bridge_alias INNER JOIN $table AS $quoted_alias ON " .
            join(' AND ', @target_on);
    } else {
        push @predicates, $self->_constant_join_predicates(
            $alias, $association->where, $params
        );
    }
    my $filters = $options->{filters} // [];
    Selecto::Error->throw('invalid_query', 'related collection filters are invalid')
        unless ref($filters) eq 'ARRAY';
    for my $filter (@$filters) {
        Selecto::Error->throw('invalid_query', 'related collection filter is invalid')
            unless ref($filter) eq 'ARRAY' && @$filter == 2
            && defined($filter->[0]) && !ref($filter->[0])
            && exists($association_fields->{$filter->[0]});
        push @$params, $filter->[1];
        push @predicates,
            $self->_qualified($alias, $filter->[0]) . ' = ' .
            $self->placeholder(scalar @$params);
    }
    my $where = join(' AND ', @predicates);
    if (defined $options->{aggregate}) {
        my $metadata = $association_fields->{$fields->[0]};
        my $type = ref($metadata) eq 'HASH' ? $metadata->{type} : $metadata;
        Selecto::Error->throw('invalid_query', 'related aggregate is invalid')
            unless ($options->{aggregate} eq 'sum' || $options->{aggregate} eq 'count')
            && @collection_fields == 1
            && !ref($fields->[0])
            && defined($type)
            && ($options->{aggregate} eq 'count'
                || "$type" =~ /\A(?:integer|decimal|float|number|numeric)\z/)
            && !@{$options->{order_by} // []}
            && !defined($options->{limit}) && !defined($options->{after});
        return '(SELECT COUNT(' . $collection_fields[0]{sql} .
            ') FROM ' . $from . ' WHERE ' . $where . ')'
            if $options->{aggregate} eq 'count';
        return '(SELECT COALESCE(SUM(' . $collection_fields[0]{sql} .
            '), 0) FROM ' . $from . ' WHERE ' . $where . ')';
    }
    my $orders = $options->{order_by} // [];
    Selecto::Error->throw('invalid_query', 'related collection ordering is invalid')
        unless ref($orders) eq 'ARRAY';
    Selecto::Error->throw(
        'unsupported_feature', 'ordered related collections require a certified dialect',
    ) if @$orders && $self->name ne 'postgresql';
    my @order_sql;
    for my $spec (@$orders) {
        my ($field, $direction) = ref($spec) eq 'ARRAY' ? @$spec : ();
        Selecto::Error->throw('invalid_query', 'related collection ordering is invalid')
            unless ref($spec) eq 'ARRAY' && @$spec == 2
            && defined($field) && !ref($field)
            && exists($association_fields->{$field})
            && defined($direction) && !ref($direction)
            && "$direction" =~ /\A(?:asc|desc)\z/i;
        push @order_sql, $self->_qualified($alias, $field) . ' ' . uc($direction);
    }
    my $order = @order_sql ? join(', ', @order_sql)
        : defined($association->target_primary_key)
            ? $quoted_alias . '.' . $self->quote_identifier($association->target_primary_key)
            : undef;
    my $limit = $options->{limit};
    Selecto::Error->throw('invalid_query', 'per-parent collection cursor requires a limit')
        if defined($options->{after}) && !defined($limit);
    if (defined $limit) {
        Selecto::Error->throw('invalid_query', 'per-parent collection limit is invalid')
            unless !ref($limit) && "$limit" =~ /\A[1-9][0-9]*\z/ && @order_sql;
        Selecto::Error->throw(
            'unsupported_feature', 'per-parent collection limits require PostgreSQL',
        ) unless $self->name eq 'postgresql';
        my $primary_key = $association->target_primary_key;
        Selecto::Error->throw(
            'invalid_query', 'per-parent collection limit requires a target primary key',
        ) unless defined($primary_key) && exists($association_fields->{$primary_key});
        my @stable_orders = map { [$_->[0], lc($_->[1])] } @$orders;
        if (!grep { $_->[0] eq $primary_key } @$orders) {
            push @order_sql, $self->_qualified($alias, $primary_key) . ' ASC';
            push @stable_orders, [$primary_key, 'asc'];
            $order = join(', ', @order_sql);
        }
        if (defined $options->{after}) {
            my $parent_primary_key = defined($parent_path)
                ? $domain->resolve_association($parent_path)->{association}->target_primary_key
                : $domain->primary_key;
            Selecto::Error->throw(
                'invalid_query', 'per-parent collection cursor requires a parent primary key',
            ) unless defined $parent_primary_key;
            my $parent_identity = $self->_qualified($parent_alias, $parent_primary_key);
            $where .= ' AND ' . $self->_related_collection_cursor_predicate(
                $params, $alias, $parent_identity, \@stable_orders, $options->{after}
            );
        }
        $from = '(SELECT ' . $quoted_alias . '.* FROM ' . $from .
            ' WHERE ' . $where . ' ORDER BY ' . $order .
            ' LIMIT ' . int($limit) . ') AS ' . $quoted_alias;
        $where = 'TRUE';
    }
    return $self->_compile_related_collection_sql({
        fields => \@collection_fields,
        quoted_alias => $quoted_alias,
        from => $from,
        where => $where,
        order => $order,
    });
}

sub _related_collection_cursor_predicate {
    my ($self, $params, $alias, $owner_key, $orders, $cursor) = @_;
    Selecto::Error->throw('invalid_query', 'per-parent collection cursor is invalid')
        unless ref($cursor) eq 'HASH' && keys(%$cursor) == 2
        && exists($cursor->{parent_key}) && exists($cursor->{values})
        && defined($cursor->{parent_key}) && !ref($cursor->{parent_key})
        && ref($cursor->{values}) eq 'ARRAY'
        && @{$cursor->{values}} == @$orders
        && !grep { ref($_) } @{$cursor->{values}};

    push @$params, $cursor->{parent_key};
    my $parent_marker = $self->placeholder(scalar @$params);
    my @terms;
    for my $index (0 .. $#$orders) {
        my @prefix;
        for my $prior (0 .. $index - 1) {
            my $column = $self->_qualified($alias, $orders->[$prior][0]);
            my $value = $cursor->{values}[$prior];
            if (defined $value) {
                push @$params, $value;
                push @prefix, $column . ' IS NOT DISTINCT FROM ' .
                    $self->placeholder(scalar @$params);
            }
            else {
                push @prefix, $column . ' IS NULL';
            }
        }
        my ($field, $direction) = @{$orders->[$index]};
        my $column = $self->_qualified($alias, $field);
        my $value = $cursor->{values}[$index];
        my $comparison;
        if (!defined $value) {
            $comparison = $direction eq 'desc' ? "$column IS NOT NULL" : 'FALSE';
        }
        else {
            push @$params, $value;
            my $marker = $self->placeholder(scalar @$params);
            $comparison = $direction eq 'desc' ? "$column < $marker"
                : "($column > $marker OR $column IS NULL)";
        }
        push @terms, '(' . join(' AND ', @prefix, $comparison) . ')';
    }
    return '(' . $owner_key . ' IS DISTINCT FROM ' . $parent_marker .
        ' OR (' . join(' OR ', @terms) . '))';
}

sub _related_collection_json_pairs {
    my ($self, $fields, $quoted_alias, $exact_decimals_as_text) = @_;
    return map {
        my $key = $_->{key};
        Selecto::Error->throw('invalid_query', 'related collection key must be an identifier path')
            unless defined($key) && !ref($key)
                && "$key" =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
        my $sql = $self->_related_collection_value_sql($_);
        $sql = "($sql)::text"
            if $exact_decimals_as_text
                && defined($_->{type})
                && $_->{type} =~ /\A(?:decimal|numeric|number)\z/;
        "'$key', $sql"
    } @$fields;
}

sub _related_collection_value_sql {
    my ($self, $field) = @_;
    return $field->{stringify}
        ? $self->_related_collection_text_sql($field->{sql}) : $field->{sql};
}

sub _related_collection_text_sql {
    my ($self, $sql) = @_;
    return "CAST($sql AS TEXT)";
}

sub _expression_field_paths {
    my ($self, $expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    return ($expression->arguments->[0]) if $expression->kind eq 'field';
    my @paths;
    for my $argument (@{$expression->arguments}) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            push @paths, $self->_expression_field_paths($argument);
        } elsif (ref($argument) eq 'ARRAY') {
            push @paths, map { $self->_expression_field_paths($_) } @$argument;
        } elsif (ref($argument) eq 'HASH') {
            push @paths, map { $self->_expression_field_paths($argument->{$_}) }
                sort keys %$argument;
        }
    }
    my %seen;
    return grep { !$seen{$_}++ } @paths;
}

sub _related_collection_aggregate_sql {
    my ($self, $aggregate, $from, $where, $empty) = @_;
    return "COALESCE((SELECT $aggregate FROM $from WHERE $where), $empty)";
}

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    Selecto::Error->throw(
        'unsupported_feature',
        'related collections are not supported by adapter ' . $self->name,
    );
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
    my $sql = $self->quote_identifier($table_alias) . '.' . $self->quote_identifier($resolved->{field});
    my $association = $resolved->{association};
    if ($association
        && $association->join_mode eq 'star_dimension'
        && defined($association->display_fallback)
        && $association->display_fallback eq 'dimension_key'
        && $resolved->{field} eq $association->display_field) {
        my @association_path = split /\./, $resolved->{association_path};
        pop @association_path;
        my $owner_alias = @association_path
            ? $self->_join_alias(join('.', @association_path))
            : $self->_root_alias;
        my $key_sql = $self->quote_identifier($owner_alias) . '.'
            . $self->quote_identifier($association->dimension_key);
        my $key_path = @association_path
            ? join('.', @association_path, $association->dimension_key)
            : $association->dimension_key;
        $key_sql = _text_case_sql(
            $key_sql, $domain->field_metadata($key_path)->{text_case},
        );
        $sql = "COALESCE($sql, $key_sql)";
    }
    return $sql unless defined($self->{_timezone})
        && ($resolved->{type} eq 'utc_datetime' || $resolved->{type} eq 'epoch_datetime')
        && !$self->{_suppress_field_timezone};
    return $self->_compile_timezone_sql(
        $sql, $resolved->{type}, $self->{_timezone}, $params,
    );
}

sub _value_field_type {
    my ($self, $domain, $path) = @_;
    if (ref($path) eq 'ARRAY') {
        my $column = $path->[1];
        my $type = ref($self->{_previous}) eq 'HASH' ? $self->{_previous}{types}{$column} : undef;
        Selecto::Error->throw(
            'invalid_value_expression', 'previous must name a typed column of the recursive member',
            {column => $column},
        ) unless defined $type;
        return $type;
    }
    my @segments = split /\./, "$path", -1;
    if (@segments == 2 && ref($self->{_query_sources}) eq 'HASH'
        && exists($self->{_query_sources}{$segments[0]})) {
        Selecto::Error->throw(
            'invalid_value_expression', 'value expressions may reference only governed domain fields',
            {field => $path},
        );
    }
    return $domain->resolve($path)->{type};
}

sub _text_case_sql {
    my ($sql, $text_case) = @_;
    return "UPPER($sql)" if defined($text_case) && $text_case eq 'uppercase';
    return "LOWER($sql)" if defined($text_case) && $text_case eq 'lowercase';
    return $sql;
}

sub _compile_computed_field {
    my ($self, $domain, $path, $computed, $params) = @_;
    Selecto::Error->throw('invalid_domain', 'unsupported computed field')
        unless $computed->{kind} eq 'association_exists' || $computed->{kind} eq 'predicate'
            || $computed->{kind} eq 'expression' || $computed->{kind} eq 'coalesce_fields';
    if ($computed->{kind} eq 'expression') {
        return '(' . $self->_compile_value_expression($domain, $computed->{expression}, $params) . ')';
    }
    if ($computed->{kind} eq 'coalesce_fields') {
        return 'COALESCE(' . join(', ', map {
            $self->_field_sql($domain, $_, $params)
        } @{$computed->{fields}}) . ')';
    }
    if ($computed->{kind} eq 'predicate') {
        my $expression = Selecto::Expression->from_filter_ast($computed->{expression});
        return '(' . $self->_compile_expression($domain, $expression, $params) . ')';
    }
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

# Compiles a governed value expression (see Selecto::ValueExpression). Every
# literal and JSON path segment is bound; literals are cast to their type.
sub _compile_value_expression {
    my ($self, $domain, $node, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support value expressions')
        unless $self->supports('value_expressions');
    my ($operator, @arguments) = @$node;
    return $self->_field_sql($domain, $arguments[0], $params) if $operator eq 'field';
    if ($operator eq 'previous') {
        Selecto::Error->throw('invalid_value_expression', 'previous is available only in a recursive member step')
            unless ref($self->{_previous}) eq 'HASH'
                && exists $self->{_previous}{types}{$arguments[0]};
        return $self->_qualified($self->{_previous}{alias}, $arguments[0]);
    }
    if ($operator eq 'literal') {
        push @$params, $arguments[0];
        return 'CAST(' . $self->placeholder(scalar @$params) . ' AS '
            . $self->_value_type_sql($arguments[1]) . ')';
    }
    if ($operator eq 'coalesce') {
        return 'COALESCE(' . join(', ', map {
            $self->_compile_value_expression($domain, $_, $params)
        } @arguments) . ')';
    }
    if ($operator eq 'add' || $operator eq 'subtract' || $operator eq 'multiply') {
        my $symbol = {add => '+', subtract => '-', multiply => '*'}->{$operator};
        return '(' . $self->_compile_value_expression($domain, $arguments[0], $params)
            . " $symbol " . $self->_compile_value_expression($domain, $arguments[1], $params) . ')';
    }
    if ($operator eq 'divide') {
        # Division is always decimal: integer operands would otherwise truncate.
        my $decimal = $self->_value_type_sql('decimal');
        return '(CAST(' . $self->_compile_value_expression($domain, $arguments[0], $params)
            . " AS $decimal) / CAST("
            . $self->_compile_value_expression($domain, $arguments[1], $params) . " AS $decimal))";
    }
    if ($operator eq 'lower' || $operator eq 'upper') {
        return uc($operator) . '(' . $self->_compile_value_expression($domain, $arguments[0], $params) . ')';
    }
    if ($operator eq 'concat') {
        my $text = $self->_value_type_sql('string');
        return 'CONCAT(' . join(', ', map {
            'CAST(' . $self->_compile_value_expression($domain, $_, $params) . " AS $text)"
        } @arguments) . ')';
    }
    if ($operator eq 'cast') {
        return 'CAST(' . $self->_compile_value_expression($domain, $arguments[0], $params)
            . ' AS ' . $self->_value_type_sql($arguments[1]) . ')';
    }
    if ($operator eq 'json_text') {
        my $field_sql = $self->_field_sql($domain, $arguments[0], $params);
        return $self->_compile_json_text($field_sql, $arguments[1], $params);
    }
    if ($operator eq 'case') {
        my @parts;
        for my $branch (@arguments) {
            if ($branch->[0] eq 'else') {
                push @parts, 'ELSE ' . $self->_compile_value_expression($domain, $branch->[1], $params);
                next;
            }
            my $condition = Selecto::Expression->from_filter_ast($branch->[0]);
            push @parts, 'WHEN ' . $self->_compile_expression($domain, $condition, $params)
                . ' THEN ' . $self->_compile_value_expression($domain, $branch->[1], $params);
        }
        return 'CASE ' . join(' ', @parts) . ' END';
    }
    Selecto::Error->throw('invalid_query', "unsupported value expression operator $operator");
}

# Adapter-owned allowlist mapping a value type to a SQL cast target.
sub _value_type_sql {
    my ($self, $type) = @_;
    my $cast = $self->_values_cast_types->{lc "$type"};
    Selecto::Error->throw(
        'unsupported_feature', "adapter cannot cast value expressions to $type",
    ) unless defined($cast) && !ref($cast);
    return $cast;
}

sub _compile_json_text {
    Selecto::Error->throw('unsupported_feature', 'adapter does not support JSON text extraction');
}

sub _referenced_associations {
    my ($self, $query, $predicate, $domain) = @_;
    local $self->{_association_domain} = $domain;
    my @expressions = (@{$query->selections});
    push @expressions, $predicate if $predicate;
    push @expressions, @{$query->groups};
    push @expressions, map { $_->[0] } @{$query->orders};
    push @expressions, map {
        Selecto::Expression->field($_->{source_field})
    } @{$query->json_rowsets}, @{$query->array_rowsets};
    my %names;
    $names{$_} = 1 for map { $self->_expression_associations($_, $domain) } @expressions;
    return sort {
        scalar(split(/\./, $a)) <=> scalar(split(/\./, $b)) || $a cmp $b
    } keys %names;
}

sub _expression_associations {
    my ($self, $expression, $domain) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    return () if $expression->kind eq 'related_collection';
    if ($expression->kind eq 'value') {
        require Selecto::ValueExpression;
        return map { $self->_expression_associations(Selecto::Expression->field($_)) }
            Selecto::ValueExpression->dependencies($arguments->[0]);
    }
    if ($expression->kind eq 'field') {
        my @segments = split /\./, $arguments->[0];
        return () if @segments == 2 && ref($self->{_query_sources}) eq 'HASH'
            && exists($self->{_query_sources}{$segments[0]});
        if (@segments == 1) {
            # A computed root field brings the joins its expression reads.
            $domain //= $self->{_association_domain};
            my $computed = $domain ? $domain->field_metadata($segments[0])->{computed} : undef;
            return () unless ref($computed) eq 'HASH';
            if ($computed->{kind} eq 'coalesce_fields') {
                return map {
                    $self->_expression_associations(Selecto::Expression->field($_), $domain)
                } @{$computed->{fields}};
            }
            return () unless $computed->{kind} eq 'expression';
            local $self->{_computed_visiting} = {%{$self->{_computed_visiting} // {}}};
            return () if $self->{_computed_visiting}{$segments[0]}++;
            require Selecto::ValueExpression;
            return map { $self->_expression_associations(Selecto::Expression->field($_), $domain) }
                Selecto::ValueExpression->dependencies($computed->{expression});
        }
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
            push @names, $self->_expression_associations($argument, $domain);
        } elsif (ref($argument) eq 'ARRAY') {
            push @names, map { $self->_expression_associations($_, $domain) } @$argument;
        } elsif (ref($argument) eq 'HASH') {
            push @names, map { $self->_expression_associations($argument->{$_}, $domain) }
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
    my $relation = Selecto::Identifier::checked($command->relation);
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
            ' (' . join(', ', map { $self->quote_identifier(Selecto::Identifier::checked($_)) } @fields) . ')' .
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
            $self->quote_identifier(Selecto::Identifier::checked($_)) . ' = ' .
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
        return $self->quote_identifier(Selecto::Identifier::checked($arguments->[0]));
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
        unless ref($returning) eq 'ARRAY' && !grep { ref($_) || !defined($_) || !Selecto::Identifier::checked($_) } @$returning;
    if (@$returning) {
        Selecto::Error->throw('write_capability_missing', 'adapter does not support returning')
            unless $self->write_capabilities->{returning};
        $sql .= ' RETURNING ' . join(', ', map { $self->_returning_field_sql(Selecto::Identifier::checked($_)) } @$returning);
    }
    return { sql => $sql, params => $params, returning => [@$returning] };
}

sub _returning_field_sql { return $_[0]->quote_identifier($_[1]); }
sub _decode_returning_values { my ($self, $sth, @values) = @_; return @values; }

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
    return Selecto::Identifier::checked($field);
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
        die _dbi_error($self->{dbh}, 'database prepare failed') unless $sth;
        my $executed = $self->_execute_statement($sth, $compiled->{params});
        die _dbi_error($sth, 'database write failed') unless defined $executed;
        if (@{$compiled->{returning} // []}) {
            my @row = $sth->fetchrow_array;
            die _dbi_error($sth, 'database returning fetch failed')
                if !@row && eval { $sth->err };
            Selecto::Error->throw('write_returning_missing', 'write did not return the requested row') unless @row;
            @values{@{$compiled->{returning}}} = $self->_decode_returning_values($sth, @row);
            # RETURNING emits one row per affected row. Some DBI drivers report
            # provisional counts until the result is exhausted. Drain before
             # checking cardinality or committing, retaining only the first row.
             my $returned = 1;
             while (my @remaining = $sth->fetchrow_array) { ++$returned; }
             $affected = $self->_logical_affected_rows($command->operation, $returned);
         } else {
             $affected = $self->_logical_affected_rows($command->operation, 0 + $sth->rows);
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
        my $auto_commit = eval { $self->{dbh}{AutoCommit} };
        if (!defined($auto_commit) || $auto_commit) {
            my $begun = $self->{dbh}->begin_work;
            die _dbi_error($self->{dbh}, 'database transaction could not begin')
                unless $begun;
        }
        $value = $operation->();
        my $committed = $self->{dbh}->commit;
        die _dbi_error($self->{dbh}, 'database transaction could not commit')
            unless $committed;
        1;
    };
    if (!$ok) {
        my $error = $@;
        eval { $self->{dbh}->rollback };
        die $error;
    }
    return $value;
}

sub _dbi_error {
    my ($handle, $fallback) = @_;
    my $message = eval { $handle->errstr };
    return defined($message) && length("$message") ? "$message" : $fallback;
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    Selecto::Error->throw('invalid_query', 'expression is not supported by this SQL dialect');
}

sub _compile_timezone_sql {
    my ($self) = @_;
    Selecto::Error->throw(
        'unsupported_feature', 'adapter does not support explicit query timezones',
    );
}

sub _compile_upsert_clause {
    my ($self, $conflict, $updates) = @_;
    return ' ON CONFLICT (' . join(', ', map { $self->quote_identifier(Selecto::Identifier::checked($_)) } @$conflict) .
        ') DO UPDATE SET ' . join(', ', map {
            my $field = Selecto::Identifier::checked($_);
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

sub _compile_row_lock {
    Selecto::Error->throw('unsupported_feature', 'adapter does not support row locks');
}

sub _rollup_sort_fix_enabled { return 1; }

sub _logical_affected_rows { return $_[2]; }

sub _column_types { return (); }

sub _decode { return $_[1]; }

1;
