package Selecto::Verification::TrustBoundarySafety;
use 5.034; use strict; use warnings;
use JSON::PP ();use Selecto::Domain ();use Selecto::Verification::WriteModel ();use Selecto::Action ();use Selecto::Action::Plan ();
my$M='Selecto::Verification::WriteModel';
sub _domain {
    my($returning)=@_;$returning//='none';
    return {source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id name assignee_id)],columns=>{id=>{type=>'integer'},name=>{type=>'string'},assignee_id=>{type=>'integer',choice_source=>'assignees'}},associations=>{}},schemas=>{},
        choice_sources=>{assignees=>{domain=>'assignees',value_field=>'id',label_field=>'name'}},
        writes=>{operations=>{insert=>{enabled=>JSON::PP::true,returning=>$returning},update=>{enabled=>JSON::PP::true,require_filter=>JSON::PP::true,expected_cardinality=>['exactly',1],returning=>$returning}},
            fields=>{name=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true},assignee_id=>{updatable=>JSON::PP::true}}}};
}
sub _update {return Selecto::Write::Operation->new(_domain($_[0]))->update({name=>'updated'});}
sub verify {
    my($class,%opts)=@_;Selecto::Verification::WriteModel::options(\%opts,qw(compile authorize));
    my$compile=$opts{compile}//sub{Selecto::Verification::WriteModel::compile(@_)};
    my$authorize=$opts{authorize}//sub{Selecto::Action->authorize_and_issue($_[0],'execute',resolver=>sub{'enabled'})};
    return Selecto::Verification::WriteModel::check('selecto_updato.trust_boundary.v1',sub{my($emit)=@_;
        my@cases=(
            ['duplicate_assignment','duplicate_assignment_identifier',sub{Selecto::Write::Operation->new(_domain())->insert([[Selecto::Verification::WriteModel::atom('name'),'one'],['name','two']])}],
            ['duplicate_filter','duplicate_filter_identifier',sub{_update()->filters([[Selecto::Verification::WriteModel::atom('id'),1],['id',2]])}],
            ['duplicate_returning','duplicate_returning_identifier',sub{_update('all')->filter([Selecto::Verification::WriteModel::atom('id'),1])->returning([Selecto::Verification::WriteModel::atom('id'),'id'])}],
            ['undeclared_filter','undeclared_write_identifier',sub{_update()->filter([Selecto::Verification::WriteModel::atom('unscoped_secret'),1])}],
            ['undeclared_returning','undeclared_write_identifier',sub{_update('all')->filter([Selecto::Verification::WriteModel::atom('id'),1])->returning([Selecto::Verification::WriteModel::atom('unscoped_secret')])}],
            ['weakened_cardinality','expected_cardinality_policy_violation',sub{_update()->filter([Selecto::Verification::WriteModel::atom('id'),1])->expected_cardinality('many')}],
            ['expanded_returning','returning_policy_violation',sub{_update()->filter([Selecto::Verification::WriteModel::atom('id'),1])->returning('all')}],
            ['missing_choice_resolver','choice_membership_resolver_required',sub{Selecto::Write::Operation->new(_domain())->update({assignee_id=>7})->filter([Selecto::Verification::WriteModel::atom('id'),1])}],
        );
        for my$c(@cases){my$r=Selecto::Verification::WriteModel::capture(sub{$compile->($c->[2]->())});$emit->({case=>$c->[0],expected_code=>$c->[1]},{case=>$c->[0],expected_code=>$c->[1],result=>$r});}
        for my$mode(qw(opaque forged)){
            my$r=Selecto::Verification::WriteModel::capture(sub{
                require Selecto::Write::PlannedOperation;
                my$operation=$mode eq 'opaque'?Selecto::Action->planned_operation(Selecto::Verification::WriteModel::work_items(),{action=>'archive',target=>7}):bless(\(my$fake=0),'Selecto::Write::PlannedOperation');
                return $compile->($operation,context=>{},action_phase=>'execute');
            });
            $emit->({case=>$mode.'_planned_operation',expected_code=>'opaque_planned_operation'},{expected_code=>'opaque_planned_operation',result=>$r});
        }
        my$unregistered=Selecto::Action::Plan->new(action=>'archive',capability=>'work_items.archive',operation=>'update');
        my$r=Selecto::Verification::WriteModel::capture(sub{$authorize->($unregistered)});
        $emit->({case=>'unregistered_nil_plan',expected_code=>'invalid_planned_operation'},{expected_code=>'invalid_planned_operation',result=>$r});
        $r=Selecto::Verification::WriteModel::capture(sub{
            # Actual canonical plain document planning, followed by mutation of
            # the exact accepted object; no injected error stands in for it.
            my$document=Selecto::Domain->project(Selecto::Verification::WriteModel::work_items(),'write');
            my$plan=Selecto::Action->plan($document,{action=>'archive',target=>{id=>7}});
            $plan->target({id=>99});return $authorize->($plan);
        });
        $emit->({case=>'modified_contract_only_plan',expected_code=>'action_policy_mismatch'},{expected_code=>'action_policy_mismatch',result=>$r});
    },[
        ['adversarial_intent_fails_closed',sub{my($s)=@_;return Selecto::Verification::WriteModel::typed($s->{result})}],
        ['failure_reason_matches_boundary',sub{my($s)=@_;return Selecto::Verification::WriteModel::typed($s->{result})&&(Selecto::Verification::WriteModel::code($s->{result})//'') eq $s->{expected_code}}],
    ]);
}
1;
