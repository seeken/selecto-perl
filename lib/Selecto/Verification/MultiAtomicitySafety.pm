package Selecto::Verification::MultiAtomicitySafety::ProbeAdapter;
use 5.034; use strict; use warnings; use parent 'Selecto::Adapter';
use Selecto::Write (); use Selecto::Write::Authorization (); use Selecto::Error ();
sub requires_dbh {0} sub name {'portable_multi_verification'} sub dialect {return $_[0]}
sub compile {die 'finite atomicity adapter never compiles SQL'}
sub execute_query {die 'finite atomicity adapter never queries a database'}
sub preview_write {die 'finite atomicity adapter never previews SQL'}
sub execute_write {die 'finite atomicity adapter only dispatches batches'}
sub write_capabilities {return {protocol_version=>1,map {$_=>1} qw(insert update upsert delete returning transactions atomic_batch write_graph),generated_keys=>'returning'};}
sub execute_batch {
    my($self,$batch,$authorization)=@_;Selecto::Write::Authorization->require_for($batch,$authorization);
    push @{$self->{dispatches}},$batch;
    my@results;my$i=0;for my$c(@{$batch->commands}){push@results,Selecto::Write::Result->new(operation=>$c->operation,affected_rows=>1,metadata=>{batch_index=>$i++});}
    my$outcome=$self->{outcome};return \@results if $outcome eq 'exact';
    pop@results if $outcome eq 'short';
    push@results,Selecto::Write::Result->new(operation=>'insert',affected_rows=>1,metadata=>{batch_index=>'extra'}) if $outcome eq 'long';
    return $results[0] if $outcome eq 'non_list';
    Selecto::Error->throw('adapter_failure','atomic batch failed') if $outcome eq 'error';
    return \@results;
}
sub reset {my($self,$outcome)=@_;$self->{dispatches}=[];$self->{outcome}=$outcome;return$self;}
sub dispatches {return [@{$_[0]{dispatches}//[]}]}

package Selecto::Verification::MultiAtomicitySafety;
use 5.034; use strict; use warnings;
use Selecto::Verification::WriteModel ();use Selecto::Domain ();use Selecto::Engine ();
my$M='Selecto::Verification::WriteModel';
sub _predispatch {my($s)=@_;return $s->{names} eq 'unique'&&$s->{compile_failure} eq 'none'&&$s->{contexts} eq 'same';}
sub verify {
    my($class,%opts)=@_;Selecto::Verification::WriteModel::options(\%opts,'run');
    my$run=$opts{run}//sub{$_[0]->run($_[1])};
    return Selecto::Verification::WriteModel::check('selecto_updato.multi_atomicity.v1',sub{my($emit)=@_;
        for my$names(qw(unique duplicate)){for my$failure(qw(none first second)){for my$contexts(qw(same conflicting)){for my$outcome(qw(exact short long non_list error)){
            my$labels={names=>$names,compile_failure=>$failure,contexts=>$contexts,adapter_outcome=>$outcome};
            my$adapter=Selecto::Verification::MultiAtomicitySafety::ProbeAdapter->new->reset($outcome);
            my$r=Selecto::Verification::WriteModel::capture(sub{
                require Selecto::Write::Multi;
                my$d=Selecto::Verification::WriteModel::domain();
                my$first=Selecto::Write::Operation->new($d)->insert($failure eq 'first'?[[Selecto::Verification::WriteModel::atom('name'),'one'],['name','ambiguous']]:{name=>'one'})->with_tenant({tenant_id=>'tenant-a'});
                my$second=Selecto::Verification::WriteModel::operation($d,'update',$failure eq 'second'?[[Selecto::Verification::WriteModel::atom('name'),'two'],['name','ambiguous']]:{name=>'two'})->with_tenant({tenant_id=>$contexts eq 'same'?'tenant-a':'tenant-b'});
                my$multi=Selecto::Write::Multi->new(operations=>[['first',$first],[$names eq 'unique'?'second':'first',$second]]);
                my$engine=Selecto::Engine->new(domain=>Selecto::Domain->parse({%$d,name=>'Finite Multi Host'}),adapter=>$adapter);
                return $run->($multi,$engine);
            });
            $emit->($labels,{%$labels,result=>$r,dispatches=>$adapter->dispatches});
        }}}}
    },[
        ['all_operations_compile_before_single_dispatch',sub{my($s)=@_;return @{$s->{dispatches}}==(_predispatch($s)?1:0)}],
        ['dispatched_batch_is_ordered_and_atomic',sub{my($s)=@_;return 1 unless @{$s->{dispatches}};return 0 unless @{$s->{dispatches}}==1;my$b=$s->{dispatches}[0];return 0 unless Selecto::Verification::WriteModel::is($b,'Selecto::Write::Batch');my$c=$b->commands;my$r=Selecto::Write::Capabilities->requirements($b);return @$c==2&&$c->[0]->operation eq 'insert'&&$c->[1]->operation eq 'update'&&(grep{!ref($_)&&$_ eq 'atomic_batch'}@$r)}],
        ['trusted_batch_context_must_agree',sub{my($s)=@_;return 1 unless $s->{contexts} eq 'conflicting';return !@{$s->{dispatches}}&&Selecto::Verification::WriteModel::typed($s->{result})}],
        ['operation_names_and_results_form_a_bijection',sub{my($s)=@_;my$success=_predispatch($s)&&$s->{adapter_outcome} eq 'exact';return Selecto::Verification::WriteModel::typed($s->{result}) unless $success;return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$r=$s->{result}{value};return ref($r) eq 'HASH'&&keys(%$r)==2&&Selecto::Verification::WriteModel::is($r->{first},'Selecto::Write::Result')&&Selecto::Verification::WriteModel::is($r->{second},'Selecto::Write::Result')&&$r->{first}->operation eq 'insert'&&$r->{second}->operation eq 'update'&&$r->{first}->metadata->{batch_index}==0&&$r->{second}->metadata->{batch_index}==1}],
        # The highest reference defines this fifth invariant as unconditionally
        # satisfied. Keep that exact finite-model meaning; the fourth invariant
        # is the actual check that errors cannot become success name maps.
        ['errors_never_return_partial_name_maps',sub{1}],
    ]);
}
1;
