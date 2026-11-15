package Selecto::SQL::ReadPlan;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed refaddr reftype);
use Cpanel::JSON::XS ();
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use Selecto::Statement ();
use Selecto::QueryEnforcement ();

# Private, adapter-owned LRU. No query, engine, domain, rows, credentials or
# parameter values are retained. Native extensions/subclasses use the renderer.
# Both the entry count and the accounted payload bytes are bounded.
use constant MAX_ENTRIES => 64;
use constant MAX_BYTES => 262_144;

sub compile {
    my ($class, $adapter, $domain, $query, $render) = @_;
    my $key = _key($adapter, $domain, $query);
    return $render->() unless defined $key;
    my $cache = $adapter->{_selecto_read_plans} //= {entries => {}, bytes => 0, tick => 0};
    my $entry = $cache->{entries}{$key};
    if ($entry) {
        # Refusals and dynamic checks are not cached. Execute the same source
        # budget/ownership and field-resolution obligations in renderer order.
        # The key admits only stored fields and unconditional simple joins;
        # every other policy-dependent rendering remains on the reference path.
        local $adapter->{_root_alias} = 's0';
        local $adapter->{_tenant_root} = $domain;
        local $adapter->{_timezone};
        local $adapter->{_read_prefix} = $domain->{_read_prefix};
        $adapter->_physical_relations($domain, $query);
        local $adapter->{_query_sources} = $adapter->_query_sources($domain, $query);
        my $predicate = Selecto::QueryEnforcement::combine($domain->required_predicate, $query->predicate);
        my @paths = $adapter->_referenced_associations($query, $predicate, $domain);
        my ($joins, $through) = Selecto::SQL::_association_alias_maps(@paths);
        local $adapter->{_join_aliases} = $joins;
        local $adapter->{_through_aliases} = $through;
        $adapter->_validate_query_aliases($adapter->{_query_sources}, @paths);
        my @params;
        for my $path (@{$entry->{selection_fields}}) {
            # This includes resolve and current field metadata, in the same
            # order as a cold selection. No authorization result is retained.
            $adapter->_field_sql($domain, $path, \@params);
        }
        $domain->resolve_association($_) for @paths;
        $adapter->_compile_expression($domain, $predicate, \@params) if $predicate;
        $adapter->_compile_expression($domain, $_->[0], \@params) for @{$query->orders};
        $adapter->_compile_pagination($query->limit_value, $query->offset_value, @{$query->orders} ? 1 : 0);
        $adapter->{_selecto_relation_sink}{$_} = 1 for @{$entry->{relations}};
        $entry->{used} = ++$cache->{tick};
        return Selecto::Statement->new(sql => $entry->{sql}, params => \@params,
            columns => $entry->{columns}, adapter_name => $adapter->name);
    }
    my $sink = $adapter->{_selecto_relation_sink};
    my ($statement, @relations);
    {
        local $adapter->{_selecto_relation_sink} = {};
        $statement = $render->();
        @relations = sort keys %{$adapter->{_selecto_relation_sink}};
    }
    $sink->{$_} = 1 for @relations;
    my $sql = $statement->sql;
    my $columns = $statement->columns;
    my $bytes = length($key) + length($sql) * 4 + length(join('', @$columns, @relations, map { $_->arguments->[0] } @{$query->selections})) * 4 + 512;
    if ($bytes <= MAX_BYTES) {
        while (keys(%{$cache->{entries}}) >= MAX_ENTRIES || $cache->{bytes} + $bytes > MAX_BYTES) {
            my ($old) = sort { $cache->{entries}{$a}{used} <=> $cache->{entries}{$b}{used} } keys %{$cache->{entries}};
            $cache->{bytes} -= delete($cache->{entries}{$old})->{bytes};
        }
        $cache->{entries}{$key} = {sql => $sql, columns => $columns, relations => \@relations,
            selection_fields => [map { $_->arguments->[0] } @{$query->selections}],
            bytes => $bytes, used => ++$cache->{tick}};
        $cache->{bytes} += $bytes;
    }
    return $statement;
}

# A separate native snapshot, not the domain's cached public fingerprint.
# No serialization hooks, overloads, ties or subclass methods may run here.
# Failure is a cache bypass, so the reference compiler owns refusal order.
sub _plain {
    my ($value, $state, $depth) = @_;
    die "bypass\n" if ++$state->{nodes} > 4096 || $depth > 48;
    my $type = reftype($value);
    if (!$type) {
        $state->{bytes} += defined($value) ? do { use bytes; length($value) } : 0;
        die "bypass\n" if $state->{bytes} > MAX_BYTES;
        return $value;
    }
    my $class = blessed($value) // '';
    return $value if JSON::PP::is_bool($value);
    die "bypass\n" unless !$class || $class =~ /\ASelecto::(?:Domain(?:::Association)?|Expression|Query|Limits)\z/;
    my $id = refaddr($value);
    die "bypass\n" if $state->{active}{$id};
    local $state->{active}{$id} = 1;
    if ($type eq 'HASH') {
        die "bypass\n" if tied %$value;
        my @keys = keys %$value;
        die "bypass\n" if ($state->{nodes} += @keys) > 4096;
        return [$class, {map { $_ => ref($value->{$_})
            ? _plain($value->{$_}, $state, $depth + 1) : $value->{$_} } @keys}];
    }
    if ($type eq 'ARRAY') {
        die "bypass\n" if tied @$value;
        die "bypass\n" if ($state->{nodes} += @$value) > 4096;
        return [map { ref($_) ? _plain($_, $state, $depth + 1) : $_ } @$value];
    }
    die "bypass\n";
}

