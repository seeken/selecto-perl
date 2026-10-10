use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain ();
use Selecto::FieldPolicy ();

my $raw = {schema_version => 1, name => 'Policy', source => {
    source_table => 'policy_rows', primary_key => 'id', fields => [qw(id status secret)],
    columns => {id => {type => 'integer'}, status => {type => 'string'}, secret => {type => 'string', internal => JSON::PP::true}},
    associations => {}}, writes => {operations => {insert => {enabled => JSON::PP::true}, update => {enabled => JSON::PP::true}},
    fields => {status => {insertable => JSON::PP::true, updatable => JSON::PP::true, required => JSON::PP::true}}}};
my $domain = Selecto::Domain->parse($raw, strict => 1);
my $policy = Selecto::FieldPolicy->new(domain => $domain);
my $snapshot = {id => 9_007_199_254_740_993, status => {nested => ['A']}, secret => 'host-only'};
my $profile = ['id', {field => 'status', options => [{value => 'A', active => JSON::PP::true}]}, 'secret'];
my $before = dclone({snapshot => $snapshot, profile => $profile});
my $fields = $policy->resolve(profile => $profile, snapshot => $snapshot, include_hidden_values => 1);
my $safe = $policy->resolve(profile => $profile, snapshot => $snapshot);
ok(!exists($safe->[2]{value}), 'default hidden descriptor still omits its value');
for my $flag (0, JSON::PP::false) {
    ok(!exists($policy->resolve(profile => ['secret'], snapshot => $snapshot, include_hidden_values => $flag)->[0]{value}), 'explicit false retains safe hidden descriptor');
}
is($policy->resolve(profile => ['secret'], snapshot => $snapshot, include_hidden_values => JSON::PP::true)->[0]{value}, 'host-only', 'canonical true explicitly selects complete host descriptors');
is_deeply($policy->visible(profile => ['secret'], snapshot => $snapshot, include_hidden_values => 1), [], 'complete host mode still filters hidden descriptors from visible');
is_deeply($policy->accepted_fields(profile => ['secret'], snapshot => $snapshot, include_hidden_values => 1), [], 'complete host mode never grants hidden assignments');
is($fields->[0]{value}, 9_007_199_254_740_993, 'exact native integer snapshot is retained');
is($fields->[2]{value}, 'host-only', 'full host descriptors retain hidden snapshot value');
is_deeply([map {$_->{field}} @{$policy->visible(profile => $profile, snapshot => $snapshot)}], [qw(id status)], 'visible excludes hidden values and descriptors');
is_deeply($policy->accepted_fields(profile => $profile), ['status'], 'only editable fields are accepted');
is($policy->resolve(operation => 'view', profile => ['status'])->[0]{writable}, 0, 'view never grants direct assignments');
is($policy->resolve(operation => 'insert', profile => ['status'])->[0]{required}, 1, 'insert applies write-contract requiredness');
is($policy->resolve(profile => [{field => 'status', action => 'transition'}])->[0]{state}, 'action-backed', 'workflow action stays outside accepted assignments');
$fields->[1]{value}{nested}[0] = 'changed';
$fields->[1]{options}[0]{value} = 'changed';
${$fields->[1]{options}[0]{active}} = 0;
is_deeply({snapshot => $snapshot, profile => $profile}, $before, 'nested values, options and Boolean copies do not alias authored inputs');
my $again = $policy->resolve(profile => $profile, snapshot => $snapshot);
is($again->[1]{value}{nested}[0], 'A', 'later resolution follows original snapshot');
ok($again->[1]{options}[0]{active}, 'later resolution retains original true option');

