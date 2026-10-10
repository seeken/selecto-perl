use 5.034;use strict;use warnings;
use Test::More;use Selecto::Error ();use Selecto::Write ();use Selecto::Expression ();
use Selecto::Verification::WriteModel ();
my@models=(['WriteSafety',16,80,5],['PortableCommandSafety',48,432,9],['NestedGraphSafety',24,144,6],['TenantNonInterferenceSafety',5832,34992,6],['MultiAtomicitySafety',60,300,5],['TrustBoundarySafety',12,24,2]);
for my$entry(@models){
 my($name,$states,$checks,$invariants)=@$entry;my$module='Selecto::Verification::'.$name;(my$file=$module.'.pm')=~s{::}{/}g;require$file;
 my$r=$module->verify;
 is($r->{state_count},$states,"$name enumerates the complete original state space");
 is($r->{check_count},$checks,"$name executes every original state/invariant check");
 is($r->{invariant_count},$invariants,"$name retains every original invariant");
 is_deeply($r->{counterexamples},[],"$name actual public boundary satisfies its finite model");
}
my$wrong=Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{name=>'unsafe',tenant_id=>'tenant-b'},metadata=>{});
my$f=Selecto::Verification::WriteSafety->verify(validate_scope=>sub{1});
ok(grep($_->{invariant} eq 'required_scope_fails_closed',@{$f->{counterexamples}}),'scope model detects an actually permissive validator');
$f=Selecto::Verification::PortableCommandSafety->verify(compile=>sub{{command=>$wrong,context=>{tenant_id=>'tenant-a'}}});
ok(grep($_->{invariant} eq 'tenant_scope_is_compiled',@{$f->{counterexamples}}),'command model detects a compiled command emitting the wrong tenant');
$f=Selecto::Verification::NestedGraphSafety->verify(compile=>sub{{command=>$wrong,context=>{tenant_id=>'tenant-a'}}});
ok(grep($_->{invariant} eq 'valid_states_compile_atomic_graphs',@{$f->{counterexamples}}),'nested model detects a flat command replacing the graph');
$f=Selecto::Verification::TenantNonInterferenceSafety->verify(compile=>sub{{command=>$wrong,context=>{tenant_id=>'tenant-a'}}});
ok(grep($_->{invariant} eq 'trusted_tenant_is_the_only_emitted_tenant',@{$f->{counterexamples}}),'tenant model detects wrong emitted tenant independently of compile success');
$f=Selecto::Verification::MultiAtomicitySafety->verify(run=>sub{{first=>Selecto::Write::Result->new(operation=>'insert',affected_rows=>1)}});
ok(grep($_->{invariant} eq 'all_operations_compile_before_single_dispatch',@{$f->{counterexamples}}),'multi model detects success without required actual single dispatch');
ok(grep($_->{invariant} eq 'operation_names_and_results_form_a_bijection',@{$f->{counterexamples}}),'multi model detects a partial result name map');
$f=Selecto::Verification::TrustBoundarySafety->verify(compile=>sub{Selecto::Error->throw('wrong_boundary','wrong boundary')},authorize=>sub{{status=>'enabled'}});
ok(grep($_->{invariant} eq 'failure_reason_matches_boundary',@{$f->{counterexamples}}),'trust model detects typed errors with an incorrect reason');
ok(grep($_->{invariant} eq 'adversarial_intent_fails_closed',@{$f->{counterexamples}}),'trust model detects forged provenance authorization');
for my$entry(@models){my$module='Selecto::Verification::'.$entry->[0];my$ok=eval{$module->verify(unknown=>sub{1});1};ok(!$ok&&ref($@) eq 'Selecto::Error',"$entry->[0] refuses unknown verifier configuration");}
done_testing;
