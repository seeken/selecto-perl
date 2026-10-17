package Selecto::QueryBinding;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed refaddr reftype);
use Hash::Util::FieldHash qw(fieldhash);
use Selecto::ConfiguredDomain ();
use Selecto::Error ();

# Internal lifecycle evidence. Neither the query record nor its public cached
# domain fingerprint can supply policy or tenant authority.
fieldhash my %OWNER;
fieldhash my %BUILDERS;
fieldhash my %INPUT_PARENT;

sub configure_engine {
    my ($class, $engine, $given) = @_;
    $given //= {};
    Selecto::Error->throw('invalid_query_members', 'member_builders must be a plain object')
        unless ref($given) eq 'HASH' && !defined(tied(%$given));
    my %builders;
    for my $key (keys %$given) {
        Selecto::Error->throw('invalid_query_members', 'member builder must be an explicit host callback')
            unless $key =~ /\A(?:ctes|subqueries):[A-Za-z_][A-Za-z0-9_]*\z/
                && !defined(tied($given->{$key})) && ref($given->{$key}) eq 'CODE';
        $builders{$key} = $given->{$key};
    }
    $BUILDERS{$engine} = \%builders;
    return $engine;
}
sub inherit_engine {
    my ($class, $from, $to, %options) = @_;
    $BUILDERS{$to} = $BUILDERS{$from} // {};
    $INPUT_PARENT{$to} = $from if $options{flat_input};
    return $to;
}
sub bind { $OWNER{$_[2]} = $_[1]; return $_[2] }
sub inherit { $OWNER{$_[2]} = $OWNER{$_[1]} if exists $OWNER{$_[1]}; return $_[2] }
sub owner { return $OWNER{$_[1]} }
sub _identity {
    my ($engine) = @_;
    $engine->assert_domain_identity;
    return {
        mode => $engine->query_mode,
        domain => Selecto::ConfiguredDomain->digest($engine->domain, {}),
        scope => Selecto::ConfiguredDomain->digest({}, [
            $engine->scope, $engine->tenant_context, $engine->required_filters]),
    };
}
sub compatible {
    my ($class, $left, $right, %options) = @_;
    if (refaddr($left) == refaddr($right)) {
        $left->assert_domain_identity;
        return 1;
    }
    my ($a, $b) = map { _identity($_) } ($left, $right);
    Selecto::Error->throw('mixed_query_policies', 'composed queries have different query policies')
        unless $a->{mode} eq $b->{mode};
    Selecto::Error->throw('mixed_tenant_scopes', 'composed queries have different tenant scopes')
        unless $a->{scope} eq $b->{scope};
    Selecto::Error->throw('mixed_query_domains', 'set operands have different configured domains')
        if !$options{source} && $a->{domain} ne $b->{domain};
    return 1;
}
sub compose {
    my ($class, $left, $right) = @_;
    my ($a, $b) = @OWNER{$left, $right};
    return $class->compatible($a, $b) if $a && $b;
    Selecto::Error->throw('mixed_query_policies', 'strict set operands must retain configured query authority')
        if ($a && $a->query_mode eq 'strict') || ($b && $b->query_mode eq 'strict');
    return 1;
}
sub guard_source {
    my ($class, $query, $code) = @_;
    my $owner = $OWNER{$query};
    Selecto::Error->throw($code, 'ad-hoc source is forbidden by the configured query policy')
        if $owner && $owner->query_mode eq 'strict';
    return;
}
sub source_domain {
    my ($class, $left, $domain, $child) = @_;
    my ($a, $b) = @OWNER{$left, $child};
    if ($a && $b) { $class->compatible($a, $b, source => 1) }
    if ($b) {
        my $given = Selecto::ConfiguredDomain->digest($domain, {});
        Selecto::Error->throw('mixed_query_domains', 'source domain differs from its configured query')
            unless $given eq Selecto::ConfiguredDomain->digest($b->domain, {})
                || $given eq Selecto::ConfiguredDomain->digest($b->read_domain, {});
        return $b->read_domain;
    }
    Selecto::Error->throw('mixed_tenant_scopes', 'scoped source queries must retain configured query authority')
        if $a && $a->_has_read_tenant_policy;
    return $domain;
}
sub _flat_intent {
    my ($query) = @_;
    return 0 if defined $query->{retarget};
    return 0 if grep { @{$query->{$_} // []} }
        qw(ctes lateral_joins values_sources function_laterals json_rowsets array_rowsets subqueries members set_operations);
    my $library = $query->{applied_query_library} // {};
    return 0 if grep { ref($_) eq 'ARRAY' ? @$_ : defined($_) } values %$library;
    return 1;
}
sub _execution {
    my ($class, $engine, $owner, $query) = @_;
    return $class->compatible($engine, $owner) if refaddr($engine) == refaddr($owner);
    if (_flat_intent($query)) {
        my ($target, $origin) = map { _identity($_) } ($engine, $owner);
        if ($target->{mode} eq $origin->{mode}) {
            # Existing scalar query intent may be reused with an ungoverned
            # target engine. Its domain remains the sole physical authority.
            if ($target->{scope} eq $origin->{scope}
                && !$owner->_has_read_tenant_policy && !$engine->_has_read_tenant_policy
                && !defined($owner->domain->required_predicate) && !@{$owner->required_filters}) {
                return 1;
            }
            # Only approved initial read-context attachment, additive scope/
            # filter or budget transitions may consume ancestor flat intent.
            # Sources and set branches retain exact configured policy/scope
            # matching; no reverse transfer.
            if ($target->{domain} eq $origin->{domain}) {
                my $ancestor = $engine;
                while ($ancestor = $INPUT_PARENT{$ancestor}) {
                    $ancestor->assert_domain_identity;
                    return 1 if refaddr($ancestor) == refaddr($owner);
                }
                # Engines scoped from one configured family to different
                # trusted tenants (base->with_scope(tenant => A) and
                # base->with_scope(tenant => B)) may share flat intent: the
                # target compiles it under its own trusted tenant and every
                # other read obligation is identical, so nothing is dropped.
                return 1 if _trusted_tenant_siblings($engine, $owner);
            }
        }
    }
    return $class->compatible($engine, $owner);
}
sub _flat_ancestors {
    my ($engine) = @_;
    my @chain;
    while ($engine = $INPUT_PARENT{$engine}) {
        $engine->assert_domain_identity;
        push @chain, $engine;
    }
    return @chain;
}
sub _trusted_tenant_siblings {
    my ($engine, $owner) = @_;
    my %owner_ancestors = map { (refaddr($_) => 1) } _flat_ancestors($owner);
    # A shared proper ancestor of both; an ancestor/descendant pair is either
    # the approved forward transition above or a refused reverse transfer.
    return 0 if $owner_ancestors{refaddr($engine)};
    return 0 unless grep { $owner_ancestors{refaddr($_)} } _flat_ancestors($engine);
    my ($target, $origin) = map { $_->scope->{tenant} } ($engine, $owner);
    return 0 unless defined($target) && defined($origin);
    my ($a, $b) = map {
        my $scope = $_->scope;
        delete $scope->{tenant};
        Selecto::ConfiguredDomain->digest({}, [$scope, $_->tenant_context, $_->{tenant_required_filters} // []]);
    } ($engine, $owner);
    return $a eq $b ? 1 : 0;
}
sub validate {
    my ($class, $engine, $query) = @_;
    my $owner = $OWNER{$query};
    $class->_execution($engine, $owner, $query) if $owner;
    if ($engine->query_mode eq 'strict') {
        Selecto::Error->throw('ad_hoc_source_forbidden', 'strict queries require declared source activation')
            if grep { @{$query->{$_} // []} } qw(ctes lateral_joins values_sources function_laterals json_rowsets array_rowsets);
        Selecto::Error->throw('ad_hoc_join_forbidden', 'strict queries require declared joins')
            if @{$query->{subqueries} // []};
    }
    $query->_validate_source_plans;
    for my $op (@{$query->set_operations}) {
        $class->compose($query, $op->{query});
        $class->validate($engine, $op->{query});
    }
    for my $source (@{$query->ctes}, @{$query->lateral_joins}, @{$query->subqueries}) {
        Selecto::Error->throw('invalid_query', 'advanced source plan is incomplete')
            unless defined($source->{name}) && !defined(reftype($source->{name}))
                && $source->{name} =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
                && blessed($source->{domain}) && UNIVERSAL::isa($source->{domain}, 'Selecto::Domain')
                && ref($source->{columns}) eq 'ARRAY' && @{$source->{columns}}
                && (($source->{recursive} && blessed($source->{anchor}) && blessed($source->{recursive_query}))
                    || blessed($source->{query}));
        for my $child (grep { defined } @{$source}{qw(query anchor recursive_query)}) {
            Selecto::Error->throw('invalid_query', 'advanced source requires a Selecto query')
                unless UNIVERSAL::isa($child, 'Selecto::Query');
            my $other = $OWNER{$child};
            if ($other) {
                $class->compatible($engine, $other, source => 1);
                my $actual = Selecto::ConfiguredDomain->digest($source->{domain}, {});
                Selecto::Error->throw('mixed_query_domains', 'source domain differs from its configured query')
                    unless $actual eq Selecto::ConfiguredDomain->digest($other->read_domain, {});
            } elsif ($engine->_has_read_tenant_policy) {
                Selecto::Error->throw('mixed_tenant_scopes', 'scoped source queries require configured authority');
            }
        }
    }
    return 1;
}
sub builder {
    my ($class, $engine, $group, $name) = @_;
    my $builder = ($BUILDERS{$engine} // {})->{"$group:$name"};
    Selecto::Error->throw('unsupported_query_member', 'portable callback markers require an explicit host member builder',
        {member => $name, group => $group}) unless $builder;
    my $query = $builder->($engine);
    Selecto::Error->throw('invalid_query_members', 'host member builder must return a configured Selecto query')
        unless blessed($query) && UNIVERSAL::isa($query, 'Selecto::Query') && $OWNER{$query};
    $class->compatible($engine, $OWNER{$query}, source => 1);
    return ($OWNER{$query}->read_domain, $query);
}
1;

=head1 NAME

Selecto::QueryBinding - internal configured query lifecycle evidence

=head1 DESCRIPTION

This private helper preserves engine-owned query policy, tenant identity and
explicit host member builders through approved immutable builder transitions.
Its functions are internal lifecycle operations, not a public way to establish
or replace configured authority. Use L<Selecto::Engine> and L<Selecto::Query>.

=cut
