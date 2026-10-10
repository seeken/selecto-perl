use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed refaddr);
use Selecto::Domain;
use Selecto::Domain::WriteContract;
use Selecto::Domain::QueryContract;

my $api = 'Selecto::Domain::WriteContract';
my $json = JSON::PP->new->canonical;
sub copy { Selecto::Domain::QueryContract->copy_declaration($_[0]) }
sub truth { my $v = $_[0] ? 1 : 0; bless \$v, 'JSON::PP::Boolean' }
sub domain {
    return {source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id tenant_id parent_id title state version)],
        columns => {map { $_ => {type => 'integer'} } qw(id tenant_id parent_id title state version)},
        associations => {owner => {queryable => 'users', owner_key => 'parent_id', related_key => 'id', cardinality => 'one'}}},
        schemas => {users => {source_table => 'users', primary_key => 'id', fields => [qw(id tenant_id name)],
            columns => {map {$_ => {type => 'integer'}} qw(id tenant_id name)}, associations => {}}},
        joins => {owner => {type => 'left'}},
        writes => {operations => {insert => {enabled => truth(1)}, update => {enabled => truth(1), require_filter => truth(1)},
                delete => {enabled => truth(0)}, upsert => {enabled => truth(1)}},
            fields => {title => {insertable => truth(1), updatable => truth(1), immutable => truth(0),
                write_once => truth(0), server_managed => truth(0)}},
            scope => {tenant => {required => truth(1), field => 'tenant_id', satisfied_by => ['trusted_context']}}}};
}
sub error {
    my ($run, $code, $label) = @_;
    my $ok = eval { $run->(); 1 };
    my $error = $@;
    ok(!$ok && blessed($error) && ref($error) eq 'Selecto::Error', "$label is typed");
    is(blessed($error) ? $error->code : undef, $code, "$label code") if defined $code;
    return $error;
}
sub invalid {
    my ($edit, $code, $label) = @_;
    my $d = domain(); $edit->($d);
    my $before = $json->encode($d);
    my $report = $api->validate($d);
    ok(!$report->{valid}, "$label invalid");
    ok((grep { $_->{code} eq $code } @{$report->{errors}}), "$label diagnostic $code");
    is($json->encode($d), $before, "$label leaves input unchanged");
    error(sub { $api->compile($d) }, 'invalid_domain', "$label compile refusal");
}

my $d = domain();
my $before = $json->encode($d);
my $contract = Selecto::Domain->compile_write_contract($d);
ok(Selecto::Domain->validate_write_contract($d)->{valid}, 'public Domain validation wrapper');
is_deeply([sort keys %{$contract->{operations}}], [qw(insert update upsert)], 'only explicitly enabled operations survive');
ok($contract->{fields_declared}, 'compiled fields_declared canonical true');
is(ref($contract->{fields_declared}), 'JSON::PP::Boolean', 'fields_declared is canonical Boolean');
ok($api->operation_enabled($contract, 'update'), 'enabled accessor');
ok(!$api->operation_enabled($contract, 'delete'), 'disabled accessor');
ok($api->writable($contract, 'insert', 'title'), 'insert grant');
ok($api->writable($contract, 'upsert', 'title'), 'upsert grant');
ok($api->writable($contract, 'update', 'title'), 'update grant');
ok(!$api->writable($contract, 'delete', 'title'), 'delete has no assignment grant');
ok(!$api->writable($contract, 'update', 'id'), 'read field grants no assignment');
ok($api->require_write_policy($contract, 'update'), 'explicit fields satisfy assignment policy');
is_deeply($contract->{scope}, $d->{writes}{scope}, 'complete scope metadata retained');
my $spec = $api->field_spec($contract, 'title');
$spec->{updatable} = truth(0);
ok($api->writable($contract, 'update', 'title'), 'field accessor returns isolated snapshot');
$contract->{source}{columns}{title}{type} = 'changed';
${$contract->{operations}{update}{enabled}} = 0;
is($json->encode($d), $before, 'compile and output mutation leave original input unchanged including Boolean storage');
ok($api->operation_enabled($api->compile($d), 'update'), 'fresh compilation remains independent');

