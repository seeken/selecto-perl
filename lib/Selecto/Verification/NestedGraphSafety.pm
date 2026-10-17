package Selecto::Verification::NestedGraphSafety;
use 5.034; use strict; use warnings;
use JSON::PP (); use Selecto::Verification::WriteModel (); use Selecto::Write::Capabilities ();
my $M='Selecto::Verification::WriteModel';
sub _valid {my($s)=@_;return $s->{tenant}&&$s->{policy} eq 'valid'&&!$s->{override};}
sub verify {
    my($class,%opts)=@_;Selecto::Verification::WriteModel::options(\%opts,'compile');my$compile=$opts{compile}//sub{Selecto::Verification::WriteModel::compile(@_)};
    return Selecto::Verification::WriteModel::check('selecto_updato.nested_graph.v1',sub{my($emit)=@_;
        for my$type(qw(insert update)){for my$tenant(0,1){for my$policy(qw(absent valid invalid_child_key)){for my$override(0,1){
            my$child={name=>'child'};$child->{id}=11 if $type eq 'update';$child->{parent_id}=99 if $override;
            my$op=Selecto::Write::Operation->new(Selecto::Verification::WriteModel::nested_domain($policy))->operation($type,{name=>'parent',children=>[$child]});
            $op=$op->filter([Selecto::Verification::WriteModel::atom('id'),42]) if $type eq 'update';$op=$op->with_tenant({tenant_id=>'tenant-a'}) if $tenant;
            my$r=Selecto::Verification::WriteModel::capture(sub{$compile->($op)});
            $emit->({operation=>$type,tenant=>$tenant,relationship_policy=>$policy,ownership_override=>$override},{operation=>$type,tenant=>$tenant,policy=>$policy,override=>$override,result=>$r});
        }}}}
    },[
        ['invalid_states_fail_closed',sub{my($s)=@_;_valid($s)||Selecto::Verification::WriteModel::typed($s->{result})}],
        ['valid_states_compile_atomic_graphs',sub{my($s)=@_;return 1 unless _valid($s);return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$r=$s->{result}{value};return 0 unless ref($r) eq 'HASH'&&Selecto::Verification::WriteModel::is($r->{command},'Selecto::Write::Graph')&&($r->{context}{tenant_id}//'') eq 'tenant-a';my$validated=$r->{command}->validate;return 0 unless Selecto::Verification::WriteModel::is($validated,'Selecto::Write::Graph');my$req=Selecto::Write::Capabilities->requirements($r->{command});return (grep {!ref($_)&&$_ eq 'transactions'} @$req)&&(grep {!ref($_)&&$_ eq 'write_graph'} @$req)}],
        ['generated_ownership_is_topological',sub{my($s)=@_;return 1 unless _valid($s);return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$n=$s->{result}{value}{command}->nodes;return 0 unless @$n==2&&@{$n->[1]{bindings}}==1;my$b=$n->[1]{bindings}[0];return $b->{field} eq 'parent_id'&&$b->{from} eq 'root'&&!exists($n->[1]{command}->assignments->{parent_id})}],
        ['tenant_scope_covers_every_row',sub{my($s)=@_;return 1 unless _valid($s);return 0 unless Selecto::Verification::WriteModel::successful($s->{result});for my$c(@{Selecto::Verification::WriteModel::commands($s->{result}{value}{command})}){return 0 unless grep{defined($_)&&$_ eq 'tenant-a'}@{Selecto::Verification::WriteModel::command_tenants($c)}}return 1}],
        ['sync_identity_and_delete_policy_are_preserved',sub{my($s)=@_;return 1 unless _valid($s)&&$s->{operation} eq 'update';return 0 unless Selecto::Verification::WriteModel::successful($s->{result});my$g=$s->{result}{value}{command};my$n=$g->nodes;my$m=$n->[1]{command}->metadata;my$nested=$m->{nested_graph}//{};my$sets=$g->owned_sets;return @$sets==1&&$sets->[0]{delete_missing}&&$sets->[0]{relationship} eq 'children'&&($nested->{strategy}//'') eq 'sync'&&ref($nested->{identity_fields}) eq 'ARRAY'&&@{$nested->{identity_fields}}==1&&$nested->{identity_fields}[0] eq 'id'&&ref($m->{returning}) eq 'ARRAY'&&@{$m->{returning}}==1&&$m->{returning}[0] eq 'id'}],
        ['graph_is_adapter_neutral',sub{my($s)=@_;return !Selecto::Verification::WriteModel::successful($s->{result})||Selecto::Verification::WriteModel::neutral($s->{result}{value}{command})}],
    ]);
}
1;
