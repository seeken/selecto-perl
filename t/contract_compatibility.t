use 5.034;
use strict;
use warnings;
use Test::More;
use FindBin ();
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Domain::ContractVerification;
use Selecto::Verification::ContractSafety;

my $api = 'Selecto::Domain::ContractVerification';
open my $input, '<:raw', "$FindBin::Bin/fixtures/contract_compatibility.json" or die $!;
my $fixtures = JSON::PP->new->utf8->decode(do { local $/; <$input> });
close $input;
my $provider = $fixtures->{D014}{provider_domain};
my $original = dclone($provider);
my $snapshot = $api->snapshot($provider);
is_deeply({map { $_ => $snapshot->{$_} } qw(format format_version)},
    {format => 'selecto.domain_contract_snapshot', format_version => 1}, 'D014 snapshot envelope');
is_deeply({map { $_ => $snapshot->{provider}{$_} } qw(name domain_version domain_fingerprint)},
    {name => 'billing', domain_version => '1.2.0', domain_fingerprint => 'sha256:provider'}, 'D014 provider identity');
is_deeply([map { $_->{id} } @{$snapshot->{surfaces}}], ['manager_rollup'], 'D014 surface ids');
is_deeply($snapshot->{surfaces}[0]{fields}, [qw(state total)], 'output fields come from published result columns');
is_deeply($provider, $original, 'snapshot leaves callback-bearing input untouched');
my $native_callbacks = dclone($provider);
my $callback_calls = 0;
my $callback = sub { ++$callback_calls; die 'metadata verification must not execute callbacks' };
$native_callbacks->{published_views}{manager_rollup}{query} = $callback;
$native_callbacks->{query_members}{ctes}{open_items}{query} = $callback;
is_deeply($api->snapshot($native_callbacks), $snapshot, 'actual native callbacks remain opaque snapshot metadata');
ok($api->verify($native_callbacks, $fixtures->{D015}{consumer_domain})->{compatible}, 'actual callbacks do not prevent interface-only verification');
is($callback_calls, 0, 'snapshot and verification execute no native callback');
my $encoded = JSON::PP->new->canonical->encode($snapshot);
unlike($encoded, qr/declared_callback|work_item_manager_rollup/, 'snapshot excludes executable definitions and physical view names');
$snapshot->{surfaces}[0]{fields}[0] = 'altered';
is($api->snapshot($provider)->{surfaces}[0]{fields}[0], 'state', 'snapshot copies are independent');

my $compatible = $api->verify(@{$fixtures->{D015}}{qw(provider_domain consumer_domain)});
ok($compatible->{compatible}, 'D015 compatible consumer');
is(scalar @{$compatible->{dependencies}}, 1, 'D015 dependency counted');
is_deeply($compatible->{errors}, [], 'D015 no errors');
is_deeply($compatible->{warnings}, [], 'D015 no warnings');
my $incompatible = $api->verify(@{$fixtures->{D016}}{qw(provider_domain consumer_domain)});
ok(!$incompatible->{compatible}, 'D016 incompatible consumer');
is_deeply([sort map { $_->{code} } @{$incompatible->{errors}}], [qw(incompatible_contract_version missing_field missing_query_member provider_fingerprint_changed unsatisfied_required_filter)],
    'D016 reports every independently incompatible dimension');
my $old = $api->snapshot($fixtures->{D017}{provider_domain});
my $add = $api->diff_snapshots($old, $api->snapshot($fixtures->{D017}{additive_provider}));
my $remove = $api->diff_snapshots($old, $api->snapshot($fixtures->{D017}{removal_provider}));
ok($add->{changed} && !$add->{breaking}, 'D017 result field addition is additive');
ok($remove->{changed} && $remove->{breaking}, 'D017 surface removal is breaking');
ok(!$api->diff_snapshots($old, $api->snapshot($provider))->{changed}, 'identical metadata produces no changes');

