use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Write::Operation;
use Selecto::Write::PortableCommand;
use Selecto::Domain::Choices;

sub domain {
    return {name => 'items', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id tenant_id account_id name quantity)],
        columns => {map {$_ => {type => $_ eq 'name' || $_ eq 'tenant_id' ? 'string' : 'integer'}} qw(id tenant_id account_id name quantity)},
        associations => {}}, schemas => {}, writes => {
        operations => {map {$_ => {enabled => JSON::PP::true, returning => 'all',
            ($_ eq 'upsert' ? (conflict_targets => [[qw(tenant_id name)]]) : ())}} qw(insert update upsert delete)},
        fields => {tenant_id => {insertable => JSON::PP::true, immutable => JSON::PP::true},
            account_id => {insertable => JSON::PP::true, updatable => JSON::PP::true},
            name => {insertable => JSON::PP::true, updatable => JSON::PP::true, required_on => ['insert']},
            quantity => {insertable => JSON::PP::true, updatable => JSON::PP::true}},
        scope => {tenant => {required => JSON::PP::true, field => 'tenant_id', satisfied_by => ['trusted_context']}},
        constraints => {foreign_keys => {account_id => {source => ['context','account_id'], required => JSON::PP::true,
            references => {relation => 'accounts', field => 'id'}}}}}};
}
sub operation { Selecto::Write::Operation->new(domain())->with_tenant({tenant_id => 'tenant-a'}) }
sub compile { $_[0]->compile(context => {account_id => 42}) }
sub refuses {
    my ($code, $work, $label) = @_;
    my $ok = eval {$work->();1};my$error=$@;
    ok !$ok && ref($error) eq 'Selecto::Error', $label;
    is ref($error) ? $error->details->{code} // $error->code : 'untyped', $code, 'typed boundary reason';
    return $error;
}

for my $type (qw(insert update upsert delete)) {
    my $op = operation()->operation($type, $type eq 'delete' ? {} : {name => 'item', quantity => 2});
    $op = $op->filter(['id',7]) if $type eq 'update' || $type eq 'delete';
    my $compiled = compile($op);
    isa_ok $compiled->{command}, 'Selecto::Write::Command', "adapter-neutral $type command";
    is $compiled->{command}->relation, 'items', 'relation comes from authored domain';
    is_deeply $compiled->{command}->metadata->{expected_cardinality}, ['exactly',1], 'exact cardinality preserved';
    is_deeply $compiled->{command}->metadata->{returning}, [qw(account_id id name quantity tenant_id)], 'all returning resolves actual root fields';
    is $compiled->{context}{tenant_id}, 'tenant-a', 'canonical tenant accompanies the command';
    if ($type eq 'insert' || $type eq 'upsert') {
        is_deeply $compiled->{command}->assignments,
            {name => 'item', quantity => 2, account_id => 42, tenant_id => 'tenant-a'}, 'trusted fills materialize in actual command';
        is_deeply $compiled->{command}->metadata->{foreign_key_guards},
            [{field => 'account_id', relation => 'accounts', target_field => 'id'}], 'structural foreign-key guard preserved';
        is $compiled->{command}->foreign_key_guards->[0]{value}, 42, 'native guard binds the actual reference';
    } else {
        ok defined($compiled->{command}->predicate), 'target predicate retained';
    }
}
refuses('duplicate_assignment_identifier',sub {compile(operation()->insert([[{'$atom'=>'name'},'one'],['name','two']]))},'mixed assignment identifiers refuse');
refuses('duplicate_filter_identifier',sub {compile(operation()->update({name=>'x'})->filters([[{'$atom'=>'id'},1],['id',2]]))},'mixed filter identifiers refuse');
refuses('duplicate_returning_identifier',sub {compile(operation()->update({name=>'x'})->filter(['id',1])->returning([{'$atom'=>'id'},'id']))},'mixed returning identifiers refuse');
refuses('undeclared_write_identifier',sub {compile(operation()->update({name=>'x'})->filter(['secret',1]))},'read-unknown field cannot target a write');
refuses('undeclared_write_identifier',sub {compile(operation()->update({name=>'x'})->filter(['id',1])->returning(['secret']))},'undeclared returning field refuses');
refuses('expected_cardinality_policy_violation',sub {compile(operation()->update({name=>'x'})->filter(['id',1])->expected_cardinality('many'))},'caller cannot widen exact domain policy');
refuses('tenant_mismatch',sub {compile(operation()->insert({name=>'x',tenant_id=>'tenant-b'}))},'payload cannot replace trusted tenant');
refuses('foreign_key_source_mismatch',sub {compile(operation()->insert({name=>'x',account_id=>7}))},'payload cannot replace trusted foreign key');
refuses('query_enforcement_unsupported_operation',sub {compile(operation()->upsert({name=>'x'})->filter(['quantity',2]))},'upsert refuses a filter its conflict branch cannot enforce');
refuses('invalid_predicate',sub {compile(operation()->update({name=>'x'})->filter(['id','in',[]]))},'empty IN refuses before any adapter exists');
my $missing=refuses('missing_required_write_fields',sub {Selecto::Write::Operation->new(domain())->insert({})->compile},'required authored field has precise priority even without tenant');
is_deeply $missing->details->{fields}, ['name'], 'required field diagnostic identifies authored omission';
my $range=compile(operation()->update({quantity=>3})->filters([['id','gte',1],['id','lte',7]]));
isa_ok $range->{command}, 'Selecto::Write::Command', 'repeated same-spelling range filters remain valid';
my $pairs=compile(operation()->insert([[{'$atom'=>'name'},'pair'],['quantity',4]]));
is $pairs->{command}->assignments->{name}, 'pair', 'single atom marker lowers to a native identifier';

