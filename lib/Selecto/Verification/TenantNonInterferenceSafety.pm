package Selecto::Verification::TenantNonInterferenceSafety;
use 5.034; use strict; use warnings;
use Selecto::Verification::WriteModel ();
my$M='Selecto::Verification::WriteModel';
my@SOURCES=qw(canonical opts_source_conflict duplicate_execution_opts operation_key_conflict execution_key_conflict execution_field_conflict context_tenant_id_conflict context_tenant_key_conflict context_nested_field_conflict);
sub _value {return $_[0] eq 'tenant_a'?'tenant-a':$_[0] eq 'tenant_b'?'tenant-b':undef;}
sub _effective {return $_[1] ne 'absent'?$_[1]:$_[0];}
sub _conflict {return $_[0] ne 'absent'&&$_[1] ne 'absent'&&$_[0] ne $_[1];}
sub _valid {my($s)=@_;my$effective=_effective(@{$s}{qw(operation_tenant execution_tenant)});return !_conflict(@{$s}{qw(operation_tenant execution_tenant)})&&$s->{source_form} eq 'canonical'&&$effective ne 'absent'&&($s->{caller_tenant} eq 'absent'||$s->{caller_tenant} eq $effective)&&($s->{caller_tenant} eq 'absent'||$s->{spelling} ne 'both')&&($s->{surface} ne 'batch'||$s->{batch_context} eq 'same');}
sub _attrs {
    my($caller,$spelling,$name)=@_;my@a=(['name',$name]);return \@a if $caller eq 'absent';
    push@a,[Selecto::Verification::WriteModel::atom('tenant_id'),_value($caller)] if $spelling ne 'string';
    push@a,['tenant_id',_value($caller)] if $spelling ne 'atom';return \@a;
}
sub _op {
    my($s,$trusted,$caller,$spelling,$nested)=@_;
    my$d=$nested?Selecto::Verification::WriteModel::nested_domain():Selecto::Verification::WriteModel::domain('items',[qw(id tenant_id name)],string_ids=>1,required_name=>1);
    if($nested){delete $_->{expected_cardinality} for values %{$d->{writes}{operations}};delete $_->{expected_cardinality} for values %{$d->{writes}{relationships}{children}{domain}{writes}{operations}};$d->{writes}{scope}{tenant}{satisfied_by}=['trusted_context'];$d->{writes}{relationships}{children}{domain}{writes}{scope}{tenant}{satisfied_by}=['trusted_context'];delete $d->{joins};delete $d->{writes}{relationships}{children}{domain}{joins};}
    my$values=$nested?{name=>'parent',children=>[_attrs($caller,$spelling,'child')]}:$s->{operation} eq 'insert'?_attrs($caller,$spelling,'item'):{name=>'updated'};
    my$op=Selecto::Verification::WriteModel::operation($d,$s->{operation},$values);
    if($s->{operation} eq 'update'&&$caller ne 'absent'){
        $op=$op->filter([Selecto::Verification::WriteModel::atom('tenant_id'),_value($caller)]) if $spelling ne 'string';
        $op=$op->filter(['tenant_id',_value($caller)]) if $spelling ne 'atom';
    }
    $op=$op->with_tenant({tenant_id=>_value($trusted)}) if $trusted ne 'absent';
    $op=$op->with_tenant([[Selecto::Verification::WriteModel::atom('tenant_id'),'tenant-a'],['tenant_id','tenant-b']]) if $s->{source_form} eq 'operation_key_conflict';
    return $op;
}
sub _execution {
    my($s)=@_;my$f=$s->{source_form};
    return [['tenant',{tenant_id=>'tenant-a'}],['tenant_id','tenant-b']] if $f eq 'opts_source_conflict';
    return [['tenant_id','tenant-a'],['tenant_id','tenant-b']] if $f eq 'duplicate_execution_opts';
    return {tenant=>[[Selecto::Verification::WriteModel::atom('tenant_id'),'tenant-a'],['tenant_id','tenant-b']]} if $f eq 'execution_key_conflict';
    return {tenant=>[['tenant_field','other_tenant_id'],[Selecto::Verification::WriteModel::atom('tenant_field'),'tenant_id'],['tenant_id','tenant-a']]} if $f eq 'execution_field_conflict';
    return $s->{execution_tenant} eq 'absent'?{}:{tenant=>{tenant_id=>_value($s->{execution_tenant})}};
}
sub _opts {
    my($s)=@_;my$f=$s->{source_form};
    return (context=>[[Selecto::Verification::WriteModel::atom('tenant_id'),'tenant-a'],['tenant_id','tenant-b']]) if $f eq 'context_tenant_id_conflict';
    return (context=>[[Selecto::Verification::WriteModel::atom('tenant'),{tenant_id=>'tenant-a'}],['tenant',{tenant_id=>'tenant-b'}]]) if $f eq 'context_tenant_key_conflict';
    return (context=>{tenant=>{tenant_id=>'tenant-a',tenant_field=>'account_id'},tenant_field=>'tenant_id'}) if $f eq 'context_nested_field_conflict';
    return ();
}
sub verify {
    my($class,%opts)=@_;Selecto::Verification::WriteModel::options(\%opts,qw(compile apply_scope compile_batch));
    my$compile=$opts{compile}//sub{Selecto::Verification::WriteModel::compile(@_)};
    my$apply=$opts{apply_scope}//sub{$_[0]->apply_execution_scope($_[1])};
    my$batch=$opts{compile_batch}//sub{require Selecto::Write::Multi;return Selecto::Write::Multi->new(operations=>$_[0])->compile(@_[1..$#_]);};
    return Selecto::Verification::WriteModel::check('selecto_updato.tenant_non_interference.v1',sub{my($emit)=@_;
        for my$surface(qw(flat nested batch)){for my$type(qw(insert update)){for my$ot(qw(absent tenant_a)){for my$et(qw(absent tenant_a tenant_b)){for my$caller(qw(absent tenant_a tenant_b)){for my$spelling(qw(atom string both)){for my$bc(qw(same conflicting)){for my$source(@SOURCES){
            my$s={surface=>$surface,operation=>$type,operation_tenant=>$ot,execution_tenant=>$et,caller_tenant=>$caller,spelling=>$spelling,batch_context=>$bc,source_form=>$source};
            my$r=Selecto::Verification::WriteModel::capture(sub{
                my$first=$apply->(_op($s,$ot,$caller,$spelling,$surface eq 'nested'),_execution($s));
                return $compile->($first,_opts($s)) if $surface ne 'batch';
                my$effective=_effective($ot,$et);my$second_tenant=$bc eq 'same'?$ot:$effective eq 'tenant_b'?'tenant_a':'tenant_b';
                my$second=$apply->(_op($s,$second_tenant,'absent','atom',0),_execution($s));
                return $batch->([['first',$first],['second',$second]],_opts($s));
            });
            $emit->({%$s},{%$s,result=>$r});
        }}}}}}}}
    },[
        ['invalid_tenant_states_fail_before_dispatch',sub{my($s)=@_;_valid($s)||Selecto::Verification::WriteModel::typed($s->{result})}],
        ['valid_tenant_states_reach_the_portable_data_plane',sub{my($s)=@_;return 1 unless _valid($s);return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$r=$s->{result}{value};return ref($r) eq 'HASH'&&ref($r->{context}) eq 'HASH'&&@{Selecto::Verification::WriteModel::commands($r->{command})}>0}],
        ['trusted_tenant_is_the_only_emitted_tenant',sub{my($s)=@_;return 1 unless Selecto::Verification::WriteModel::successful($s->{result});my$v=Selecto::Verification::WriteModel::emitted_tenants($s->{result}{value}{command});my$expected=_value(_effective(@{$s}{qw(operation_tenant execution_tenant)}));return 0 unless @$v&&defined($expected);return !grep{!defined($_)||$_ ne $expected}@$v}],
        ['operation_and_execution_tenant_sources_agree',sub{my($s)=@_;return 1 unless _conflict(@{$s}{qw(operation_tenant execution_tenant)})||$s->{source_form} ne 'canonical';return Selecto::Verification::WriteModel::typed($s->{result})}],
        ['normalized_tenant_ambiguity_fails_closed',sub{my($s)=@_;return 1 unless $s->{caller_tenant} ne 'absent'&&$s->{spelling} eq 'both';return Selecto::Verification::WriteModel::typed($s->{result})}],
        ['batch_context_cannot_mix_tenants',sub{my($s)=@_;return 1 unless $s->{surface} eq 'batch'&&$s->{batch_context} eq 'conflicting';return Selecto::Verification::WriteModel::typed($s->{result})}],
    ]);
}
1;
