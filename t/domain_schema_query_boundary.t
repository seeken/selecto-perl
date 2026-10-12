use 5.034;
use strict;
use warnings;
use Test::More;
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
use JSON::PP ();
use Storable qw(dclone);
use Selecto;
use Selecto::Domain::Schema;
use Selecto::QueryLibrary::Contract;

sub read_json { open my $f, '<:raw', $_[0] or die $!; local $/; JSON::PP->new->utf8->decode(<$f>) }
my $fixtures = read_json('t/fixtures/schema_query_boundary.json');
my $expected = read_json('t/fixtures/schema_query_boundary_expected.json');
my $before = dclone($fixtures);
my %expected = map { $_->{id} => $_->{accepted} ? 1 : 0 } @{$expected->{DS001}};
my %cases = map { $_->{id} => $_->{domain} } @{$fixtures->{DS001}{cases}};
sub caught { my ($run) = @_; my $ok = eval { $run->(); 1 }; $ok ? undef : $@ }
sub code { ref($_[0]) && UNIVERSAL::isa($_[0], 'Selecto::Error') ? $_[0]->code : 'none' }
sub codes { [sort map { $_->{code} } @{$_[0]{errors}}] }

for my $case (@{$fixtures->{DS001}{cases}}) {
    my $report = Selecto::Domain->validate_schema($case->{domain});
    is($report->{valid} ? 1 : 0, $expected{$case->{id}}, "DS001 $case->{id}: complete original declaration");
    ok($report->{valid} || @{$report->{errors}}, "$case->{id}: rejection has actual diagnostics");
}
is_deeply($fixtures, $before, 'all complete original declarations remain unchanged');
my $base = $cases{baseline};
my $report = Selecto::Domain->validate_schema($base);
${$report->{valid}} = 0;
ok(Selecto::Domain->validate_schema($base)->{valid}, 'schema valid flag has an independent Boolean referent');
my $invalid = Selecto::Domain->validate_schema($cases{invalid_event_type});
$invalid->{errors}[0]{path}[0] = 'changed';
is(Selecto::Domain->validate_schema($cases{invalid_event_type})->{errors}[0]{path}[0], 'events', 'returned diagnostics are independent');
for my $control (
    ['unknown event type', sub { $_[0]{events}={e=>{schema_version=>1,data=>{x=>'bad'}}} }, 'unsupported_event_field_type'],
    ['numeric event option', sub { $_[0]{events}={e=>{schema_version=>1,data=>{x=>{type=>'string',required=>1}}}} }, 'invalid_event_field_option'],
    ['string event version', sub { $_[0]{events}={e=>{schema_version=>'1',data=>{}}} }, 'invalid_event_schema_version'],
    ['empty consumer ID', sub { $_[0]{operations}={' '=>{}} }, 'invalid_consumer_registry_id'],
    ['null readonly', sub { $_[0]{source}{readonly}=undef }, 'invalid_readonly'],
    ['both relation source identities', sub { $_[0]{schemas}{x}={%{dclone($_[0]{source})},values=>[{id=>1,name=>'n'}]} }, 'invalid_relation_source'],
    ['neither relation source identity', sub { $_[0]{schemas}{x}=dclone($_[0]{source}); delete $_[0]{schemas}{x}{source_table} }, 'invalid_relation_source'],
    ['ragged VALUES row', sub { $_[0]{schemas}{x}={%{dclone($_[0]{source})},values=>[{id=>1}]};delete $_[0]{schemas}{x}{source_table} }, 'invalid_relation_values_row'],
    ['nested VALUES member', sub { $_[0]{schemas}{x}={%{dclone($_[0]{source})},values=>[{id=>1,name=>{}}]};delete $_[0]{schemas}{x}{source_table} }, 'invalid_relation_values_row'],
) {
    my ($name,$edit,$expected_code)=@$control; my $c=dclone($base); $edit->($c);
    ok(grep($_ eq $expected_code,@{codes(Selecto::Domain->validate_schema($c))}), "$name has contextual public diagnostics");
}
my $event=dclone($base);
$event->{events}={' '=>{schema_version=>1,additional_fields=>undef,data=>{' '=>{type=>'list',nullable=>JSON::PP::true,item=>{type=>'enum',values=>[]}}}}};
ok(Selecto::Domain->validate_schema($event)->{valid}, 'declared nested list/enum and nullable payload metadata validates');
$event->{events}{' '}{data}{' '}{item}{type}='missing';
ok(!Selecto::Domain->validate_schema($event)->{valid}, 'changed nested payload type actually invalidates');
my $values=dclone($base);$values->{schemas}{x}={%{dclone($values->{source})},values=>[{id=>1,name=>'n'}]};delete $values->{schemas}{x}{source_table};
ok(Selecto::Domain->validate_schema($values)->{valid}, 'bounded exact field-identity VALUES metadata validates');
my $library=$cases{query_library_contract};
ok(Selecto::QueryLibrary::Contract->validate_declaration($library)->{valid}, 'portable declaration permits scalar ordering metadata');
my $libreport=Selecto::QueryLibrary::Contract->validate_declaration($library);${$libreport->{valid}}=0;
ok(Selecto::QueryLibrary::Contract->validate_declaration($library)->{valid}, 'public metadata library report Boolean is independent');
my $native=caught(sub{Selecto::Domain->parse($library)});
is(code($native),'invalid_query_library','pure scalar ordering metadata does not silently enable unsupported native library execution');
for my $edit (
    sub { $_[0]{joins}{ghost}={};$_[0]{query_library}{projections}{tree}{associations}=[{name=>'ghost'}] },
    sub { $_[0]{source}{associations}{child}{queryable}='absent' },
    sub { $_[0]{joins}{child}{joins}{ghost}={};$_[0]{query_library}{projections}{tree}{associations}[0]{associations}=[{name=>'ghost'}] },
    sub { $_[0]{query_library}{projections}{tree}{associations}[0]{fields}=[JSON::PP::false] },
) {
    my$c=dclone($cases{nested_projection});$edit->($c);
    ok(!Selecto::Domain->validate_schema($c)->{valid},'projection cannot invent associations or launder non-scalar fields');
}
my $calls=0;
{package SchemaEvil;use overload '""'=>sub{$calls++;'evil'},'bool'=>sub{$calls++;1},fallback=>1;sub isa{$calls++;1}sub STORABLE_freeze{$calls++;die 'callback'}sub TO_JSON{$calls++;die 'callback'}}
{no strict 'refs'; @{'0::ISA'}=('SchemaEvil')}
for my $bad (sub{$calls++},bless({},'SchemaEvil'),bless({},'0')) {
    my$c=dclone($base);$c->{extension}=$bad;
    is(code(caught(sub{Selecto::Domain->validate_schema($c)})),'invalid_query_contract','schema refuses executable/unknown object before hooks');
    is(code(caught(sub{Selecto::QueryLibrary::Contract->validate_declaration($c)})),'invalid_query_contract','library metadata refuses executable/unknown object before hooks');
}
{package SchemaTie;sub TIEHASH{bless{},shift}sub FIRSTKEY{$calls++;die 'hook'}sub FETCH{$calls++;die 'hook'}sub TIESCALAR{bless{},shift}}
tie my %tied,'SchemaTie';
is(code(caught(sub{Selecto::Domain->validate_schema(\%tied)})),'invalid_query_contract','schema refuses tied root before hooks');
my$t=dclone($base);tie $t->{source}{readonly},'SchemaTie';
is(code(caught(sub{Selecto::Domain->validate_schema($t)})),'invalid_query_contract','schema refuses tied nested flag before FETCH');
is($calls,0,'no overload, serialization or tied callback executes');
for my $shape(qw(cycle depth breadth bytes aliases)) {
    my$c=dclone($base);
    if($shape eq 'cycle'){$c->{extension}=$c}
    elsif($shape eq 'depth'){my$n={};$c->{extension}=$n;for(1..70){$n->{next}={};$n=$n->{next}}}
    elsif($shape eq 'breadth'){$c->{extension}=[(1)x10001]}
    elsif($shape eq 'bytes'){$c->{extension}='x'x131073}
    else{my$n=['leaf'];$n=[$n,$n]for 1..14;$c->{extension}=$n}
    is(code(caught(sub{Selecto::Domain->validate_schema($c)})),'invalid_query_contract',"$shape refuses within trusted input budget");
}
my$long='e'x4096;my$c=dclone($base);$c->{events}{$long}={schema_version=>1,data=>{map{("f$_"=>'bad')}1..40}};
is_deeply(Selecto::Domain::QueryContract->copy_declaration($c),$c,'compact diagnostic amplification input is admitted');
is(code(caught(sub{Selecto::Domain->validate_schema($c)})),'invalid_domain_schema','repeated emitted event paths are cumulatively bounded');
my$l=dclone($base);$l->{query_library}{projections}{$long}={fields=>[('missing')x40]};
is_deeply(Selecto::Domain::QueryContract->copy_declaration($l),$l,'compact library diagnostic input fits whole-declaration admission');
is(code(caught(sub{Selecto::QueryLibrary::Contract->validate_declaration($l)})),'invalid_query_library','emitted library diagnostic identifiers use a cumulative byte budget');

