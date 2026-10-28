package Selecto::SQL;

use Mojo::Base 'Selecto::Adapter';
use JSON::PP ();
use Cpanel::JSON::XS ();
use B ();
use Digest::SHA qw(sha1_hex);
use Scalar::Util qw(blessed refaddr);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::InsertAdmission ();
use Selecto::OperationBudget ();
use Selecto::QueryEnforcement ();
use Selecto::ConfiguredDomain ();
use Selecto::Statement ();
use Selecto::Stream ();
use Selecto::Write ();
use Selecto::Write::Expression ();
use Selecto::Write::Authorization ();
use Selecto::Write::Capabilities ();
use Selecto::Write::Policy ();

our @FEATURE_INVENTORY = qw(
    cte recursive_cte window_functions set_operations transactions returning rollup stream
    schema_introspection text_search json_rowset lateral_join
);
our %WRITE_CAPABILITIES = map { $_ => 1 } qw(
    insert update upsert delete transactions atomic_batch mutation_expressions
);

has transaction_mode => 'managed';
has 'transaction_handler';
has 'query_budget_progress_handler';

# Mojo::Base copies every constructor argument into the object. Keys with the
# _selecto_ prefix are the adapter's private per-call state (a verified
# session, the compiling engine, the admitted query, a server version cache),
# so a caller can never preset them.
sub new {
    my ($class, @args) = @_;
    my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;
    delete @args{grep { /\A_selecto_/ } keys %args};
    return $class->SUPER::new(%args);
}

sub query_budget_supported {
    require Selecto::QueryBudget;
    return Selecto::QueryBudget->supported($_[0]);
}

sub begin_query_budget {
    my ($self, %options) = @_;
    require Selecto::QueryBudget;
    return Selecto::QueryBudget->begin($self, %options);
}

sub feature_inventory { return [@FEATURE_INVENTORY]; }
sub write_capabilities { return { protocol_version => 1, %WRITE_CAPABILITIES }; }

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
    local $self->{_source_expansions} = $self->{_source_expansions} // {};
    local $self->{_source_budget} = $self->{_source_budget}
        // Selecto::OperationBudget->new(limits => $self->{_selecto_compile_limits}, code => 'invalid_query');
    # Every relation the statement names, as its SQL spells it, collected
    # while compiling (see _note_relation and Selecto::Statement relations).
    my $top = ref($self->{_selecto_relation_sink}) ne 'HASH';
    local $self->{_selecto_relation_sink} = $top ? {} : $self->{_selecto_relation_sink};
    local $self->{_selecto_relation_schemas} = $top ? {} : $self->{_selecto_relation_schemas};
    my $statement = $self->_compile_query($domain, $query);
    $statement->{_selecto_relations} = [sort keys %{$self->{_selecto_relation_sink}}]
        if $top && blessed($statement) && $statement->isa('Selecto::Statement');
    # Selecto::Engine::compile admits these parameters itself, with the same
    # limits, code and label, as soon as this returns.
    $self->admit_parameters(
        Selecto::OperationBudget->new(limits => $self->{_selecto_compile_limits}, code => 'invalid_query'),
        $statement->params, label => 'statement parameter')
        unless _engine_admitted($self, $query);
    return $statement;
}

# True for the exact query Selecto::Engine::compile admitted under the same
# limits immediately before calling compile.
sub _engine_admitted {
    my ($self, $query) = @_;
    my $admitted = $self->{_selecto_admitted_query};
    return ref($admitted) && ref($query) && refaddr($admitted) == refaddr($query) ? 1 : 0;
}

