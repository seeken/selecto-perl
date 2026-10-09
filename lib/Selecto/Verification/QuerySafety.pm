package Selecto::Verification::QuerySafety;

use 5.034;
use strict;
use warnings;
use DBI ();
use JSON::PP ();
use Selecto ();
use Selecto::Error ();

my @CONTEXTS = qw(none tenant_id mismatched_tenant_id ambiguous_tenant_id prefix compound_tenant);

# The oracle is independent of the public validator: it describes the finite
# model, while every check below observes the actual configured engine.
sub _expected_valid {
    my ($s) = @_;
    return 0 if $s->{context} eq 'mismatched_tenant_id' || $s->{context} eq 'ambiguous_tenant_id';
    return 0 if !$s->{apply_scope} && ($s->{context} eq 'tenant_id' || $s->{context} eq 'compound_tenant');
    return 1 unless $s->{tenant_required};
    return 1 if $s->{context} eq 'prefix';
    return 1 if $s->{apply_scope} && ($s->{context} eq 'tenant_id' || $s->{context} eq 'compound_tenant');
    return 0;
}
sub _domain {
    my ($required) = @_;
    return {name => 'Verification Accounts', tenant_required => $required ? JSON::PP::true : JSON::PP::false,
        source => {source_table => 'accounts', primary_key => 'id', fields => [qw(id name active tenant_id)],
            redact_fields => [], associations => {}, columns => {
                id => {type => 'integer'}, name => {type => 'string'}, active => {type => 'boolean'}, tenant_id => {type => 'string'}}},
        schemas => {}, joins => {}, required_filters => [['active', JSON::PP::true]]};
}
sub _state {
    my ($adapter, $required, $context, $apply, $user) = @_;
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(_domain($required)), adapter => $adapter);
    if ($context ne 'none') {
        my %attached = (required => $required);
        $attached{tenant_id} = 'tenant-a' unless $context eq 'prefix';
        $attached{prefix} = 'tenant_a' if $context eq 'prefix' || $context eq 'compound_tenant';
        $engine = $engine->with_tenant(\%attached);
        $engine = $engine->require_tenant_filter('tenant_id', 'tenant-b') if $context eq 'mismatched_tenant_id';
        if ($context eq 'ambiguous_tenant_id') {
            $engine = $engine->require_tenant_filter('tenant_id', 'tenant-a')->require_tenant_filter('tenant_id', 'tenant-b');
        }
    }
    if ($apply) {
        my $scope = $engine->validate_tenant_scope;
        $engine = $engine->apply_tenant_scope unless !$scope->{valid}
            && $scope->{error}{code} =~ /\Atenant_scope_(?:mismatch|ambiguous)\z/;
    }
    my $query = $engine->query->select('name');
    $query = $query->where(Selecto::Expression->eq('name', 'Ada')) if $user;
    return {tenant_required => $required, context => $context, apply_scope => $apply, user_filter => $user,
        engine => $engine, query => $query};
}
sub _same { JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1]); }
sub _invariants {
    return [
        ['required_scope_fails_closed', sub {
            my ($s) = @_;
            my $actual = $s->{engine}->validate_tenant_scope->{valid} ? 1 : 0;
            my $expected = _expected_valid($s);
            return $actual == $expected ? undef : {expected_valid => $expected, actual_valid => $actual};
        }],
        ['required_filters_are_preserved', sub {
            my ($s) = @_;
            return undef unless _expected_valid($s);
            my $actual = $s->{engine}->query_filters($s->{query});
            my @missing = grep { my $required = $_; !grep { _same($_, $required) } @$actual } @{$s->{engine}->required_filters};
            return {missing_filters => \@missing} if @missing;
            # Also execute the same public query on actual main/attached memory
            # tables. This detects clauses that are reported but not enforced.
            my @actual_rows = sort map { $_->[0] } @{$s->{engine}->all($s->{query})->{rows}};
            my @expected_rows = $s->{user_filter} || $s->{context} eq 'tenant_id' || $s->{context} eq 'compound_tenant'
                ? ('Ada') : $s->{context} eq 'prefix' ? ('Ada', 'Other') : ('Ada', 'Lin');
            return _same(\@actual_rows, \@expected_rows) ? undef : {expected_rows => \@expected_rows, actual_rows => \@actual_rows};
        }],
        ['row_scope_is_parameterized', sub {
            my ($s) = @_;
            return undef unless $s->{context} eq 'tenant_id' && $s->{apply_scope};
            my $statement = $s->{engine}->compile($s->{query});
            return {reason => 'tenant_field_missing_from_sql'} unless $statement->sql =~ /tenant_id/i;
            return {reason => 'tenant_value_missing_from_params'} unless grep { defined($_) && !ref($_) && $_ eq 'tenant-a' } @{$statement->params};
            return $statement->sql =~ /tenant-a/ ? {reason => 'tenant_value_interpolated_into_sql'} : undef;
        }],
        ['attached_prefix_cannot_be_substituted', sub {
            my ($s) = @_;
            return undef unless $s->{context} eq 'prefix';
            my $exact = $s->{engine}->merge_execution_options(prefix => 'tenant_a');
            my $ok = eval { $s->{engine}->merge_execution_options(prefix => 'tenant_b'); 1 };
            my $error = $@;
            return {reason => 'conflicting_execution_prefix_accepted'} if $ok;
            return undef if $exact->{prefix} eq 'tenant_a' && ref($error) && UNIVERSAL::isa($error, 'Selecto::Error')
                && $error->code eq 'tenant_prefix_mismatch' && $error->message =~ /execution prefix conflicts/;
            return {reason => 'unexpected_prefix_refusal'};
        }],
        ['user_filters_cannot_replace_required_scope', sub {
            my ($s) = @_;
            return undef unless $s->{tenant_required} && $s->{context} eq 'none' && $s->{user_filter};
            my $report = $s->{engine}->validate_tenant_scope;
            return !$report->{valid} && $report->{error}{code} eq 'tenant_scope_missing' ? undef
                : {reason => 'ordinary_filter_satisfied_tenant_scope'};
        }],
    ];
}
sub verify {
    my ($class, @options) = @_;
    Selecto::Error->throw('invalid_query', 'the built-in query safety model takes no options') if @options;
    Selecto::Error->throw('unsupported_feature', 'query safety verification requires DBD::SQLite')
        unless eval { require DBD::SQLite; 1 };
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    my ($report, $error);
    my $ok = eval {
        $db->do('PRAGMA temp_store=MEMORY');
        $db->do(q{ATTACH DATABASE ':memory:' AS tenant_a});
        for my $schema (qw(main tenant_a)) {
            $db->do(qq{CREATE TABLE $schema.accounts(id INTEGER PRIMARY KEY, name TEXT, active INTEGER, tenant_id TEXT)});
        }
        $db->do(q{INSERT INTO main.accounts VALUES(1,'Ada',1,'tenant-a'),(2,'Lin',1,'tenant-b'),(3,'Inactive',0,'tenant-a')});
        $db->do(q{INSERT INTO tenant_a.accounts VALUES(1,'Ada',1,'tenant-a'),(2,'Other',1,'tenant-b'),(3,'Inactive',0,'tenant-a')});
        my $adapter = Selecto->adapter(sqlite => dbh => $db);
        my $invariants = _invariants();
        my ($states, $checks, @counterexamples) = (0, 0);
        for my $required (0, 1) { for my $context (@CONTEXTS) { for my $apply (0, 1) { for my $user (0, 1) {
            my $state = _state($adapter, $required, $context, $apply, $user);
            ++$states;
            for my $invariant (@$invariants) {
                ++$checks;
                my $failure;
                my $checked = eval { $failure = $invariant->[1]->($state); 1 };
                if (!$checked) {
                    my $caught = $@;
                    $failure = {reason => 'invariant_raised', code => ref($caught) && UNIVERSAL::isa($caught, 'Selecto::Error') ? $caught->code : 'unexpected_error'};
                }
                push @counterexamples, {state => {map { $_ => $state->{$_} } qw(tenant_required context apply_scope user_filter)},
                    invariant => $invariant->[0], evidence => $failure} if defined $failure;
            }
        } } } }
        $report = {proof_level => 'bounded_exhaustive', model => 'selecto.query_scope.v1', state_count => $states,
            check_count => $checks, invariant_count => scalar(@$invariants), counterexamples => \@counterexamples};
        1;
    };
    $error = $@;
    eval { $db->disconnect; 1 } or $error ||= $@;
    die $error unless $ok && !$error;
    return $report;
}

1;

=head1 NAME

Selecto::Verification::QuerySafety - bounded exhaustive public read-scope proof

=head1 DESCRIPTION

C<< Selecto::Verification::QuerySafety->verify >> enumerates the original 48
query-scope states and checks five invariants through actual public engine
validation, filter inspection, SQL compilation and execution. It owns only
in-memory main and attached SQLite databases and uses TEMP MEMORY. Required
filter preservation additionally checks native result rows. Counts and
counterexamples are derived from the checks performed. This finite model does
not establish arbitrary query, callback, UDF or native catalog authority.

=cut
