package Selecto::CompileCache;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Selecto::Statement ();
use Selecto::Error ();

# Adapter-local, process-local pure render plans. No query, domain, engine,
# statement, bind value or authority object is retained in an entry.
fieldhash my %CACHE;
fieldhash my %DOMAINS;
my %QUERY_KEYS = map { $_ => 1 } qw(selections predicate groups grouping_mode orders
    limit_value offset_value ctes lateral_joins values_sources function_laterals
    json_rowsets array_rowsets subqueries members set_operations timezone row_lock
    retarget applied_query_library);
my %ADAPTER_KEYS = map { $_ => 1 } qw(dbh compile_cache compile_cache_size canonical_values
    canonical_sql rollup_sort_fix temporary_relations catalog_trust transaction_mode
    transaction_handler query_budget_progress_handler _source_expansions _source_budget);

sub render {
    my ($class, $adapter, $domain, $query) = @_;
    return unless ref($adapter) eq 'Selecto::PostgreSQL' || ref($adapter) eq 'Selecto::SQLite';
    return unless $adapter->{_selecto_cache_top};
    return if $adapter->{canonical_sql}; # projection fieldhash stays on the normal path
    my $enabled = $adapter->{_selecto_compile_cache} // $adapter->compile_cache;
    Selecto::Error->throw('invalid_query', 'compile_cache must be 0 or 1')
        unless defined($enabled) && !ref($enabled) && $enabled =~ /\A[01]\z/;
    return unless $enabled;
    my $size = $adapter->{_selecto_compile_cache_size} // $adapter->compile_cache_size;
    Selecto::Error->throw('invalid_query', 'compile_cache_size must be a positive integer')
        unless defined($size) && !ref($size) && $size =~ /\A[1-9][0-9]*\z/;
    return unless ref($domain) eq 'Selecto::Domain' && ref($query) eq 'Selecto::Query';
    return if defined($domain->{_read_prefix}); # request-selected schema identities stay uncached
    my $engine = $adapter->{_selecto_compile_engine};
    # A tenant on an untenantized root can still scope another relation. Its
    # authority is not represented by a root bind, so keep normal compilation.
    return if $engine && defined($engine->{scope}{tenant}) && !defined($domain->tenant_field);
    return unless ref($adapter->{_source_budget}) eq 'Selecto::OperationBudget'
        && ref($adapter->{_source_budget}{limits}) eq 'Selecto::Limits';
    # Only the audited grammar below can enter. Unknown records/expressions,
    # value-dependent SQL, callbacks and advanced features retain the ordinary
    # compiler, including all its validations and dialect hooks.
    return if grep { !$ADAPTER_KEYS{$_} && $_ !~ /\A_selecto_/ } keys %$adapter;
    return if grep { ref($adapter->{$_}) } qw(canonical_values canonical_sql rollup_sort_fix temporary_relations catalog_trust);
    return if ref($domain->{contract}) eq 'HASH' && exists($domain->{contract}{required_filters});
    # Domain metadata is immutable through its API. Inspect eligibility once
    # per object, including a private value-independent render fingerprint.
    my $metadata = $DOMAINS{$domain} //= _domain($domain);
    return unless $metadata->{eligible};
    return unless _flat_query($query);
    my (@values, @shape);
    return unless _shape($domain->{required_predicate}, \@values, \@shape, 0, 1);
    return unless _shape($query->{predicate}, \@values, \@shape, 0, 1);
    for my $part (qw(selections groups orders)) {
        push @shape, $part, scalar @{$query->{$part}};
        for my $item (@{$query->{$part}}) {
            my $expression = $part eq 'orders' ? $item->[0] : $item;
            return unless _shape($expression, \@values, \@shape, 0, 0);
            push @shape, _scalar($item->[1]) if $part eq 'orders';
        }
    }
    return unless @{$query->{selections}};
    push @shape, map { _scalar($_) } @{$query}{qw(limit_value offset_value)};
    my $key = join('|', $metadata->{identity}, $metadata->{render_fingerprint},
        ref($adapter), $adapter->dialect, $Selecto::VERSION // 'unloaded', $adapter->contract_version,
        (map { my $value = $adapter->{$_}; _scalar($value) } qw(canonical_values canonical_sql rollup_sort_fix temporary_relations catalog_trust)),
        @shape);
    # _compile_single and its physical-source proof each expand flat intent
    # on main. Retain their live owner/QueryBinding checks on a render hit.
    $adapter->_expand_query($domain, $query);
    my $cache = $CACHE{$adapter};
    if (!$cache || $cache->{pid} != $$) {
        $cache = $CACHE{$adapter} = {pid => $$, entries => {}, clock => 0};
    }
    my $entry = $cache->{entries}{$key};
    if (!$entry) {
        # Only a miss builds the marker tree. The hot walk above collects
        # values and structural identity together, without serialization.
        my @render_values;
        my $required = _predicate($domain->{required_predicate}, \@render_values);
        my $predicate = _predicate($query->{predicate}, \@render_values);
        return unless @render_values == @values;
        my $render_query = bless {%$query, predicate => $predicate}, 'Selecto::Query';
        my $render_domain = bless {%$domain, required_predicate => $required}, 'Selecto::Domain';
        # Render with opaque slot markers, never request data. The allowed grammar's
        # literal and IN leaves are emitted unchanged into params, so the
        # resulting parameter vector must consist exclusively of those markers.
        my $statement;
        my @relations;
        {
            local $adapter->{_selecto_relation_sink} = {};
            my $source_counts = {%{$adapter->{_source_budget}{counts}}};
            local $adapter->{_source_budget} = Selecto::OperationBudget->new(
                limits=>$adapter->{_source_budget}->limits, code=>'invalid_query');
            $adapter->{_source_budget}{counts} = $source_counts;
            # Speculation never charges the real request budget. An unexpected
            # bind or refusal returns to the complete compiler below.
            $statement = eval { $adapter->_compile_single($render_domain, $render_query) };
            return unless $statement;
            @relations = sort keys %{$adapter->{_selecto_relation_sink}};
        }
        $entry = {sql => $statement->sql, columns => $statement->columns,
            slots => $statement->params, relations => \@relations, association_work=>$metadata->{association_work}};
        for my $slot (@{$entry->{slots}}) {
            # An unanticipated dialect/domain bind means this render was not
            # pure under the audited grammar. Never infer a slot by equality
            # with a request value; keep the complete normal compiler path.
            return unless defined($slot) && !ref($slot)
                && $slot =~ /\A\0selecto bind:([0-9]+)\0\z/ && $1 < @values;
            $slot = 0 + $1;
        }
        $cache->{entries}{$key} = $entry;
    }
    # The physical-source proof is pure, but its limits and cumulative counters
    # are request-owned. Replay its exact admission under the current budget.
    my $budget = $adapter->{_source_budget};
    my $count = $entry->{association_work};
    $budget->consume_count('max_expression_nodes',1,label=>'source proof work');
    $budget->limits->check_count('max_expression_depth',0,'invalid_query','source proof depth');
    $adapter->_expand_query($domain, $query);
    $budget->consume_count('max_expression_nodes',1,label=>'association proof work') for 1..$count;
    # Preserve main's order: physical-source admission precedes the implicit
    # Expression admission of the live combined required/query predicate.
    Selecto::QueryEnforcement::combine($domain->required_predicate, $query->predicate)
        if defined($domain->required_predicate) && defined($query->predicate);
    $entry->{used} = ++$cache->{clock};
    while (keys(%{$cache->{entries}}) > $size) {
        my ($oldest) = sort { $cache->{entries}{$a}{used} <=> $cache->{entries}{$b}{used} } keys %{$cache->{entries}};
        delete $cache->{entries}{$oldest};
    }
    # Relation evidence is accumulated for every returned statement, including
    # hits; it must never turn a hand-built statement into generated evidence.
    # Only ordinary physical associations can enter this cache.
    $adapter->{_selecto_relation_sink}{$_} = 1 for @{$entry->{relations}};
    return Selecto::Statement->new(sql => $entry->{sql}, columns => $entry->{columns},
        params => [map { $values[$_] } @{$entry->{slots}}], adapter_name => $adapter->name);
}

