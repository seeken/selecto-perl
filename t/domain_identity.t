use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;

open my $file, '<:raw', 't/fixtures/domain_identity.json' or die $!;
my $fixtures = JSON::PP->new->utf8->decode(do {local $/; <$file>}); close $file;
my $base = $fixtures->{D013}{domains}{inferred};
sub codes { [map { $_->{code} } @{$_[0]}] }
my $identity = Selecto::Domain->validate_identity($fixtures->{D009}{governed_domain});
ok($identity->{ok}, 'original governed source identity validates');
is($identity->{normalized}{schema_version}, 1, 'declared schema version retained');
is($identity->{normalized}{domain_version}, '2.1.0', 'opaque version retained');
is($identity->{normalized}{domain_fingerprint}, 'sha256:certification-work-items-v2', 'authored fingerprint retained');
is_deeply(codes($identity->{diagnostics}{warnings}), [qw(projection_sections proposed_sections)], 'canonical section warning order');
is_deeply($identity->{diagnostics}{errors}, [], 'valid source identity has no errors');
for my $kind (qw(inferred future invalid)) {
    my $result = Selecto::Domain->normalize_identity($fixtures->{D013}{domains}{$kind});
    ok($result->{ok}, "$kind version is diagnostic only");
    is($result->{normalized}{schema_version}, $kind eq 'future' ? 99 : 1, "$kind selects expected version");
    is(!!$result->{diagnostics}{schema_version_inferred}, $kind eq 'inferred' ? 1 : '', "$kind inference is explicit");
    is_deeply(codes($result->{diagnostics}{warnings}), [$kind eq 'inferred' ? 'schema_version_inferred'
        : $kind eq 'future' ? 'unsupported_schema_version' : 'invalid_schema_version'], "$kind emits stable warning");
}
for my $value (undef, 0, -1, 1.0, 1.5, JSON::PP::true, [], {}, '', '1x', ' 1', "\x{663}", "\x{ff11}", '9223372036854775808') {
    my $result = Selecto::Domain->normalize_identity({%$base, schema_version => $value});
    is($result->{normalized}{schema_version}, 1, 'invalid schema version falls back without coercion');
    is(codes($result->{diagnostics}{warnings})->[0], 'invalid_schema_version', 'invalid schema version has its own warning');
    ok(!$result->{diagnostics}{schema_version_inferred}, 'present invalid version is not inferred');
}
for my $value ('1', '+01', 1, '99') {
    my $result = Selecto::Domain->normalize_identity({%$base, schema_version => $value});
    is($result->{normalized}{schema_version}, 0 + $value, 'integer strings and integers normalize');
}
my $labels = Selecto::Domain->normalize_identity({%$base, domain_version => ' release-A ', domain_fingerprint => ' fp:any '});
is($labels->{normalized}{domain_version}, 'release-A', 'version label is trimmed and opaque');
is($labels->{normalized}{domain_fingerprint}, 'fp:any', 'fingerprint label is trimmed and opaque');
for my $bad ([], JSON::PP::true, 1.5) {
    my $result = Selecto::Domain->normalize_identity({%$base, domain_version => $bad, domain_fingerprint => $bad});
    ok(!defined($result->{normalized}{domain_version}), 'malformed version label omitted from identity');
    ok(!defined($result->{normalized}{domain_fingerprint}), 'malformed fingerprint omitted from identity');
}
my $invalid = Selecto::Domain->validate_identity($fixtures->{D012}{invalid_domain});
ok(!$invalid->{ok}, 'missing source field column is invalid');
is_deeply(codes($invalid->{diagnostics}{errors}), ['source_field_missing_column'], 'source failure is precise');
is_deeply($invalid->{diagnostics}{errors}[0]{path}, [qw(source columns missing)], 'source failure includes path');
my $absent = Selecto::Domain->validate_identity({});
is_deeply([map {$_->{path}[0]} grep {$_->{code} eq 'missing_required_section'} @{$absent->{diagnostics}{errors}}],
    [qw(source schemas)], 'missing required identity sections reported together');
for my $malformed (undef, JSON::PP::false, []) {
    my $result = Selecto::Domain->validate_identity({%$base, schemas => $malformed});
    ok(!$result->{ok}, 'explicit malformed schemas are not replaced with an empty object');
    is($result->{diagnostics}{errors}[0]{code}, 'invalid_section_shape', 'malformed schemas produce a structured error');
}
for my $bad (undef, [], 'domain') {
    my $result = Selecto::Domain->normalize_identity($bad);
    ok(!$result->{ok}, 'non-object domain rejects');
    is($result->{diagnostics}{errors}[0]{code}, 'invalid_domain', 'non-object diagnostic stable');
}
my $broken = dclone($base); $broken->{source}{primary_key} = ['id', 'id'];
is(Selecto::Domain->validate_identity($broken)->{diagnostics}{errors}[0]{code}, 'invalid_primary_key', 'duplicate composite keys reject');
$broken = dclone($base); $broken->{source}{primary_key} = 'missing';
is(Selecto::Domain->validate_identity($broken)->{diagnostics}{errors}[0]{code}, 'primary_key_not_found', 'primary key must be among fields');
$broken = dclone($base); $broken->{source}{columns}{id} = [];
is(Selecto::Domain->validate_identity($broken)->{diagnostics}{errors}[0]{code}, 'invalid_column_definition', 'column shape rejects');
my $schema = {primary_key => 'key', fields => [qw(key label)],
    columns => {key => {type => 'integer'}, label => {type => 'string'}},
    values => [{key => 1, label => 'one'}, {key => 2, label => undef}, {key => 3, label => JSON::PP::false}]};
