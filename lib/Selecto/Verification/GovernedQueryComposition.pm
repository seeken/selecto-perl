package Selecto::Verification::GovernedQueryComposition;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Cpanel::JSON::XS ();
use Selecto ();
use Selecto::QueryBinding ();
use Selecto::Error ();

my @SAFE = qw(declared_join named_cte named_subquery named_lateral union intersect except);
my %SET = map { $_ => 1 } qw(union intersect except);
my @UNSAFE = qw(ad_hoc_join ad_hoc_cte ad_hoc_subquery ad_hoc_lateral mixed_policy_union
    mixed_row_tenant_union mixed_prefix_tenant_union mixed_compound_tenant_union mixed_attached_tenant_union);
my %OPERATION = (declared_join => 'join', named_cte => 'with_cte', named_subquery => 'with_subquery', named_lateral => 'with_lateral');
my %EXPECTED = (ad_hoc_join => 'ad_hoc_join_forbidden', ad_hoc_cte => 'ad_hoc_source_forbidden',
    ad_hoc_subquery => 'ad_hoc_join_forbidden', ad_hoc_lateral => 'ad_hoc_source_forbidden',
    mixed_policy_union => 'mixed_query_policies', map { ($_ => 'mixed_tenant_scopes') }
        qw(mixed_row_tenant_union mixed_prefix_tenant_union mixed_compound_tenant_union mixed_attached_tenant_union));