sub _compile_query {
    my ($self, $domain, $query) = @_;
    require Selecto::QueryPolicy;
    $query = $self->_expand_query($domain, $query);
    $query = Selecto::QueryPolicy->apply($domain, $query, $self->{_selecto_compile_limits});
    Selecto::OperationBudget->new(limits => $self->{_selecto_compile_limits}, code => 'invalid_query')->check_tree(
        $query, label => 'query', allowed_classes => [qw(Selecto::Query Selecto::Expression Selecto::Domain Selecto::Domain::Association)],
        allowed_base_classes => ['Selecto::Query'])
        unless _engine_admitted($self, $query);
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
        my @terms = map {
            my $position = $positions{_expression_key($_->[0])};
            $position //= $positions{$self->_selection_name($_->[0])};
            Selecto::Error->throw(
                'invalid_query',
                'set result ordering must reference a selected output column',
            ) unless defined $position;
            [$position, uc($_->[1])];
        } @$orders;
        if ($self->_null_ordered_terms) {
            # Positions cannot carry the NULL-placement key; order the
            # compound as a derived table by its output column names.
            my $set = $self->quote_identifier('__selecto_set');
            $sql = 'SELECT * FROM (' . $sql . ") AS $set ORDER BY " . join(', ', map {
                $self->_null_ordered_term("$set." . $self->quote_identifier($columns->[$_->[0] - 1]), $_->[1])
            } @terms);
        } else {
            $sql .= ' ORDER BY ' . join(', ', map { "$_->[0] $_->[1]" } @terms);
        }
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
    return $self->_compile_retargeted($domain, $query, %options)
        if defined $query->retarget_spec;
    $query = $self->_expand_query($domain, $query);
    return $self->_compile_rollup($domain, $query, %options)
        if $query->grouping_mode eq 'rollup' && $self->_emulates_rollup;
    local $self->{_root_alias} = $options{root_alias} // 's0';
    local $self->{_tenant_root} = $domain;
    local $self->{_timezone} = $query->timezone;
    local $self->{_read_prefix} = $domain->{_read_prefix};
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    my $physical = $self->_physical_relations($domain, $query);
    my %cte_names;
    for my $spec (@{$query->ctes}, @{$query->values_sources}) {
        Selecto::Error->throw('invalid_query', 'CTE source cannot shadow a domain physical relation') if $physical->{lc $spec->{name}};
        Selecto::Error->throw('invalid_query', 'duplicate CTE source') if $cte_names{lc $spec->{name}}++;
    }
    my $sources = $self->_query_sources($domain, $query);
    local $self->{_query_sources} = $sources;
    my ($with_sql, $cte_params) = $self->_compile_cte_prefix($query, $domain);
    my @params = @$cte_params;
    my @joins;
    my $predicate = Selecto::QueryEnforcement::combine(
        $domain->required_predicate, $query->predicate);
    # The top-level eq/IN conjuncts of the host-trusted required predicate
    # decide tenant or scope identity even without a declared tenant_field.
    my @host_trees = $self->_exact_identity_compare ? (grep { defined } $domain->required_predicate,
        @{$self->{_selecto_trusted_predicates} // []}, @{$domain->{_selecto_authored_predicates} // []}) : ();
    local $self->{_selecto_host_conjuncts} = $self->_exact_identity_compare
        ? {map { (refaddr($_) => 1) } _comparison_nodes(@host_trees)} : undef;
    # Every node of those trees: a computed field they reference compiles its
    # own comparisons as host identity too.
    local $self->{_selecto_host_nodes} = $self->_exact_identity_compare
        ? {map { (refaddr($_) => 1) } _expression_nodes(@host_trees)} : undef;
    my @association_paths = $self->_referenced_associations($query, $predicate, $domain);
    my ($join_aliases, $through_aliases) = _association_alias_maps(@association_paths);
    local $self->{_join_aliases} = $join_aliases;
    local $self->{_through_aliases} = $through_aliases;
    $self->_validate_query_aliases($sources, @association_paths);
    $with_sql = $self->_append_values_ctes(
        $with_sql, \@params, $domain, $sources, $physical, \%cte_names, @association_paths,
    );
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
    local $self->{_field_types} = {};
    local $self->{_group_expression_sql} = {};
    local $self->{_group_expression_params} = \@params;
    local $self->{_group_expression_digests} = {};
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
    my @projection;
    my @selection_sql = map {
        $selection_position++;
        my $expression_sql = $self->_compile_selection_expression(
            $domain, $_, \@params, \%compiled_selections, \%options,
        );
        $compiled_selections{_expression_key($_)} //= $expression_sql;
        $selection_positions{_expression_key($_)} //= $selection_position;
        my $needs_result_alias = defined($_->alias_name)
            || ($_->kind eq 'field' && $_->arguments->[0] =~ /\./)
            || ($_->kind eq 'field'
                && ref($domain->_field_metadata_view($_->arguments->[0])->{computed}) eq 'HASH');
        my $item = $needs_result_alias
            ? $expression_sql . ' AS ' . $self->quote_identifier($columns[$selection_position - 1])
            : $expression_sql;
        push @projection, [length($expression_sql), length($item), $self->_canonical_kind($domain, $_)];
        $item
    } @$selections;
    # SELECT placeholders precede JOIN placeholders, including nested joins.
    for my $path (@association_paths) {
        my $resolved = $domain->resolve_association($path);
        local $self->{_selecto_pair_parent_types} = $self->_exact_identity_compare
            ? $self->_association_parent_types($domain, $path) : undef;
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
            # The target ON occurs inside the nested join, before the bridge ON.
            # Accumulate anonymous parameters in that emitted SQL order.
            push @target_on, $self->_constant_join_predicates(
                $target_alias, $association->where, \@params, $association->fields, $association->table
            );
            push @target_on, $self->_tenant_bound_sql($association, $target_alias, \@params);
            push @bridge_on, $self->_constant_join_predicates(
                $bridge_alias, $through->{where}, \@params, undef, $through->{table}
            );
            if (defined $through->{source_scope_key}) {
                my $exact = $self->_association_identity_exact($association, $through->{target_scope_key}, undef);
                push @bridge_on, $self->_identity_equal_sql(
                    $self->_qualified($parent_alias, $through->{source_scope_key}),
                    $self->_qualified($bridge_alias, $through->{through_scope_key}), $exact);
                push @target_on, $self->_identity_equal_sql(
                    $self->_qualified($bridge_alias, $through->{through_scope_key}),
                    $self->_qualified($target_alias, $through->{target_scope_key}), $exact);
            }
            push @bridge_on, $self->_tenant_pair_sql($association, $parent_alias, $target_alias);
            push @joins,
                $keyword . ' (' . $self->_physical_source_sql($through->{table}) .
                ' AS ' . $self->quote_identifier($bridge_alias) .
                ' INNER JOIN ' . $self->_association_source_sql($association) .
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
                    $domain->_field_metadata_view($owner_path)->{text_case},
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
                $lookup_alias, $association->where, \@params, $association->fields, $association->table
            );
            if (defined $association->source_scope_key) {
                push @target_on, $self->_identity_equal_sql(
                    $self->_qualified($parent_alias, $association->source_scope_key),
                    $self->_qualified($lookup_alias, $association->target_scope_key),
                    $self->_association_identity_exact($association, $association->target_scope_key,
                $association->source_scope_key));
            }
            push @target_on, $self->_tenant_pair_sql($association, $parent_alias, $lookup_alias),
                $self->_tenant_bound_sql($association, $lookup_alias, \@params);
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
    push @joins, @{$self->_compile_cte_joins($domain, $query)};
    push @joins, @{$self->_compile_values_joins($domain, $query)};
    push @joins, @{$self->_compile_subquery_joins($domain, $query, \@params)};
    push @joins, @{$self->_compile_function_laterals($query, \@params)};
    push @joins, @{$self->_compile_lateral_joins($domain, $query, \@params)};
    push @joins, @{$self->_compile_json_rowsets($domain, $query, \@params)};
    push @joins, @{$self->_compile_array_rowsets($domain, $query, \@params)};
    push @joins, @{$options{extra_joins} // []};
    my $root_sql = $self->_note_relation($self->_relation_sql($domain->{_read_prefix}, $domain->table));
    my $sql = 'SELECT ' . join(', ', @selection_sql) .
        ' FROM ' . $root_sql . ' AS ' . $self->quote_identifier($self->_root_alias);
    $sql .= ' ' . join(' ', @joins) if @joins;
    my @predicates;
    push @predicates, $self->_compile_expression($domain, $predicate, \@params) if $predicate;
    # An extra predicate is SQL, or a code reference that compiles a nested
    # statement into the parameter list at its position in the WHERE clause.
    push @predicates, map {
        ref($_) eq 'CODE' ? $_->(\@params) : $_
    } @{$options{extra_predicates} // []};
    push @predicates, map {
        ref($_) eq 'HASH'
            ? $self->_identity_correlation_sql($self->_qualified($self->_join_alias($_->{path}), $_->{column}),
                $_->{outer}, $_->{exact})
            : $self->_compile_expression($domain, $_->[0], \@params) . ' = ' . $_->[1]
    } @{$options{correlations} // []};
    if (@predicates) {
        $sql .= ' WHERE ' . (@predicates == 1
            ? $predicates[0]
            : join(' AND ', map { "($_)" } @predicates));
    }
    Selecto::Error->throw('unsupported_feature', 'adapter does not support rollups')
        if $query->grouping_mode eq 'rollup' && !$self->supports('rollup');
    # A member's group key joined to its root as identity groups exactly
    # (dialect hook; plain elsewhere).
    my $byte_groups = $self->{_selecto_group_bytes};
    local $self->{_selecto_group_bytes};
    my $group_sql = join(', ', map {
        my $key = _expression_key($_);
        $self->_reuses_parameter_identity && exists($compiled_selections{$key})
            ? $self->_reused_group_sql($compiled_selections{$key}, $_, $byte_groups)
            : $self->_compile_group_expression($domain, $_, \@params, $byte_groups)
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
    } elsif (@$orders && $self->_null_ordered_terms && @$groups
        && !grep { !exists $selection_positions{_expression_key($_->[0])} } @$orders) {
        # A grouped query's NULL-placement key on a computed group expression
        # is not functionally dependent under ONLY_FULL_GROUP_BY, and an output
        # alias inside it may resolve to a shadowed source column. Order the
        # grouped rows as a derived table by their qualified output columns.
        my $ordered = $self->quote_identifier('__selecto_ordered');
        $sql = 'SELECT * FROM (' . $sql . ") AS $ordered ORDER BY " . join(', ', map {
            $self->_null_ordered_term("$ordered."
                . $self->quote_identifier($columns[$selection_positions{_expression_key($_->[0])} - 1]), uc($_->[1]))
        } @$orders);
    } elsif (@$orders) {
        $sql .= ' ORDER BY ' . join(', ', map {
            my $key = _expression_key($_->[0]);
            my $direction = uc($_->[1]);
            my $expression_sql = @$groups && $self->_reuses_parameter_identity && exists($compiled_selections{$key})
                ? $compiled_selections{$key}
                : $self->_compile_expression($domain, $_->[0], \@params);
            # Anonymous parameters bind by occurrence: the NULL-placement key
            # compiles the expression again rather than repeating its SQL.
            $self->_null_ordered_terms
                ? "($expression_sql IS NULL) $direction, "
                    . $self->_compile_expression($domain, $_->[0], \@params) . " $direction"
                : "$expression_sql $direction";
        } @$orders);
    }
    $sql .= $self->_compile_pagination(
        $query->limit_value,
        $query->offset_value,
        @$orders ? 1 : 0,
    );
    if (defined($query->row_lock)) {
        if ($query->row_lock eq 'update') {
            Selecto::Error->throw('invalid_transaction', 'update locks require a configured engine transaction')
                unless $self->{_selecto_compile_engine};
            require Selecto::Write::Session;
            Selecto::Write::Session->require_live($self->{_selecto_compile_engine});
        }
        Selecto::Error->throw('unsupported_feature', 'adapter does not support row locks')
            unless $self->supports('row_locks');
        Selecto::Error->throw('invalid_query', 'row locks require an ungrouped row query')
            if @$groups;
        $sql .= $self->_compile_row_lock($query->row_lock);
    }
    my $statement = Selecto::Statement->new(
        sql => $with_sql . $sql,
        params => \@params,
        columns => \@columns,
        adapter_name => $self->name,
    );
    # The outermost SELECT list, for dialects that format result values in
    # SQL. A rollup ordered by output position is left out: its ORDER BY
    # would then sort the formatted values.
    $self->_note_projection($statement, start => length($with_sql) + length('SELECT '),
        items => \@projection)
        unless $query->grouping_mode eq 'rollup' && @$orders;
    return $statement;
}

sub _compile_group_expression {
    my ($self, $domain, $expression, $params) = @_;
    return $self->_compile_expression($domain, $expression, $params);
}

# A group key reusing a selection's compiled SQL (dialects with numbered
# parameters); a dialect that groups member keys exactly wraps it.
sub _reused_group_sql { return $_[1]; }

# Whether a member query's groups must group exactly: it has an output
# paired with its root as identity (a join or correlation), however that
# output is spelled (a field, an alias, a value expression). Every text or
# unknown-type group key then groups exactly (dialect hook).
sub _member_group_bytes {
    my ($self, $query, $columns, @paired) = @_;
    return undef unless $self->_exact_identity_compare && @paired && blessed($query) && @{$query->groups};
    return {all => 1};
}

# Dialect hooks for adapters that format result values in SQL.
# _note_projection records where each top-level selection sits in a statement
# compile just built (start offset; per selection, the expression length, the
# item length including any ' AS alias', and its _canonical_kind).
# _canonical_kind names the canonical formatting a selection's declared domain
# type calls for, or undef. The base adapter keeps nothing.
sub _note_projection { return; }

# Dialects whose NULL ordering differs from PostgreSQL's (NULLs last
# ascending, first descending) and that have no NULLS FIRST/LAST order each
# term after an (expression IS NULL) key.
sub _null_ordered_terms { return 0; }

sub _null_ordered_term {
    my ($self, $sql, $direction) = @_;
    return "($sql IS NULL) $direction, $sql $direction";
}
sub _canonical_kind { return undef; }
sub _emulates_rollup { return 0; }

# Dialects that emulate grouping sets may change projections without changing
# the expressions used by WHERE, joins, or GROUP BY in an ordinary branch.
sub _compile_selection_expression {
    my ($self, $domain, $expression, $params, $compiled_selections) = @_;
    return $self->_compile_expression($domain, $expression, $params, $compiled_selections);
}

# A retargeted query compiles on a domain rooted at the target relation. Its
# context is an ordinary query on the original domain, under the original
# required predicate, that selects the target's primary key through the full
# association path; the target rows are those whose key it produces.
sub _compile_retargeted {
    my ($self, $domain, $query, %options) = @_;
    require Selecto::Query;
    require Selecto::Retarget;
    my $spec = $query->retarget_spec;
    my $target = Selecto::Retarget->target($domain, $spec->{path});
    my $engine = $self->{_selecto_compile_engine};
    my $target_domain = Selecto::Retarget->target_domain($domain, $target,
        tenant => ($engine ? $engine->scope->{tenant} : undef));
    my $key = Selecto::Expression->field("$target->{path}.$target->{primary_key}");
    my $context = Selecto::Query->new(
        selections => [$key],
        (defined($spec->{context}) ? (predicate => $spec->{context}) : ()),
    );
    my $outer_alias = $options{root_alias} // 's0';
    my $outer_key = $self->_qualified($outer_alias, $target->{primary_key});
    # The target's key alone does not identify its row when the relation is
    # confined by a tenant field or authored scope columns: the same key can
    # repeat across tenants or scopes. The target row is rebound on its full
    # identity (key, declared tenant_field, and the scope column the last hop
    # pairs on, through a bridge too), NULL-safely, and on dialects whose
    # collations fold text, byte-exactly. Such a retarget correlates through
    # EXISTS whatever its strategy.
    my $association = $target->{association};
    my $through = $association->through;
    my %seen;
    my @identity = grep { defined($_) && !ref($_) && $_ ne $target->{primary_key} && !$seen{$_}++ }
        $association->target_tenant_field,
        ($through ? $through->{target_scope_key} : $association->target_scope_key);
    my $exists = $spec->{strategy} eq 'exists' || @identity;
    my @identity_correlations = map {
        {path => $target->{path}, column => $_, outer => $self->_qualified($outer_alias, $_),
            exact => $self->_association_identity_exact($association, $_)}
    } @identity;
    my $context_predicate = sub {
        my ($params) = @_;
        my $statement = $self->_compile_single(
            $domain, $context,
            root_alias => 'r0',
            ($exists ? (correlations => [[$key, $outer_key], @identity_correlations]) : ()),
        );
        my $sql = $self->_shift_placeholders($statement->sql, scalar @$params);
        push @$params, @{$statement->params};
        return $exists ? "EXISTS ($sql)" : $self->_in_subquery_sql($outer_key, $sql);
    };
    # The last hop's fixed where policy confines which of the target's rows
    # the association reaches, and the key alone does not identify them
    # either: it is applied to the target rows themselves, as on the join
    # (byte-exact on dialects whose collations fold text).
    my $where = $association->where;
    my @policy = ref($where) eq 'HASH' && keys(%$where) ? (sub {
        my ($params) = @_;
        return join(' AND ', $self->_constant_join_predicates($outer_alias, $where, $params, $association->fields, $association->table));
    }) : ();
    return $self->_compile_single(
        $target_domain, $query->_copy(retarget => undef),
        %options,
        extra_predicates => [@{$options{extra_predicates} // []}, @policy, $context_predicate],
    );
}

sub _association_source_sql {
    my ($self, $association) = @_;
    return defined($association->values) ? $self->quote_identifier($association->table)
        : $self->_physical_source_sql($association->table);
}
# Records a relation as the compiled SQL names it (dialect-quoted, with any
# schema prefix) in the current compile's relation list, and returns it.
# Dialect hooks for the comparisons whose operator a database looks up
# implicitly; PostgreSQL writes them with explicit operators (R46/R47).
sub _in_list_sql { my ($self, $operand, $markers) = @_; return "$operand IN (" . join(', ', @$markers) . ')'; }
sub _in_subquery_sql { my ($self, $operand, $sql) = @_; return "$operand IN ($sql)"; }
sub _between_sql { my ($self, $value, $low, $high) = @_; return "$value BETWEEN $low AND $high"; }
sub _distinct_sql {
    my ($self, $left, $right, $not) = @_;
    return "$left IS " . ($not ? 'NOT ' : '') . "DISTINCT FROM $right";
}
sub _like_sql {
    my ($self, $field, $marker, $ci) = @_;
    return $ci ? "LOWER($field) LIKE LOWER($marker) ESCAPE '!'" : "$field LIKE $marker ESCAPE '!'";
}
sub _nullif_sql { my ($self, $value, $null) = @_; return "NULLIF($value, $null)"; }

# A relation as generated SQL names it: under the read prefix (a schema the
# host pinned) when there is one. A dialect may qualify it further
# (PostgreSQL names the schema it resolves to, R23b).
sub _relation_sql {
    my ($self, $prefix, $table) = @_;
    return (defined($prefix) ? $self->quote_identifier($prefix) . '.' : '') . $self->quote_identifier($table);
}

sub _note_relation {
    my ($self, $sql) = @_;
    my $sink = $self->{_selecto_relation_sink};
    $sink->{$sql} = 1 if ref($sink) eq 'HASH' && defined($sql) && !ref($sql);
    return $sql;
}
sub _physical_source_sql {
    my ($self, $table) = @_;
    return $self->_note_relation($self->_relation_sql($self->{_read_prefix}, $table));
}

sub _append_values_ctes {
    my ($self, $with_sql, $params, $domain, $sources, $physical, $cte_names, @paths) = @_;
    my (@entries, %seen);
    for my $path (@paths) {
        my $association = $domain->resolve_association($path)->{association};
        my $rows = $association->values;
        next unless defined $rows;
        my $table = $association->table;
        my $fields = $association->value_fields;
        my $field_types = $association->fields;
        my $payload = {rows => $rows, fields => $fields, types => $field_types};
        my $signature = Selecto::ConfiguredDomain->digest($payload, {});
        if (exists $seen{lc $table}) {
            Selecto::Error->throw('invalid_query', 'inline VALUES sources with the same SQL identity must have identical declarations')
                unless $seen{lc $table} eq $signature;
            next;
        }
        $seen{lc $table} = $signature;
        $self->{_source_budget}->check_tree($payload, label => 'inline VALUES source');
        Selecto::Error->throw(
            'invalid_query',
            "query source $table conflicts with an inline values relation",
        ) if $physical->{lc $table} || $cte_names->{lc $table}
            || grep { lc($_) eq lc($table) } keys %$sources;
        Selecto::Error->throw('unsupported_feature', 'adapter does not support values relations')
            unless $self->supports('cte');
        Selecto::Error->throw('invalid_domain', 'values relation has no fields')
            unless ref($fields) eq 'ARRAY' && @$fields;
        # Bound cells have no type of their own; without a cast the database
        # infers one (PostgreSQL: text), so integers would sort as strings.
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

sub _expand_query {
    my ($self, $domain, $query) = @_;
    require Selecto::QueryBinding;
    if (my $owner = Selecto::QueryBinding->owner($query)) {
        Selecto::QueryBinding->validate($owner, $query);
    }
    return $query unless @{$query->members};
    my $key = refaddr($domain) . ':' . refaddr($query);
    return $self->{_source_expansions}{$key} if exists $self->{_source_expansions}{$key};
    $self->{_source_budget}->consume_count('max_expression_nodes', 1, label => 'named source expansions');
    require Selecto::QueryMember;
    my $engine = Selecto::QueryBinding->owner($query) // $self->{_selecto_compile_engine};
    my $has_set = @{$query->set_operations};
    my $expanded = Selecto::QueryMember->expand($domain, $has_set ? $query->_set_base_query : $query, $engine);
    $expanded = $expanded->_copy(set_operations => $query->set_operations, orders => $query->orders,
        limit_value => $query->limit_value, offset_value => $query->offset_value) if $has_set;
    $self->{_source_budget}->check_tree($expanded, label => 'expanded source query',
        allowed_classes => [qw(Selecto::Query Selecto::Expression Selecto::Domain Selecto::Domain::Association)],
        allowed_base_classes => ['Selecto::Query']);
    return $self->{_source_expansions}{$key} = $expanded;
}

sub _physical_relations {
    my ($self, $domain, $query) = @_;
    my (%physical, %visited);
    my @pending = ([$domain, $query, {}, 0]);
    while (my $entry = shift @pending) {
        my ($current, $intent, $dependencies, $depth) = @$entry;
        $self->{_source_budget}->consume_count('max_expression_nodes', 1, label => 'source proof work');
        $self->{_source_budget}->limits->check_count('max_expression_depth', $depth, 'invalid_query', 'source proof depth');
        my $key = refaddr($current) . ':' . refaddr($intent) . ':' . join(',', sort keys %$dependencies);
        next if $visited{$key}++;
        $intent = $self->_expand_query($current, $intent);
        $physical{lc $current->table} = 1 unless $dependencies->{lc $current->table};
        my @edges = values %{$current->associations};
        while (my $edge = shift @edges) {
            $self->{_source_budget}->consume_count('max_expression_nodes', 1, label => 'association proof work');
            $physical{lc $edge->table} = 1 unless defined $edge->values;
            my $bridge = $edge->through;
            $physical{lc $bridge->{table}} = 1 if $bridge;
            push @edges, values %{$edge->associations};
        }
        my %available;
        for my $spec (@{$intent->ctes}) {
            my $dependencies = $spec->{dependencies} // [];
            Selecto::Error->throw('invalid_query', 'CTE dependencies must name earlier CTEs')
                unless ref($dependencies) eq 'ARRAY' && !grep { ref($_) || !exists($available{lc $_}) } @$dependencies;
            my %authorized = map { (lc($_) => 1) } @$dependencies;
            if ($authorized{lc $spec->{domain}->table}) {
                my @expected = sort @{$available{lc $spec->{domain}->table}};
                my @actual = sort keys %{$spec->{domain}->fields};
                Selecto::Error->throw('invalid_query', 'dependent CTE domain must match the earlier projection')
                    unless join("\0", @expected) eq join("\0", @actual);
            }
            push @pending, map { [$spec->{domain}, $_, \%authorized, $depth + 1] }
                grep { defined } @{$spec}{qw(query anchor recursive_query)};
            $available{lc $spec->{name}} = $spec->{columns};
        }
        push @pending, map { [$_->{domain}, $_->{query}, {}, $depth + 1] }
            (@{$intent->lateral_joins}, @{$intent->subqueries});
        push @pending, map { [$current, $_->{query}, $dependencies, $depth + 1] } @{$intent->set_operations};
    }
    return \%physical;
}

sub _query_sources {
    my ($self, $domain, $query) = @_;
    my %sources;
    my $domain_associations = $domain->associations;
    my $register = sub {
        my ($name, $fields) = @_;
        Selecto::Error->throw('invalid_query', "duplicate query source $name")
            if grep { lc($_) eq lc($name) } keys %sources;
        Selecto::Error->throw('invalid_query', "query source $name conflicts with a domain relationship")
            if grep { lc($_) eq lc($name) } keys %$domain_associations;
        $sources{$name} = $fields;
    };
    for my $spec (grep { defined($_->{join}) } @{$query->ctes}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $register->($spec->{name}, {map { $_ => 1 } @{$spec->{columns}}});
    }
    for my $spec (@{$query->lateral_joins}, @{$query->values_sources}, @{$query->subqueries}, @{$query->function_laterals}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $register->($spec->{name}, {map { $_ => 1 } @{$spec->{columns}}});
    }
    for my $spec (@{$query->json_rowsets}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $register->($spec->{name}, {map { $_ => 1 } keys %{$spec->{columns}}});
    }
    for my $spec (@{$query->array_rowsets}) {
        Selecto::Error->throw('invalid_query', "query source $spec->{name} conflicts with a domain relationship")
            if exists $domain_associations->{$spec->{name}};
        $register->($spec->{name}, {value => 1, (defined($spec->{ordinality}) ? ($spec->{ordinality} => 1) : ())});
    }
    return \%sources;
}

sub _validate_query_aliases {
    my ($self, $sources, @association_paths) = @_;
    my %internal = (lc($self->_root_alias) => 1);
    for my $path (@association_paths) {
        $internal{lc $self->_join_alias($path)} = 1;
        $internal{lc $self->_through_alias($path)} = 1;
    }
    for my $name (sort keys %$sources) {
        Selecto::Error->throw(
            'invalid_query',
            "query source $name conflicts with an internal relation alias",
        ) if $internal{lc $name};
    }
}

sub _compile_cte_prefix {
    my ($self, $query, $root) = @_;
    my $ctes = $query->ctes;
    return ('', []) unless @$ctes || @{$query->values_sources};
    Selecto::Error->throw('unsupported_feature', 'adapter does not support CTEs')
        unless $self->supports('cte');
    my (@entries, @params);
    my $recursive = 0;
    for my $spec (@$ctes) {
        $spec->{domain} = $self->_bounded_source_domain($root, $spec->{domain}, "CTE $spec->{name}");
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
                ' ON ' . $self->_identity_equal_sql($self->_qualified($root_alias, $join->{owner_key}),
                    $self->_qualified('p_' . $spec->{name}, $join->{related_key}),
                    $self->_member_pair_exact([$spec->{domain}, $join->{owner_key}],
                        [undef, $self->_exact_identity_compare ? $self->_cte_column_type($spec, $join->{related_key}) : undef]));
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
            my $join = $spec->{join};
            my $paired = defined($join) && $self->_member_pair_exact([$root, $join->{owner_key}],
                [undef, $self->_cte_column_type($spec, $join->{related_key})]) ? [$join->{related_key}] : [];
            local $self->{_selecto_group_bytes} = $self->_member_group_bytes($spec->{query}, $columns, @$paired);
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
    for my $spec (@{$query->values_sources}) {
        my @rows;
        for my $row (@{$spec->{rows}}) {
            my @cells;
            for my $value (@$row) {
                push @params, $value;
                my $sql = $self->placeholder(scalar @params);
                my $type = _numeric_scalar_type($value);
                $sql = 'CAST(' . $sql . ' AS ' . $self->_values_source_cast_sql($type) . ')' if defined $type;
                push @cells, $sql;
            }
            push @rows, 'SELECT ' . join(', ', @cells);
        }
        push @rows, 'SELECT ' . join(', ', map { 'NULL' } @{$spec->{columns}}) . ' WHERE 1 = 0' unless @rows;
        push @entries, $self->quote_identifier($spec->{name}) . ' ('
            . join(', ', map { $self->quote_identifier($_) } @{$spec->{columns}}) . ') AS ('
            . join(' UNION ALL ', @rows) . ')';
    }
    return (
        'WITH ' . ($recursive ? 'RECURSIVE ' : '') . join(', ', @entries) . ' ',
        \@params,
    );
}

# The cast target of a numeric cell in an inline VALUES source: INTEGER or REAL.
sub _values_source_cast_sql { return $_[1] eq 'INTEGER' ? 'BIGINT' : 'DOUBLE PRECISION'; }

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
        next unless defined $join;
        my $owner = $domain->resolve($join->{owner_key});
        Selecto::Error->throw('invalid_query', 'CTE owner key must be a root field')
            if $owner->{association};
        my $keyword = $join->{type} eq 'inner' ? 'INNER JOIN' : 'LEFT JOIN';
        push @joins,
            $keyword . ' ' . $self->quote_identifier($spec->{name}) .
            ' AS ' . $self->quote_identifier($spec->{name}) .
            ' ON ' . $self->_derived_identity_equal_sql($self->_qualified($self->_root_alias, $join->{owner_key}),
                $self->_qualified($spec->{name}, $join->{related_key}),
                $self->_member_pair_exact([$domain, $join->{owner_key}], [undef, $self->_exact_identity_compare
                    ? $self->_cte_column_type($spec, $join->{related_key}) : undef]));
    }
    return \@joins;
}

# The declared type of a CTE's column, from the selection that produces it
# (a recursive CTE's anchor), or undef.
sub _cte_column_type {
    my ($self, $spec, $column) = @_;
    my $query = $spec->{recursive} ? $spec->{anchor} : $spec->{query};
    return undef unless blessed($query) && blessed($spec->{domain});
    return eval { $self->_selection_types($spec->{domain}, $query, $spec->{columns})->{$column} };
}

sub _compile_values_joins {
    my ($self, $domain, $query) = @_;
    my @joins;
    for my $spec (@{$query->values_sources}) {
        my $join = $spec->{join};
        my $sql = (defined($join) ? uc($join->{type}) . ' JOIN ' : 'CROSS JOIN ')
            . $self->quote_identifier($spec->{name}) . ' AS ' . $self->quote_identifier($spec->{name});
        if ($join) {
            my $owner = $domain->resolve($join->{owner_key});
            Selecto::Error->throw('invalid_query', 'VALUES owner key must be a root field') if $owner->{association};
            $sql .= ' ON ' . $self->_derived_identity_equal_sql($self->_qualified($self->_root_alias, $join->{owner_key}),
                $self->_qualified($spec->{name}, $join->{related_key}),
                $self->_member_pair_exact([$domain, $join->{owner_key}], [undef, undef]));
        }
        push @joins, $sql;
    }
    return \@joins;
}
# Every CTE, lateral and subquery source reads its own relation, so the root's
# trusted tenant boundary is carried onto a tenant-scoped source relation, or
# the source is refused with missing_tenant_scope (lesson 39). Declared members
# arrive already bounded; inline sources are bounded here.
sub _bounded_source_domain {
    my ($self, $root, $source, $label) = @_;
    require Selecto::QueryMember;
    my $engine = $self->{_selecto_compile_engine};
    return Selecto::QueryMember->bound_source_domain($root, $source, label => $label,
        tenant => ($engine ? $engine->scope->{tenant} : undef), allow_prefix => 1);
}
sub _compile_subquery_joins {
    my ($self, $domain, $query, $params) = @_;
    my @joins;
    for my $spec (@{$query->subqueries}) {
        $spec->{domain} = $self->_bounded_source_domain($domain, $spec->{domain}, "subquery $spec->{name}");
        my @paired = map { $_->{right} } grep {
            $self->_member_pair_exact([$domain, $_->{left}], [undef, $self->_exact_identity_compare
                ? $self->_cte_column_type($spec, $_->{right}) : undef])
        } @{$spec->{on} // []};
        my $statement = do {
            local $self->{_selecto_group_bytes} = $self->_member_group_bytes($spec->{query}, $spec->{columns}, @paired);
            $self->compile($spec->{domain}, $spec->{query});
        };
        Selecto::Error->throw('invalid_query', 'subquery projection must match declared columns')
            unless @{$statement->columns} == @{$spec->{columns}}
                && join("\0", @{$statement->columns}) eq join("\0", @{$spec->{columns}});
        my $body = $self->_shift_placeholders($statement->sql, scalar @$params);
        push @$params, @{$statement->params};
        my @on;
        for my $condition (@{$spec->{on}}) {
            my $owner = $domain->resolve($condition->{left});
            Selecto::Error->throw('invalid_query', 'subquery owner key must be a root field') if $owner->{association};
            push @on, $self->_derived_identity_equal_sql($self->_qualified($self->_root_alias, $condition->{left}),
                $self->_qualified($spec->{name}, $condition->{right}),
                $self->_member_pair_exact([$domain, $condition->{left}], [undef, $self->_exact_identity_compare
                    ? $self->_cte_column_type($spec, $condition->{right}) : undef]));
        }
        push @joins, uc($spec->{type}) . ' JOIN (' . $body . ') AS ' . $self->quote_identifier($spec->{name})
            . ' ON ' . join(' AND ', @on);
    }
    return \@joins;
}
sub _compile_function_laterals {
    my ($self, $query, $params) = @_;
    my $plans = $query->function_laterals;
    return [] unless @$plans;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support function lateral sources')
        unless $self->supports('lateral_join');
    my @joins;
    for my $spec (@$plans) {
        my @arguments = map { push @$params, $_; $self->placeholder(scalar @$params) } @{$spec->{arguments}};
        push @joins, uc($spec->{type}) . ' JOIN LATERAL ' . $self->quote_identifier($spec->{function})
            . '(' . join(', ', @arguments) . ') AS ' . $self->quote_identifier($spec->{name})
            . ' (' . join(', ', map { $self->quote_identifier($_) } @{$spec->{columns}}) . ')'
            . ($spec->{type} eq 'cross' ? '' : ' ON TRUE');
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
        $spec->{domain} = $self->_bounded_source_domain($domain, $spec->{domain}, "lateral $spec->{name}");
        my $child_alias = 'l_' . $spec->{name};
        my @correlations;
        for my $child (sort keys %{$spec->{correlations}}) {
            my $parent = $spec->{correlations}{$child};
            my $child_field = $spec->{domain}->resolve($child);
            my $parent_field = $domain->resolve($parent);
            Selecto::Error->throw('invalid_query', 'lateral correlations require root fields')
                if $child_field->{association} || $parent_field->{association};
            push @correlations, $self->_identity_equal_sql($self->_qualified($child_alias, $child),
                $self->_qualified($self->_root_alias, $parent),
                $self->_member_pair_exact([$domain, $parent], [$spec->{domain}, $child]));
        }
        my $paired = grep {
            $self->_member_pair_exact([$domain, $spec->{correlations}{$_}], [$spec->{domain}, $_])
        } keys %{$spec->{correlations}};
        my $statement = do {
            local $self->{_selecto_group_bytes} = $self->_member_group_bytes($spec->{query}, undef, $paired ? ('lateral') : ());
            $self->_compile_single($spec->{domain}, $spec->{query}, root_alias => $child_alias, extra_predicates => \@correlations);
        };
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
    my $items = $domain->_field_metadata_view($path)->{items};
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
    my ($sth, $rows);
    my $ok = eval {
        if ($self->_statement_cache_enabled) {
            $sth = $self->_cached_execute($self->_query_transport_sql($statement), $statement->params,
                'database query failed');
        } else {
            $sth = $self->{dbh}->prepare($self->_query_transport_sql($statement));
            $self->_execute_statement($sth, $statement->params);
        }
        my @types = $self->_column_types($sth);
        $rows = $sth->fetchall_arrayref;
        $self->_decode_rows($rows, \@types);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return { columns => $statement->columns, rows => $rows };
}

# Decodes fetched rows in place, cell for cell as _decode would. An adapter
# whose _decode is the identity skips the walk entirely; adapters may
# override this with a column-wise version that gives the same results.
sub _decode_rows {
    my ($self, $rows, $types) = @_;
    return if $self->can('_decode') == \&_decode;
    for my $row (@$rows) {
        $row->[$_] = $self->_decode($row->[$_], $types->[$_]) for 0 .. $#$row;
    }
    return;
}

sub bounded_stream_supported {
    my ($self) = @_;
    # SQLite steps its VM while fetching; other drivers must provide an
    # adapter-owned implementation rather than relying on RowCacheSize.
    return $self->name eq 'sqlite' && eval { $self->dbh->isa('DBI::db') } ? 1 : 0;
}

sub stream_query {
    my ($self, $statement, %options) = @_;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support streaming')
        unless $self->supports('stream');
    Selecto::Error->throw('invalid_stream', 'stream_query requires a Selecto statement')
        unless blessed($statement) && $statement->isa('Selecto::Statement');
    Selecto::Error->throw('unsupported_feature', 'adapter cannot bound driver result buffering')
        if $options{bounded} && !$self->bounded_stream_supported;
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
        decode => $self->_stream_decoder(%options),
        normalize_error => sub { return $self->normalize_error($_[0]); },
    );
}

# Dialect hook: the per-cell decoder a stream applies.
sub _stream_decoder {
    my ($self) = @_;
    return sub { return $self->_decode(@_); };
}

sub _query_transport_sql { return $_[0]->_statement_sql($_[1]->sql); }

# Dialect hook: the text sent for one library statement (reads, streams,
# writes, probes and re-reads). The default sends it unchanged.
sub _statement_sql { return $_[1]; }
sub _execute_statement { return $_[1]->execute(@{$_[2]}); }

# Dialect hook: true when queries and writes reuse statement handles
# (Selecto::PostgreSQL's opt-in statement_cache). The dialect then provides
# _cached_execute(sql, params, failure), returning the executed handle.
sub _statement_cache_enabled { return 0; }

sub preview_write {
    my ($self, $command) = @_;
    Selecto::Write::Capabilities->preflight($self, $command);
    $self->_validate_write_cardinality($command);
    my $statement = $self->_compile_write($command);
    return { sql => $statement->{sql}, params => [@{$statement->{params}}],
        (ref($statement->{logical_params}) eq 'ARRAY' ? (logical_params => [@{$statement->{logical_params}}]) : ()) };
}

sub _admit_plan_storage { return; }

# Dialect hooks: a snapshot of the session state a write's DML could change
# (undef: nothing to compare), and its comparison after the DML.
sub _write_session_open { return undef; }
sub _write_session_check { return; }
sub _write_session_close { return; }
# Dialect hook: true when post-statement re-reads name the written rows by
# their physical row id (PostgreSQL: RETURNING tableoid, ctid) instead of
# their key value. _with_row_ids appends the row ids to a compiled write.
sub _rereads_by_row_id { return 0; }
sub _with_row_ids { return $_[1]; }

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

sub execute_transaction {
    my ($self, $request, $authorization) = @_;
    Selecto::Write::Authorization->require_for($request, $authorization);
    Selecto::Error->throw('invalid_write', 'transaction work requires engine authority')
        unless blessed($request) && $request->isa('Selecto::Write::Transaction') && ref($request->{work}) eq 'CODE';
    if ($self->transaction_mode eq 'external') {
        Selecto::Error->throw('invalid_adapter', 'protected rules require an open host transaction')
            unless $self->_transaction_open;
        return $self->_savepoint_transaction($request->{work});
    }
    return $self->_transaction($request->{work});
}

sub execute_write_unsafe {
    my ($self, $command) = @_;
    Selecto::Write::Capabilities->preflight($self, $command);
    $self->_validate_write_cardinality($command);
    my $compiled = $self->_compile_write($command);
    return $self->_transaction(sub { return $self->_execute_compiled_write_in_transaction($command, $compiled); });
}

sub execute_batch_unsafe {
    my ($self, $batch) = @_;
    Selecto::Write::Capabilities->preflight($self, $batch);
    my @commands = @{$batch->commands};
    $self->_validate_write_cardinality($_) for @commands;
    my @compiled = map { $self->_compile_write($_) } @commands;
    return $self->_transaction(sub {
        $self->_admit_plan_storage(\@commands);
        my @results = map { $self->_execute_compiled_write_in_transaction($commands[$_], $compiled[$_]) } 0 .. $#commands;
        return \@results;
    });
}

sub execute_graph_unsafe {
    my ($self, $graph) = @_;
    Selecto::Write::Capabilities->preflight($self, $graph);
    $self->_validate_write_cardinality($_->{command}) for @{$graph->nodes};
    $self->_validate_write_cardinality($_->{cleanup}) for @{$graph->{_governed_owned_sets} // []};
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    Selecto::Error->throw('write_capability_missing', 'adapter does not support write graphs')
        unless $self->write_capabilities->{write_graph};

    my $work = sub {
        $self->_admit_plan_storage([map { $_->{command} } grep { !$_->{reference_only} } @{$graph->nodes}],
            [map { $_->{cleanup} } @{$graph->{_governed_owned_sets} // []}]);
        $self->_admit_graph_storage($graph) if $self->can('_admit_graph_storage');
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
            if ($node->{reference_only}) {
                my $domain = $graph->{_reference_domains}{$node->{id}};
                Selecto::Error->throw('ungoverned_write', 'read anchor requires its governing domain') unless $domain;
                my @fields = @{$command->metadata->{returning} // $domain->primary_keys};
                @fields = @{$domain->primary_keys} unless @fields;
                my $predicate = Selecto::QueryEnforcement::combine($command->predicate,
                    $command->scope_predicate, $command->query_enforcement ? $command->query_enforcement->predicate : undef);
                my $query = Selecto::Query->new->select(@fields)->limit(2);
                $query = $query->where($predicate) if defined $predicate;
                # The command's scope predicate and query-enforcement evidence
                # are host-trusted, not a caller filter: their comparisons
                # decide identity (exact on dialects with folding collations).
                local $self->{_selecto_trusted_predicates} = [grep { defined } $command->scope_predicate,
                    $command->query_enforcement ? $command->query_enforcement->predicate : undef];
                my $rows = $self->execute_query($self->compile($domain, $query))->{rows};
                Selecto::Error->throw('cardinality_mismatch', 'read anchor must resolve exactly one governed row') unless @$rows == 1;
                $results{$node->{id}} = Selecto::Write::Result->new(operation => 'update', affected_rows => 0,
                    values => {map { ($fields[$_] => $rows->[0][$_]) } 0 .. $#fields});
                next;
            }
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
        my @cleanup;
        if (@{$graph->owned_sets}) {
            Selecto::Error->throw('invalid_write_graph', 'owned sets require engine-derived cleanup')
                unless $self->write_capabilities->{owned_set_sync}
                    && ref($graph->{_governed_owned_sets}) eq 'ARRAY'
                    && @{$graph->{_governed_owned_sets}} == @{$graph->owned_sets};
            my %nodes = map { ($_->{id} => $_) } @{$graph->nodes};
            for my $set (reverse @{$graph->{_governed_owned_sets}}) {
                my $parent = $results{$set->{parent}}->values->{$set->{parent_key}};
                Selecto::Error->throw('generated_value_missing', 'owned sync parent did not return its exact key')
                    unless defined($parent) && !ref($parent);
                my (%seen, @kept);
                for my $id (@{$set->{nodes}}) {
                    next if $nodes{$id}{command}->operation eq 'delete';
                    my $values = $results{$id}->values;
                    Selecto::Error->throw('generated_value_missing', 'owned sync row identity is incomplete')
                        if grep { !exists($values->{$_}) || !defined($values->{$_}) || ref($values->{$_}) }
                            @{$set->{identity_fields}};
                    my @identity = map {
                        my $type = $nodes{$id}{command}->metadata->{__selecto_insert_types}{$_};
                        Selecto::InsertAdmission::_value(lc($type // ''), $values->{$_}, $_)
                    } @{$set->{identity_fields}};
                    my $key = Cpanel::JSON::XS->new->allow_nonref(1)->canonical->encode([map { "$_" } @identity]);
                    Selecto::Error->throw('invalid_write_graph', 'owned sync contains duplicate returned identities')
                        if $seen{$key}++;
                    push @kept, Selecto::Expression->all(map {
                        Selecto::Expression->eq($set->{identity_fields}[$_], $identity[$_])
                    } 0 .. $#identity);
                }
                my $predicate = Selecto::Expression->eq($set->{child_key}, $parent);
                $predicate = Selecto::Expression->all($predicate,
                    Selecto::Expression->not(Selecto::Expression->any(@kept))) if @kept;
                my $command = $set->{cleanup}->_with(predicate => $predicate);
                push @cleanup, $self->_execute_compiled_write_in_transaction($command, $self->_compile_write($command));
            }
        }
        my $root = $graph->nodes->[0]{id};
        # Generated keys remain available until every binding and owned-set
        # cleanup has finished. Only then apply the separately governed public
        # projection; graph metadata never controls result visibility.
        for my $node (@{$graph->nodes}) {
            my $returning=$graph->public_returning($node->{id});
            next unless defined $returning; # Preserve legacy absent intent.
            my $result=$results{$node->{id}};
            my $values=$result->values;
            $results{$node->{id}}=Selecto::Write::Result->new(
                operation=>$result->operation,affected_rows=>$result->affected_rows,
                values=>{map { exists($values->{$_}) ? ($_=>$values->{$_}) : () } @$returning},
                metadata=>$result->metadata);
        }
        return Selecto::Write::Graph::Result->new(nodes => \%results, root => $results{$root},
            metadata => {owned_sync => scalar(@cleanup), cleanup_affected_rows =>
                [map { $_->affected_rows } @cleanup]});
    };
    if (@{$graph->owned_sets} && $self->transaction_mode eq 'external') {
        Selecto::Error->throw('invalid_adapter', 'owned sync requires an open host transaction')
            unless $self->_transaction_open;
        return $self->_savepoint_transaction($work);
    }
    return $self->_transaction($work);
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
        $self->{_suppress_field_timezone} ? 1 : 0,
        $self->{_instant_fields} ? 1 : 0,
        _expression_digest($expression, $self->{_group_expression_digests} // {}),
    ]);
}

# A structural digest of an expression. Each node's digest covers its kind
# and its children's digests, memoized by node for one compile, so keying
# every node of a tree costs time linear in its size; _value_key over each
# subtree grew with size times depth. The memo holds each node it keys, so a
# temporary expression freed during the compile cannot hand its address,
# and so its digest, to another.
sub _expression_digest {
    my ($expression, $memo) = @_;
    my $entry = $memo->{refaddr $expression} //= [$expression, sha1_hex(
        $expression->kind . ':' . _digest_value($expression->arguments, $memo),
    )];
    return $entry->[1];
}

sub _digest_value {
    my ($value, $memo) = @_;
    return 'e:' . _expression_digest($value, $memo)
        if blessed($value) && $value->isa('Selecto::Expression');
    return 'a:[' . join(',', map { _digest_value($_, $memo) } @$value) . ']'
        if ref($value) eq 'ARRAY';
    return 'h:{' . join(',', map { _value_key($_) . '=' . _digest_value($value->{$_}, $memo) } sort keys %$value) . '}'
        if ref($value) eq 'HASH';
    return _value_key($value);
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
    unless (ref($value)) {
        my $type = _numeric_scalar_type($value);
        return (defined($type) ? 'n:' . $type . ':' : 's:') . length("$value") . ':' . "$value";
    }
    return 'r:' . ref($value);
}

# Match JSON's scalar distinction. A numeric-looking authored string keeps its
# string identity, including when Perl has cached a numeric interpretation.
sub _numeric_scalar_type {
    my ($value) = @_;
    return undef unless defined $value;
    return 'INTEGER' if JSON::PP::is_bool($value);
    return undef if ref($value);
    my $flags = B::svref_2object(\$value)->FLAGS;
    return undef if $flags & B::SVp_POK();
    return 'INTEGER' if $flags & B::SVf_IOK();
    return 'REAL' if $flags & (B::SVp_NOK() | B::SVp_IOK());
    return undef;
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

# Escapes LIKE wildcards with '!', the ESCAPE character every dialect declares.
sub _escape_like {
    my ($self, $text) = @_;
    $text =~ s/([!%_])/!$1/g;
    return $text;
}

sub _compile_expression {
    my ($self, $domain, $expression, $params, $compiled_selections) = @_;
    Selecto::Error->throw('invalid_query', 'expected an expression')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    if (defined($self->{_group_expression_params}) && $self->{_group_expression_params} == $params
        && %{$self->{_group_expression_sql}}) {
        my $key = $self->_group_expression_key($domain, $expression);
        return $self->{_group_expression_sql}{$key} if exists $self->{_group_expression_sql}{$key};
    }
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    Selecto::Error->throw('raw_sql_forbidden', 'raw SQL is outside governed expressions', {path => []})
        if $kind eq 'raw_sql';
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
    if ($kind =~ /\A(?:starts_with|text_contains|ends_with)(?:_ci)?\z/) {
        my $literal = $arguments->[1];
        Selecto::Error->throw('invalid_query', "$kind requires a literal string value")
            unless blessed($literal) && $literal->isa('Selecto::Expression')
            && $literal->kind eq 'literal';
        my $text = $literal->arguments->[0];
        Selecto::Error->throw('invalid_query', "$kind requires a literal string value")
            if !defined($text) || ref($text);
        $text = $self->_escape_like($text);
        my $field_sql = $self->_compile_expression($domain, $arguments->[0], $params);
        push @$params, $kind =~ /\Atext_contains/ ? "%$text%"
            : $kind =~ /\Aends_with/ ? "%$text" : "$text%";
        return $self->_like_sql($field_sql, $self->placeholder(scalar @$params), $kind =~ /_ci\z/ ? 1 : 0);
    }
    if ($kind eq 'between') {
        my $value = $self->_compile_expression($domain, $arguments->[0], $params);
        my $low = $self->_compile_expression($domain, $arguments->[1], $params);
        return $self->_between_sql($value, $low, $self->_compile_expression($domain, $arguments->[2], $params));
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
        my $operand_sql = $self->_compile_expression($domain, $operand, $params);
        push @$params, Cpanel::JSON::XS->new->canonical(1)->allow_nonref(1)->encode($arguments->[1]);
        return $self->_compile_json_contains(
            $operand_sql, $self->placeholder(scalar @$params), $params,
        );
    }
    if ($kind eq 'in') {
        my $values = $arguments->[1];
        Selecto::Error->throw('invalid_query', 'IN requires at least one value') unless ref($values) eq 'ARRAY' && @$values;
        # Anonymous markers bind by SQL occurrence, including parameters from
        # computed/association-existence operands on the left of IN.
        my $operand = $self->_compile_expression($domain, $arguments->[0], $params);
        my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
        return $self->_in_list_sql($operand, \@markers);
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
        my $key_sql = $self->_compile_expression($domain, $arguments->[1], $params);
        my $display_sql = $self->_compile_expression($domain, $arguments->[0], $params);
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
            $self->_nullif_sql("COUNT($denominator)", '0') . ')';
    }
    return $self->_compile_date_shortcut($domain, $expression, $params)
        if $kind eq 'date_shortcut';
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
        # A RANGE frame with an offset needs its single ORDER BY key, which
        # cannot then carry the NULL-placement key.
        my $null_keys = $self->_null_ordered_terms;
        Selecto::Error->throw('unsupported_feature',
            'RANGE offset frames cannot order NULLs as PostgreSQL on this adapter')
            if $null_keys && ref($over->{frame}) eq 'HASH'
                && uc($over->{frame}{type} // 'rows') eq 'RANGE'
                && grep { ref($_) eq 'HASH' } @{$over->{frame}}{qw(start end)};
        push @clauses, 'ORDER BY ' . join(', ', map {
            Selecto::Error->throw('invalid_query', 'window order entry is invalid')
                unless ref($_) eq 'ARRAY' && @$_ == 2
                    && ($_->[1] eq 'asc' || $_->[1] eq 'desc');
            ($null_keys ? '(' . $self->_compile_expression($domain, $_->[0], $params) . ' IS NULL) '
                . uc($_->[1]) . ', ' : '')
            . $self->_compile_expression($domain, $_->[0], $params) . ' ' . uc($_->[1]);
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
    local $self->{_selecto_pair_parent_types} = $self->_exact_identity_compare
        ? $self->_association_parent_types($domain, $association_name) : undef;
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
                type => 'json',
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
            ($field->{expression}->kind eq 'field' ? (type => $resolved->{type}) : ()),
            (exists($field->{stringify}) ? (stringify => $field->{stringify}) : ()),
        };
    }

    my $quoted_alias = $self->quote_identifier($alias);
    my $table = $self->_association_source_sql($association);
    my $related_key = $quoted_alias . '.' . $self->quote_identifier($association->related_key);
    my $owner_key = $self->quote_identifier($parent_alias) . '.' .
        $self->quote_identifier($association->owner_key);
    my $from = "$table AS $quoted_alias";
    my @predicates = ("$related_key = $owner_key");
    if (defined $association->source_scope_key) {
        push @predicates, $self->_identity_equal_sql(
            $quoted_alias . '.' . $self->quote_identifier($association->target_scope_key),
            $self->_qualified($parent_alias, $association->source_scope_key),
            $self->_association_identity_exact($association, $association->target_scope_key,
                $association->source_scope_key));
    }
    if (my $through = $association->through) {
        my $bridge_alias = 'ct_' . $association_name;
        my $quoted_bridge_alias = $self->quote_identifier($bridge_alias);
        my $bridge_table = $self->_physical_source_sql($through->{table});
        my @target_on = (
            $quoted_bridge_alias . '.' . $self->quote_identifier($through->{related_key}) .
            ' = ' . $self->_join_target_key($related_key, $through->{target_key_cast}),
        );
        @predicates = (
            $quoted_bridge_alias . '.' . $self->quote_identifier($through->{owner_key}) .
            ' = ' . $owner_key,
        );
        if (defined $through->{source_scope_key}) {
            my $exact = $self->_association_identity_exact($association, $through->{target_scope_key}, undef);
            push @predicates, $self->_identity_equal_sql(
                $quoted_bridge_alias . '.' . $self->quote_identifier($through->{through_scope_key}),
                $self->_qualified($parent_alias, $through->{source_scope_key}), $exact);
            push @target_on, $self->_identity_equal_sql(
                $quoted_bridge_alias . '.' . $self->quote_identifier($through->{through_scope_key}),
                $quoted_alias . '.' . $self->quote_identifier($through->{target_scope_key}), $exact);
        }
        # ON precedes WHERE in the emitted SQL, so bind target predicates first.
        # Do not bind the discarded direct-association predicate for this path.
        push @target_on, $self->_constant_join_predicates(
            $alias, $association->where, $params, $association_fields, $association->table
        );
        push @target_on, $self->_tenant_bound_sql($association, $alias, $params);
        push @predicates, $self->_constant_join_predicates(
            $bridge_alias, $through->{where}, $params, undef, $through->{table}
        );
        push @predicates, $self->_tenant_pair_sql($association, $parent_alias, $alias);
        $from = "$bridge_table AS $quoted_bridge_alias INNER JOIN $table AS $quoted_alias ON " .
            join(' AND ', @target_on);
    } else {
        push @predicates, $self->_constant_join_predicates(
            $alias, $association->where, $params, $association_fields, $association->table
        );
        push @predicates, $self->_tenant_pair_sql($association, $parent_alias, $alias),
            $self->_tenant_bound_sql($association, $alias, $params);
    }
    my $filters = $options->{filters} // [];
    Selecto::Error->throw('invalid_query', 'related collection filters are invalid')
        unless ref($filters) eq 'ARRAY';
    for my $filter (@$filters) {
        Selecto::Error->throw('invalid_query', 'related collection filter is invalid')
            unless ref($filter) eq 'ARRAY' && @$filter == 2
            && defined($filter->[0]) && !ref($filter->[0])
            && exists($association_fields->{$filter->[0]});
        push @predicates, $self->_identity_values_sql($self->_qualified($alias, $filter->[0]), [$filter->[1]], $params,
            defined($filter->[1]) && !ref($filter->[1])
                && $self->_identity_field_exact($domain, "$association_name.$filter->[0]"));
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
    ) if @$orders && $self->name ne 'postgresql' && !$self->supports('ordered_related_collections');
    my @order_sql;
    for my $spec (@$orders) {
        my ($field, $direction) = ref($spec) eq 'ARRAY' ? @$spec : ();
        Selecto::Error->throw('invalid_query', 'related collection ordering is invalid')
            unless ref($spec) eq 'ARRAY' && @$spec == 2
            && defined($field) && !ref($field)
            && exists($association_fields->{$field})
            && defined($direction) && !ref($direction)
            && "$direction" =~ /\A(?:asc|desc)\z/i;
        push @order_sql, $self->_related_collection_order_term($alias, $field, $direction);
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
            'unsupported_feature', 'per-parent collection limits require a certified dialect',
        ) unless $self->name eq 'postgresql' || $self->supports('bounded_related_collections');
        my $primary_key = $association->target_primary_key;
        Selecto::Error->throw(
            'invalid_query', 'per-parent collection limit requires a target primary key',
        ) unless defined($primary_key) && exists($association_fields->{$primary_key});
        my @stable_orders = map { [$_->[0], lc($_->[1])] } @$orders;
        if (!grep { $_->[0] eq $primary_key } @$orders) {
            push @order_sql, $self->_related_collection_order_term($alias, $primary_key, 'asc');
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
        ($from, $where, $limit) = $self->_bounded_related_collection_source(
            $from, $where, $order, int($limit), $quoted_alias);
    }
    return $self->_compile_related_collection_sql({
        fields => \@collection_fields,
        quoted_alias => $quoted_alias,
        from => $from,
        where => $where,
        order => $order,
        (defined($limit) ? (limit => $limit) : ()),
    });
}

# Bounds one parent's children to $limit rows in $order. Returns the new
# source, predicate and a limit the aggregate itself must still apply (undef
# when the source already applies it).
sub _bounded_related_collection_source {
    my ($self, $from, $where, $order, $limit, $quoted_alias) = @_;
    return ('(SELECT ' . $quoted_alias . '.* FROM ' . $from .
        ' WHERE ' . $where . ' ORDER BY ' . $order .
        ' LIMIT ' . int($limit) . ') AS ' . $quoted_alias, 'TRUE', undef);
}

sub _related_collection_order_term {
    my ($self, $alias, $field, $direction) = @_;
    return $self->_qualified($alias, $field) . ' ' . uc($direction);
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
                push @prefix, $self->_distinct_sql($column, $self->placeholder(scalar @$params), 1);
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
    return '(' . $self->_distinct_sql($owner_key, $parent_marker, 0) .
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
                && !$_->{stringify}
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
            local $self->{_selecto_field_prefix};
            return $self->_compile_computed_field(
                $domain, $path, $metadata->{computed}, $params
            );
        }
    } else {
        # A joined relation's computed field compiles over that join: the
        # fields its body names are the relation's own.
        my $metadata = eval { $domain->_field_metadata_view("$path") };
        if (ref($metadata) eq 'HASH' && ref($metadata->{computed}) eq 'HASH') {
            my $computed = $metadata->{computed};
            my $kind = $computed->{kind} // '';
            Selecto::Error->throw('unsupported_feature',
                'a joined relation\'s association_exists computed field is not available through the join', {field => "$path"})
                if $kind eq 'association_exists';
            # A joined schema's computed columns are not checked when the
            # domain is parsed: a reference cycle is refused here, and a value
            # expression is parsed (typed) as the root's are.
            Selecto::Error->throw('invalid_domain', 'computed column references itself', {field => "$path"})
                if $self->{_selecto_computed_stack}{"$path"};
            local $self->{_selecto_computed_stack} = {%{$self->{_selecto_computed_stack} // {}}, "$path" => 1};
            if ($kind eq 'expression') {
                require Selecto::ValueExpression;
                my $ast = eval { Selecto::ValueExpression->parse($computed->{expression}) };
                Selecto::Error->throw('invalid_domain', 'computed value expression is invalid', {field => "$path"})
                    unless defined $ast;
                $computed = {%$computed, expression => $ast};
            }
            local $self->{_selecto_field_prefix} = "$resolved->{association_path}.";
            return $self->_compile_computed_field($domain, $path, $computed, $params);
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
            $key_sql, $domain->_field_metadata_view($key_path)->{text_case},
        );
        $sql = "COALESCE($sql, $key_sql)";
    } elsif ($self->{_field_types}) {
        # The declared type of a stored field this compile read, for
        # _canonical_kind.
        $self->{_field_types}{"$path"} = $resolved->{type};
    }
    my $localize = defined($self->{_timezone})
        && ($resolved->{type} eq 'utc_datetime' || $resolved->{type} eq 'epoch_datetime')
        && !$self->{_suppress_field_timezone};
    # A naive column holding UTC becomes a true instant wherever the value is
    # used as one: before a zone conversion, and in instant formats.
    $sql = $self->_compile_naive_utc_instant_sql($sql)
        if $resolved->{type} eq 'utc_datetime'
        && ($localize || $self->{_suppress_field_timezone} || $self->{_instant_fields})
        && ($domain->field_storage($path) // '') eq 'naive_utc';
    return $sql unless $localize;
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
            $self->_field_sql($domain, ($self->{_selecto_field_prefix} // '') . $_, $params)
        } @{$computed->{fields}}) . ')';
    }
    if ($computed->{kind} eq 'predicate') {
        return '(' . $self->_compile_authored_condition($domain, $computed->{expression}, $params) . ')';
    }
    my $association_name = $computed->{association};
    my $association = $domain->associations->{$association_name};
    Selecto::Error->throw('invalid_domain', 'computed field association is unavailable', {
        field => $path, association => $association_name,
    }) unless $association && !$association->through;
    my $alias = 'e_' . $association_name;
    local $self->{_selecto_pair_parent_types} = $self->_exact_identity_compare ? (eval { $domain->fields } // {}) : undef;
    my @predicates = (
        $self->_qualified($alias, $association->related_key) . ' = ' .
            $self->_qualified($self->_root_alias, $association->owner_key),
    );
    if (defined $association->source_scope_key) {
        push @predicates, $self->_identity_equal_sql(
            $self->_qualified($alias, $association->target_scope_key),
            $self->_qualified($self->_root_alias, $association->source_scope_key),
            $self->_association_identity_exact($association, $association->target_scope_key,
                $association->source_scope_key));
    }
    push @predicates, $self->_constant_join_predicates(
        $alias, $association->where, $params, $association->fields, $association->table
    );
    push @predicates, $self->_tenant_pair_sql($association, $self->_root_alias, $alias),
        $self->_tenant_bound_sql($association, $alias, $params);
    return 'EXISTS (SELECT 1 FROM ' . $self->_association_source_sql($association) .
        ' AS ' . $self->quote_identifier($alias) . ' WHERE ' .
        join(' AND ', @predicates) . ')';
}

# A condition authored in the domain (a computed predicate's body, a value
# expression's CASE condition), as a filter AST.
sub _compile_authored_condition {
    my ($self, $domain, $ast, $params) = @_;
    return $self->_compile_expression($domain, $self->_authored_condition($ast), $params);
}

# The condition as an expression, its fields qualified by the joined
# relation it belongs to (_selecto_field_prefix), if any.
sub _authored_condition {
    my ($self, $ast) = @_;
    my $expression = Selecto::Expression->from_filter_ast($ast);
    my $prefix = $self->{_selecto_field_prefix};
    return defined($prefix) && length($prefix) ? _prefix_fields($expression, $prefix) : $expression;
}

sub _prefix_fields {
    my ($value, $prefix) = @_;
    if (blessed($value) && $value->isa('Selecto::Expression')) {
        return Selecto::Expression->field($prefix . $value->arguments->[0])
            if $value->kind eq 'field' && defined($value->arguments->[0]) && !ref($value->arguments->[0]);
        my $copy = Selecto::Expression->new($value->kind, map { _prefix_fields($_, $prefix) } @{$value->arguments});
        return defined($value->alias_name) ? $copy->as($value->alias_name) : $copy;
    }
    return [map { _prefix_fields($_, $prefix) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => _prefix_fields($value->{$_}, $prefix)) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}

# Compiles a governed value expression (see Selecto::ValueExpression). Every
# literal and JSON path segment is bound; literals are cast to their type.
sub _compile_value_expression {
    my ($self, $domain, $node, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support value expressions')
        unless $self->supports('value_expressions');
    my ($operator, @arguments) = @$node;
    return $self->_field_sql($domain, ($self->{_selecto_field_prefix} // '') . $arguments[0], $params)
        if $operator eq 'field';
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
        # Casting to an instant reads naive-UTC columns as instants.
        local $self->{_instant_fields} = $self->{_instant_fields} || $arguments[1] eq q{utc_datetime};
        return 'CAST(' . $self->_compile_value_expression($domain, $arguments[0], $params)
            . ' AS ' . $self->_value_type_sql($arguments[1]) . ')';
    }
    if ($operator eq 'json_text') {
        my $field_sql = $self->_field_sql($domain, ($self->{_selecto_field_prefix} // '') . $arguments[0], $params);
        return $self->_compile_json_text($field_sql, $arguments[1], $params);
    }
    if ($operator eq 'case') {
        my @parts;
        for my $branch (@arguments) {
            if ($branch->[0] eq 'else') {
                push @parts, 'ELSE ' . $self->_compile_value_expression($domain, $branch->[1], $params);
                next;
            }
            push @parts, 'WHEN ' . $self->_compile_authored_condition($domain, $branch->[0], $params)
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
            my $computed = $domain ? $domain->_field_metadata_view($segments[0])->{computed} : undef;
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
            # A plain scalar (an IN member, say) names no association.
            push @names, map { ref($_) ? $self->_expression_associations($_, $domain) : () } @$argument;
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
# Lesson 41: a join between two relations that both declare tenant_field
# pairs their tenant fields, even when authored scope keys pair another
# column or the join runs through a bridge. An authored pair that already is
# that tenant pair is not repeated.
sub _tenant_pair_sql {
    my ($self, $association, $parent_alias, $target_alias) = @_;
    my ($source, $target) = ($association->source_tenant_field, $association->target_tenant_field);
    return () unless defined($source) && defined($target);
    my $authored = $association->through
        // {source_scope_key => $association->source_scope_key, target_scope_key => $association->target_scope_key};
    return () if defined($authored->{source_scope_key}) && defined($authored->{target_scope_key})
        && $authored->{source_scope_key} eq $source && $authored->{target_scope_key} eq $target;
    return $self->_identity_equal_sql($self->_qualified($parent_alias, $source),
        $self->_qualified($target_alias, $target), $self->_association_identity_exact($association, $target, $source));
}

# Comparisons that decide tenant or site identity (tenant pairs and bounds,
# authored scope keys, reference guards, member correlations on a tenant
# column, and write predicates on tenant columns) go through these hooks.
# $exact is true when the dialect compares text under collations that fold
# case, accents or trailing spaces (MySQL and MariaDB) and the column stores
# text: such a dialect then compares the bytes as well. Everywhere else the
# SQL is the plain comparison.
sub _exact_identity_compare { return 0; }

# Every eq, ne or IN comparison anywhere in expression trees, through AND, OR
# and NOT: the comparisons of a host or trusted predicate that decide tenant
# or scope identity.
sub _comparison_nodes {
    my @pending = grep { defined } @_;
    my @nodes;
    while (my $expression = shift @pending) {
        next unless blessed($expression) && $expression->isa('Selecto::Expression');
        my $kind = $expression->kind;
        if ($kind eq 'and' || $kind eq 'or') { push @pending, @{$expression->arguments->[0]}; next }
        if ($kind eq 'not') { push @pending, $expression->arguments->[0]; next }
        push @nodes, $expression if $kind eq 'eq' || $kind eq 'ne' || $kind eq 'in';
    }
    return @nodes;
}

# Every expression node of expression trees.
sub _expression_nodes {
    my @pending = grep { defined } @_;
    my @nodes;
    while (@pending) {
        my $value = shift @pending;
        if (blessed($value) && $value->isa('Selecto::Expression')) {
            push @nodes, $value;
            push @pending, @{$value->arguments};
        } elsif (ref($value) eq 'ARRAY') {
            push @pending, @$value;
        } elsif (ref($value) eq 'HASH' && !blessed($value)) {
            push @pending, map { $value->{$_} } sort keys %$value;
        }
    }
    return @nodes;
}

# The fields compared by those nodes (plain root fields only).
sub _comparison_fields {
    return map {
        my @operands = ($_->arguments->[0], $_->kind eq 'in' ? () : ($_->arguments->[1]));
        map {
            blessed($_) && $_->isa('Selecto::Expression') && $_->kind eq 'field' && !ref($_->arguments->[0])
                && $_->arguments->[0] !~ /\./ ? ($_->arguments->[0]) : ()
        } @operands
    } _comparison_nodes(@_);
}

# The top-level conjuncts of an expression (the operands of nested ANDs).
sub _top_conjuncts {
    my @pending = grep { defined } @_;
    my @conjuncts;
    while (my $expression = shift @pending) {
        next unless blessed($expression) && $expression->isa('Selecto::Expression');
        if ($expression->kind eq 'and') { push @pending, @{$expression->arguments->[0]}; next }
        push @conjuncts, $expression;
    }
    return @conjuncts;
}

sub _identity_equal_sql {
    my ($self, $left, $right, $exact) = @_;
    return "$left = $right";
}

# A pair with a derived source's column (CTE, VALUES, subquery): such a
# column has no index to keep, and may carry a collation of its own.
sub _derived_identity_equal_sql {
    my ($self, @arguments) = @_;
    local $self->{_selecto_derived_pair} = 1;
    return $self->_identity_equal_sql(@arguments);
}

# A NULL-safe identity comparison of an inner and an outer column (retarget
# rebinding): two NULLs match. Dialects override with their own operator.
sub _identity_correlation_sql {
    my ($self, $inner, $outer, $exact) = @_;
    return "($inner = $outer OR ($inner IS NULL AND $outer IS NULL))";
}

# $column compared with bound values: = for one value, IN for several.
sub _identity_values_sql {
    my ($self, $column, $values, $params, $exact) = @_;
    my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
    return @markers == 1 ? "$column = $markers[0]" : $self->_in_list_sql($column, \@markers);
}

# How a declared field type takes part in exact identity comparison: 1 for a
# declared text type (string, text, char, varchar, citext, enum), 2 for an
# undeclared type (compared exactly when it holds text, see the dialect),
# 0 for every other declared type (numbers, booleans, temporal, json,
# decimal, uuid, binary), which compares plainly.
sub _identity_text_type {
    my ($type) = @_;
    $type = $type->{type} if ref($type) eq 'HASH';
    return 2 unless defined($type) && !ref($type);
    my $name = lc("$type");
    $name =~ s/\s+(?:character\s+set|charset|collate)\s+\S+//g;
    $name =~ s/\(.*\)//;
    $name =~ s/\A\s+|\s+\z//g;
    $name =~ s/\s+/ /g;
    return 2 unless length($name);
    # Known non-text: numbers, booleans, temporal values, JSON and binary.
    return 0 if $name =~ /\A(?:integer|int|bigint|smallint|tinyint|mediumint|serial|bigserial|decimal|numeric|number
        |float|double|double[ ]precision|real|money|boolean|bool|bit|date|time|datetime|timestamp|timestamptz
        |timestamp[ ]with[ ]time[ ]zone|timestamp[ ]without[ ]time[ ]zone|time[ ]with[ ]time[ ]zone|time[ ]without[ ]time[ ]zone|year|interval
        |naive_\w+|utc_\w+|epoch_\w+|json|jsonb|map|binary|varbinary|bytes|bytea|blob|tinyblob|mediumblob|longblob)\z/x;
    # Known text: the declared text names and their synonyms, listed
    # explicitly (a name merely containing 'char' or 'text' may be a custom
    # name for anything; it is guarded below).
    return 1 if $name =~ /\A(?:string|text|tinytext|mediumtext|longtext|ntext|char|character|nchar|national[ ]char
        |national[ ]character|varchar|char[ ]varying|character[ ]varying|nvarchar|national[ ]varchar|national[ ]char[ ]varying
        |national[ ]character[ ]varying|nchar[ ]varying|varchar2|nvarchar2|citext|clob|nclob|enum|set)\z/x;
    # Everything else (uuid, unknown, custom names) is decided by the server.
    return 2;
}
# Exactness of a comparison on an association's target column; for a pair
# with a source column ($source_field), of the pair: exact when either side
# is declared text, plain only when both are known non-text, otherwise
# decided by the server. The source column's type comes from the parent
# relation being joined (_selecto_pair_parent_types); a bridge column has
# none.
sub _association_identity_exact {
    my ($self, $association, $field, $source_field) = @_;
    return 0 unless $self->_exact_identity_compare;
    my $fields = eval { $association->fields } // {};
    my $target = _identity_text_type($fields->{$field});
    return $target if @_ < 4;
    my $types = $self->{_selecto_pair_parent_types};
    my $source = defined($source_field) && ref($types) eq 'HASH' ? _identity_text_type($types->{$source_field}) : 2;
    return 1 if $target == 1 || $source == 1;
    return 0 if $target == 0 && $source == 0;
    return 2;
}

# The declared field types of the relation an association path joins from.
sub _association_parent_types {
    my ($self, $domain, $path) = @_;
    my @segments = split /\./, "$path";
    pop @segments;
    return @segments ? (eval { $domain->resolve_association(join('.', @segments))->{association}->fields } // {})
        : (eval { $domain->fields } // {});
}

# Whether a field path of $domain is a tenant or site column of its relation
# that stores text: the root's tenant_field, writes.scope.tenant column and
# tenant-family columns, or a joined relation's tenant_field or a column
# named like one of the root's.
sub _identity_field_exact {
    my ($self, $domain, $path) = @_;
    return 0 unless $self->_exact_identity_compare && blessed($domain) && $domain->can('resolve')
        && defined($path) && !ref($path);
    my $resolved = eval { $domain->resolve("$path") };
    return 0 unless ref($resolved) eq 'HASH' && defined $resolved->{field};
    my %names = map { ($_ => 1) } $self->_identity_root_columns($domain);
    if (my $association = $resolved->{association}) {
        my $target = eval { $association->target_tenant_field };
        $names{$target} = 1 if defined $target;
    }
    return 0 unless $names{$resolved->{field}};
    my $metadata = eval { $domain->_field_metadata_view("$path") } // {};
    return 0 if ref($metadata) eq 'HASH' && ref($metadata->{computed}) eq 'HASH';
    return _identity_text_type($resolved->{type});
}

# Exactness of a member correlation pair (CTE, VALUES, subquery, lateral and
# recursive joins). Each side is [$domain, $path] (a field of a relation) or
# [undef, $type] (a source column of known or unknown declared type). The
# pair decides identity when either side is a tenant or scope column of its
# relation; it is then classified from both sides' declared types: exact when
# either is known text, plain only when both are known non-text, otherwise
# decided by the server (an INT tenant must not match text '07' or ' 7').
sub _member_pair_exact {
    my ($self, @sides) = @_;
    return 0 unless $self->_exact_identity_compare;
    my ($identity, @classes) = (0);
    for my $side (@sides) {
        my ($domain, $path) = @$side;
        unless (defined $domain) {
            push @classes, _identity_text_type($path);
            next;
        }
        my $resolved = eval { $domain->resolve("$path") };
        push @classes, ref($resolved) eq 'HASH' ? _identity_text_type($resolved->{type}) : 2;
        next unless ref($resolved) eq 'HASH' && defined $resolved->{field};
        # Tenant and scope columns, and every column the host's required or
        # trusted predicates compare: those decide identity too.
        my %names = map { ($_ => 1) } $self->_identity_root_columns($domain),
            _comparison_fields(eval { $domain->required_predicate }, @{$self->{_selecto_trusted_predicates} // []});
        $identity = 1 if !$resolved->{association} && $names{$resolved->{field}};
    }
    return 0 unless $identity;
    return 1 if grep { $_ == 1 } @classes;
    return 0 unless grep { $_ != 0 } @classes;
    return 2;
}

sub _identity_root_columns {
    my ($self, $domain) = @_;
    my $scope = eval { $domain->write_tenant_scope };
    my $family = eval { $domain->tenant_family } // {};
    return grep { defined && !ref } eval { $domain->tenant_field }, (ref($scope) eq 'HASH' ? $scope->{field} : undef),
        $family->{tenant}, $family->{site};
}

# Lesson 42: a tenant-scoped relation joined from a shared parent (one that
# declares no tenant_field, such as a shared root) is bound to the trusted
# engine tenant in its join condition, so a left join keeps the parent row
# without exposing another tenant's. A tenant-scoped parent is itself bounded
# (the root by Selecto::Engine::read_domain, a joined parent by this rule or
# its tenant pair), so its pair carries the bound.
#
# Lessons 41b, 41e and 41f: such an unpaired relation is also bound to the
# admitted tenant sets of the compile root (its required tenant conjuncts, or
# those a retarget carried past an untenanted hop) as IN, so a root bounded
# only by a required predicate keeps its boundary past a shared hop. In a
# two-column tenant family only the tenant_field column takes those bounds:
# a relation tenanted on the write-scope (site) column pairs by name with a
# hop chained to the root or is refused, since a shared hop that merely
# stores that column is no pairing source. A bounded root with nothing to
# carry refuses the relation with missing_tenant_scope; a root with no
# boundary at all keeps reading every tenant.
sub _tenant_bound_sql {
    my ($self, $association, $target_alias, $params) = @_;
    my $field = $association->target_tenant_field;
    return () unless defined($field) && !defined($association->source_tenant_field);
    my $engine = $self->{_selecto_compile_engine};
    my $tenant = $engine ? $engine->scope->{tenant} : undef;
    my $root = $self->{_tenant_root};
    my $family = $root ? $root->tenant_family : undef;
    require Selecto::QueryMember;
    my ($sets, $bounded) = $root ? Selecto::QueryMember->admitted_tenant_sets($root) : ([], 0);
    $bounded ||= defined $tenant;
    my $refuse = sub {
        Selecto::Error->throw('missing_tenant_scope', $_[0], {tenant_field => "$field", association => $association->name});
    };
    if ($family && "$field" ne $family->{tenant}) {
        return () unless $bounded;
        $refuse->('a relation tenanted on the write-scope column must pair by name with a hop chained to the tenant-bound root');
    }
    my @predicates;
    my $exact = $self->_association_identity_exact($association, $field);
    my $column = $self->_qualified($target_alias, $field);
    push @predicates, $self->_identity_values_sql($column, [$tenant], $params, $exact) if defined $tenant;
    for my $set (@$sets) {
        my ($from, $values) = @$set;
        next if $family && $from ne "$field";
        push @predicates, $self->_identity_values_sql($column, $values, $params, $exact);
    }
    return @predicates if @predicates || !$bounded;
    $refuse->('a tenant-scoped relation past an untenanted hop has no tenant boundary of the root to carry');
}

# An association's fixed where policy (on its target, or on a through
# bridge) is domain-authored scope: on dialects whose collations fold text
# each pin compares as identity, classified by the column's declared type
# ($types: the target relation's field types; a bridge column has none, so
# the server decides).
sub _constant_join_predicates {
    my ($self, $alias, $where, $params, $types) = @_;
    return () unless ref($where) eq 'HASH' && keys %$where;
    my @predicates;
    for my $field (sort keys %$where) {
        my $column = $self->_qualified($alias, $field);
        if (!defined($where->{$field})) {
            push @predicates, "$column IS NULL";
            next;
        }
        if ($self->_exact_identity_compare) {
            push @predicates, $self->_identity_values_sql($column, [$where->{$field}], $params,
                _identity_text_type(ref($types) eq 'HASH' ? $types->{$field} : undef));
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

# ON CONFLICT ... DO UPDATE updates the conflicting row whatever its scope.
# A scope predicate (host, trusted or engine tenant) is kept only when each
# of its conjuncts is an equality on a conflict-target column: the
# conflicting row then holds the candidate's value there, and the candidate
# was admitted under that scope. Any other scope is refused, as MySQL and
# MariaDB refuse every scoped upsert.
sub _refuse_unbounded_scoped_upsert {
    my ($command, $conflict) = @_;
    my $scope = $command->scope_predicate;
    return unless defined $scope;
    my %target = map { ($_ => 1) } @$conflict;
    my $assignments = $command->assignments;
    for my $conjunct (_top_conjuncts($scope)) {
        my ($field, $value) = @{$conjunct->arguments};
        next if $conjunct->kind eq 'eq' && blessed($field) && $field->kind eq 'field' && !ref($field->arguments->[0])
            && $target{$field->arguments->[0]} && blessed($value) && $value->kind eq 'literal'
            && exists $assignments->{$field->arguments->[0]};
        Selecto::Error->throw('unsupported_scope_predicate',
            'an upsert can keep a write scope only on its conflict-target columns',
            {upsert_strategy => 'on_conflict'});
    }
    return;
}

sub _compile_write {
    my ($self, $command) = @_;
    # The relations the write's SQL names: its target and every reference
    # guard's parent (the session checks refuse temp shadows of them).
    local $self->{_selecto_relation_schemas} = {};
    local $self->{_selecto_relation_sink} = {};
    my $compiled = $self->_compile_write_sql($command);
    $compiled->{relations} = [sort keys %{$self->{_selecto_relation_sink}}] if ref($compiled) eq 'HASH';
    return $compiled;
}

sub _compile_write_sql {
    my ($self, $command) = @_;
    $self->_validate_write_cardinality($command);
    my $relation = Selecto::Identifier::checked($command->relation);
    my $target_sql = $self->_note_relation($self->_relation_sql(undef, $relation));
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
            if (exists $command->metadata->{__selecto_insert_types}) {
                Selecto::InsertAdmission->prepare($insert_predicate, $assignments,
                    $command->metadata->{__selecto_insert_types});
            } else {
                # Explicit *_unsafe adapter tooling: the in-process v2
                # evaluator decides by declared type. A command's declared
                # field_types (a portable command carries them) are names
                # only, never checked against the column, so they are
                # unverified: the evaluator decides nothing but NULL, and the
                # comparison is deferred to the verified-storage check before
                # DML (_check_typed_insert_admission). Without declared types
                # there is no such check and the insert is refused.
                my $types = _declared_admission_types($command);
                my $truth = eval {
                    Selecto::QueryEnforcement::evaluate($insert_predicate, $self->_insert_candidate($assignments),
                        $types // {}, metadata => 'unverified', backend => $self->name =~ /\A(?:mysql|mariadb)\z/ ? 'mysql_family' : 'other');
                };
                unless (defined $truth) {
                    my $error = $@;
                    die $error unless defined($types) && blessed($error) && $error->isa('Selecto::Error')
                        && $error->code eq 'query_rule_not_evaluable' && !$error->details->{missing_fields};
                }
                Selecto::Error->throw(
                'query_rule_violation',
                'insert candidate does not satisfy the enforced query',
                { truth_value => $truth },
                ) if defined($truth) && $truth ne 'true';
            }
        }
        my @params;
        my @values = map {
            $self->_compile_assignment_value($assignments->{$_}, \@params, $operation, 1)
        } @fields;
        # A guarded row is inserted through a SELECT that yields it only when
        # every referenced parent belongs to the trusted tenant (TW-05).
        my $guard = $self->_compile_foreign_key_guards($command, \@params);
        Selecto::Error->throw('invalid_write', 'a guarded insert cannot assign DEFAULT')
            if defined($guard) && grep { $_ eq 'DEFAULT' } @values;
        my $sql = 'INSERT INTO ' . $target_sql .
            ' (' . join(', ', map { $self->quote_identifier(Selecto::Identifier::checked($_)) } @fields) . ')' .
            (defined($guard) ? ' ' . $self->_guarded_insert_source(\@values, $guard)
                : ' VALUES (' . join(', ', @values) . ')');
        if ($operation eq 'upsert') {
            my $metadata = $command->metadata;
            my $conflict = $metadata->{conflict_target};
            my $updates = $metadata->{upsert_update_fields};
            Selecto::Error->throw('invalid_write', 'upsert conflict target must be a non-empty string array')
                unless ref($conflict) eq 'ARRAY' && @$conflict && !grep { ref($_) } @$conflict;
            Selecto::Error->throw('invalid_write', 'upsert update fields must be a non-empty string array')
                unless ref($updates) eq 'ARRAY' && !(grep { ref($_) } @$updates)
                    && (@$updates || $self->_admits_empty_upsert_mask($command));
            _refuse_unbounded_scoped_upsert($command, $conflict);
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
        my $guard = $self->_compile_foreign_key_guards($command, \@params);
        $predicate .= " AND $guard" if defined $guard;
        return $self->_append_returning('UPDATE ' . $target_sql . ' SET ' . join(', ', @set) . " WHERE $predicate", \@params, $command);
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
        return $self->_append_returning('DELETE FROM ' . $target_sql . " WHERE $predicate", \@params, $command);
    }
    Selecto::Error->throw('invalid_write', "unsupported operation $operation");
}

# TW-05: one EXISTS per foreign-key guard, ANDed; undef without guards. The
# parent's columns are qualified by an alias so a column missing from it
# fails instead of resolving to the written row, and the referenced value and
# trusted tenants are bound.
sub _compile_foreign_key_guards {
    my ($self, $command, $params) = @_;
    my @guards = @{$command->foreign_key_guards};
    return undef unless @guards;
    my $alias = $self->quote_identifier('selecto_fk_parent');
    my $valid_tenants = sub {
        my ($condition) = @_;
        return ref($condition) eq 'HASH' && defined($condition->{tenant_field}) && ref($condition->{tenants}) eq 'ARRAY'
            && @{$condition->{tenants}} && !grep { !defined($_) || ref($_) } @{$condition->{tenants}};
    };
    return join ' AND ', map {
        my $guard = $_;
        Selecto::Error->throw('invalid_write', 'foreign-key guard must name its parent and literal value')
            unless ref($guard) eq 'HASH' && defined($guard->{value}) && !ref($guard->{value})
                && (!exists($guard->{tenant_field}) && !exists($guard->{tenants}) && !exists($guard->{more_tenant_fields})
                    || $valid_tenants->($guard) && (!exists($guard->{more_tenant_fields})
                        || ref($guard->{more_tenant_fields}) eq 'ARRAY'
                            && !grep { !$valid_tenants->($_) } @{$guard->{more_tenant_fields}}));
        push @$params, $guard->{value};
        my $value = $self->placeholder(scalar @$params);
        # On a two-column root one referenced row can be guarded on each root
        # tenant column, each with its own set, in the same EXISTS.
        my $tenant_sql = join '', map {
            my $condition = $_;
            ' AND ' . $self->_identity_values_sql(
                "$alias." . $self->quote_identifier(Selecto::Identifier::checked($condition->{tenant_field})),
                $condition->{tenants}, $params, $self->_guard_identity_exact($condition));
        } (exists($guard->{tenant_field}) ? ($guard) : ()), @{$guard->{more_tenant_fields} // []};
        $self->_foreign_key_exists_sql(
            'SELECT 1 FROM ' . $self->_note_relation($self->_relation_sql(undef, Selecto::Identifier::checked($guard->{relation}))) . " AS $alias"
            . " WHERE $alias." . $self->quote_identifier(Selecto::Identifier::checked($guard->{target_field})) . " = $value"
            . $tenant_sql,
        );
    } @guards;
}

sub _foreign_key_exists_sql { return "EXISTS ($_[1])"; }

# A referenced parent's tenant column is compared with the trusted tenants by
# the parent column's own declared type (the guard's tenant_type), exactly
# unless it is declared numeric: the written relation's tenant type says
# nothing about the parent's column.
sub _guard_identity_exact {
    my ($self, $condition) = @_;
    return 0 unless $self->_exact_identity_compare;
    return _identity_text_type(ref($condition) eq 'HASH' ? $condition->{tenant_type} : undef);
}

sub _guarded_insert_source {
    my ($self, $values, $guard) = @_;
    return 'SELECT ' . join(', ', @$values) . " WHERE $guard";
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
    Selecto::OperationBudget->new(limits => $command->metadata->{__selecto_limits}, code => 'invalid_write')
        ->consume_parameters($params, label => 'write parameter');
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
        return $self->_in_list_sql($self->quote_identifier(_write_field($arguments->[0])), \@markers);
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

sub insert_admission_storage {
    Selecto::Error->throw('query_rule_not_evaluable',
        'adapter cannot establish typed insert storage semantics');
}

# The declared field types an untyped (*_unsafe) command carries for its
# deferred verified-storage check, or undef.
sub _declared_admission_types {
    my ($command) = @_;
    my $types = $command->metadata->{field_types};
    return ref($types) eq 'HASH' && keys(%$types) ? $types : undef;
}

sub _check_typed_insert_admission {
    my ($self, $command) = @_;
    return unless $command->operation eq 'insert' || $command->operation eq 'upsert';
    # Engine-governed commands carry the domain's types; explicit *_unsafe
    # tooling defers to this check through its declared field_types.
    my $types = $command->metadata->{__selecto_insert_types} // _declared_admission_types($command);
    return unless defined $types; # Untyped tooling was refused at compile.
    my $predicate = Selecto::QueryEnforcement::combine(
        $command->predicate, $command->scope_predicate,
        defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
    );
    return unless $predicate;
    my $candidate = Selecto::InsertAdmission->prepare($predicate, $command->assignments, $types);
    Selecto::Error->throw('query_rule_not_evaluable', 'adapter cannot establish typed insert storage semantics')
        unless $self->name =~ /\A(?:sqlite|postgresql|mysql|mariadb)\z/ && $self->query_budget_supported;
    my $savepoint = $self->name eq 'postgresql' ? _savepoint_name('selecto_insert_admission') : undef;
    $self->_savepoint_command(create => $savepoint) if $savepoint;
    my ($budget, $error);
    my $ok = eval {
        $budget = $self->begin_query_budget(timeout_ms => 5000);
        $self->_typed_insert_admission_probe($command, $predicate, $candidate, $budget);
        1;
    };
    $error = $self->normalize_error($@) unless $ok;
    my $restored = eval {
        $self->_savepoint_command(rollback => $savepoint) if !$ok && $savepoint;
        $budget->close if $budget;
        $self->_savepoint_command(release => $savepoint) if $savepoint;
        1;
    };
    die $self->normalize_error($@) unless $restored;
    die $error unless $ok;
}

sub _typed_insert_admission_probe {
    my ($self, $command, $predicate, $candidate, $budget) = @_;
    # This runs inside the write transaction. Concrete adapters verify actual
    # column storage, hold schema stable, and refuse transforming triggers.
    my $storage = $self->insert_admission_storage($command, $candidate->{types});
    $budget->check;
    my @params;
    my $where = $self->_compile_write_predicate($predicate, \@params);
    my @fields = sort keys %{$candidate->{values}};
    my @columns;
    for my $field (@fields) {
        my $spec = $storage->{$field};
        Selecto::Error->throw('query_rule_not_evaluable', 'insert storage metadata is unavailable')
            unless ref($spec) eq 'HASH' && defined($spec->{cast});
        push @params, $candidate->{values}{$field};
        my $value = 'CAST(' . $self->placeholder(scalar @params) . ' AS ' . $spec->{cast} . ')';
        $value .= ' COLLATE ' . $spec->{collation} if defined $spec->{collation};
        push @columns, $value . ' AS ' . $self->quote_identifier($field);
    }
    # Return an integer truth marker, independent of driver boolean settings
    # such as DBD::Pg's pg_bool_tf (where the string "f" is truthy in Perl).
    my $sql = 'SELECT CASE WHEN (' . $where . ') THEN 1 ELSE 0 END, ' . join(', ', map { $self->quote_identifier($_) } @fields)
        . ' FROM (SELECT ' . join(', ', @columns) . ') AS ' . $self->quote_identifier('__selecto_candidate');
    Selecto::OperationBudget->new(limits => $command->metadata->{__selecto_limits}, code => 'invalid_write')
        ->consume_parameters(\@params, label => 'insert policy parameter');
    my ($sth, @row);
    my $ok = eval {
        $sth = $self->dbh->prepare($self->_statement_sql($sql));
        die _dbi_error($self->dbh, 'insert admission preparation failed') unless $sth;
        defined($self->_execute_statement($sth, \@params))
            or die _dbi_error($sth, 'insert admission failed');
        @row = $sth->fetchrow_array;
        die _dbi_error($sth, 'insert admission fetch failed') unless @row;
        # Overflow to a non-finite database number is outside this profile.
        for my $index (0 .. $#fields) {
            # A verified BOOLEAN cast cannot overflow; its driver rendering
            # may be 0/1 or t/f and need not match canonical caller scalars.
            next if $candidate->{types}{$fields[$index]} eq 'boolean';
            Selecto::InsertAdmission::_value($candidate->{types}{$fields[$index]}, $row[$index + 1], $fields[$index]);
        }
        1;
    };
    # Normalize first: finish clears the handle's SQLSTATE.
    my $error = $ok ? undef : $self->normalize_error($@);
    eval { $sth->finish } if $sth;
    die $error unless $ok;
    $budget->check;
    Selecto::Error->throw('query_rule_violation', 'insert candidate does not satisfy the enforced query',
        {truth_value => 'false_or_unknown'}) unless defined($row[0]) && "$row[0]" eq '1';
}

# Resolve declared cardinality independently of SQL rendering. A caller's
# legacy exact count remains an additional constraint; trusted engine ceilings
# bound both probes and the final effect, even for an otherwise unbounded range.
sub _validate_write_cardinality {
    my ($self, $command) = @_;
    my $metadata = $command->metadata;
    my $declared = exists $metadata->{expected_cardinality};
    my $expected = $command->expected_count;
    my ($minimum, $maximum) = (0, undef);
    if ($declared) {
        ($minimum, $maximum) = @{Selecto::Write::Policy->cardinality_bounds($metadata->{expected_cardinality})};
        Selecto::Error->throw('invalid_expected_cardinality', 'legacy count conflicts with declared write cardinality')
            if defined($expected) && (ref($expected) || "$expected" !~ /\A\d{1,9}\z/
                || $expected < $minimum || defined($maximum) && $expected > $maximum);
    }
    if (exists $metadata->{__selecto_primary_key}) {
        my $ceiling = $metadata->{__selecto_write_limit} // 1000;
        Selecto::Error->throw('invalid_write', 'write row ceiling must be a positive integer')
            if ref($ceiling) || "$ceiling" !~ /\A[1-9]\d{0,8}\z/;
        Selecto::Error->throw('invalid_write', 'write cardinality requires a finite nonnegative integer')
            if defined($expected) && (ref($expected) || "$expected" !~ /\A\d{1,9}\z/);
        Selecto::Error->throw('invalid_write', 'write cardinality exceeds the trusted row ceiling')
            if defined($expected) && $expected > $ceiling || $minimum > $ceiling;
        $maximum = 0 + $ceiling if !defined($maximum) || $maximum > $ceiling;
    }
    if (defined $expected) {
        $minimum = 0 + $expected;
        $maximum = 0 + $expected;
    }
    return { minimum => $minimum, maximum => $maximum, declared => $declared,
        expected => $declared ? $metadata->{expected_cardinality} : $expected };
}

sub _check_write_cardinality {
    my ($self, $command, $affected, $bounds) = @_;
    $bounds //= $self->_validate_write_cardinality($command);
    Selecto::Error->throw('cardinality_mismatch', 'write affected an unexpected number of rows',
        { expected => $bounds->{expected} })
        if $affected < $bounds->{minimum} || defined($bounds->{maximum}) && $affected > $bounds->{maximum};
    return 1;
}

sub _execute_compiled_write_in_transaction {
    my ($self, $command, $compiled) = @_;
    # Session state around the DML (dialect hook; PostgreSQL, brief items 54,
    # 56, 59): read before any of the write's own SQL, compared by the first
    # statement after the DML. The write's relation as resolved before the
    # DML (item 51) lives for this write only.
    my $session = $self->_write_session_open($command, $compiled);
    local $self->{_selecto_write_target} = {};
    my $bounds = $self->_validate_write_cardinality($command);
    $self->_admit_plan_storage([$command]);
    $self->_check_typed_insert_admission($command);
    # A governed update's trusted scope (required predicate, host scope,
    # query enforcement) must hold for the rows it leaves behind too: an
    # assignment, or a BEFORE UPDATE trigger, could move a row out of scope.
    # Its rows are locked and named by key first, and re-read afterwards.
    my $post_image = _post_image_predicate($command);
    $self->_admit_post_image_target($command) if $post_image;
    # A guarded insert's stored rows are re-read under its full guard after
    # the statement, where the dialect re-reads by row id (PostgreSQL, items
    # 24, 65, R13): ordinary row triggers (updated_at, audit) then stay
    # allowed, and one that rewrites the row out of the guard is caught.
    my $insert_guard = $self->_rereads_by_row_id ? _insert_post_image_predicate($command) : undef;
    # The bound-scope target contract for deletes and for graph descendants
    # (see _bound_target_event), and for re-read guarded inserts: table
    # lock, READ COMMITTED, and no deferrable trigger, statement-level
    # trigger or rule for the event, checked before the statement and again
    # after it.
    my $bound_event = _bound_target_event($command) // ($insert_guard ? 'insert' : undef);
    $self->_bound_target_check($command, $bound_event, 'before') if $bound_event;
    my ($bounded, $identities) = $self->_bounded_write_command($command, $post_image ? (force => 1) : ());
    $compiled = $self->_compile_write($bounded) if $bounded != $command;
    $command = $bounded;
    my $row_ids = ($post_image || $insert_guard) && $self->_rereads_by_row_id;
    $compiled = $self->_with_row_ids($compiled) if $row_ids;
    my @row_ids;
    my ($sth, $affected, %values);
    my $ok = eval {
        if ($self->_statement_cache_enabled) {
            $sth = $self->_cached_execute($self->_statement_sql($compiled->{sql}), $compiled->{params}, 'database write failed');
        } else {
            $sth = $self->{dbh}->prepare($self->_statement_sql($compiled->{sql}));
            die _dbi_error($self->{dbh}, 'database prepare failed') unless $sth;
            my $executed = $self->_execute_statement($sth, $compiled->{params});
            die _dbi_error($sth, 'database write failed') unless defined $executed;
        }
        if ($compiled->{row_ids}) {
            # Every row's (tableoid, ctid) follows the requested RETURNING
            # columns; the first row's leading columns are the values.
            my @wanted = @{$compiled->{returning} // []};
            my ($first, $returned);
            while (my @row = $sth->fetchrow_array) {
                Selecto::Error->throw('query_error', 'write row identity is unavailable')
                    unless @row == @wanted + 2 && defined($row[-1]) && defined($row[-2]);
                push @row_ids, [@row[-2, -1]];
                $first //= [@row[0 .. $#wanted]];
                ++$returned;
            }
            die _dbi_error($sth, 'database returning fetch failed') if eval { $sth->err };
            if (@wanted) {
                _guarded_cardinality($command, 0) if !$returned && @{$command->foreign_key_guards};
                $self->_check_write_cardinality($command, 0, $bounds) unless $returned;
                Selecto::Error->throw('write_returning_missing', 'write did not return the requested row')
                    if !$returned && !$bounds->{declared};
                @values{@wanted} = $self->_decode_returning_values($sth, @$first) if $returned;
            }
            $affected = $self->_logical_affected_rows($command->operation, $returned // 0);
        } elsif (@{$compiled->{returning} // []}) {
            my @row = $sth->fetchrow_array;
            die _dbi_error($sth, 'database returning fetch failed')
                if !@row && eval { $sth->err };
            # A guarded write that yields no row was refused by its guard.
            _guarded_cardinality($command, 0) if !@row && @{$command->foreign_key_guards};
            $self->_check_write_cardinality($command, 0, $bounds) unless @row;
            Selecto::Error->throw('write_returning_missing', 'write did not return the requested row')
                if !@row && !$bounds->{declared};
            @values{@{$compiled->{returning}}} = $self->_decode_returning_values($sth, @row) if @row;
            # RETURNING emits one row per affected row. Some DBI drivers report
            # provisional counts until the result is exhausted. Drain before
            # checking cardinality or committing, retaining only the first row.
            my $returned = @row ? 1 : 0;
            while (my @remaining = $sth->fetchrow_array) { ++$returned; }
            die _dbi_error($sth, 'database returning fetch failed') if eval { $sth->err };
            $affected = $self->_logical_affected_rows($command->operation, $returned);
        } else {
            $affected = $self->_logical_affected_rows($command->operation, 0 + $sth->rows);
        }
        1;
    };
    die $self->normalize_error($@) unless $ok;
    # The first statement after the DML (item 54a).
    $self->_write_session_check($session);
    $self->_check_write_cardinality($command, $affected, $bounds);
    $self->_bound_target_check($command, $bound_event, 'after') if $bound_event;
    if ($post_image) {
        $self->_recheck_post_image_target($command);
        $row_ids ? $self->_verify_row_post_image($command, $post_image, \@row_ids, $affected)
            : $self->_verify_post_image($command, $post_image, $identities, $affected);
    }
    $self->_verify_row_post_image($command, $insert_guard, \@row_ids, $affected, 'insert') if $insert_guard;
    # Without an expected count, a guarded write that changed nothing is still
    # refused rather than reported as an empty success.
    _guarded_cardinality($command, $affected) if !$affected && @{$command->foreign_key_guards};
    # The session as the host had it (PostgreSQL restores its search_path,
    # pinned for the write, R30); a refusal above rolls the pin back instead.
    $self->_write_session_close($session);
    return Selecto::Write::Result->new(operation => $command->operation, affected_rows => $affected, values => \%values);
}

# The bound part of a governed update's predicate, which its post-image must
# still satisfy (TW-09, bound tenant-like scope): the engine tenant,
# writes.scope and the host's scope predicate, as the engine recorded them.
# The required predicate, query enforcement and the caller's filter bound
# the pre-image only: an update may change the column it was found by.
# The engine tenant's columns are immutable, but a BEFORE UPDATE trigger
# could still rewrite them: they are re-read like any bound scope.
# A guarded insert's full guard (its predicate, scope and query
# enforcement: an insert has no pre-image, items 24, 65), when it has one and
# the typed storage admission runs for it.
sub _insert_post_image_predicate {
    my ($command) = @_;
    return undef unless $command->operation eq 'insert';
    return undef unless defined($command->metadata->{__selecto_insert_types} // _declared_admission_types($command));
    return Selecto::QueryEnforcement::combine(
        $command->predicate, $command->scope_predicate,
        defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
    );
}

# The post-image re-read by row id (PostgreSQL, R9): the rows the statement
# reported (RETURNING tableoid, ctid) are read again after every trigger has
# run, FROM the schema-qualified relation resolved before the statement and
# only among its own oids; each must still exist at that row id (a row a
# later trigger moved again has a new one) and satisfy $predicate under the
# write's host-exact comparison. A key-renumbering trigger or a decoy row
# sharing the old key value cannot stand in for a moved row.
sub _verify_row_post_image {
    my ($self, $command, $predicate, $row_ids, $affected, $kind) = @_;
    return 1 unless $affected;
    my %wanted = map { (join(':', @$_) => 1) } @$row_ids;
    Selecto::Error->throw('query_rule_violation', 'the written rows could not be identified',
        {truth_value => 'false_or_unknown'}) unless keys(%wanted) == @$row_ids && @$row_ids == $affected;
    my $relation = Selecto::Identifier::checked($command->relation);
    my $target = $self->_pg_write_target($relation);
    my @params;
    my $condition = $self->_compile_write_predicate($predicate, \@params);
    push @params, $target->{oids};
    my $oids = $self->placeholder(scalar @params);
    push @params, [map { $_->[1] } @$row_ids];
    my $tids = $self->placeholder(scalar @params);
    my $sql = 'SELECT CAST(tableoid AS pg_catalog.text), CAST(ctid AS pg_catalog.text), '
        . "CASE WHEN ($condition) THEN 1 ELSE 0 END FROM $target->{qualified}"
        . " WHERE tableoid OPERATOR(pg_catalog.=) ANY (CAST($oids AS pg_catalog.oid[]))"
        . " AND ctid OPERATOR(pg_catalog.=) ANY (CAST($tids AS pg_catalog.tid[]))";
    my $rows;
    my $ok = eval { $rows = $self->dbh->selectall_arrayref($self->_statement_sql($sql), undef, @params); 1 };
    die $self->normalize_error($@) unless $ok;
    my %seen;
    for my $row (@$rows) {
        my $id = "$row->[0]:$row->[1]";
        next unless $wanted{$id};
        $seen{$id} = defined($row->[2]) && "$row->[2]" eq '1' ? 1 : 0;
    }
    return 1 if keys(%seen) == keys(%wanted) && !grep { !$_ } values %seen;
    # A guarded insert the typed admission accepted, rewritten by a BEFORE
    # INSERT row trigger so it no longer satisfies its guard: the trigger
    # made the admission unevaluable (typed_insert_admission TA005), and the
    # insert is refused and rolled back as before the re-read existed.
    Selecto::Error->throw('query_rule_not_evaluable',
        'a BEFORE INSERT trigger rewrote the guarded row; the insert admission cannot be evaluated',
        {reason => 'transforming_trigger', relation => $relation})
        if ($kind // '') eq 'insert' && $self->_pg_before_insert_triggers($target->{oid});
    Selecto::Error->throw('query_rule_violation',
        ($kind // '') eq 'insert' ? 'inserted row does not satisfy its guard after the statement'
            : 'updated row no longer satisfies its trusted scope',
        {truth_value => 'false_or_unknown'});
}

# Whether the relation (by oid) has an enabled user-defined BEFORE INSERT
# row trigger (tgtype bits: ROW 1, BEFORE 2, INSERT 4).
sub _pg_before_insert_triggers {
    my ($self, $oid) = @_;
    my ($count);
    my $ok = eval {
        ($count) = $self->dbh->selectrow_array(q{SELECT pg_catalog.count(*) FROM pg_catalog.pg_trigger t
            WHERE t.tgrelid OPERATOR(pg_catalog.=) CAST(? AS pg_catalog.oid) AND NOT t.tgisinternal
              AND t.tgenabled OPERATOR(pg_catalog.<>) 'D'
              AND (t.tgtype OPERATOR(pg_catalog.&) CAST(7 AS pg_catalog.int2)) OPERATOR(pg_catalog.=) CAST(7 AS pg_catalog.int2)},
            undef, $oid);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return $count ? 1 : 0;
}

sub _post_image_predicate {
    my ($command) = @_;
    return undef unless $command->operation eq 'update' && exists $command->metadata->{__selecto_primary_key};
    my $predicate = $command->metadata->{__selecto_post_image_scope};
    return blessed($predicate) && $predicate->isa('Selecto::Expression') ? $predicate : undef;
}

# The re-read runs after the statement, when every BEFORE and AFTER trigger
# (row or statement level) has run, so ordinary triggers (updated_at, audit)
# keep working and one that moves a row out of scope is caught. It cannot see
# what runs later, or through another relation: a deferrable constraint
# trigger (PostgreSQL) fires at commit, and a view's rules or INSTEAD OF
# triggers write elsewhere. Those are refused before the update.
#
# PostgreSQL: a deferrable constraint trigger anywhere in the database is
# refused, not only one on the written relation: a leaf partition's or an
# inheritance child's fires for rows the update reaches through the parent,
# and one on another table fires when a row trigger writes there (an audit
# table) and can then rewrite the updated row at commit. Statement-level
# update triggers and rules are refused on the relation and on every
# partition or child below it. A relation with (non-partition) inheritance
# children is refused: its key is not unique across the children, so the
# re-read by key could find a decoy row in a child. Every other adapter
# (SQL Server, DuckDB) refuses bound-scope updates outright: it never
# re-reads the rows, so a generated column, a trigger or a view/synonym
# could leave the scope unseen.
sub _admit_post_image_target {
    my ($self, $command) = @_;
    my $table = Selecto::Identifier::checked($command->relation);
    my $refuse = sub { Selecto::Error->throw('query_rule_not_evaluable', $_[0], {relation => $table}) };
    my $name = $self->name;
    Selecto::Error->throw('write_capability_missing',
        ({mssql => 'SQL Server', duckdb => 'DuckDB'}->{$name} // 'adapter')
            . ' cannot verify that an update keeps its rows in their trusted scope', {relation => $table})
        unless $name =~ /\A(?:postgresql|sqlite|mysql|mariadb)\z/;
    my $dbh = $self->dbh;
    my @row;
    my $ok = eval {
        if ($name eq 'postgresql') {
            # ROW EXCLUSIVE (what the UPDATE takes anyway, on every partition
            # and child too) conflicts with CREATE TRIGGER, ALTER TABLE ...
            # ENABLE TRIGGER and CREATE RULE on them: the catalog read below
            # stays true for these relations until commit.
            $dbh->do('LOCK TABLE ' . $self->quote_identifier($table) . ' IN ROW EXCLUSIVE MODE');
            $self->_require_read_committed($table);
            # Resolved under the lock, before the statement (item 51).
            @row = $self->_pg_post_image_catalog($self->_pg_resolve_write_target($table)->{oid});
        } elsif ($name eq 'sqlite') {
            @row = $dbh->selectrow_array(q{SELECT type, 0 FROM sqlite_master WHERE name = ? AND type IN ('table', 'view')},
                undef, $table);
        } else {
            # Read the table first, in the write's transaction: its shared
            # metadata lock holds until commit, so a concurrent CREATE
            # TRIGGER, ALTER or DROP INDEX cannot change what the
            # information_schema checks below (kind, unique key) describe.
            $dbh->do($self->_statement_sql('SELECT 1 FROM ' . $self->quote_identifier($table) . ' LIMIT 0'));
            @row = $dbh->selectrow_array($self->_statement_sql(q{SELECT TABLE_TYPE, 0 FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?}), undef, $table);
        }
        1;
    };
    die $self->normalize_error($@) unless $ok;
    my ($kind, $deferrable, $statement_trigger, $inheritance, $rules) = @row;
    $refuse->('a governed update through a view cannot verify the rows it leaves behind')
        unless defined($kind) && ($kind eq 'r' || $kind eq 'p' || $kind eq 'table' || $kind eq 'BASE TABLE');
    $refuse->('a deferrable constraint trigger could change the rows after their verification') if $deferrable;
    $refuse->('a governed update under a bound scope cannot verify a relation with inheritance children') if $inheritance;
    $refuse->('a rule on the relation could rewrite the update outside the verified scope') if $rules;
    # A statement-level UPDATE trigger can write rows the re-read does not
    # name. Row-level triggers that modify OTHER rows stay allowed (user
    # decision, TW item 19): their effects are the schema owner's
    # responsibility, and the re-read covers the updated rows only.
    Selecto::Error->throw('write_capability_missing',
        'a statement-level update trigger can write rows outside the verified scope', {relation => $table})
        if $statement_trigger;
    # information_schema describes the base table, not a session TEMPORARY
    # table shadowing it (MySQL).
    $self->_refuse_temporary_shadow($table) if $self->can('_refuse_temporary_shadow');
    # The re-read names the updated rows by their key: the key must be
    # unique (contain an enforced PRIMARY/UNIQUE index of whole, NOT NULL
    # columns) and must not change, or another row sharing the old key value
    # could stand in for a row the update moved out of scope.
    # A re-read by row id (PostgreSQL) needs no key: any key, assigned or
    # not, unique or not, only bounds which rows are locked.
    return if $self->_rereads_by_row_id;
    my $primary = $command->metadata->{__selecto_primary_key};
    my @keys = map { Selecto::Identifier::checked($_) } ref($primary) eq 'ARRAY' ? @$primary : ($primary);
    my %key = map { (lc($_) => 1) } @keys;
    $refuse->('a governed update under a bound scope cannot assign its key')
        if grep { $key{lc $_} } keys %{$command->assignments};
    $refuse->('a governed update under a bound scope requires an enforced unique key')
        unless $self->_enforced_unique_key($table, \@keys);
    return;
}

# PostgreSQL: a guarded write's catalog checks (triggers, rules,
# inheritance) are only meaningful under READ COMMITTED. Under REPEATABLE
# READ or SERIALIZABLE, catalog queries read the transaction snapshot while
# trigger firing uses the latest catalog, so a trigger committed after the
# snapshot passes every check and still fires. Read in the write's
# transaction (a host's transaction, or a managed one, which begins READ
# COMMITTED explicitly); anything else is refused.
sub _require_read_committed {
    my ($self, $table) = @_;
    return unless $self->name eq 'postgresql';
    my $level;
    my $ok = eval { ($level) = $self->dbh->selectrow_array(q{SELECT pg_catalog.current_setting('transaction_isolation')}); 1 };
    die $self->normalize_error($@) unless $ok;
    Selecto::Error->throw('query_rule_not_evaluable',
        'a guarded PostgreSQL write requires READ COMMITTED isolation',
        {reason => 'isolation_level', relation => $table, isolation => $level})
        unless defined($level) && $level eq 'read committed';
    return;
}

# PostgreSQL catalog facts the post-image check depends on: the relation's
# kind; whether any enabled non-internal deferrable trigger exists in the
# database; statement-level UPDATE triggers, (non-partition) inheritance
# children and rules on the relation or any partition or child below it.
# Read by the oid resolved before the statement (item 51a).
sub _pg_post_image_catalog {
    my ($self, $oid) = @_;
    return $self->dbh->selectrow_array(q{
                WITH RECURSIVE tree(oid, partition) AS (
                  SELECT c.oid, TRUE FROM pg_catalog.pg_class c WHERE c.oid OPERATOR(pg_catalog.=) CAST(? AS pg_catalog.oid)
                  UNION ALL
                  SELECT i.inhrelid, child.relispartition FROM pg_catalog.pg_inherits i
                  JOIN tree ON i.inhparent OPERATOR(pg_catalog.=) tree.oid
                  JOIN pg_catalog.pg_class child ON child.oid OPERATOR(pg_catalog.=) i.inhrelid)
                SELECT CAST(c.relkind AS pg_catalog.text),
                  CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t WHERE NOT t.tgisinternal
                    AND t.tgenabled OPERATOR(pg_catalog.<>) 'D' AND t.tgdeferrable) AS pg_catalog.int4),
                  CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t JOIN tree ON t.tgrelid OPERATOR(pg_catalog.=) tree.oid
                    WHERE NOT t.tgisinternal AND t.tgenabled OPERATOR(pg_catalog.<>) 'D'
                    AND (t.tgtype OPERATOR(pg_catalog.&) CAST(1 AS pg_catalog.int2)) OPERATOR(pg_catalog.=) CAST(0 AS pg_catalog.int2)
                    AND (t.tgtype OPERATOR(pg_catalog.&) CAST(16 AS pg_catalog.int2)) OPERATOR(pg_catalog.<>) CAST(0 AS pg_catalog.int2)) AS pg_catalog.int4),
                  CAST(EXISTS(SELECT 1 FROM tree WHERE NOT tree.partition) AS pg_catalog.int4),
                  CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_rewrite r JOIN tree ON r.ev_class OPERATOR(pg_catalog.=) tree.oid
                    WHERE r.rulename OPERATOR(pg_catalog.<>) CAST('_RETURN' AS pg_catalog.name)) AS pg_catalog.int4)
                FROM pg_catalog.pg_class c WHERE c.oid OPERATOR(pg_catalog.=) CAST(? AS pg_catalog.oid)}, undef, $oid, $oid);
}

# After the UPDATE and before the re-read (PostgreSQL): the table lock keeps
# the written relations' triggers and rules fixed, but a deferrable trigger
# on another table (an audit table a row trigger writes to) could have been
# created or enabled while the update waited for its rows. A deferred event
# is queued only for a trigger that existed when the row trigger fired, so a
# clean check now closes that window; otherwise the write is refused and
# rolled back.
sub _recheck_post_image_target {
    my ($self, $command) = @_;
    return unless $self->name eq 'postgresql';
    my $table = Selecto::Identifier::checked($command->relation);
    my @row;
    my $oid = $self->_pg_write_target($table)->{oid};
    my $ok = eval { @row = $self->_pg_post_image_catalog($oid); 1 };
    die $self->normalize_error($@) unless $ok;
    my ($kind, $deferrable, $statement_trigger, $inheritance, $rules) = @row;
    Selecto::Error->throw('query_rule_not_evaluable',
        'a deferrable constraint trigger could change the rows after their verification', {relation => $table})
        if $deferrable;
    Selecto::Error->throw('query_rule_not_evaluable',
        'the relation gained inheritance children or rules while the update ran', {relation => $table})
        if $inheritance || $rules;
    Selecto::Error->throw('write_capability_missing',
        'a statement-level update trigger can write rows outside the verified scope', {relation => $table})
        if $statement_trigger;
    return;
}

# True when @$keys contain every column of an enforced unique index (or
# primary key) whose columns are whole and NOT NULL, read from the catalog
# in the write's transaction.
sub _enforced_unique_key {
    my ($self, $table, $keys) = @_;
    # MySQL and MariaDB share the stored-row re-check's rule.
    return $self->_unique_key_columns($table, $keys) if $self->can('_unique_key_columns');
    my %want = map { (lc($_) => 1) } @$keys;
    my $dbh = $self->dbh;
    my @indexes;
    my $ok = eval {
        if ($self->name eq 'sqlite') {
            my %info = map { (lc($_->{name}) => $_) }
                @{$dbh->selectall_arrayref('PRAGMA table_info(' . $self->quote_identifier($table) . ')', {Slice => {}})};
            my @pk = sort { $a->{pk} <=> $b->{pk} } grep { $_->{pk} } values %info;
            # An INTEGER PRIMARY KEY is the rowid: unique and never NULL.
            push @indexes, [[$pk[0]{name}, 1]] if @pk == 1 && uc($pk[0]{type} // '') eq 'INTEGER';
            for my $index (@{$dbh->selectall_arrayref('PRAGMA index_list(' . $self->quote_identifier($table) . ')', {Slice => {}})}) {
                next unless $index->{unique} && !$index->{partial};
                my $columns = $dbh->selectall_arrayref('PRAGMA index_info(' . $self->quote_identifier($index->{name}) . ')', {Slice => {}});
                # SQLite lets a non-INTEGER PRIMARY KEY column hold NULL
                # unless declared NOT NULL. A NULL key is never named by the
                # re-read (IN never matches it; a NULL locked key fails the
                # count), and the index keeps every other value unique.
                my $primary = ($index->{origin} // '') eq 'pk';
                push @indexes, [map { [$_->{name}, defined($_->{name}) && ($primary || $info{lc $_->{name}}{notnull}) ? 1 : 0] } @$columns];
            }
        }
        1;
    };
    die $self->normalize_error($@) unless $ok;
    for my $index (@indexes) {
        next unless @$index;
        return 1 unless grep { !defined($_->[0]) || !$want{lc $_->[0]} || !$_->[1] } @$index;
    }
    return 0;
}

# Which bound-scope target contract a write runs (PostgreSQL), if any:
# - a governed delete under a bound scope (engine tenant, writes.scope, host
#   scope, a required tenant pin) or under query enforcement alone (a plain
#   required filter alone is not bound, TW-09);
# - a delete or update of any node of a graph whose root (or any node) is
#   bound (__selecto_graph_bound, set by the engine), even when its own table
#   has no tenant column. A graph update that carries its own post-image
#   scope already runs the post-image contract.
sub _bound_target_event {
    my ($command) = @_;
    my $metadata = $command->metadata;
    return undef unless exists $metadata->{__selecto_primary_key};
    my $operation = $command->operation;
    return 'delete' if $operation eq 'delete'
        && (blessed($metadata->{__selecto_post_image_scope}) || defined($command->query_enforcement)
            || $metadata->{__selecto_graph_bound});
    return 'update' if $operation eq 'update' && $metadata->{__selecto_graph_bound} && !_post_image_predicate($command);
    # A graph-bound insert or upsert (a child, join-table or deeper row under a
    # bound root) may carry no predicate of its own, so no insert admission
    # runs; it still gets the target contract for its events.
    return $operation if ($operation eq 'insert' || $operation eq 'upsert') && $metadata->{__selecto_graph_bound};
    return undef;
}

# PostgreSQL bound-scope target contract. Before the statement: LOCK TABLE
# ... IN ROW EXCLUSIVE MODE (the write's own lock, recursing to partitions
# and children), so triggers and rules on these relations cannot change
# until commit, and READ COMMITTED. Before and after it: no enabled
# deferrable constraint trigger anywhere in the database (it fires at
# commit), and no statement-level trigger or rule for the event on the
# relation or below it (they can write rows outside the write's scope).
# Row-level triggers that modify other rows are the schema owner's
# responsibility (item 19).
sub _bound_target_check {
    my ($self, $command, $event, $phase) = @_;
    return unless $self->name eq 'postgresql';
    my $table = Selecto::Identifier::checked($command->relation);
    # pg_trigger.tgtype bits (4 INSERT, 8 DELETE, 16 UPDATE) and
    # pg_rewrite.ev_type ('3' INSERT, '4' DELETE, '2' UPDATE) for the events
    # the write can fire; an upsert can insert or update.
    my ($mask, @rule_events) = @{{delete => [8, '4'], update => [16, '2'], insert => [4, '3'], upsert => [4 | 16, '3', '2']}->{$event}};
    my ($first_rule, $second_rule) = (@rule_events, @rule_events)[0, 1];
    my ($deferrable, $statement, $rules);
    my $ok = eval {
        my $oid;
        if ($phase eq 'before') {
            $self->dbh->do('LOCK TABLE ' . $self->quote_identifier($table) . ' IN ROW EXCLUSIVE MODE');
            $self->_require_read_committed($table);
            $oid = $self->_pg_resolve_write_target($table)->{oid};
        } else {
            # By the oid resolved before the statement (item 51a).
            $oid = $self->_pg_write_target($table)->{oid};
        }
        ($deferrable, $statement, $rules) = $self->dbh->selectrow_array(q{
            WITH RECURSIVE tree(oid) AS (
              SELECT CAST(? AS pg_catalog.oid)
              UNION ALL
              SELECT i.inhrelid FROM pg_catalog.pg_inherits i JOIN tree ON i.inhparent OPERATOR(pg_catalog.=) tree.oid)
            SELECT
              CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t WHERE NOT t.tgisinternal
                AND t.tgenabled OPERATOR(pg_catalog.<>) 'D' AND t.tgdeferrable) AS pg_catalog.int4),
              CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t JOIN tree ON t.tgrelid OPERATOR(pg_catalog.=) tree.oid
                WHERE NOT t.tgisinternal AND t.tgenabled OPERATOR(pg_catalog.<>) 'D'
                AND (t.tgtype OPERATOR(pg_catalog.&) CAST(1 AS pg_catalog.int2)) OPERATOR(pg_catalog.=) CAST(0 AS pg_catalog.int2)
                AND (t.tgtype OPERATOR(pg_catalog.&) CAST(? AS pg_catalog.int2)) OPERATOR(pg_catalog.<>) CAST(0 AS pg_catalog.int2)) AS pg_catalog.int4),
              CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_rewrite r JOIN tree ON r.ev_class OPERATOR(pg_catalog.=) tree.oid
                WHERE (r.ev_type OPERATOR(pg_catalog.=) CAST(? AS pg_catalog."char") OR r.ev_type OPERATOR(pg_catalog.=) CAST(? AS pg_catalog."char"))
                  AND r.rulename OPERATOR(pg_catalog.<>) CAST('_RETURN' AS pg_catalog.name)) AS pg_catalog.int4)},
            undef, $oid, $mask, $first_rule, $second_rule);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    Selecto::Error->throw('query_rule_not_evaluable',
        'a deferrable constraint trigger could change the rows after their verification', {relation => $table})
        if $deferrable;
    Selecto::Error->throw('write_capability_missing',
        "a statement-level $event trigger can write rows outside the write's scope", {relation => $table})
        if $statement;
    Selecto::Error->throw('write_capability_missing',
        "a rule on the relation can rewrite the $event outside the write's scope", {relation => $table})
        if $rules;
    return;
}

# Every locked row the update could have changed must still satisfy the
# trusted predicate, re-read in the write's transaction under the same
# (host-exact) comparison; otherwise the write fails and rolls back. Rows the
# update left unchanged satisfied it before and still do.
sub _verify_post_image {
    my ($self, $command, $predicate, $identities, $affected) = @_;
    return unless ref($identities) eq 'ARRAY' && @$identities;
    my $primary = $command->metadata->{__selecto_primary_key};
    my @keys = map { Selecto::Identifier::checked($_) } ref($primary) eq 'ARRAY' ? @$primary : ($primary);
    my $locked = @keys == 1 ? Selecto::Expression->in($keys[0], [map { $_->[0] } @$identities])
        : Selecto::Expression->any(map {
            my $identity = $_;
            Selecto::Expression->all(map { Selecto::Expression->eq($keys[$_], $identity->[$_]) } 0 .. $#keys)
        } @$identities);
    my @params;
    my $relation = Selecto::Identifier::checked($command->relation);
    my $table = $self->quote_identifier($relation);
    my $pg = $self->name eq 'postgresql';
    # PostgreSQL (item 51/51a): through the schema-qualified relation resolved
    # before the statement, and only its own rows (and its partitions'), with
    # pg_catalog functions; the session check before this ensured the rest
    # of the statement resolves as it did before the DML.
    my $target = $pg ? $self->_pg_write_target($relation) : undef;
    $table = $target->{qualified} if $target;
    my ($count, $sum) = $pg ? ('pg_catalog.count', 'pg_catalog.sum') : ('COUNT', 'SUM');
    my $sql = "SELECT $count(*), COALESCE($sum(CASE WHEN (" . $self->_compile_write_predicate($predicate, \@params)
        . ") THEN 1 ELSE 0 END), 0) FROM $table WHERE " . $self->_compile_write_predicate($locked, \@params);
    if ($target) {
        push @params, $target->{oids};
        $sql .= ' AND tableoid OPERATOR(pg_catalog.=) ANY (CAST(' . $self->placeholder(scalar @params) . ' AS pg_catalog.oid[]))';
    }
    my @row;
    my $ok = eval { @row = $self->dbh->selectrow_array($self->_statement_sql($sql), undef, @params); 1 };
    die $self->normalize_error($@) unless $ok;
    Selecto::Error->throw('query_rule_violation', 'updated row no longer satisfies its trusted scope',
        {truth_value => 'false_or_unknown'})
        unless defined($row[0]) && defined($row[1]) && $row[0] == @$identities && $row[1] == $row[0]
            && (!defined($affected) || $affected <= @$identities);
    return 1;
}

sub _bounded_write_command {
    my ($self, $command, %options) = @_;
    return $command unless $command->operation eq 'update' || $command->operation eq 'delete';
    my $metadata = $command->metadata;
    # Only the engine supplies this key before sealing the exact command in its
    # authorization. Explicit *_unsafe calls remain a trusted adapter escape.
    return $command unless exists $metadata->{__selecto_primary_key};
    my $primary = $metadata->{__selecto_primary_key};
    my @keys = map { Selecto::Identifier::checked($_) } ref($primary) eq 'ARRAY' ? @$primary : ($primary);
    Selecto::Error->throw('invalid_write', 'bounded write requires primary-key fields') unless @keys;
    my $bounds = $self->_validate_write_cardinality($command);
    my $limit = $bounds->{maximum};
    my $predicate = Selecto::QueryEnforcement::combine(
        $command->predicate, $command->scope_predicate,
        defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
    );
    my @identity_bounds = map { _write_identity_bound($predicate, $_) } @keys;
    # The conjunction must bound every component. Multiply component bounds
    # conservatively; an equality on just one part is never a row identity.
    my $identity_bound = 1;
    for my $bound (@identity_bounds) {
        if (!defined $bound) { $identity_bound = undef; last }
        $identity_bound *= $bound;
        if ($identity_bound > $limit) { $identity_bound = undef; last }
    }
    # A predicate selecting at most N distinct primary keys already bounds
    # mutation work without a second query or a check/use interval.
    my $name = $self->name;
    my $lockable = $name =~ /\A(?:postgresql|sqlite|mysql|mariadb)\z/;
    if (defined($identity_bound) && $identity_bound <= $limit) {
        return $command unless $options{force};
        # An adapter that cannot lock and re-read the rows keeps an identity-
        # bounded update only when it assigns no column its trusted scope
        # reads (the post-image then cannot leave the scope by assignment).
        if (!$lockable) {
            my %scoped = map { ($_ => 1) } Selecto::Expression->field_references(_post_image_predicate($command));
            Selecto::Error->throw('write_capability_missing',
                'adapter cannot verify that an update keeps its rows in their trusted scope')
                if grep { $scoped{$_} } keys %{$command->assignments};
            return $command;
        }
    }
    Selecto::Error->throw('write_capability_missing', 'adapter cannot safely bound a broad write')
        unless $lockable;
    my @params;
    my $where = $self->_compile_write_predicate($predicate, \@params);
    my $table = $self->quote_identifier(Selecto::Identifier::checked($command->relation));
    my $columns = join(', ', map { $self->quote_identifier($_) } @keys);
    my $probe_limit = $limit + 1;
    # PostgreSQL locks and then names the rows by (tableoid, ctid): exact
    # whatever the key's type or the session's settings (a float or
    # timestamp key rebound as text could miss its row), and stable while
    # the row lock is held.
    my $by_row = $self->_rereads_by_row_id;
    my $selected = $by_row ? 'CAST(tableoid AS pg_catalog.text), CAST(ctid AS pg_catalog.text)' : $columns;
    my $sql = "SELECT $selected FROM $table WHERE $where ORDER BY $columns LIMIT $probe_limit";
    # InnoDB locking reads hold the selected keys until the write commits.
    $sql .= ' FOR UPDATE' if $name =~ /\A(?:postgresql|mysql|mariadb)\z/;
    # Recover a timed-out PostgreSQL statement before restoring session
    # settings. The outer write transaction still owns all selected row locks.
    my $savepoint = $name eq 'postgresql' ? _savepoint_name('selecto_bounded_probe') : undef;
    if ($savepoint) {
        eval { $self->_savepoint_command(create => $savepoint); 1 }
            or die $self->_transaction_control_error($@);
    }
    my ($budget, $sth, @identities, $error);
    my $ok = eval {
        $budget = $self->begin_query_budget(timeout_ms => 5000);
        $sth = $self->dbh->prepare($self->_statement_sql($sql));
        die _dbi_error($self->dbh, 'bounded write preparation failed') unless $sth;
        defined($self->_execute_statement($sth, \@params))
            or die _dbi_error($sth, 'bounded write selection failed');
        while (my @row = $sth->fetchrow_array) {
            $budget->check;
            push @identities, [@row];
            last if @identities > $limit;
        }
        die _dbi_error($sth, 'bounded write fetch failed') if eval { $sth->err };
        1;
    };
    $error = $self->normalize_error($@) unless $ok;
    eval { $sth->finish } if $sth;
    my $restored = eval {
        $self->_savepoint_command(rollback => $savepoint) if !$ok && $savepoint;
        $budget->close if $budget;
        $self->_savepoint_command(release => $savepoint) if $savepoint;
        1;
    };
    if (!$restored) {
        eval { $budget->close } if $budget;
        $self->dbh->{private_selecto_query_budget_poisoned} = 1;
        Selecto::Error->throw('query_budget_restore_failed', 'bounded write could not restore its execution scope');
    }
    die $error unless $ok;
    $self->_check_write_cardinality($command, scalar(@identities), $bounds);
    # Keep every original scope and precondition, then constrain DML to the
    # exact locked keys. New matching rows can never join this mutation.
    my %by_oid;
    push @{$by_oid{$_->[0]}}, $_->[1] for $by_row ? @identities : ();
    my $keys = !@identities
        ? Selecto::Expression->all(Selecto::Expression->is_null($keys[0]), Selecto::Expression->not_null($keys[0]))
        : $by_row ? Selecto::Expression->any(map {
            Selecto::Expression->all(Selecto::Expression->eq('tableoid', $_), Selecto::Expression->in('ctid', $by_oid{$_}))
        } sort keys %by_oid)
        : @keys == 1 ? Selecto::Expression->in($keys[0], [map { $_->[0] } @identities])
        : Selecto::Expression->any(map {
            my $identity = $_;
            Selecto::Expression->all(map { Selecto::Expression->eq($keys[$_], $identity->[$_]) } 0 .. $#keys)
        } @identities);
    my $bounded = $command->with_scope_predicate(
        Selecto::QueryEnforcement::combine($command->scope_predicate, $keys));
    return wantarray ? ($bounded, \@identities) : $bounded;
}

sub _write_identity_bound {
    my ($expression, $key) = @_;
    return undef unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    my $args = $expression->arguments;
    if (($kind eq 'eq' || $kind eq 'in') && blessed($args->[0])
        && $args->[0]->kind eq 'field' && $args->[0]->arguments->[0] eq $key) {
        if ($kind eq 'eq') {
            return 1 if blessed($args->[1]) && $args->[1]->kind eq 'literal'
                && defined($args->[1]->arguments->[0]) && !ref($args->[1]->arguments->[0]);
        } elsif (ref($args->[1]) eq 'ARRAY' && !grep { !defined($_) || ref($_) } @{$args->[1]}) {
            my %ids = map { ("$_" => 1) } @{$args->[1]};
            return scalar keys %ids;
        }
    }
    if ($kind eq 'and') {
        my @bounds = grep { defined } map { _write_identity_bound($_, $key) } @{$args->[0]};
        return (sort { $a <=> $b } @bounds)[0] if @bounds;
    }
    return undef;
}

sub _guarded_cardinality {
    my ($command, $affected) = @_;
    Selecto::Error->throw('cardinality_mismatch', 'write affected an unexpected number of rows', {
        expected => $command->expected_count // 'at least 1',
    });
}

sub _transaction {
    my ($self, $operation) = @_;
    my $mode = $self->transaction_mode;
    Selecto::Error->throw('invalid_adapter', 'transaction_mode must be managed or external')
        unless defined($mode) && ($mode eq 'managed' || $mode eq 'external');
    my $handler = $self->transaction_handler;
    if (defined $handler) {
        Selecto::Error->throw('invalid_adapter', 'transaction_handler must be a code reference')
            unless ref($handler) eq 'CODE';
        Selecto::Error->throw('invalid_adapter', 'transaction_handler requires managed transaction mode')
            if $mode eq 'external';
    }
    if ($mode eq 'external') {
        my $auto_commit = eval { $self->{dbh}{AutoCommit} };
        Selecto::Error->throw(
            'invalid_adapter',
            'external transaction mode requires AutoCommit to be disabled',
        ) unless defined($auto_commit) && !$auto_commit;
        return $self->_external_transaction($operation);
    }
    return $self->_handler_transaction($handler, $operation) if defined $handler;
    return $self->_savepoint_transaction($operation) if $self->_transaction_open;
    return $self->_own_transaction($operation);
}

# External mode: the host owns the transaction, but a write refused after its
# DML ran (a post-image violation, a post-DML catalog recheck, a cardinality
# mismatch) must not leave that DML for the host to commit. The write runs in
# its own savepoint and rolls back to it on failure; the host's earlier work
# and its transaction are kept, and nothing is ever committed. (DuckDB has no
# savepoints and overrides this.)
sub _external_transaction {
    my ($self, $operation) = @_;
    return $self->_savepoint_transaction($operation);
}

# Managed mode on an idle handle: the write's own transaction.
sub _own_transaction {
    my ($self, $operation) = @_;
    # A transaction that never began is not rolled back: the handle may be
    # inside work this adapter cannot see.
    eval { $self->_begin_transaction; 1 }
        or die $self->_transaction_control_error($@);
    my ($value, $error);
    # The write unit this transaction owns (see _savepoint_transaction).
    my $ok = eval { $value = $operation->(); 1 };
    if ($ok) {
        $ok = eval { $self->_commit_transaction; 1 };
        $error = $self->_transaction_control_error($@) unless $ok;
    } else {
        $error = $@;
    }
    if (!$ok) {
        eval { $self->_rollback_transaction };
        die $error;
    }
    return $value;
}

# Managed mode inside the host's open transaction: the write commits or
# rolls back with the host, and a failure undoes only its savepoint.
sub _savepoint_transaction {
    my ($self, $operation) = @_;
    my $name = _savepoint_name('selecto_write');
    eval { $self->_savepoint_command(create => $name); 1 }
        or die $self->_transaction_control_error($@);
    # Inside a transaction the host owns (or an outer unit's), the host's
    # COMMIT, not Selecto's, ends it.
    my ($value, $error);
    my $ok = eval { $value = $operation->(); 1 };
    if ($ok) {
        $ok = eval { $self->_savepoint_command(release => $name); 1 };
        $error = $self->_transaction_control_error($@) unless $ok;
    } else {
        $error = $@;
    }
    if (!$ok) {
        eval {
            $self->_savepoint_command(rollback => $name);
            $self->_savepoint_command(release => $name);
        };
        die $error;
    }
    return $value;
}

# The host's transaction API runs the write; it must call the work once,
# inside a transaction. A write can be refused after its statement (an
# expected count, a post-image check), and on an autocommit handle its DML
# would already be committed, so work the handler runs outside a
# transaction is refused before any DML.
sub _handler_transaction {
    my ($self, $handler, $operation) = @_;
    my ($ran, $value, $failure) = (0);
    $handler->(sub {
        $ran = 1;
        my $ok = eval {
            Selecto::Error->throw('transaction_unavailable',
                'transaction_handler ran the write outside a transaction', {reason => 'autocommit'})
                unless $self->_transaction_open;
            # The write's own savepoint inside the handler's transaction: a
            # write refused after its statement undoes itself even when the
            # handler (or the host around it) goes on to commit.
            $value = $self->_handler_unit($operation);
            1;
        };
        unless ($ok) { $failure = $@; die $failure }
        return $value;
    });
    Selecto::Error->throw('invalid_adapter', 'transaction handler did not run the write')
        unless $ran;
    # A handler that swallowed the write's failure (and perhaps committed)
    # never turns it into a success: the original error is raised again.
    die $failure if defined $failure;
    return $value;
}

sub _handler_unit {
    my ($self, $operation) = @_;
    return $self->_savepoint_transaction($operation);
}

# A savepoint name no other savepoint shares, so a cleanup can only ever
# roll back to (or release) its own savepoint, never one an earlier or outer
# operation, or the host, created. A process serial keeps names distinct
# within the process; a random nonce (mixed with the pid, so forked children
# differ) keeps a host savepoint from colliding with it: on MySQL and
# MariaDB a SAVEPOINT reusing a name replaces the older one, and the
# write's RELEASE would then delete the host's savepoint. The old
# <prefix>_<pid>_<n> shape is never produced. Short enough for SQL Server's
# 32 characters: selecto_write_<hex serial>_<8 hex>.
my $SAVEPOINT_SERIAL = 0;
sub _savepoint_name {
    my ($prefix) = @_;
    my $nonce = (int(rand(4294967296)) ^ (($$ * 2654435761) % 4294967296)) % 4294967296;
    return sprintf('%s_%x_%08x', $prefix, ++$SAVEPOINT_SERIAL, $nonce);
}

# Whether the handle is inside a transaction the host opened: AutoCommit is
# off (after begin_work, or on an AutoCommit => 0 handle), or the dialect
# can see one on the server.
sub _transaction_open {
    my ($self) = @_;
    my $auto_commit = eval { $self->{dbh}{AutoCommit} };
    return 1 if defined($auto_commit) && !$auto_commit;
    return $self->_server_transaction_open ? 1 : 0;
}

# Dialect hook: true when the server reports an open transaction although
# AutoCommit is on (a raw BEGIN). Undef (unknown) keeps begin/commit.
sub _server_transaction_open { return undef; }

sub _begin_transaction {
    my ($self) = @_;
    $self->{dbh}->begin_work
        or die _dbi_error($self->{dbh}, 'database transaction could not begin');
    return;
}

sub _commit_transaction {
    my ($self) = @_;
    $self->{dbh}->commit
        or die _dbi_error($self->{dbh}, 'database transaction could not commit');
    return;
}

sub _rollback_transaction {
    my ($self) = @_;
    # A COMMIT that failed (a deferred constraint) has already ended the
    # transaction and turned AutoCommit back on: nothing is left to roll back.
    return if eval { $self->{dbh}{AutoCommit} } && !eval { $self->{dbh}{BegunWork} };
    $self->{dbh}->rollback;
    return;
}

# Dialect hook: the statement that creates (create), releases (release;
# undef when the dialect has none) or rolls back to (rollback) a savepoint.
sub _savepoint_sql {
    my ($self, $action, $name) = @_;
    return {
        create => "SAVEPOINT $name",
        release => "RELEASE SAVEPOINT $name",
        rollback => "ROLLBACK TO SAVEPOINT $name",
    }->{$action};
}

sub _savepoint_command {
    my ($self, $action, $name) = @_;
    my $sql = $self->_savepoint_sql($action, $name);
    return unless defined $sql;
    defined($self->{dbh}->do($sql))
        or die _dbi_error($self->{dbh}, "database savepoint $action failed");
    return;
}

# Begin, commit and savepoint failures become Selecto errors.
sub _transaction_control_error {
    my ($self, $error) = @_;
    return $error if blessed($error) && $error->isa('Selecto::Error');
    return $self->normalize_error($error);
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

# A dialect that can name its current date compares a shortcut's period with
# it, so the session (or query) time zone decides when a day begins. Others
# bind the bounds of the server's date.
sub _current_date_shortcuts { return 0 }

sub _compile_date_shortcut {
    my ($self, $domain, $expression, $params) = @_;
    my ($operand, $shortcut) = @{$expression->arguments};
    require Selecto::DateShortcut;
    unless ($self->_current_date_shortcuts) {
        require POSIX;
        return $self->_compile_expression($domain, Selecto::DateShortcut->expression(
            $operand, $shortcut, POSIX::strftime('%Y-%m-%d', localtime)), $params);
    }
    if (blessed($operand) && $operand->kind eq 'field') {
        my $type = $domain->resolve($operand->arguments->[0])->{type} // '';
        Selecto::Error->throw('invalid_query', 'date shortcut requires a date or time field')
            unless $type =~ /(?:date|time)/i;
        $operand = Selecto::Expression->epoch_datetime($operand) if $type eq 'epoch_datetime';
    }
    my $terms = Selecto::DateShortcut->terms($shortcut);
    if ($terms->{kind} eq 'recurring_month_day') {
        my $value = $self->_compile_expression($domain,
            Selecto::Expression->datetime_format($operand, 'month_day'), $params);
        my ($start, $end) = map {
            $self->_month_day_sql($self->_date_shortcut_bound_sql($_, $params))
        } $terms->{start}, $terms->{end};
        return "($value >= $start) AND ($value <= $end)";
    }
    my $value = $self->_compile_expression($domain, $operand, $params);
    my ($start, $end) = map { $self->_date_shortcut_bound_sql($_, $params) }
        $terms->{start}, $terms->{end};
    return "($value >= $start) AND ($value < $end)";
}

# [anchor, months, days] from Selecto::DateShortcut, as a SQL date.
sub _date_shortcut_bound_sql {
    my ($self, $term, $params) = @_;
    my ($anchor, $months, $days) = @$term;
    Selecto::Error->throw('invalid_query', 'date shortcut bound is invalid')
        unless $anchor =~ /\A(?:today|week|month|quarter|year)\z/
            && "$months" =~ /\A-?\d+\z/ && "$days" =~ /\A-?\d+\z/;
    my $today = defined($self->{_timezone})
        ? 'CAST(' . $self->_compile_timezone_sql(
            'CURRENT_TIMESTAMP', 'utc_datetime', $self->{_timezone}, $params) . ' AS DATE)'
        : 'CURRENT_DATE';
    my $sql = $anchor eq 'today' ? $today : "CAST(DATE_TRUNC('$anchor', $today) AS DATE)";
    $sql = 'CAST(' . $sql . ' + ' . $self->_months_interval_sql($months) . ' AS DATE)' if $months;
    return $days ? "($sql + $days)" : $sql;
}

# A utc_datetime column declared storage naive_utc holds UTC wall time without
# a zone. Dialects with zone-aware timestamps turn it into an instant here;
# the others store every timestamp naive and leave it unchanged.
sub _compile_naive_utc_instant_sql {
    my ($self, $sql) = @_;
    return $sql;
}

sub _compile_timezone_sql {
    my ($self) = @_;
    Selecto::Error->throw(
        'unsupported_feature', 'adapter does not support explicit query timezones',
    );
}

# Only an adapter that proves the native conflict branch may compile an empty
# update mask as DO NOTHING.
sub _admits_empty_upsert_mask { return 0 }

sub _compile_upsert_clause {
    my ($self, $conflict, $updates) = @_;
    my $target = ' ON CONFLICT (' . join(', ', map { $self->quote_identifier(Selecto::Identifier::checked($_)) } @$conflict) . ')';
    return $target . ' DO NOTHING' unless @$updates;
    return $target . ' DO UPDATE SET ' . join(', ', map {
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

__END__

=head1 NAME

Selecto::SQL - shared implementation for SQL database adapters

=head1 SYNOPSIS

  # Every bundled SQL adapter accepts these attributes:
  my $adapter = Selecto->adapter(postgresql => (
      dbh              => $dbh,         # a connected DBI handle you own
      transaction_mode => 'managed',    # or 'external'
      # transaction_handler => sub { my ($work) = @_; ... },   # optional
  ));

  # Subclassing for a new database:
  package MyApp::Selecto::FutureDB;
  use Mojo::Base 'Selecto::SQL';
  sub name        { 'futuredb' }
  sub dialect     { __PACKAGE__ }
  sub placeholder { '?' }

=head1 DESCRIPTION

C<Selecto::SQL> inherits L<Selecto::Adapter> and implements query
compilation (joins, computed fields, CTEs, set operations, windows, related
collections), eager and streaming execution, portable writes, write graphs
and transactions. The bundled adapters (L<Selecto::PostgreSQL>,
L<Selecto::SQLite>, L<Selecto::MySQL>, L<Selecto::MariaDB>,
L<Selecto::MSSQL>, L<Selecto::DuckDB>) subclass it and override only what
differs in their dialect.

Identifiers are validated and quoted separately from values; every value is
a bound parameter.

=head1 ATTRIBUTES

=head2 dbh

The DBI handle. Selecto never connects, reconnects or disconnects it.

=head2 transaction_mode

Every write, batch and graph is atomic, and Selecto never commits or rolls
back work it did not start. C<transaction_mode> chooses how:

C<managed> (default). On an idle handle (C<AutoCommit> on) the write runs in
its own transaction: C<begin_work>, then C<commit>, or C<rollback> on
failure. On a handle that is already inside a transaction (C<AutoCommit>
off after C<begin_work>, an C<< AutoCommit => 0 >> handle, or a transaction
the server reports although C<AutoCommit> is on) the write runs inside a
savepoint instead: C<SAVEPOINT selecto_write_E<lt>serialE<gt>_E<lt>nonceE<gt>> ...
C<RELEASE SAVEPOINT>, and C<ROLLBACK TO SAVEPOINT> then C<RELEASE> on
failure. Each savepoint name carries a process serial and a random nonce,
so no other savepoint (not one of the host's either) shares it, and a
cleanup can only roll back to or release its own. The write then
commits or rolls back with the host's transaction, a failed write undoes
only itself, and on PostgreSQL the host's transaction stays usable. The
host still commits; a managed write never commits an C<< AutoCommit => 0 >>
handle.

  $dbh->begin_work;
  $engine->execute_write($command);   # SAVEPOINT ... RELEASE, no commit
  $dbh->rollback;                     # the write is undone with the rest

Per adapter:

=over 4

=item * PostgreSQL, SQLite, MySQL and MariaDB use C<SAVEPOINT>. PostgreSQL
also detects a raw C<BEGIN> through C<pg_ping> and MySQL/MariaDB through
C<@@in_transaction>; DBD::SQLite turns C<AutoCommit> off itself.

=item * SQL Server uses C<SAVE TRANSACTION> and C<ROLLBACK TRANSACTION>
(it has no release) and detects a transaction with C<@@TRANCOUNT>. On an
C<< AutoCommit => 0 >> handle with nothing pending yet, the write's own
statements open the transaction, which is left for the host to commit and
rolled back on failure.

=item * DuckDB has no savepoints, so a managed write on a handle with
C<AutoCommit> off fails with C<invalid_adapter> before running anything;
use C<external> mode there. A transaction opened with raw C<BEGIN> makes the
adapter's own C<BEGIN> fail, and nothing is rolled back.

=back

A transaction that fails to begin is never rolled back. Begin, commit and
savepoint failures are reported as L<Selecto::Error>s (normally
C<query_error>); the write's own failure is reported unchanged. If a
savepoint cannot be rolled back (for example after a dropped connection)
the original error is still raised and the host must roll back.

C<external>: for hosts that already own a unit-of-work transaction. The
handle must have C<AutoCommit> disabled (otherwise C<invalid_adapter>) and
the adapter never begins, commits or rolls back the transaction. Each write
runs inside its own savepoint (as a managed write inside a host transaction
does), so a write refused after its statements ran (for example a post-image
violation) undoes only itself and a host that commits afterwards never
persists it. DuckDB, which has no savepoints, runs the write directly and
refuses (C<transaction_unavailable>, before any DML) a write that could be
refused after its statement ran; see L<Selecto::DuckDB>. The
host must still commit on success and should roll back on an exception it
cannot handle. Use this mode, or C<managed> inside the host's transaction,
with L<Selecto::Query/for_share> to keep an eligibility read valid until the
write commits.

An unknown mode fails with C<invalid_adapter> when a write runs.

=head2 transaction_handler

  my $adapter = Selecto->adapter(postgresql => (
      dbh => $dbh,
      transaction_handler => sub {
          my ($work) = @_;
          return $schema->txn_do($work);   # for example DBIx::Class
      },
  ));

C<managed> mode only. A code reference that replaces the adapter's own
transaction control: it is called with a code reference that runs the
write, must call it exactly once inside a transaction it controls, and
should return its value and let its exceptions propagate. A handler that
never calls the work fails with C<invalid_adapter>, as do a handler that is
not a code reference and a handler combined with C<external> mode.
The transaction must be open on the adapter's own connection when the work
starts (C<AutoCommit> off, or a transaction the server reports): a write can
be refused after its statement (an expected count, a post-image check), so
work run in autocommit is refused with C<transaction_unavailable> (details
C<< {reason => 'autocommit'} >>) before any statement. Inside the handler's
transaction the write runs in its own savepoint (DuckDB, which has none,
runs it directly), so a refused write undoes itself even if the handler
commits, and a failure the handler swallows is raised again after it
returns. On SQLite, writes
governed by stored-stage data rules additionally require the handler's
transaction (C<required_data_rule_pending> otherwise). The handler may
be called again for the write inside its own transaction, so it should run
nested work directly.

=head1 METHODS

C<compile>, C<execute_query>, C<stream_query>, C<preview_write>,
C<execute_write>, C<execute_batch> and C<execute_graph> implement the
L<Selecto::Adapter> contract. C<quote_identifier> uses double quotes by
default. C<feature_inventory> and C<write_capabilities> describe the SQL
family; subclasses narrow them through C<supports> and
C<write_capabilities>.

=head2 execute_write_unsafe, execute_batch_unsafe, execute_graph_unsafe

Execute without an engine authorization, skipping all domain governance.
They exist for trusted internal tooling and adapter tests; application code
should always write through L<Selecto::Engine>.

=head1 WRITING A SUBCLASS

A subclass must provide C<name>, C<dialect> and C<placeholder($index)>
(returning the SQL text for the 1-based parameter C<$index>, such as C<?> or
C<$1>), and should override C<supports> to declare its features and
C<write_capabilities> when it adds C<returning> or C<write_graph>. Dialects
that differ in quoting override C<quote_identifier>.

Result decoding, upsert syntax, pagination and dialect-only expressions are
customized through methods whose names begin with an underscore (for example
C<_decode>, C<_column_types>, C<_compile_upsert_clause>,
C<_compile_pagination>). Transaction control uses C<_begin_transaction>,
C<_commit_transaction>, C<_rollback_transaction>, C<_savepoint_sql>,
C<_server_transaction_open> and C<_savepoint_transaction>. Those hooks are
not yet a stable interface; study the bundled adapters and expect changes
between releases.

Register the class with L<Selecto::Adapter::Registry> under a lowercase
name.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Adapter>, L<Selecto::Adapter::Registry>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