my $raw=domain();my$attrs={name=>'initial'};
my $sealed=Selecto::Write::Operation->new($raw)->insert($attrs)->with_tenant({tenant_id=>'tenant-a'});
$raw->{source}{source_table}='other';$attrs->{name}='changed';
my $first=compile($sealed);$first->{context}{account_id}=7;
is compile($sealed)->{command}->assignments->{name},'initial','builder owns independent authored input';
is compile($sealed)->{context}{account_id},42,'compiled context copies are independent';
my $normalized=Selecto::Write::Operation->new({schema_version=>'1',domain=>domain(),query=>{},projection=>{}})
    ->insert({name=>'normalized'})->with_tenant({tenant_id=>'tenant-a'});
is compile($normalized)->{command}->relation,'items','normalized domain wrapper uses its canonical domain';
eval {Selecto::Write::Operation->new({schema_version=>'1',domain=>domain(),query=>{},projection=>{},unused=>sub{}})};
isa_ok $@,'Selecto::Error','complete wrapper is admitted before canonical extraction';

my $choice_domain=domain();$choice_domain->{source}{columns}{quantity}{choice_source}='quantities';
$choice_domain->{choice_sources}={quantities=>{domain=>'quantities',value_field=>'id',label_field=>'name'}};
my $choice=Selecto::Write::Operation->new($choice_domain)->update({quantity=>2})->filter(['id',1])->with_tenant({tenant_id=>'tenant-a'});
refuses('choice_membership_resolver_required',sub {compile($choice)},'membership is required for an actual choice-bound field');
my $calls=0;
my $allowed=$choice->compile(context=>{account_id=>42},choice_membership_resolver=>sub {
    my($request)=@_;$calls++;is$request->{value},2,'provider receives actual authored value';
    return Selecto::Domain::Choices->valid('allowed');
});
is $calls,1,'one actual trusted choice decision';
isa_ok $allowed->{command},'Selecto::Write::Command','sealed membership result admits a command';
my $before=$calls;
eval {$choice->compile(context=>{account_id=>42},unused=>sub{},choice_membership_resolver=>sub{$calls++;die 'must not run'})};
isa_ok $@,'Selecto::Error','complete unused host options are admitted before callbacks';
is$calls,$before,'malformed unused metadata invokes no resolver';
eval {$choice->compile(context=>{account_id=>42},choice_membership_resolver=>sub{{status=>'valid',outcome=>'ok'}})};
isa_ok $@,'Selecto::Error','serialized choice result cannot impersonate native membership authority';