sub _domain {
    return Selecto::Domain->parse({name => 'Governed verification accounts', tenant_required => JSON::PP::true,
        source => {source_table => 'accounts', primary_key => 'id', fields => [qw(id name active tenant_id team_id)],
            redact_fields => [], columns => {id => {type => 'integer'}, name => {type => 'string'},
                active => {type => 'boolean'}, tenant_id => {type => 'string'}, team_id => {type => 'integer'}},
            associations => {team => {queryable => 'team', field => 'team', owner_key => 'team_id', related_key => 'id'}}},
        schemas => {team => {source_table => 'teams', primary_key => 'id', fields => [qw(id name)], redact_fields => [],
            columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}}},
        joins => {team => {name => 'Team', type => 'left', display_field => 'name'}},
        required_filters => [['active', JSON::PP::true]], query_members => {
            ctes => {scoped_accounts => {query => {kind => 'declared_callback'}}},
            subqueries => {scoped_accounts => {query => {kind => 'declared_callback'}, type => 'inner', on => [{left => 'id', right => 'id'}]}},
            laterals => {bounded_series => {source => ['function', 'bounded_row_source', [1, 2]], as => 'bounded_series', join_type => 'inner'}},
            values => {}, unnests => {}}});
}
sub _engine {
    my ($adapter, $mode, $tenant_mode, $identity, %options) = @_;
    $identity //= 'tenant-a';
    my $engine = Selecto::Engine->new(domain => _domain(), adapter => $adapter, mode => $mode,
        member_builders => {map { ($_ . ':scoped_accounts' => sub { $_[0]->query->select(qw(id name)) }) } qw(ctes subqueries)});
    if ($tenant_mode eq 'prefix') {
        $identity = 'tenant_a' if $identity eq 'tenant-a';
        return $engine->with_tenant({prefix => $identity, required => JSON::PP::true});
    }
    $engine = $engine->with_tenant({tenant_id => $identity, required => $options{attached} ? JSON::PP::false : JSON::PP::true});
    return $options{attached} ? $engine : $engine->apply_tenant_scope;
}
sub _query { $_[0]->query->select(qw(id name)) }
sub _safe {
    my ($form, $s, $adapter) = @_;
    my $query = $s->{query};
    return $query->join('team') if $form eq 'declared_join';
    return $query->with_cte('scoped_accounts') if $form eq 'named_cte';
    return $query->with_subquery('scoped_accounts') if $form eq 'named_subquery';
    return $query->with_lateral('bounded_series') if $form eq 'named_lateral';
    my $right = _query(_engine($adapter, $s->{mode}, $s->{tenant}))->where(Selecto::Expression->eq('name', 'Grace'));
    return $query->$form($right);
}
sub _unsafe {
    my ($form, $s, $adapter) = @_;
    my ($q, $engine) = @{$s}{qw(query engine)};
    return $q->join('audit_log', source => 'audit_log', owner_key => 'id', related_key => 'account_id', fields => {id => {type => 'integer'}}) if $form eq 'ad_hoc_join';
    return $q->with_cte('manual_accounts', sub { _query(_engine($adapter, 'permissive', $s->{tenant})) }) if $form eq 'ad_hoc_cte';
    return $q->subquery_join('manual_accounts', $engine->domain, _query($engine), on => [{left => 'id', right => 'id'}]) if $form eq 'ad_hoc_subquery';
    return $q->function_lateral('bounded_row_source', [1, 2], as => 'manual_series') if $form eq 'ad_hoc_lateral';
    return $q->union(_query(_engine($adapter, 'permissive', $s->{tenant}))) if $form eq 'mixed_policy_union';
    return $q->union(_query(_engine($adapter, $s->{mode}, 'row', 'tenant-b'))) if $form eq 'mixed_row_tenant_union';
    return $q->union(_query(_engine($adapter, $s->{mode}, 'prefix', 'tenant_b'))) if $form eq 'mixed_prefix_tenant_union';
    if ($form eq 'mixed_compound_tenant_union') {
        my @engines = map { _engine($adapter, $s->{mode}, 'prefix')->with_tenant({prefix => 'tenant_a', tenant_id => $_, required => JSON::PP::true})->apply_tenant_scope } qw(tenant-a tenant-b);
        return _query($engines[0])->union(_query($engines[1]));
    }
    my @engines = map { _engine($adapter, $s->{mode}, 'row', $_, attached => 1) } qw(tenant-a tenant-b);
    return _query($engines[0])->union(_query($engines[1]));
}
sub _branches {
    my ($query) = @_;
    return ($query, map { _branches($_->{query}) } @{$query->set_operations});
}
sub _same { Cpanel::JSON::XS->new->canonical->encode($_[0]) eq Cpanel::JSON::XS->new->canonical->encode($_[1]) }
sub _invariants {
    return [
        ['tenant_scope_is_closed_under_supported_composition', sub {
            my ($s) = @_; return unless $s->{scenario} eq 'closure';
            for my $q (_branches($s->{query})) {
                my $owner = Selecto::QueryBinding->owner($q);
                return {reason => 'scope_authority_missing'} unless $owner;
                return {reason => 'scope_invalid'} unless $owner->validate_tenant_scope->{valid};
            } return;
        }],
        ['required_filters_are_closed_under_supported_composition', sub {
            my ($s) = @_; return unless $s->{scenario} eq 'closure';
            my @expected = (['active', JSON::PP::true], $s->{tenant} eq 'row' ? (['tenant_id', 'tenant-a']) : ());
            for my $q (_branches($s->{query})) {
                my $owner = Selecto::QueryBinding->owner($q); my $actual = $owner->query_filters($q);
                return {reason => 'required_filter_missing'} if grep { my $f = $_; !grep { _same($_, $f) } @$actual } @expected;
            } return;
        }],
        ['strict_policy_is_closed_under_supported_composition', sub {
            my ($s) = @_; return unless $s->{scenario} eq 'closure';
            for my $q (_branches($s->{query})) {
                return {reason => 'query_policy_changed'} unless Selecto::QueryBinding->owner($q)->query_mode eq $s->{mode};
            }
            return $s->{engine}->validate_query($s->{query}) ? undef : {reason => 'query_validation_failed'};
        }],
        ['composed_scope_reaches_parameterized_sql', sub {
            my ($s) = @_; return unless $s->{scenario} eq 'closure';
            my $statement = $s->{engine}->compile($s->{query}); my @used = @{$s->{used}};
            pop @used if $s->{attempt} && $s->{attempt}{boundary} eq 'terminal_set' && $s->{attempt}{outcome} eq 'rejected';
            my $expected = 1 + grep { $_ eq 'named_cte' || $_ eq 'named_subquery' || $SET{$_} } @used;
            my $active = grep { JSON::PP::is_bool($_) && $_ } @{$statement->params};
            my $tenant = grep { defined($_) && !ref($_) && $_ eq 'tenant-a' } @{$statement->params};
            return {reason => 'required_filter_parameter_count', expected => $expected, actual => $active} if $active != $expected;
            return {reason => 'row_scope_parameter_count', expected => $expected, actual => $tenant} if $s->{tenant} eq 'row' && $tenant != $expected;
            return {reason => 'scope_interpolated'} if $statement->sql =~ /tenant-a/;
            return {reason => 'prefix_scope_lost'} if $s->{tenant} eq 'prefix'
                && ($tenant || ($s->{engine}->merge_execution_options->{prefix} // '') ne 'tenant_a');
            return;
        }],
        ['post_set_structural_composition_fails_closed', sub {
            my ($s) = @_; return unless $s->{scenario} eq 'closure' && $s->{attempt};
            my $a = $s->{attempt};
            return if $a->{boundary} eq 'terminal_set' && $a->{outcome} eq 'rejected' && $a->{unchanged}
                && $a->{code} eq 'invalid_query' && index($a->{message}, "$OPERATION{$a->{form}} cannot be applied after a set operation") == 0;
            return {reason => 'terminal_mutation_not_rejected'};
        }],
        ['strict_mode_rejects_ad_hoc_composition', sub {
            my ($s) = @_; return unless $s->{scenario} eq 'strict_rejection' && $s->{attempt};
            my $a = $s->{attempt};
            return $a->{outcome} eq 'rejected' && ($a->{code} // '') eq $EXPECTED{$a->{form}} ? undef
                : {reason => 'unexpected_source_admission', form => $a->{form}, actual => $a->{code}};
        }],
    ];
}
sub verify {
    my ($class, @options) = @_;
    Selecto::Error->throw('invalid_query', 'the built-in governed composition model takes no options') if @options;
    my $adapter = Selecto::Verification::GovernedQueryComposition::Adapter->new(dbh => bless({}, 'Selecto::Verification::GovernedQueryComposition::Offline'));
    my @queue;
    for my $scenario (qw(closure strict_rejection)) {
        for my $mode ($scenario eq 'closure' ? qw(permissive strict) : ('strict')) {
            for my $tenant (qw(row prefix)) {
                my $engine = _engine($adapter, $mode, $tenant);
                push @queue, {scenario => $scenario, mode => $mode, tenant => $tenant, engine => $engine,
                    query => _query($engine), used => [], attempt => undef};
            }
        }
    }
    my $invariants = _invariants(); my ($states, $checks, @failures) = (0, 0);
    while (my $s = shift @queue) {
        ++$states;
        for my $invariant (@$invariants) {
            ++$checks; my $failure;
            my $ok = eval { $failure = $invariant->[1]->($s); 1 };
            $failure = {reason => 'invariant_raised', code => ref($@) && UNIVERSAL::isa($@, 'Selecto::Error') ? $@->code : 'unexpected_error'} unless $ok;
            push @failures, {state => {map { ($_ => $s->{$_}) } qw(scenario mode tenant used)}, invariant => $invariant->[0], evidence => $failure} if defined $failure;
        }
        next if @{$s->{used}} >= 2;
        my @forms = $s->{scenario} eq 'closure' ? @SAFE : @{$s->{used}} ? () : @UNSAFE;
        for my $form (@forms) {
            next if grep { $_ eq $form } @{$s->{used}};
            my $terminal = $s->{scenario} eq 'closure' && !$SET{$form} && grep { $SET{$_} } @{$s->{used}};
            my ($next, $error); my $ok = eval { $next = $s->{scenario} eq 'closure' ? _safe($form, $s, $adapter) : _unsafe($form, $s, $adapter); 1 }; $error = $@;
            my $attempt;
            if ($terminal || $s->{scenario} eq 'strict_rejection' || !$ok) {
                $attempt = {form => $form, boundary => $terminal ? 'terminal_set' : 'source', outcome => $ok ? 'accepted' : 'rejected',
                    unchanged => $ok ? ($next == $s->{query} ? 1 : 0) : 1,
                    code => !$ok && ref($error) && UNIVERSAL::isa($error, 'Selecto::Error') ? $error->code : 'unexpected_error',
                    message => !$ok && ref($error) && UNIVERSAL::isa($error, 'Selecto::Error') ? $error->message : ''};
            }
            push @queue, {%$s, query => $ok ? $next : $s->{query}, used => [@{$s->{used}}, $form], attempt => $attempt};
        }
    }
    return {proof_level => 'bounded_exhaustive', model => 'selecto.governed_query_composition.v1',
        state_count => $states, check_count => $checks, invariant_count => scalar(@$invariants), counterexamples => \@failures};
}
1;

package Selecto::Verification::GovernedQueryComposition::Adapter;
use Mojo::Base 'Selecto::SQLite';
sub supports { $_[1] =~ /\A(?:lateral_join|cte|recursive_cte|set_operations)\z/ ? 1 : shift->SUPER::supports(@_) }
sub execute_query { Selecto::Error->throw('unsupported_feature', 'governed composition model is compile-only') }
1;

=head1 NAME

Selecto::Verification::GovernedQueryComposition - finite public composition checks

=head1 DESCRIPTION

C<verify> enumerates the declared two-event model through public configured
query builders, policy and tenant validators, and actual SQL compilation.
State and check counts are derived from those events. Like the canonical
model, its table-function adapter is compile-only; this proves neither arbitrary
callback behavior nor table-function execution, and is not an unbounded proof.
Native SQLite composition is covered separately with memory-only regressions.

=cut