my $context = bless {}, 'PolicyContext';
my @requests;
my $decision = {status => 'disabled', reason => 'Locked', reason_code => 'locked'};
my $mutating = Selecto::FieldPolicy->new(domain => $domain, authorize => sub {
    my ($request) = @_; push @requests, dclone($request->{snapshot});
    is($request->{context}, $context, 'trusted context stays opaque');
    $request->{snapshot}{status}{nested}[0] = 'callback mutation';
    return $request->{phase} eq 'edit' ? $decision : {status => 'enabled'};
});
my $resolved = $mutating->resolve(profile => [{field => 'status', view_capability => 'read', edit_capability => 'edit'}], snapshot => $snapshot, context => $context);
is_deeply(\@requests, [$snapshot, $snapshot], 'view and edit each receive independent actual snapshot copies');
is($resolved->[0]{value}{nested}[0], 'A', 'host callback cannot change descriptor snapshot');
is($snapshot->{status}{nested}[0], 'A', 'host callback cannot change caller snapshot');
is($resolved->[0]{state}, 'read-only', 'actual disabled host decision removes edit eligibility');
is($resolved->[0]{writable}, 1, 'contract authority remains separate from host denial');
is($resolved->[0]{reason_code}, 'locked', 'host reason code is observed');
$resolved->[0]{reason} = 'different';
is($decision->{reason}, 'Locked', 'returned reason does not mutate host decision');

my $calls = 0;
my $counting = Selecto::FieldPolicy->new(domain => $domain, authorize => sub {$calls++; return {status => 'enabled'}});
sub reject {
    my ($label, $args, $no_auth) = @_;
    $calls = 0; my $ok = eval {$counting->resolve(%$args); 1}; my $error = $@;
    ok(!$ok && ref($error) && UNIVERSAL::isa($error, 'Selecto::Error') && $error->code eq 'invalid_field_policy', "$label is a typed refusal");
    is($calls, 0, "$label is refused before capability callbacks") if $no_auth;
}
for my $case (
    ['unknown field', {profile => ['unknown']}], ['duplicate field', {profile => ['status','status']}],
    ['unknown setting', {profile => [{field => 'status', raw_sql => '1=1'}]}],
    ['invalid Boolean', {profile => [{field => 'status', eligible => 'yes'}]}],
    ['invalid rows', {profile => [{field => 'status', rows => 21}]}],
    ['invalid options', {profile => [{field => 'status', options => 'bad'}]}],
    ['invalid mode', {profile => [{field => 'status', mode => 'force_edit'}]}],
    ['invalid operation', {operation => 'delete', profile => ['status']}],
    ['malformed view capability', {profile => [{field => 'status', view_capability => []}]}],
    ['malformed edit capability', {profile => [{field => 'status', edit_capability => {}}]}],
    ['undefined rows', {profile => [{field => 'status', rows => undef}]}],
    ['field-owned full descriptor option', {profile => [{field => 'secret', include_hidden_values => 1}]}],
) {reject(@$case)}
my $cycle = [];push @$cycle,$cycle;
my $deep = {};my $cursor = $deep;for (1..66) {$cursor->{next}={};$cursor=$cursor->{next}}
my $large = ['x' x 131_073];
my $many = [(undef) x 10_001];
our $hooks = 0;
{package PolicyHook;sub STORABLE_freeze {$main::hooks++;return 'bad'};use overload '""'=>sub{$main::hooks++;'bad'},fallback=>1;}
{no strict 'refs'; @{'0::ISA'} = ('PolicyHook');}
{package PolicyTied;sub TIEHASH {bless {},shift}sub FIRSTKEY {$main::hooks++;undef}sub NEXTKEY {undef}sub FETCH {$main::hooks++;undef}}
my %tied;tie %tied,'PolicyTied';
$hooks=0;my$false_class=bless({},'0');is("$false_class",'bad','false class name has a reachable overload positive control');is($hooks,1,'false class overload witness actually ran');
my @bad = (
    ['executable option', [sub {$hooks++}]], ['serialization object', [bless({},'PolicyHook')]],
    ['false class name', [bless({},'0')]], ['tied option', [\%tied]], ['cyclic option',$cycle],
    ['deep option',[$deep]], ['oversized option',$large], ['too many occurrences',$many],
);
for my $case (@bad) {
    $hooks=0;reject($case->[0],{profile => [{field => 'status', view_capability => 'read', options => $case->[1]}]},1);
    is($hooks,0,"$case->[0] does not run metadata hooks");
}
for my $bad_flag ('yes', 2, undef, [], {}, sub {$hooks++}, bless({},'PolicyHook'), bless({},'0')) {
    $hooks=0;reject('malformed host descriptor option',{profile=>[{field=>'status',view_capability=>'read'}],include_hidden_values=>$bad_flag},1);
    is($hooks,0,'malformed host descriptor option invokes no hooks');
}
my $tied_value;{package PolicyTiedScalar;sub TIESCALAR {bless{},shift}sub FETCH {$main::hooks++;'A'}sub STORE {}}
my $tied_flag;tie $tied_flag,'PolicyTiedScalar';my $bool_ref=bless(\$tied_flag,'JSON::PP::Boolean');$hooks=0;
reject('tied Boolean host descriptor option',{profile=>[{field=>'status',view_capability=>'read'}],include_hidden_values=>$bool_ref},1);
is($hooks,0,'tied host descriptor option is refused without FETCH');
my $slot={status=>'A'};tie $slot->{status},'PolicyTiedScalar';$hooks=0;
reject('tied snapshot scalar',{profile=>[{field=>'status',view_capability=>'read'}],snapshot=>$slot},1);
is($hooks,0,'tied snapshot is refused without FETCH');
reject('non-object snapshot',{profile=>['status'],snapshot=>[]},1);
reject('non-array profile',{profile=>{}},1);