SKIP: {
    skip 'DBD::SQLite is required', 12 unless eval{require DBI;require DBD::SQLite;1};
    my$db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});$db->do('PRAGMA temp_store=MEMORY');
    $db->do('CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name TEXT,active INTEGER)');
    $db->do('INSERT INTO selecto_cert_people VALUES(?,?,?)',undef,@$_) for ([1,'Ada Lovelace',1],[2,'Grace Hopper',1],[3,'Renée 東京',0],[4,'Linus Torvalds',1]);
    my$domain=Selecto::Domain->parse($fixtures->{DQ001}{domain});
    my$engine=Selecto::Engine->new(domain=>$domain,adapter=>Selecto->adapter(sqlite=>dbh=>$db));
    sub intent_query {
        my($e,$i)=@_;my$q=$e->query->select($i->{select});$q=$q->order_by($_->{field},$_->{direction})for @{$i->{order_by}};
        $q=$q->where(Selecto::Expression->any(map{Selecto::Expression->eq($_->{field},$_->{value})}@{$i->{filter}{args}}))if$i->{filter};$q;
    }
    for my$name(sort keys%{$fixtures->{DQ001}{queries}}){
        my$q=intent_query($engine,$fixtures->{DQ001}{queries}{$name});
        is_deeply($engine->all($q)->{rows},$expected->{DQ001}{"${name}_rows"},"DQ001 $name uses full original imported domain and caller intent");
        my$s=$engine->compile($q);
        like($s->sql,qr/"active" = \?/,'required domain filter stays parameterized');
    }
    my$q=intent_query($engine,$fixtures->{DQ001}{queries}{narrowed});my$s=$engine->compile($q);
    is_deeply($s->params,[JSON::PP::true,1,3],'native caller OR follows mandatory domain parameter');
    like($s->sql,qr/AND \(\(.* OR /,'mandatory predicate encloses the caller disjunction');
    my$changed=dclone($fixtures->{DQ001}{domain});$changed->{required_filters}=[['active',JSON::PP::false]];
    my$other=Selecto::Engine->new(domain=>Selecto::Domain->parse($changed),adapter=>Selecto->adapter(sqlite=>dbh=>$db));
    is_deeply($other->all(intent_query($other,$fixtures->{DQ001}{queries}{narrowed}))->{rows},[[3]],'changed authored domain filter changes actual native permitted rows');
    my$events=0;$db->sqlite_set_authorizer(sub{$events++;return 0});
    $engine->domain->{contract}{source}{source_table}='elsewhere';
    is(code(caught(sub{$engine->all($q)})),'domain_modified_after_configuration','imported configured domain cannot retarget native query');
    is($events,0,'configured identity refusal occurs before native SQL');
    $db->sqlite_set_authorizer(undef);
    is($db->selectrow_array('PRAGMA temp_store'),2,'native TEMP remains memory');
    is($db->selectall_arrayref('PRAGMA database_list')->[0][2],'','native main remains memory');
    is_deeply($fixtures,$before,'native queries leave complete fixture unchanged');
    $db->disconnect;
}
done_testing;