# Length-delimited scalars distinguish undef, empty strings, Unicode and
# embedded delimiters. Bind values never enter the structural key.
sub _scalar { my ($value) = @_; return defined($value) ? length($value) . ':' . $value : '-'; }

sub _domain {
    my ($domain) = @_;
    my $contract = $domain->{contract};
    my $source = ref($contract) eq 'HASH' ? $contract->{source} : undef;
    if (ref($source) eq 'HASH') {
        return {} if grep { ref($_) eq 'HASH' && exists($_->{computed}) }
            values %{$source->{columns} // {}};
    }
    # Canonical nested graphs resolve lazily. Keep those advanced graphs on
    # the compiler; the cached grammar covers direct physical associations.
    for my $relation (values %{$domain->{canonical_schemas} // {}}) {
        return {} if keys %{$relation->{associations} // {}};
        return {} if exists($relation->{values});
        return {} if grep { ref($_) eq 'HASH' && exists($_->{computed}) }
            values %{$relation->{columns} // {}};
    }
    my @pending = ($domain);
    my $count = -1;
    while (my $node = pop @pending) {
        return {} unless ref($node) eq ($count < 0 ? 'Selecto::Domain' : 'Selecto::Domain::Association');
        return {} if defined($node->{values}) || defined($node->{through}) || defined($node->{where})
            || defined($node->{target_tenant_field}) || defined($node->{_tenant_carry})
            || ($node->{join_strategy} // '') eq 'lateral_lookup';
        return {} if grep { ref($_) eq 'HASH' && exists($_->{computed}) } values %{$node->{fields}};
        ++$count;
        push @pending, values %{$node->{associations}};
    }
    # Copy optional hash leaves before map: aliasing a missing hash slot in
    # a map argument list would insert that key into the immutable contract.
    my @identity = ($domain->{name}, $domain->{table},
        ref($contract) eq 'HASH' ? $contract->{domain_version} : undef);
    # Reuse the complete derived-domain fingerprint coverage, but remove only
    # the required predicate from a private shallow copy. Its masked shape is
    # included separately by _shape on every call, along with fresh bind values.
    # Never refresh or replace the live domain's public fingerprint. This runs
    # once per immutable domain object and retains only the digest, not a copy
    # of the domain or its request values, in the fieldhash metadata.
    my $render_fingerprint = $domain->fingerprint;
    if (defined($domain->{required_predicate})) {
        my $render_domain = bless {%$domain, required_predicate => undef}, 'Selecto::Domain';
        $render_domain->_refresh_fingerprint;
        $render_fingerprint = $render_domain->fingerprint;
    }
    return {eligible => 1, association_work => $count,
        render_fingerprint => $render_fingerprint,
        identity => join('|', map { _scalar($_) } @identity)};
}

# One cheap, bounded grammar walk. Admission has already run on the live
# query; this is structural evidence only, never an admission receipt.
sub _shape {
    my ($node, $values, $shape, $depth, $predicate) = @_;
    if (!defined($node)) { push @$shape, 'none'; return $predicate; }
    return unless $depth <= 100 && ref($node) eq 'Selecto::Expression';
    my ($kind, $args, $alias) = @{$node}{qw(kind arguments alias_name)};
    return if !defined($kind) || ref($kind) || ref($alias) || ref($args) ne 'ARRAY';
    return if grep { $_ ne 'kind' && $_ ne 'arguments' && $_ ne 'alias_name' && $_ ne '_query_filter_list' } keys %$node;
    push @$shape, _scalar($kind), _scalar($alias), $node->{_query_filter_list} ? 1 : 0;
    if ($kind eq 'field') {
        return unless @$args == 1 && defined($args->[0]) && !ref($args->[0]);
        push @$shape, _scalar($args->[0]);
    } elsif (!$predicate) {
        return !@$args if $kind eq 'count';
        return unless @$args == 1 && $kind =~ /\A(?:count_field|count_distinct|sum|sum_zero|avg|min|max|trim|true_count|false_count|true_percentage)\z/;
        return _shape($args->[0], $values, $shape, $depth+1, 0);
    } elsif ($kind eq 'literal') {
        return unless @$args == 1 && !ref($args->[0]);
        push @$values, $args->[0];
    } elsif ($kind eq 'in') {
        return unless @$args == 2 && ref($args->[1]) eq 'ARRAY' && @{$args->[1]}
            && !grep { ref($_) } @{$args->[1]};
        return unless _shape($args->[0], $values, $shape, $depth+1, 0);
        push @$shape, scalar @{$args->[1]};
        push @$values, @{$args->[1]};
    } elsif ($kind eq 'and' || $kind eq 'or') {
        return unless @$args == 1 && ref($args->[0]) eq 'ARRAY' && @{$args->[0]};
        push @$shape, scalar @{$args->[0]};
        for (@{$args->[0]}) { return unless _shape($_, $values, $shape, $depth+1, 1); }
    } else {
        my $arity = $kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/ ? 2
            : $kind eq 'between' ? 3 : $kind =~ /\A(?:not|is_null|not_null)\z/ ? 1 : 0;
        return unless $arity && @$args == $arity;
        for (@$args) { return unless _shape($_, $values, $shape, $depth+1, 1); }
    }
    return 1;
}

sub _flat_query {
    my ($query)=@_;
    return if defined($query->{row_lock}) || defined($query->{retarget}) || defined($query->{timezone})
        || ($query->{grouping_mode} // '') ne 'plain';
    return if grep { @{$query->{$_} // []} }
        qw(ctes lateral_joins values_sources function_laterals json_rowsets array_rowsets subqueries members set_operations);

    return if grep { !$QUERY_KEYS{$_} } keys %$query;
    return if ref($query->{limit_value}) || ref($query->{offset_value});
    return if grep { ref($_) ne 'ARRAY' || @$_ != 2 || !defined($_->[1]) || ref($_->[1]) } @{$query->{orders}};
    return 1;
}

sub _selection {
    my ($node) = @_;
    return 0 unless ref($node) eq 'Selecto::Expression';
    return 0 if ref($node->{alias_name});
    return 0 if grep { $_ ne 'kind' && $_ ne 'arguments' && $_ ne 'alias_name' } keys %$node;
    my ($kind, $args) = @{$node}{qw(kind arguments)};
    return 0 unless ref($args) eq 'ARRAY';
    return @$args == 1 && defined($args->[0]) && !ref($args->[0]) if $kind eq 'field';
    return !@$args if $kind eq 'count';
    return @$args == 1 && _selection($args->[0])
        if $kind =~ /\A(?:count_field|count_distinct|sum|sum_zero|avg|min|max|trim|true_count|false_count|true_percentage)\z/;
    return 0;
}

sub _predicate {
    my ($node, $values, $depth) = @_;
    $depth //= 0;
    return if $depth > 100;
    return undef unless ref($node) eq 'Selecto::Expression';
    return if grep { $_ ne 'kind' && $_ ne 'arguments' && $_ ne 'alias_name' && $_ ne '_query_filter_list' } keys %$node;
    my ($kind, $args) = @{$node}{qw(kind arguments)};
    return undef unless ref($args) eq 'ARRAY';
    my @next;
    if ($kind eq 'literal') {
        return if @$args != 1 || ref($args->[0]);
        @next = ("\0selecto bind:" . scalar(@$values) . "\0");
        push @$values, $args->[0];
    } elsif ($kind eq 'field') {
        return unless _selection($node);
        @next = @$args;
    } elsif ($kind eq 'in') {
        return unless @$args == 2 && _selection($args->[0]) && ref($args->[1]) eq 'ARRAY'
            && @{$args->[1]} && !grep { ref($_) } @{$args->[1]};
        my @slots = map { my $slot = "\0selecto bind:" . scalar(@$values) . "\0"; push @$values, $_; $slot } @{$args->[1]};
        @next = ($args->[0], \@slots);
    } elsif ($kind eq 'and' || $kind eq 'or') {
        return unless @$args == 1 && ref($args->[0]) eq 'ARRAY' && @{$args->[0]};
        my @children = map { scalar _predicate($_, $values, $depth + 1) } @{$args->[0]};
        return if grep { !defined } @children;
        @next = (\@children);
    } else {
        my $arity = $kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/ ? 2
            : $kind eq 'between' ? 3 : $kind =~ /\A(?:not|is_null|not_null)\z/ ? 1 : 0;
        return unless $arity && @$args == $arity;
        @next = map { scalar _predicate($_, $values, $depth + 1) } @$args;
        return if grep { !defined } @next;
    }
    return bless {%$node, arguments => \@next}, 'Selecto::Expression';
}

1;
