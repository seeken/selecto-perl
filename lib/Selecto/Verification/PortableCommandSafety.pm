package Selecto::Verification::PortableCommandSafety;
use 5.034; use strict; use warnings;
use JSON::PP (); use Selecto::Verification::WriteModel ();
my $M='Selecto::Verification::WriteModel';
sub _domain {
    my $d=Selecto::Verification::WriteModel::domain('items',[qw(id tenant_id account_id name quantity)],required_name=>1);
    $d->{source}{columns}{$_}{type}='integer' for qw(account_id quantity);
    $d->{writes}{operations}={map {$_=>{enabled=>JSON::PP::true,returning=>'all'}} qw(insert update upsert delete)};
    $d->{writes}{operations}{upsert}{conflict_targets}=[[qw(tenant_id name)]];
    $d->{writes}{fields}{name}={insertable=>JSON::PP::true,required_on=>['insert']};
    $d->{writes}{fields}{$_}={insertable=>JSON::PP::true,updatable=>JSON::PP::true} for qw(account_id quantity);
    $d->{writes}{constraints}={foreign_keys=>{account_id=>{source=>['context','account_id'],references=>{relation=>'accounts',field=>'id'},required=>JSON::PP::true}}};
    return $d;
}
sub _valid {my($s)=@_;return $s->{trusted}&&($s->{operation}!~/\A(?:insert|upsert)\z/||$s->{required})&&($s->{operation} eq 'delete'||$s->{fk} ne 'mismatched');}
sub verify {
    my($class,%opts)=@_;Selecto::Verification::WriteModel::options(\%opts,'compile');my$compile=$opts{compile}//sub {Selecto::Verification::WriteModel::compile(@_)};
    return Selecto::Verification::WriteModel::check('selecto_updato.portable_command.v1',sub {my($emit)=@_;
        for my$type(qw(insert update upsert delete)){for my$trusted(0,1){for my$required(0,1){for my$fk(qw(absent matching mismatched)){
            my$values=$type eq 'update'?{quantity=>2}:$type eq 'delete'?{}:$required?{name=>'item'}:{};
            $values->{account_id}=$fk eq 'matching'?42:7 if $type ne 'delete'&&$fk ne 'absent';
            my$op=Selecto::Verification::WriteModel::operation(_domain(),$type,$values,'id')->expected_cardinality(['exactly',1])->returning('all');
            $op=$op->with_tenant({tenant_id=>'tenant-a'}) if $trusted;
            my$r=Selecto::Verification::WriteModel::capture(sub {$compile->($op,$trusted?(context=>{account_id=>42}):())});
            $emit->({operation=>$type,trusted_context=>$trusted,required_field=>$required,foreign_key_input=>$fk},{operation=>$type,trusted=>$trusted,required=>$required,fk=>$fk,result=>$r});
        }}}}
    },[
        ['invalid_states_fail_closed',sub{my($s)=@_;_valid($s)||Selecto::Verification::WriteModel::typed($s->{result})}],
        ['valid_states_compile',sub{my($s)=@_;!_valid($s)||(Selecto::Verification::WriteModel::successful($s->{result})&&ref($s->{result}{value}) eq 'HASH'&&Selecto::Verification::WriteModel::is($s->{result}{value}{command},'Selecto::Write::Command')&&ref($s->{result}{value}{context}) eq 'HASH')}],
        ['required_insert_fields_are_enforced',sub{my($s)=@_;return 1 unless $s->{operation}=~/\A(?:insert|upsert)\z/&&!$s->{required};return 0 unless Selecto::Verification::WriteModel::typed($s->{result});my$f=$s->{result}{error}->details->{fields};return ref($f) eq 'ARRAY'&&grep {$_ eq 'name'} @$f}],
        ['trusted_foreign_keys_cannot_be_overridden',sub{my($s)=@_;return 1 unless $s->{trusted}&&$s->{fk} eq 'mismatched'&&$s->{operation} ne 'delete';return 1 if $s->{operation}=~/\A(?:insert|upsert)\z/&&!$s->{required};return Selecto::Verification::WriteModel::typed($s->{result})&&$s->{result}{error}->code eq 'foreign_key_source_mismatch'}],
        ['tenant_scope_is_compiled',sub{my($s)=@_;return 1 unless _valid($s);return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$c=$s->{result}{value}{command};return 0 unless Selecto::Verification::WriteModel::is($c,'Selecto::Write::Command');return Selecto::Verification::WriteModel::literal($c->assignments->{tenant_id}) eq 'tenant-a' if $s->{operation}=~/\A(?:insert|upsert)\z/;return grep {defined($_)&&$_ eq 'tenant-a'} (@{Selecto::Verification::WriteModel::predicate_values($c->predicate,'tenant_id')},@{Selecto::Verification::WriteModel::predicate_values($c->scope_predicate,'tenant_id')})}],
        ['upsert_conflict_is_tenant_scoped',sub{my($s)=@_;return 1 unless $s->{operation} eq 'upsert'&&Selecto::Verification::WriteModel::successful($s->{result});my$t=$s->{result}{value}{command}->metadata->{conflict_target};return ref($t) eq 'ARRAY'&&grep {$_ eq 'tenant_id'} @$t}],
        ['foreign_key_guards_are_preserved',sub{my($s)=@_;return 1 unless _valid($s)&&$s->{operation}=~/\A(?:insert|upsert)\z/;return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$c=$s->{result}{value}{command};return grep {($_->{field}//'') eq 'account_id'&&($_->{relation}//'') eq 'accounts'&&($_->{target_field}//'') eq 'id'} @{$c->foreign_key_guards}}],
        # Native Perl expands returning=all to the complete declared root field set.
        ['cardinality_and_returning_are_preserved',sub{my($s)=@_;return 1 unless Selecto::Verification::WriteModel::successful($s->{result});my$m=$s->{result}{value}{command}->metadata;my$c=$m->{expected_cardinality};return ref($c) eq 'ARRAY'&&@$c==2&&$c->[0] eq 'exactly'&&$c->[1]==1&&ref($m->{returning}) eq 'ARRAY'&&join(',',sort @{$m->{returning}}) eq 'account_id,id,name,quantity,tenant_id'}],
        ['command_is_adapter_neutral',sub{my($s)=@_;return !Selecto::Verification::WriteModel::successful($s->{result})||Selecto::Verification::WriteModel::neutral($s->{result}{value}{command})}],
    ]);
}
1;