for my $kind (qw(absent empty)) {
    my $x = domain();
    $kind eq 'absent' ? delete $x->{writes}{operations} : ($x->{writes}{operations} = {});
    ok($api->validate($x)->{valid}, "$kind operations are valid optional metadata");
    error(sub {$api->compile($x)}, 'write_policy_missing', "$kind executable policy");
}
{
    my $x = domain(); $x->{writes}{operations} = {update => {enabled => truth(0)}};
    is_deeply($api->compile($x)->{operations}, {}, 'nonempty all-disabled declaration compiles without inferred grants');
    delete $x->{writes}{fields};
    my $c = $api->compile($x);
    ok(!$c->{fields_declared}, 'missing fields canonical false');
    ok($api->require_write_policy($c, 'delete'), 'delete does not require assignments');
    error(sub {$api->require_write_policy($c, 'update')}, 'write_policy_missing', 'assignment requires fields');
}
for my $card ('many', ['exactly',1], ['at_most',0], ['at_least',0], ['between',0,3]) {
    my $x = domain(); $x->{writes}{operations}{update}{expected_cardinality} = $card;
    ok($api->validate($x)->{valid}, 'portable cardinality accepted: '.$json->encode($card));
}
for my $card (['exactly',0], ['exactly','1'], ['exactly',1.5], ['at_most',-1], ['between',2,1], ['between',0], 'one') {
    invalid(sub {$_[0]{writes}{operations}{update}{expected_cardinality} = $card}, 'invalid_write_cardinality',
        'cardinality '.$json->encode($card));
}
for my $flag (qw(enabled bulk require_filter)) {
    invalid(sub {$_[0]{writes}{operations}{update}{$flag}=1}, 'invalid_write_operation_option', "numeric operation $flag");
}
for my $flag (qw(insertable updatable immutable write_once server_managed)) {
    invalid(sub {$_[0]{writes}{fields}{title}{$flag}='true'}, 'invalid_write_field_option', "string field $flag");
}
invalid(sub {$_[0]{writes}{operations}{execute}={enabled=>truth(1)}}, 'unknown_write_operation', 'unknown operation');
invalid(sub {$_[0]{writes}{operations}{update}=[]}, 'invalid_write_operation_spec', 'operation shape');
invalid(sub {$_[0]{writes}{operations}{update}{fields}=['ghost']}, 'write_operation_field_not_found', 'operation field authority');
invalid(sub {$_[0]{writes}{fields}{ghost}={updatable=>truth(1)}}, 'write_field_not_found', 'field authority');
invalid(sub {$_[0]{writes}{fields}{title}=[]}, 'invalid_write_field_spec', 'field shape');
invalid(sub {$_[0]{writes}{scope}{tenant}{required}=1}, 'invalid_tenant_required', 'tenant Boolean');
invalid(sub {$_[0]{writes}{scope}{tenant}{field}='ghost'}, 'tenant_scope_field_not_found', 'tenant field authority');
for my $field ('users.name','owner.name') {
    my $x=domain(); $x->{writes}{fields}{$field}={updatable=>truth(1)};
    ok($api->validate($x)->{valid}, "$field declared metadata field");
    error(sub {$api->compile($x)}, 'invalid_domain', "$field is not a root assignment");
}
{
    my $x=domain();$x->{writes}{scope}{tenant}{required}=truth(0);
    ok($api->validate($x)->{valid}, 'optional metadata tenant flag can be false');
    error(sub {$api->compile($x)}, 'invalid_domain', 'compiled tenant must explicitly require scope');
}
for my $section (qw(operations fields scope relationships constraints transitions)) {
    invalid(sub {$_[0]{writes}{$section}=23}, 'invalid_section_shape', "malformed $section section");
}
for my $section (qw(operations fields relationships)) {
    my $edit = $section eq 'operations' ? sub {$_[0]{writes}{operations}{update}{value}=['unsafe_sql','secret']} :
        $section eq 'fields' ? sub {$_[0]{writes}{fields}{title}{value}=['unsafe_fragment','secret']} :
        sub {$_[0]{writes}{relationships}{child}={value=>['unsafe_sql','secret']}};
    invalid($edit, 'unsafe_write_fragment', "unsafe $section term");
}