sub invalid {
    my ($value, $label) = @_;
    my $ok = eval { $api->snapshot($value); 1 };
    ok(!$ok && ref($@) eq 'Selecto::Error' && $@->code eq 'invalid_domain', $label);
}
for my $case (
    ['fields', ['missing'], 'unpublished result field rejected'],
    ['filters', ['missing'], 'undeclared filter rejected'],
    ['query_members', ['status_labels'], 'unqualified member rejected'],
    ['required_filters', ['missing'], 'undeclared required scope rejected'],
    ['stable', 'yes', 'nonboolean stability rejected'],
) {
    my $bad = dclone($provider);
    $bad->{published_views}{manager_rollup}{$case->[0]} = $case->[1];
    invalid($bad, $case->[2]);
}
my $bad_shape = dclone($provider);
delete $bad_shape->{published_views}{manager_rollup}{columns}{state}{type};
invalid($bad_shape, 'result type required');
for my $case (
    [sub { $_[0]{filters}{state} = 42 }, 'malformed published filter definition'],
    [sub { $_[0]{filters}{state}{field} = [] }, 'malformed filter field reference'],
    [sub { $_[0]{query_members}{values}{status_labels} = 42 }, 'malformed published member definition'],
    [sub { $_[0]{query_members}{unknown} = {status_labels => {}} }, 'unknown query member group'],
) {
    my $bad = dclone($provider);
    $case->[0]->($bad);
    invalid($bad, $case->[1]);
}
my $duplicates = dclone($provider);
$duplicates->{published_views}{manager_rollup}{filters} = [qw(state state)];
is_deeply($api->snapshot($duplicates)->{surfaces}[0]{filters}, ['state'], 'set declarations canonicalize duplicates');

my $consumer = dclone($fixtures->{D015}{consumer_domain});
my $dependency = $consumer->{domain_dependencies}[0];
for my $case (
    ['1.2.0', '~> 1.0', 1], ['1.9.99', '~> 1.0', 1], ['2.0.0', '~> 1.0', 0],
    ['1.2.9', '~> 1.2.0', 1], ['1.3.0', '~> 1.2.0', 0],
    ['1.2.0', '>= 1.0 and < 2.0', 1], ['2.0.0', '>= 1.0 and < 2.0', 0],
    ['1.2', '= 1.2.0', 1], ['1.2.0', '== 1.2', 1], ['1.2.0', '> 1.2.0', 0],
    ['1.2.0', '<= 1.2.0', 1], ['1.2.0', 'bogus', 0], ['1.2.0', '*', 0],
    ['1.2.0', '>= 1.0 and', 0], ['1.2.0', '>= 1.0 or < 2.0', 0],
    ['1.2.0-beta', '~> 1.0', 0], ['9999999999.0.0', '~> 1.0', 0],
) {
    my $current = dclone($provider);
    $current->{published_views}{manager_rollup}{version} = $case->[0];
    $dependency->{accepts} = $case->[1];
    my $report = $api->verify($current, $consumer);
    is(!!$report->{compatible}, !!$case->[2], "bounded version $case->[0] / $case->[1]");
}
$consumer = dclone($fixtures->{D015}{consumer_domain});
$consumer->{domain_dependencies}[0]{contract} = 'missing';
is($api->verify($provider, $consumer)->{errors}[0]{code}, 'missing_provider_contract', 'missing surface diagnosed');
$consumer->{domain_dependencies}[0]{provider} = 'another_provider';
is_deeply($api->verify($provider, $consumer)->{dependencies}, [], 'other providers are outside this report');
$consumer->{domain_dependencies}[0]{uses}{unknown} = [];
my $ok = eval { $api->verify($provider, $consumer); 1 };
ok(!$ok && $@->code eq 'invalid_domain', 'even other-provider declarations are structurally validated');
my $fallback = dclone($provider);
delete $fallback->{published_views}{manager_rollup}{fingerprint};
$consumer = dclone($fixtures->{D015}{consumer_domain});
$consumer->{domain_dependencies}[0]{expected_fingerprint} = 'sha256:provider';
ok($api->verify($fallback, $consumer)->{compatible}, 'provider fingerprint fallback is checked');

