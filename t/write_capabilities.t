use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Write;
use Selecto::Write::Expression;
use Selecto::Write::Capabilities;
use Selecto::Verification::WriteCapabilitySafety;

my $api = 'Selecto::Write::Capabilities';
my $model = 'Selecto::Verification::WriteCapabilitySafety';
sub caught {
    my ($work) = @_; my $ok = eval { $work->(); 1 }; my $error = $@;
    return $ok ? 'ok' : Scalar::Util::blessed($error) && UNIVERSAL::isa($error, 'Selecto::Error') ? $error->code : die $error;
}
sub command { Selecto::Write::Command->new(operation => 'insert', relation => 'items', assignments => {name => 'safe'}, @_) }
my $full = {protocol_version => 1, map { $_ => 1 } qw(insert update delete upsert transactions atomic_batch write_graph generated_keys returning mutation_expressions)};
is($api->protocol_version, 1, 'public protocol identity is one');
ok($api->validate($full), 'complete native report validates');
is(caught(sub {$api->validate({insert => 1})}), 'invalid_write_capabilities', 'missing version refuses');
is(caught(sub {$api->validate({protocol_version => 99})}), 'write_protocol_mismatch', 'wrong version refuses');
is(caught(sub {$api->validate({protocol_version => '1'})}), 'write_protocol_mismatch', 'numeric-looking version string is not protocol integer');
for my $bad (undef, [], 1, 'map') {
    is(caught(sub {$api->validate($bad)}), 'invalid_write_capabilities', 'non-object reports refuse');
}
for my $bad ('yes', '1', 2, -1, undef, {}) {
    is(caught(sub {$api->validate({protocol_version => 1, insert => $bad})}), 'invalid_write_capabilities', 'truthy/non-Boolean support is refused');
}
ok($api->validate({protocol_version => 1, insert => JSON::PP::true, update => JSON::PP::false}), 'JSON Boolean flags are supported');
ok(!$api->supported({protocol_version => 1, update => JSON::PP::false}, 'update'), 'JSON false is actually false');
is_deeply($api->requirements(command()), ['insert'], 'ordinary insert requires its real operation');
is_deeply($api->requirements(command(metadata => {returning => ['id']})), ['insert', ['returning','insert']], 'selected output requires operation returning');
for my $returning (1, ['insert'], {insert => JSON::PP::true, update => 0}) {
    ok($api->supported({protocol_version => 1, returning => $returning}, ['returning','insert']), 'supported returning form binds the requested operation');
}
ok(!$api->supported({protocol_version => 1, returning => {update => 1}}, ['returning','insert']), 'another returning operation does not grant insert output');
is(caught(sub {$api->validate({protocol_version => 1, returning => ['invented']})}), 'invalid_write_capabilities', 'unknown returning operation refuses');
is(caught(sub {$api->validate({protocol_version => 1, returning => {insert => 'yes'}})}), 'invalid_write_capabilities', 'returning maps require explicit flags');
is(caught(sub {$api->require({protocol_version => 1}, command())}), 'write_capability_missing', 'missing operation fails closed');
ok($api->require($full, command()), 'ordinary supported insert passes');
for my $count (undef,0,1,'2') {
    ok($api->require($full,command(expected_count=>$count)), 'finite nonnegative legacy exact count or nil remains admitted');
}
for my $count ([],{},-1,1.5,'NaN','1e3') {
    is(caught(sub{$api->requirements(command(expected_count=>$count))}), 'invalid_write', 'malformed legacy exact count refuses structurally');
}
my $extra = command(metadata => {required_capabilities => ['custom_semantics']});
is(caught(sub {$api->require($full, $extra)}), 'write_capability_missing', 'explicit custom semantics cannot disappear');
ok($api->require({%$full, custom_semantics => 1}, $extra), 'explicit custom report satisfies custom requirement');
my $mutation = command(assignments => {name => Selecto::Write::Expression->literal('safe')});
ok(grep($_ eq 'mutation_expressions', @{$api->requirements($mutation)}), 'actual mutation expression requires expression support');
is(caught(sub {$api->require({%$full, mutation_expressions => 0}, $mutation)}), 'write_capability_missing', 'expression support cannot be guessed');
my $native_constraint = command(metadata => {native_constraints => [{name => 'known_unique', code => 'conflict'}]});
is(caught(sub {$api->require($full, $native_constraint)}), 'write_capability_missing', 'native mapping needs its explicit capability');
ok($api->require({%$full, native_constraint_mapping => 1}, $native_constraint), 'an explicit provider may report native mapping');
is(caught(sub {$api->requirements(command(metadata => {document => {patch => []}}))}), 'invalid_write', 'unsupported native document lowering is refused');
my $batch = Selecto::Write::Batch->new(command(), command(operation => 'update'));
is_deeply($api->requirements($batch), [qw(transactions atomic_batch insert update)], 'batch accumulates real command and atomicity requirements');
is(caught(sub {$api->require({%$full, transactions => 0}, $batch)}), 'write_capability_missing', 'batch cannot dispatch without transactions');
my $graph = Selecto::Write::Graph->new(nodes => [
    {id => 'root', command => command()},
    {id => 'child', command => command(relation => 'children'), bindings => [{field => 'parent_id', from => 'root', key => 'id'}]},
]);
is_deeply($api->requirements($graph), ['transactions','write_graph','insert',['returning','insert'],'generated_keys'], 'binding graph requires generated keys and source returning');
for my $flag (qw(transactions write_graph returning generated_keys)) {
    is(caught(sub {$api->require({%$full, $flag => 0}, $graph)}), 'write_capability_missing', "graph refuses missing $flag");
}
ok($api->require({%$full, generated_keys => 'returning'}, $graph), 'recognized native generated-value mode is supported');
$graph->{nodes}[0]{command}{metadata}{returning} = [];
is(caught(sub {$api->require({%$full, returning => 0}, $graph)}), 'write_capability_missing', 'a stripped mutable source request cannot erase binding returning requirements');
my $hooks = 0;
{ package CapabilityHooks; use overload '""' => sub { ++$hooks; '1' }, bool => sub { ++$hooks; 0 }, fallback => 1;
  sub TO_JSON { ++$hooks; {} } sub STORABLE_freeze { ++$hooks; '' } }
{ no strict 'refs'; @{'0::ISA'} = ('CapabilityHooks') }
for my $bad (sub { ++$hooks }, bless({}, 'CapabilityHooks'), bless({}, '0')) {
    is(caught(sub {$api->validate({protocol_version => 1, unused => $bad})}), 'invalid_write_capabilities', 'complete capability admission rejects unused executable/object data');
    my $write = command(); $write->{metadata}{unused} = $bad;
    is(caught(sub {$api->requirements($write)}), 'invalid_write', 'complete native admission rejects unused executable/object data');
}
{ package CapabilityTie; sub TIEHASH { bless {}, shift } sub FIRSTKEY { ++$hooks; die 'hook' } sub FETCH { ++$hooks; die 'hook' } sub SCALAR { ++$hooks; die 'hook' } }
tie my %tied, 'CapabilityTie';
is(caught(sub {$api->validate(\%tied)}), 'invalid_write_capabilities', 'tied capability root refuses before enumeration');
my $tied_write = command(); $tied_write->{metadata} = \%tied;
is(caught(sub {$api->requirements($tied_write)}), 'invalid_write', 'tied native metadata refuses before enumeration');
is($hooks, 0, 'all rejected callback/tie/class-zero/overload routes invoke zero hooks');
untie %tied;
my $cycle = {protocol_version => 1}; $cycle->{cycle} = $cycle;
is(caught(sub {$api->validate($cycle)}), 'invalid_write_capabilities', 'cyclic capability report refuses');
my $wide = {protocol_version => 1, map { ('feature'.$_ => 1) } 1 .. 10001};
is(caught(sub {$api->validate($wide)}), 'invalid_write_capabilities', 'broad capability report refuses before traversal allocation');
my $large = 'x' x 70000;
is(caught(sub {$api->validate({protocol_version => 1, unused => [$large,$large]})}), 'invalid_write_capabilities', 'repeated input occurrences consume cumulative bytes');