sub _field {
    my ($expression, $domain) = @_;
    return 0 unless ref($expression) eq 'Selecto::Expression' && $expression->{kind} eq 'field'
        && @{$expression->{arguments}} == 1 && !ref($expression->{arguments}[0]);
    my $path = $expression->{arguments}[0];
    return 0 unless defined($path) && $path =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
    my $resolved = $domain->resolve($path);
    return 0 if grep { !_simple_edge($_) } @{$resolved->{associations}};
    my $metadata = $domain->_field_metadata_view($path);
    return 0 if ref($metadata->{computed}) eq 'HASH';
    return 1;
}
sub _simple_edge {
    my ($edge) = @_;
    return ref($edge) eq 'Selecto::Domain::Association'
        && !$edge->through && !defined($edge->values)
        && $edge->join_mode ne 'star_dimension' && !defined($edge->source_scope_key)
        && !defined($edge->source_tenant_field) && !defined($edge->target_tenant_field)
        && !keys(%{$edge->where // {}}) && !defined($edge->join_strategy);
}
sub _predicate {
    my ($node, $domain) = @_;
    return 1 unless defined $node;
    return 0 unless ref($node) eq 'Selecto::Expression';
    my ($kind, $args) = @{$node}{qw(kind arguments)};
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/) {
        return @$args == 2 && _field($args->[0], $domain)
            && ref($args->[1]) eq 'Selecto::Expression' && $args->[1]{kind} eq 'literal'
            && @{$args->[1]{arguments}} == 1 && !ref($args->[1]{arguments}[0]);
    }
    return @$args == 1 && _field($args->[0], $domain) if $kind eq 'is_null' || $kind eq 'not_null';
    return @$args == 1 && _predicate($args->[0], $domain) if $kind eq 'not';
    return @$args == 1 && ref($args->[0]) eq 'ARRAY' && @{$args->[0]}
        && !grep { !_predicate($_, $domain) } @{$args->[0]} if $kind eq 'and' || $kind eq 'or';
    return 0;
}

sub _key {
    my ($adapter, $domain, $query) = @_;
    return unless (ref($adapter) eq 'Selecto::PostgreSQL' || ref($adapter) eq 'Selecto::SQLite')
        && ref($domain) eq 'Selecto::Domain' && ref($query) eq 'Selecto::Query';
    return if $adapter->{canonical_sql} || defined($query->{timezone}) || defined($query->{row_lock})
        || defined($query->{retarget}) || $query->{grouping_mode} ne 'plain';
    return if grep { @{$query->{$_}} } qw(groups set_operations ctes values_sources subqueries function_laterals
        lateral_joins json_rowsets array_rowsets members);
    return unless @{$query->{selections}};
    # Bound preflight; cycles/unknown native state are a bypass, never an error.
    my $key = eval {
        my $engine = $adapter->{_selecto_compile_engine};
        my $state = {nodes => 0, bytes => 0, active => {}};
        my $snapshot = _plain([$domain, $engine ? $engine->_read_authority : undef,
            $adapter->{_selecto_compile_limits}], $state, 0);
        die "bypass\n" if grep { !_field($_, $domain) } @{$query->{selections}};
        die "bypass\n" unless _predicate($query->{predicate}, $domain) && _predicate($domain->{required_predicate}, $domain);
        die "bypass\n" if grep { !_field($_->[0], $domain) } @{$query->{orders}};
        # Conditional/tenant joins, computed fallbacks and virtual sources keep
        # all their rendering and governance on the original compiler path.
        # Values are not part of a plan: expression literals become bind slots.
        # The current predicate is compiled every request, in renderer order.
        my $shape = _shape($query);
        my $version = eval { $adapter->dbh->{pg_server_version} } // '';
        my $encoded = Cpanel::JSON::XS->new->allow_nonref(1)->canonical->utf8->encode([
            ref($adapter), $version, $adapter->{canonical_values} // 0,
            $adapter->{transaction_mode} // 'managed', $snapshot, $shape,
        ]);
        die "bypass\n" if length($encoded) > MAX_BYTES;
        sha256_hex($encoded);
    };
    return $key;
}
sub _shape {
    my ($value) = @_;
    return $value unless ref $value;
    if (ref($value) eq 'Selecto::Expression') {
        return ['literal', 'slot'] if $value->{kind} eq 'literal';
        return {map { $_ => _shape($value->{$_}) } keys %$value};
    }
    return [map { _shape($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _shape($value->{$_}) } keys %$value}
        if ref($value) eq 'HASH' || ref($value) eq 'Selecto::Query';
    die "bypass\n";
}

1;

=head1 NAME

Selecto::SQL::ReadPlan - bounded native read rendering plans

=head1 DESCRIPTION

Internal optimization for simple stored-field reads. Governance, current
parameter binding, session checks and result decoding run every request.
Unsupported shapes use the reference renderer. See docs/read_plan_cache.md.

=cut