for my $bad (undef, [], {status=>'maybe'}, {status=>'enabled',reason=>[]}, {status=>'enabled',reason_code=>{}}, {status=>'enabled',extra=>sub{$hooks++}}, bless({},'PolicyHook')) {
    my $p=Selecto::FieldPolicy->new(domain=>$domain,authorize=>sub{$bad});$hooks=0;
    my$ok=eval{$p->resolve(profile=>[{field=>'status',edit_capability=>'edit'}]);1};my$error=$@;
    ok(!$ok&&ref($error)&&$error->code eq'invalid_field_policy','malformed host decision returns a typed refusal');
    is($hooks,0,'malformed host decision invokes no serialization or object hook');
}
my $large_raw=dclone($raw);my@ids=map{"field$_"}1..100;
$large_raw->{source}{fields}=['id',@ids];$large_raw->{source}{columns}={id=>{type=>'integer'},map{($_=>{type=>'string'})}@ids};
$large_raw->{writes}{fields}={map{($_=>{updatable=>1})}@ids};
my $large_domain=Selecto::Domain->parse($large_raw,strict=>1);my$emitted=0;
my $amplifier=Selecto::FieldPolicy->new(domain=>$large_domain,authorize=>sub{$emitted++;{status=>'disabled',reason=>'L'x5000}});
my $ok=eval{$amplifier->resolve(profile=>[map{{field=>$_,edit_capability=>'edit'}}@ids]);1};my$error=$@;
ok(!$ok&&ref($error)&&$error->code eq'invalid_field_policy','cumulative emitted host decisions have a byte budget');
cmp_ok($emitted,'<',100,'amplification is refused before retaining the full expanded result');

$emitted=0;my$copy_amplifier=Selecto::FieldPolicy->new(domain=>$large_domain,authorize=>sub{$emitted++;{status=>'enabled'}});
$ok=eval{$copy_amplifier->resolve(profile=>[map{{field=>$_,edit_capability=>'edit'}}@ids],snapshot=>{id=>'S'x10_000});1};$error=$@;
ok(!$ok&&ref($error)&&$error->code eq'invalid_field_policy','repeated callback snapshot copies have a cumulative budget');
cmp_ok($emitted,'<',100,'snapshot amplification refuses before invoking every callback');

done_testing;