for my $case (
    [sub { $_[0]{published_views}{manager_rollup}{columns}{total}{type} = 'string' }, 1, 'type change'],
    [sub { $_[0]{published_views}{manager_rollup}{required_filters} = [qw(tenant_id owner_id)] }, 1, 'added required scope'],
    [sub { $_[0]{published_views}{manager_rollup}{filters} = [] }, 1, 'removed filter'],
    [sub { $_[0]{published_views}{manager_rollup}{query_members} = [] }, 1, 'removed query member'],
    [sub { $_[0]{published_views}{manager_rollup}{required_filters} = [] }, 0, 'removed required scope'],
    [sub { $_[0]{domain_fingerprint} = 'sha256:new' }, 0, 'provider identity review'],
) {
    my $changed = dclone($provider);
    $case->[0]->($changed);
    my $diff = $api->diff_snapshots($old, $api->snapshot($changed));
    ok($diff->{changed}, "$case->[2] is reported");
    is(!!$diff->{breaking}, !!$case->[1], "$case->[2] classification");
}
my $malformed = dclone($old);
push @{$malformed->{surfaces}}, dclone($malformed->{surfaces}[0]);
$ok = eval { $api->diff_snapshots($old, $malformed); 1 };
ok(!$ok && $@->code eq 'invalid_domain', 'ambiguous duplicate snapshot ids rejected');
for my $case (
    [sub { $_[0]{format_version} = 2 }, 'unsupported snapshot version'],
    [sub { $_[0]{surfaces}[0]{stable} = 'yes' }, 'malformed snapshot stability'],
    [sub { $_[0]{surfaces}[0]{fingerprint} = [] }, 'malformed snapshot fingerprint'],
    [sub { $_[0]{surfaces}[0]{extra} = sub { die 'must not execute' } }, 'non-JSON snapshot metadata'],
) {
    my $bad = dclone($old);
    $case->[0]->($bad);
    $ok = eval { $api->diff_snapshots($old, $bad); 1 };
    ok(!$ok && ref($@) eq 'Selecto::Error' && $@->code eq 'invalid_domain', $case->[1]);
}

my $domain = Selecto::Domain->parse({name => 'billing', source => {
    source_table => 'orders', fields => ['id'], columns => {id => {type => 'integer'}}, primary_key => 'id'},
    published_views => {ids => {columns => {id => {type => 'integer'}}}}});
is_deeply($domain->contract_snapshot, $api->snapshot($domain), 'parsed Domain exposes the public snapshot method');
ok($domain->verify_contract_compatibility({name => 'consumer', domain_dependencies => [{provider => 'billing', contract => 'ids'}]})->{compatible},
    'parsed Domain exposes public consumer verification');
ok(!$domain->diff_contract_snapshots($old, $old)->{changed}, 'Domain exposes public snapshot comparison');

my $proof = Selecto::Verification::ContractSafety->verify;
is_deeply($proof, {proof_level => 'bounded_exhaustive', model => 'selecto.domain_contract_compatibility.v1',
    state_count => 32, check_count => 64, invariant_count => 2, counterexamples => []}, 'D062 actual bounded verification');
my $false_admit = Selecto::Verification::ContractSafety->verify(verifier => sub { return {compatible => JSON::PP::true, errors => []} });
is(scalar(grep { $_->{invariant} eq 'compatibility_result_is_complete' } @{$false_admit->{counterexamples}}), 31,
    'bounded model detects all 31 false accepts');
is(scalar(grep { $_->{invariant} eq 'incompatible_dimensions_have_specific_diagnostics' } @{$false_admit->{counterexamples}}), 31,
    'bounded model detects missing diagnostics separately');
my $false_reject = Selecto::Verification::ContractSafety->verify(verifier => sub {
    my $report = $api->verify(@_); $report->{compatible} = JSON::PP::false; return $report;
});
is(scalar @{$false_reject->{counterexamples}}, 1, 'bounded model detects false rejection of the all-valid state');
my $throws = Selecto::Verification::ContractSafety->verify(verifier => sub { die 'deliberate failure' });
is(scalar @{$throws->{counterexamples}}, 64, 'exception cannot masquerade as a completed proof');
my $malformed_result = Selecto::Verification::ContractSafety->verify(verifier => sub { return {compatible => 1, errors => []} });
is(scalar @{$malformed_result->{counterexamples}}, 64, 'malformed verifier results fail both invariants');
my $isolated_provider = Selecto::Verification::ContractSafety->verify(verifier => sub {
    my $report = $api->verify(@_);
    $_[0]{published_views} = {};
    return $report;
});
is_deeply($isolated_provider->{counterexamples}, [], 'each bounded state receives independent provider input');
done_testing;