sub relationship {
    return {enabled=>truth(1), cardinality=>'many', ownership=>'composition', identity_fields=>['id'],
        read=>{allowed=>truth(1),max_depth=>2,max_rows=>20,default_depth=>0,max_bytes=>100,max_complexity=>10},
        write=>{modes=>['full_set'],create=>truth(1),update=>truth(1),delete=>truth(1),reorder=>truth(0),
            link=>truth(0),unlink=>truth(0),omission=>'delete_missing',min_items=>0,max_items=>20,max_mutations=>30},
        tenant_scope=>{mode=>'recursive'},capabilities=>{update=>'items.edit'},
        offline=>{eligible=>truth(1)},conflict=>{strategy=>'reject'},idempotency=>{key=>'request_id'},
        ordering=>{},validation=>{},assurance=>{},output=>{},domain=>{id=>'child'},path_id=>'children'};
}
{
    my $x=domain();$x->{writes}{relationships}{children}=relationship();
    ok($api->validate($x)->{valid}, 'full bounded explicit nested composition accepted');
    is_deeply($api->compile($x)->{relationships},$x->{writes}{relationships},'full nested metadata preserved');
}
my @rel_invalid = (
    [sub {delete $_[0]{ownership}}, 'missing_write_relationship_policy','missing ownership'],
    [sub {$_[0]{cardinality}='one'},'invalid_relationship_cardinality_mode','one full_set'],
    [sub {$_[0]{ownership}='shared_association'},'shared_relationship_target_mutation','shared target mutation'],
    [sub {$_[0]{ownership}='derived'},'read_only_relationship_mutation','derived mutation'],
    [sub {$_[0]{write}{modes}=['link_delta']},'invalid_link_delta_ownership','composition link mode'],
    [sub {delete $_[0]{identity_fields}},'nested_identity_required','stable identity'],
    [sub {delete $_[0]{write}{omission}},'nested_omission_policy_required','full_set omission'],
    [sub {delete $_[0]{read}{max_rows}},'nested_read_bounds_required','read bounds'],
    [sub {delete $_[0]{conflict}},'offline_nested_controls_required','offline controls'],
    [sub {$_[0]{write}{max_items}=-1},'invalid_write_relationship_option','negative bound'],
    [sub {$_[0]{write}{min_items}=21},'invalid_write_relationship_option','bound inversion'],
    [sub {$_[0]{write}{update}=1},'invalid_write_relationship_option','nested strict Boolean'],
    [sub {$_[0]{write}{modes}=[]},'invalid_write_relationship_option','empty modes'],
    [sub {$_[0]{identity_fields}=[]},'invalid_write_relationship_option','empty identity'],
    [sub {$_[0]{capabilities}{update}=[]},'invalid_write_relationship_option','capability identifier'],
    [sub {$_[0]{tenant_scope}='wildcard'},'invalid_write_relationship_option','tenant policy'],
    [sub {$_[0]{allowed_ops}=['execute']},'invalid_write_relationship_operation','nested operation'],
);
for my $test (@rel_invalid) {
    my($edit,$code,$label)=@$test;
    invalid(sub {my$r=relationship();$edit->($r);$_[0]{writes}{relationships}{children}=$r},$code,$label);
}
{
    my $x=domain();$x->{writes}{relationships}{legacy}={strategy=>'sync',enabled=>truth(1),cardinality=>'many',
        ownership=>'owned',allowed_ops=>[qw(insert update delete)],identity_fields=>['id'],child_key=>'parent_id',
        parent_key=>'id',min_items=>0,max_items=>10,delete_missing=>truth(1),domain=>{source_table=>'child'}};
    ok($api->validate($x)->{valid}, 'legacy native sync shape preserved without invented explicit modes');
    my$r=relationship();$r->{ownership}='shared_reference';$r->{write}={modes=>['link_delta'],link=>truth(1),unlink=>truth(1)};
    $x->{writes}{relationships}{links}=$r;
    ok($api->validate($x)->{valid}, 'shared reference link-only mode accepted');
    $r=relationship();$r->{cardinality}='one';$r->{write}{modes}=['replace_one'];
    $x->{writes}{relationships}{one}=$r;
    ok($api->validate($x)->{valid}, 'one replace mode accepted');
}
{
    my$x=domain();$x->{writes}{constraints}={optimistic_lock=>{field=>'version'},foreign_keys=>{
        parent_id=>{source=>['context','actor_id'],required=>truth(1),references=>{relation=>'users',field=>'id',tenant_field=>'tenant_id'}}},
        unique=>[['tenant_id','title']]};
    $x->{writes}{transitions}={state=>{open=>['done'],done=>[]}};
    my$c=$api->compile($x);
    is_deeply($c->{constraints},$x->{writes}{constraints},'complete FK/lock/opaque native constraint metadata retained');
    is_deeply($c->{transitions},$x->{writes}{transitions},'transition graph retained');
    my$f=$api->foreign_keys($c);$f->{parent_id}{references}{field}='changed';
    is($api->foreign_keys($c)->{parent_id}{references}{field},'id','FK accessor isolates reference maps');
    for my$source ('input',{kind=>'context',key=>'tenant_id'}) {
        my$y=copy($x);$y->{writes}{constraints}{foreign_keys}{parent_id}{source}=$source;
        ok($api->validate($y)->{valid},'portable FK source accepted');
    }
    for my$test ([sub {$_[0]{source}='computed'},'invalid_foreign_key_source'],
        [sub {delete $_[0]{source}},'missing_foreign_key_source'],
        [sub {delete $_[0]{references}},'missing_foreign_key_reference'],
        [sub {$_[0]{references}{relation}=''},'invalid_foreign_key_reference'],
        [sub {$_[0]{references}{tenant_field}='ghost'},'unknown_foreign_key_tenant_field'],
        [sub {$_[0]{references}{tenant_field}=truth(1)},'invalid_foreign_key_tenant_field'],
        [sub {$_[0]{required}=1},'invalid_foreign_key_required']) {
        my($edit,$code)=@$test;
        invalid(sub {$_[0]{writes}{constraints}=copy({v=>$x->{writes}{constraints}})->{v};$edit->($_[0]{writes}{constraints}{foreign_keys}{parent_id})},$code,$code);
    }
    my$y=copy($x);$y->{writes}{constraints}{foreign_keys}{parent_id}{references}{relation}='external_table';
    $y->{writes}{constraints}{foreign_keys}{parent_id}{references}{tenant_field}='external_tenant';
    ok($api->validate($y)->{valid},'external relation metadata not mistaken for a native FK proof');
    $y=copy($x);$y->{writes}{constraints}{foreign_keys}{parent_id}{references}{tenant_field}=truth(0);
    ok($api->validate($y)->{valid},'shared FK relation explicitly false tenant accepted');
}
invalid(sub {$_[0]{writes}{constraints}={optimistic_lock=>{field=>'ghost'}}},'optimistic_lock_field_not_found','lock field authority');
invalid(sub {$_[0]{writes}{transitions}{ghost}={a=>['b']}},'transition_field_not_found','transition field authority');
invalid(sub {$_[0]{writes}{transitions}{state}={a=>'b'}},'invalid_transition_targets','transition target shape');
invalid(sub {$_[0]{writes}{transitions}{state}={a=>[{}]}},'invalid_transition_state','transition state shape');
{
    my$x=domain();delete$x->{writes}{fields}{title};$x->{source}{columns}{title}{write}={updatable=>truth(1)};
    $x->{source}{associations}{owner}{write}={enabled=>truth(1),ownership=>'owned',strategy=>'sync'};
    my$n=$api->normalize($x);
    is_deeply($n->{domain}{writes}{fields}{title},{updatable=>truth(1)},'explicit column shorthand relocated');
    is_deeply([@{$n->{domain}{writes}{relationships}{owner}}{qw(cardinality parent_key child_key)}],['one','parent_id','id'],'relationship shorthand copies only declared structural defaults');
    ok(!exists$n->{domain}{source}{columns}{title}{write},'normalized source removes colocated write');
    ok(exists$x->{source}{columns}{title}{write},'normalization does not mutate authored source');
    $x->{writes}{fields}{title}={insertable=>truth(1)};
    my$n2=$api->normalize($x);
    ok(!exists$n2->{domain}{writes}{fields}{title},'duplicate grant is removed rather than merged');
    is($n2->{errors}[0]{code},'duplicate_write_authoring','duplicate authoring diagnostic');
    error(sub {$api->compile($x)},'invalid_domain','authored duplicate refuses compilation');
    ok($api->validate($n2->{domain})->{valid},'caller can explicitly validate the normalized duplicate-free declaration');
    my$outer=domain();$outer->{authored_domain}={};$outer->{domain}=domain();
    $outer->{writes}{operations}{update}{enabled}=truth(0);
    ok(!$api->operation_enabled($api->compile($outer),'update'),'unrelated envelope-like keys cannot replace the supplied write authority');
}

