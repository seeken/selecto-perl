use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 't/lib';
use TestSelecto;
use Selecto;

sub join_domain {
    my ($through) = @_;
    return Selecto::Domain->new(name => 'Synthetic bindings', table => 'records',
        fields => {id => 'integer', child_id => 'integer'},
        associations => {child => {
            table => 'children', fields => {id => 'integer', active => 'integer', name => 'string'},
            owner_key => $through ? 'id' : 'child_id', related_key => 'id', where => {active => 7},
            ($through ? (through => {table => 'bridges', owner_key => 'record_id',
                related_key => 'child_id', where => {active => 3}}) : ()),
        }});
}

for my $name (qw(sqlite mysql mariadb mssql postgresql duckdb)) {
    subtest "$name emitted clause binding order" => sub {
        for my $through (0, 1) {
            my $engine = Selecto::Engine->new(domain => join_domain($through),
                adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
            my $statement = $engine->compile($engine->query->select(
                Selecto::Expression->literal(99)->as('value'), 'child.name')
                ->where(Selecto::Expression->eq('id', 1)));
            is_deeply $statement->params, $through ? [99, 7, 3, 1] : [99, 7, 1],
                'bindings follow SELECT, target JOIN, bridge JOIN, WHERE';
            if ($name eq 'postgresql' || $name eq 'duckdb') {
                like $statement->sql, qr/SELECT \$1 AS/, 'selected literal has first numbered identity';
            } else {
                my $count = () = $statement->sql =~ /\?/g;
                is $count, scalar @{$statement->params}, 'every anonymous marker has its own binding';
            }
        }
    };
}

subtest 'live SQLite join restrictions keep their authored values' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBI; require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE records(id INTEGER PRIMARY KEY, child_id INTEGER)');
    $dbh->do('CREATE TABLE children(id INTEGER PRIMARY KEY, active INTEGER, name TEXT)');
    $dbh->do('CREATE TABLE bridges(record_id INTEGER, child_id INTEGER, active INTEGER)');
    $dbh->do('INSERT INTO records VALUES (1,10)');
    $dbh->do(q{INSERT INTO children VALUES (10,7,'allowed'), (11,99,'forbidden')});
    $dbh->do('INSERT INTO bridges VALUES (1,10,3),(1,11,3),(1,10,7)');
    for my $through (0, 1) {
        my $engine = Selecto::Engine->new(domain => join_domain($through),
            adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
        my $result = $engine->all($engine->query->select(
            Selecto::Expression->literal(99)->as('value'), 'child.name')
            ->where(Selecto::Expression->eq('id', 1)));
        is_deeply $result->{rows}, [[99, 'allowed']], 'only the governed joined row is returned';
    }
};

subtest 'originating cardinality errors never serialize match counts' => sub {
    for my $returning (0, 1) {
        my $dbh = TestSelecto::DBH->new({affected => 2, rows => [[1], [2]], columns => ['id']});
        my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
        my $command = Selecto::Write::Command->new(operation => 'update', relation => 'records',
            assignments => {child_id => 1}, predicate => Selecto::Expression->gte('id', 1),
            expected_count => 1, metadata => $returning ? {returning => ['id']} : {});
        my $ok = eval { $adapter->execute_write_unsafe($command); 1 };
        my $error = $@;
        ok !$ok, 'mismatched write is refused';
        is $error->code, 'cardinality_mismatch', 'typed mismatch';
        ok !exists($error->details->{actual}), 'details exclude actual';
        unlike(JSON::PP->new->encode($error->to_hash), qr/"actual"/, 'JSON excludes actual');
        is_deeply $dbh->events, ['BEGIN', 'ROLLBACK'], 'refusal rolls back';
    }
};
subtest 'parameterized IN operands retain SQL occurrence order' => sub {
    for my $name (qw(sqlite mysql mariadb mssql postgresql duckdb)) {
        my $engine = Selecto::Engine->new(domain => TestSelecto::people_domain(),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
        my $statement = $engine->compile($engine->query->select('id')->where(
            Selecto::Expression->not(Selecto::Expression->in(Selecto::Expression->literal('operand'), ['list_a', 'list_b']))));
        is_deeply $statement->params, ['operand', 'list_a', 'list_b'], "$name scalar IN bindings follow emitted order";
    }
};

subtest 'live SQLite computed IN and NOT IN preserve row eligibility' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBI; require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, sqlite_see_if_its_a_number => 1});
    $dbh->do('CREATE TABLE scoped_records(id INTEGER PRIMARY KEY, tenant_id INTEGER)');
    $dbh->do('INSERT INTO scoped_records VALUES (1,7),(2,2),(3,3)');
    my $domain = Selecto::Domain->parse({name => 'Synthetic computed scope', source => {
        source_table => 'scoped_records', primary_key => 'id', fields => [qw(id tenant_id eligible)],
        columns => {id => {type => 'integer'}, tenant_id => {type => 'integer'},
            eligible => {type => 'boolean', computed => {kind => 'predicate', expression => ['eq', 'tenant_id', 7]}}},
        associations => {}}, schemas => {}, joins => {}});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my $predicate = Selecto::Expression->in('eligible', [2, 1]);
    is_deeply $engine->all($engine->query->select('id')->where($predicate)->order_by('id'))->{rows}, [[1]],
        'intended tenant row matches computed IN';
    is_deeply $engine->all($engine->query->select('id')->where(Selecto::Expression->not($predicate))->order_by('id'))->{rows}, [[2],[3]],
        'NOT IN preserves its computed operand too';
};

done_testing;
