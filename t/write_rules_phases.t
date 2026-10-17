use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Domain;
use Selecto::WriteRules;

sub domain {
    my ($bindings) = @_;
    return Selecto::Domain->new(name => 'Write phases', table => 'items',
        fields => {id => 'integer', name => 'string'},
        (defined($bindings) ? (rules => {
            schema => 'selecto.data_rules.v1',
            definitions => {name => {version => 1, test => {op => 'presence.required'}}},
            normalizers => {}, bindings => $bindings,
        }) : ()));
}
sub binding {
    my ($stage, %options) = @_;
    return {subject => {scope => $stage, path => ['name'],
                ($stage eq 'action_input' ? (action => 'rename') : ())},
        rule => {id => 'name', version => 1}, operations => ['upsert'], %options};
}

my $none = domain();
ok(!Selecto::WriteRules->has_rules($none, 'upsert'), 'no registry has no write rules');
ok(!Selecto::WriteRules->has_stored_rules($none, 'upsert'), 'no registry requires no stored subject');
my $input = domain({input => binding('input')});
ok(Selecto::WriteRules->has_rules($input, 'upsert'), 'INPUT remains visible to the all-rules predicate');
ok(!Selecto::WriteRules->has_stored_rules($input, 'upsert'), 'INPUT alone consumes no stored candidate');
ok(!Selecto::WriteRules->has_rules($input, 'update'), 'INPUT operation filtering is preserved');
my $action = domain({action => binding('action_input')});
ok(!Selecto::WriteRules->has_rules($action, 'upsert'), 'ACTION_INPUT remains a separate planning stage');
ok(!Selecto::WriteRules->has_stored_rules($action, 'upsert'), 'ACTION_INPUT does not request a stored write subject');

for my $stage (qw(candidate transaction evidence)) {
    for my $enforcement (qw(required advisory)) {
        my $d = domain({stored => binding($stage, enforcement => $enforcement,
            condition => {op => 'presence.absent'})});
        ok(Selecto::WriteRules->has_rules($d, 'upsert'), "$enforcement $stage is an applicable write stage");
        ok(Selecto::WriteRules->has_stored_rules($d, 'upsert'),
            "$enforcement $stage keeps stored admission even with a conditional test");
        ok(!Selecto::WriteRules->has_stored_rules($d, 'update'), "$enforcement $stage respects operation filtering");
    }
}
my $mixed = domain({input => binding('input'), stored => binding('candidate', operations => ['update'])});
ok(Selecto::WriteRules->has_rules($mixed, 'upsert'), 'mixed registry retains active submitted rules');
ok(!Selecto::WriteRules->has_stored_rules($mixed, 'upsert'), 'inactive stored bindings do not turn INPUT into a final-state obligation');
ok(Selecto::WriteRules->has_stored_rules($mixed, 'update'), 'the same registry still protects its active stored operation');
my $all_operations = domain({stored => binding('transaction', operations => [])});
ok(Selecto::WriteRules->has_stored_rules($all_operations, $_), "unfiltered transaction binding protects $_")
    for qw(insert update upsert delete);

done_testing;