ok(Selecto::Domain->validate_identity({%$base, schemas => {lookup => $schema}})->{ok},
    'scalar VALUES schema identity validates, including null and booleans');
my $table_schema = dclone($schema); delete $table_schema->{values}; $table_schema->{source_table} = '';
ok(Selecto::Domain->validate_identity({%$base, schemas => {lookup => $table_schema}})->{ok},
    'canonical empty binary source_table remains allowed');
for my $kind (qw(neither both)) {
    my $relation = dclone($schema);
    if ($kind eq 'neither') { delete $relation->{values} } else { $relation->{source_table} = 'lookup' }
    my $result = Selecto::Domain->validate_identity({%$base, schemas => {lookup => $relation}});
    ok(!$result->{ok}, "$kind schema source identity rejects");
    is($result->{diagnostics}{errors}[0]{code}, 'invalid_relation_source', "$kind has stable source-kind diagnostics");
}
for my $rows (undef, [], {}, [undef], [{key => 1}], [{key => 1, label => 'one', extra => 2}],
    [{key => 1, label => []}], [{key => 1, label => {nested => 'value'}}], [{key => 1, label => sub {die 'not executed'}}]) {
    my $relation = {%$schema, values => $rows};
    my $result = Selecto::Domain->validate_identity({%$base, schemas => {lookup => $relation}});
    ok(!$result->{ok}, 'malformed VALUES rows reject');
    like($result->{diagnostics}{errors}[0]{code}, qr/\Ainvalid_relation_values(?:_row)?\z/, 'VALUES failure is structured');
}
my $empty_fields = {%$schema, fields => []};
ok(!Selecto::Domain->validate_identity({%$base, schemas => {lookup => $empty_fields}})->{ok}, 'VALUES requires declared fields');
my $before = dclone($fixtures->{D011});
my $composed = Selecto::Domain->compose_identity($fixtures->{D011}{base}, $fixtures->{D011}{overlays});
ok($composed->{ok}, 'original identity overlay composition succeeds');
is_deeply($composed->{normalized}{query}{default_selected}, ['name'], 'selected list is replaced');
is($composed->{normalized}{source}{columns}{name}{name}, 'Display name', 'column map is merged');
is_deeply($composed->{normalized}{source}{redact_fields}, ['nickname'], 'redacted fields union uniquely');
is_deeply(codes($composed->{diagnostics}{warnings}), ['proposed_sections'], 'composition warnings match merged domain');
is_deeply($fixtures->{D011}, $before, 'composition preserves all inputs');
$composed->{normalized}{source}{columns}{name}{name} = 'modified';
is_deeply($fixtures->{D011}, $before, 'returned containers are isolated');
for my $bad (1, ['bad']) {
    my $result = Selecto::Domain->compose_identity($base, $bad);
    ok(!$result->{ok}, 'malformed overlay returns diagnostics');
    is($result->{diagnostics}{errors}[0]{code}, 'invalid_domain_overlay', 'overlay error stable');
}
my $calls = 0; my $callback = sub { ++$calls; die 'must not run' };
my $with_callback = {%$base, extensions => [{merge_domain => $callback}], filters => {callback => {apply => $callback}}};
my $no_execution = Selecto::Domain->compose_identity($with_callback, {extensions => [{merge_domain => $callback}]});
ok($no_execution->{ok}, 'callback-bearing metadata composes without execution');
is($calls, 0, 'no declared callback is invoked');
is(scalar @{$no_execution->{normalized}{domain}{extensions}}, 1, 'same extension declaration unions once');
my $cyclic = {}; $cyclic->{cycle} = $cyclic;
eval { Selecto::Domain->normalize_identity($cyclic) };
is(ref($@) ? $@->code : '', 'invalid_domain', 'cycles reject without runaway recursion');
my $portable = $fixtures->{D010}{domains}[0];
my $first = Selecto::Domain->query_identity($portable);
my $second = Selecto::Domain->query_identity(JSON::PP->new->decode(JSON::PP->new->encode($portable)));
is_deeply($first->{identity}, $second->{identity}, 'portable string keys retain query identity');
my $parsed = Selecto::Domain->parse($portable);
is_deeply($parsed->query_identity->{identity}, $first->{identity}, 'instance identity delegates to public metadata API');
isnt($parsed->fingerprint, 'sha256:certification-work-items-v2', 'runtime semantic fingerprint remains independent');
done_testing;