{
    package WriteContract::Object;
    our $calls=0;
    use overload '""'=>sub {$calls++;'object'}, fallback=>1;
    sub STORABLE_freeze {$calls++;return ''}
    package WriteContract::Tie;
    our $calls=0;
    sub TIEHASH {bless{},shift} sub FETCH {$calls++;die 'FETCH invoked'}
    sub FIRSTKEY {$calls++;die 'FIRSTKEY invoked'} sub NEXTKEY {$calls++;die 'NEXTKEY invoked'}
    sub SCALAR {$calls++;die 'SCALAR invoked'}
    package WriteContract::Scalar;
    our $calls=0;
    sub TIESCALAR {bless{},shift} sub FETCH {$calls++;die 'FETCH invoked'}
    package main;
    for my$bad (sub {},bless({},'WriteContract::Object'),bless({},'0')) {
        my$x=domain();$x->{extension}=$bad;
        error(sub {$api->compile($x)},'invalid_write_contract','executable/object metadata');
    }
    is($WriteContract::Object::calls,0,'no overload or serialization callback');
    tie my%tied,'WriteContract::Tie';
    error(sub {$api->validate(\%tied)},'invalid_write_contract','tied root');
    my$x=domain();tie$x->{writes}{scope},'WriteContract::Scalar';
    error(sub {$api->compile($x)},'invalid_write_contract','tied nested slot');
    is($WriteContract::Tie::calls+$WriteContract::Scalar::calls,0,'no tied FETCH/iteration callbacks');
}
for my$bad ([],23,undef) {
    error(sub {$api->operation_enabled($bad,'update')},'invalid_write_contract','accessor structural contract');
}
{
    my$x=domain();$x->{extension}=$x;
    error(sub {$api->compile($x)},'invalid_write_contract','cycle');
    $x=domain();$x->{extension}=[(1)x10001];
    error(sub {$api->compile($x)},'invalid_write_contract','input node bound');
    $x=domain();my$v={};$x->{extension}=$v;for(1..65){$v->{next}={};$v=$v->{next}}
    error(sub {$api->compile($x)},'invalid_write_contract','depth bound');
    $x=domain();$x->{extension}='x'x131073;
    error(sub {$api->compile($x)},'invalid_write_contract','byte bound');
    $x=domain();my$id='x'x4096;$x->{writes}{fields}={map {($id.$_)=>{}} 1..29};
    error(sub {$api->validate($x)},undef,'cumulative generated diagnostics bound');
}

done_testing;
