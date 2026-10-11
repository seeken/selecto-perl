use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::DataRules;
use Selecto::WriteRules;
use Selecto::Write::Operation;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }
use Selecto::SQLite;

# a_confirm sorts before b_email, so its related-path test runs before the
# email normalizer. The submission must be re-tested once fully normalized.
sub rules {
    my (%options) = @_;
    my $scope = $options{scope} // 'input';
    return {schema => 'selecto.data_rules.v1',
        definitions => {same => {version => 1, test => {op => 'value.compare_path', comparison => 'eq', path => ['email']}},
            nonblank => {version => 1, test => {op => 'text.nonblank'}}},
        normalizers => {lower => {version => 1, steps => [{op => 'text.lowercase', profile => 'ascii_v1'}]}},
        bindings => {
            a_confirm => {subject => {scope => $scope, path => ['confirm'], ($options{action} ? (action => $options{action}) : ())},
                operations => [qw(insert update)], rule => {id => 'same', version => 1},
                ($options{advisory} ? (enforcement => 'advisory') : ())},
            b_email => {subject => {scope => $scope, path => ['email'], ($options{action} ? (action => $options{action}) : ())},
                operations => [qw(insert update)], rule => {id => 'nonblank', version => 1},
                normalizer => {id => 'lower', version => 1}}}};
}
sub document {
    my (%options) = @_;
    return {name => 'Confirmed accounts', source => {source_table => 'accounts', primary_key => 'id',
        fields => [qw(id email confirm)], columns => {id => {type => 'integer'},
            email => {type => 'string'}, confirm => {type => 'string'}}, associations => {}}, schemas => {},
        writes => {operations => {map { $_ => {enabled => JSON::PP::true} } qw(insert update)},
            fields => {id => {insertable => JSON::PP::true},
                map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} } qw(email confirm)}},
        rules => rules(%options)};
}
sub code_of {
    my ($work) = @_;
    return 'ok' if eval { $work->(); 1 };
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return $error->code;
}

subtest 'INPUT related-path tests see every normalized field' => sub {
    my $rules = Selecto::DataRules->parse(rules());
    is(code_of(sub { Selecto::WriteRules->evaluate($rules, 'input', 'insert', {email => 'A@X', confirm => 'A@X'}) }),
        'data_rule_failed', 'confirmation equal only to the unnormalized email refuses');
    my $normalized = Selecto::WriteRules->evaluate($rules, 'input', 'insert', {email => 'a@x', confirm => 'a@x'});
    is_deeply($normalized, {email => 'a@x', confirm => 'a@x'}, 'confirmation equal to the canonical email passes');
    my $result = $rules->evaluate(stage => 'input', operation => 'insert', subject => {email => 'A@X', confirm => 'A@X'});
    is($result->{state}, 'passed', 'the single ordered pass alone cannot see the later normalizer');
    my $advisory = Selecto::DataRules->parse(rules(advisory => 1));
    is_deeply(Selecto::WriteRules->evaluate($advisory, 'input', 'insert', {email => 'A@X', confirm => 'A@X'}),
        {email => 'a@x', confirm => 'A@X'}, 'an advisory confirmation keeps its advisory outcome after the recheck');
    my $action = Selecto::DataRules->parse(rules(scope => 'action_input', action => 'register'));
    is(code_of(sub { Selecto::WriteRules->evaluate($action, 'action_input', 'insert',
        {email => 'A@X', confirm => 'A@X'}, action => 'register') }),
        'data_rule_failed', 'ACTION_INPUT receives the same normalized recheck');
};

subtest 'native SQLite writes refuse before DML' => sub {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    $db->do('CREATE TABLE accounts(id INTEGER PRIMARY KEY, email TEXT NOT NULL, confirm TEXT NOT NULL)');
    $db->do(q{INSERT INTO accounts VALUES(1,'b@y','b@y')});
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(document()), adapter => Selecto::SQLite->new(dbh => $db));
    my @hooks;
    $db->sqlite_update_hook(sub { push @hooks, [@_] });
    my $insert = sub { Selecto::Write::Command->new(operation => 'insert', relation => 'accounts', assignments => {id => 2, @_}) };
    is(code_of(sub { $engine->execute_write($insert->(email => 'A@X', confirm => 'A@X')) }), 'data_rule_failed',
        'insert whose confirmation matches only the raw email refuses');
    is(code_of(sub { $engine->preview_write($insert->(email => 'A@X', confirm => 'A@X')) }), 'data_rule_failed',
        'preview refuses the same submission');
    my $update = Selecto::Write::Command->new(operation => 'update', relation => 'accounts',
        assignments => {email => 'C@Z', confirm => 'C@Z'}, predicate => Selecto::Expression->eq('id', 1), expected_count => 1);
    is(code_of(sub { $engine->execute_write($update) }), 'data_rule_failed', 'update receives the same recheck');
    is(scalar @hooks, 0, 'no business row was mutated');
    is_deeply($db->selectall_arrayref('SELECT * FROM accounts ORDER BY id'), [[1, 'b@y', 'b@y']], 'stored rows unchanged');
    is(code_of(sub { $engine->execute_write($insert->(email => 'a@x', confirm => 'a@x')) }), 'ok',
        'confirmation matching the canonical email is admitted');
    is_deeply($db->selectall_arrayref('SELECT * FROM accounts ORDER BY id'), [[1, 'b@y', 'b@y'], [2, 'a@x', 'a@x']],
        'positive control stores the canonical email');
    $db->sqlite_update_hook(undef);
    $db->disconnect;
};

subtest 'portable compilation does not seal a stale INPUT proof' => sub {
    is(code_of(sub { Selecto::Write::Operation->new(document())->insert({id => 3, email => 'A@X', confirm => 'A@X'})->compile }),
        'data_rule_failed', 'compiler refuses before retaining INPUT evidence');
    is(code_of(sub { Selecto::Write::Operation->new(document())->insert({id => 3, email => 'a@x', confirm => 'a@x'})->compile }),
        'ok', 'compiler admits the normalized confirmation');
};

done_testing;