my $guarded_domain=domain();
$guarded_domain->{required_filters}=[['and', [['gte','quantity',2], ['name', ['not_in',['blocked','hidden']]]]]];
my $guarded=Selecto::Write::Operation->new($guarded_domain)->with_tenant({tenant_id=>'tenant-a'});
my $guarded_insert=compile($guarded->insert({name=>'allowed',quantity=>2}));
ok defined($guarded_insert->{command}->scope_predicate),'domain query guard is retained on the actual native command';
# query_enforced_scalar v2: the contract's declared types are unverified at
# compile time, so the in-process admission decides nothing here; the
# comparison is deferred to the verified-storage check before DML (live in
# t/scalar_admission_v2_live.t). The command keeps the guard for it.
for my $candidate ({name=>'blocked',quantity=>2}, {name=>'allowed',quantity=>1}) {
    my $deferred_guard = compile($guarded->insert($candidate));
    ok defined($deferred_guard->{command}->scope_predicate), 'an undecided candidate keeps its guard for the storage check';
    is $deferred_guard->{command}->metadata->{field_types}{name}, 'string', 'with its declared field types';
}
refuses('query_rule_not_evaluable',sub {compile($guarded->insert({name=>'allowed'}))},'missing candidate fields cannot silently bypass query guard');
refuses('query_enforcement_unsupported_operation',sub {compile($guarded->upsert({name=>'allowed',quantity=>2}))},'upsert refuses a required predicate its conflict branch cannot enforce');
my $null_domain=domain();$null_domain->{required_filters}=[['quantity',undef]];
isa_ok compile(Selecto::Write::Operation->new($null_domain)->with_tenant({tenant_id=>'tenant-a'})->insert({name=>'null',quantity=>undef}))->{command},'Selecto::Write::Command','null query guard admits an explicit SQL NULL';
my $range_domain=domain();$range_domain->{required_filters}=[['quantity',['between',2,4]]];
isa_ok compile(Selecto::Write::Operation->new($range_domain)->with_tenant({tenant_id=>'tenant-a'})->insert({name=>'range',quantity=>3}))->{command},'Selecto::Write::Command','between query guard lowers both bounds';
my $unknown_domain=domain();$unknown_domain->{required_filters}=[['eq','account.secret',1]];
refuses('query_rule_unsupported_field',sub {compile(Selecto::Write::Operation->new($unknown_domain)->with_tenant({tenant_id=>'tenant-a'})->insert({name=>'x'}))},'association query guard refuses at pure boundary');
my $deferred=$guarded->insert({name=>'blocked',quantity=>2})->compile(context=>{account_id=>42},storage_backend=>'sqlite');
ok defined($deferred->{command}->scope_predicate),'SQLite candidate guard survives deferred physical admission';
is_deeply $deferred->{command}->metadata->{required_capabilities},['insert','typed_insert_admission'],'SQLite insert announces actual typed admission requirement';
my $ordinary=operation()->insert({name=>'ordinary',quantity=>1})->filter(['quantity',2]);
isa_ok compile($ordinary)->{command},'Selecto::Write::Command','ordinary insert filter retains adapter-neutral highest semantics';
ok defined($ordinary->compile(context=>{account_id=>42},storage_backend=>'sqlite')->{command}->predicate),'SQLite insert explicitly retains authored candidate filters';

my $literal_domain=domain();$literal_domain->{required_filters}=[['name','not_null']];
my $literal_op=Selecto::Write::Operation->new($literal_domain)->with_tenant({tenant_id=>'tenant-a'});
isa_ok compile($literal_op->insert({name=>'not_null'}))->{command},'Selecto::Write::Command','literal null-operator spelling remains an equality value';
ok defined(compile($literal_op->insert({name=>'other'}))->{command}->scope_predicate),
    'literal not_null stays an equality value for the deferred storage check';

my $collision_domain=domain();push @{$collision_domain->{source}{fields}},'is_null';
$collision_domain->{source}{columns}{is_null}={type=>'string'};
$collision_domain->{writes}{fields}{is_null}={insertable=>JSON::PP::true};
$collision_domain->{required_filters}=[['is_null','sentinel']];
isa_ok compile(Selecto::Write::Operation->new($collision_domain)->with_tenant({tenant_id=>'tenant-a'})->insert({name=>'collision',is_null=>'sentinel'}))->{command},'Selecto::Write::Command','declared field named is_null remains a field in a literal pair';

done_testing;