my $states = $model->states;
is(scalar(@$states), 30, 'all original five-by-six states exist');
my %profiles; $profiles{$_->{profile}}{$_->{shape}} = 1 for @$states;
is_deeply([sort keys %profiles], [sort qw(full no_returning flat_only missing_version wrong_version)], 'all original adapter profiles exist');
is_deeply([sort keys %{$profiles{full}}], [sort qw(insert insert_returning update batch graph generated_graph)], 'all original write shapes exist');
my ($plain_graph) = map { $_->{write} } grep { $_->{profile} eq 'full' && $_->{shape} eq 'graph' } @$states;
is(scalar(@{$plain_graph->nodes}), 2, 'plain graph is the actual two-row original shape');
is_deeply([map { $_->{bindings} } @{$plain_graph->nodes}], [[],[]], 'plain graph retains both independent original rows');
my $report = $model->verify;
is_deeply($report, {proof_level => 'bounded_exhaustive', model => 'selecto.write_capability_preflight.v1', state_count => 30,
    check_count => 90, invariant_count => 3, counterexamples => []}, 'genuine full public preflight model passes all original invariants');
my $fault = $model->verify(preflight => sub { 1 });
ok(@{$fault->{counterexamples}} > 0, 'independent model detects a permissive preflight implementation');
ok(grep($_->{invariant} eq 'protocol_mismatch_never_dispatches', @{$fault->{counterexamples}}), 'model specifically detects protocol dispatch faults');
$fault = $model->verify(preflight => sub { Selecto::Error->throw('write_capability_missing','injected denial') });
ok(grep($_->{invariant} eq 'dispatch_matches_independent_matrix' && $_->{state}{profile} eq 'full', @{$fault->{counterexamples}}), 'model detects blanket refusal of supported writes');
is(caught(sub {$model->verify(preflight => bless({}, '0'))}), 'invalid_argument', 'model callback boundary rejects false-named objects');
done_testing;
