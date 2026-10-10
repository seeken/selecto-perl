use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use POSIX ();
use DBI;
use Selecto;
use lib 't/lib';
use TestSelecto;

{
    package Local::SQLiteStatementEvidence;
    use parent 'Selecto::SQLite';
    sub _execute_statement {
        my ($self, $sth, $params) = @_;
        my $result = $self->SUPER::_execute_statement($sth, $params);
        push @{$self->{native_handles}}, {class => ref($sth), driver => $sth->{Database}{Driver}{Name},
            sql => $sth->{Statement}, values => $sth->{ParamValues}};
        return $result;
    }
}

my $x = 'Selecto::Expression';
my $json = JSON::PP->new->canonical;
my $domain = Selecto::Domain->new(name => 'Amounts', table => 'amounts',
    fields => {id => 'integer', amount => 'decimal'});
my $adapter = Selecto->adapter(sqlite => dbh => TestSelecto::DBH->new);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
sub error_code {
    my ($run) = @_;
    my $ok = eval { $run->(); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : die $@;
}

subtest 'numeric and string identities survive compiler admission without a driver' => sub {
    my $values = $json->decode('[2,"2",3.5,"3.50","001","9007199254740993.000001"]');
    my $query = $engine->query->select(map { $x->literal($values->[$_])->as("v$_") } 0 .. $#$values);
    my $statement = $engine->compile($query);
    is($json->encode($statement->params), $json->encode($values), 'parameter JSON scalar types and decimal bytes are unchanged');
    is(scalar(() = $statement->sql =~ /\?/g), 6, 'typed execution preserves ordinary placeholder SQL');
    unlike($statement->sql, qr/CAST/, 'binding types do not add SQL expression affinity');
    my $number = $x->literal(2)->as('number');
    my $text = $x->literal('2')->as('text');
    is(error_code(sub {$engine->compile($engine->query->select($number, $text,
        $x->grouping($number, $text)->as('mask'))->group_by_rollup($number, $text))}),
        'ok', 'numeric and string dimensions with the same spelling have distinct identities');
    my $out_of_range = $json->decode('9223372036854775808');
    is(error_code(sub {$engine->compile($engine->query->select($x->literal($out_of_range)))}),
        'invalid_query', 'native unsigned integer beyond SQLite signed64 is refused');
    my $infinity = POSIX::HUGE_VAL();
    my $nan = $infinity - $infinity;
    for my $value ($infinity, -$infinity, $nan) {
        is(error_code(sub {$engine->compile($engine->query->select($x->literal($value)))}),
            'invalid_query', 'nonfinite native real cannot become a misleading cast result');
    }
    is(error_code(sub {$engine->compile($engine->query->select($x->literal('9223372036854775808')))}),
        'ok', 'exact wide authored text remains representable');
};

subtest 'native aggregate comparisons and typed literals in memory' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('PRAGMA temp_store = MEMORY');
    $dbh->do('CREATE TEMP TABLE memory_proof(id INTEGER)');
    $dbh->do('CREATE TABLE amounts(id INTEGER PRIMARY KEY, amount NUMERIC)');
    $dbh->do('INSERT INTO amounts VALUES(?,?)', undef, @$_) for [1, 1.25], [2, 2.50], [3, -0.25];
    my $adapter = Local::SQLiteStatementEvidence->new(dbh => $dbh);
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    my @checks = (
        $x->gte($x->count, 2), $x->gte($x->count, 4), $x->eq($x->count, 3),
        $x->gte($x->count, '2'), $x->eq($x->count, '3'),
        $x->gte($x->sum('amount'), 3.5), $x->gt($x->sum('amount'), 3.5),
        $x->gt($x->sum('amount'), -0.5), $x->lt($x->sum('amount'), 4),
        $x->gte($x->sum('amount'), '3.5'),
        $x->between($x->count, 2, 3), $x->in($x->count, 3, 4), $x->in($x->count, '3', '4'),
    );
    my $query = $engine->query->select(map { $checks[$_]->as("c$_") } 0 .. $#checks);
    my $expected = [[1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 1, 0]];
    is_deeply($engine->all($query)->{rows}, $expected, 'COUNT/SUM, BETWEEN and IN compare numbers without converting authored strings');
    is_deeply($dbh->selectall_arrayref(q{SELECT COUNT(*) >= 2, COUNT(*) >= 4, COUNT(*) = 3,
        COUNT(*) >= '2', COUNT(*) = '3', SUM(amount) >= 3.5, SUM(amount) > 3.5,
        SUM(amount) > -0.5, SUM(amount) < 4, SUM(amount) >= '3.5',
        COUNT(*) BETWEEN 2 AND 3, COUNT(*) IN (3,4), COUNT(*) IN ('3','4') FROM amounts}),
        $expected, 'native SQL literals independently confirm both positive and negative expectations');
    my $negative = $engine->query->select($x->sum('amount')->as('total'),
        $x->gte($x->sum('amount'), -0.5)->as('ge'), $x->lt($x->sum('amount'), 0)->as('negative'),
        $x->gte($x->sum('amount'), 0)->as('nonnegative'))->where($x->eq('id', 3));
    is_deeply($engine->all($negative)->{rows}, [[-0.25, 1, 1, 0]], 'negative fractional SUM compares in both directions');

    my $values = $json->decode('[2,"2",3.5,"3.50","001","9007199254740993.000001"]');
    my $cached_string = '001';
    my $cached_number = 0 + $cached_string;
    push @$values, $cached_string, $json->decode('9223372036854775807'), $json->decode('-9223372036854775808');
    my $literals = $engine->query->select(map { $x->literal($values->[$_])->as("v$_") } 0 .. $#$values)
        ->where($x->eq('id', 1));
    for my $guessing (0, 1) {
        $dbh->{sqlite_see_if_its_a_number} = $guessing;
        is($json->encode($engine->all($literals)->{rows}), $json->encode([$values]),
            "numeric JSON, cached numeric-looking strings, exact decimal text and signed64 remain typed with driver guessing=$guessing");
        is($dbh->{sqlite_see_if_its_a_number}, $guessing, 'compilation and execution preserve caller driver configuration');
    }
    $dbh->{sqlite_see_if_its_a_number} = 0;
    my $type_params = $engine->compile($literals)->params;
    pop @$type_params;
    my $types = $adapter->execute_query(Selecto::Statement->new(
        sql => 'SELECT ' . join(', ', map { "typeof(?) AS v$_" } 0 .. $#$values),
        params => $type_params,
        columns => [map { "v$_" } 0 .. $#$values], adapter_name => 'sqlite'));
    is_deeply($types->{rows}, [[qw(integer text real text text text text integer integer)]],
        'actual DBI handles bind compiled parameters as native integer, real and text storage classes');
    $dbh->do('CREATE TABLE stored(id INTEGER PRIMARY KEY, quantity INTEGER, amount REAL, label TEXT, exact_text TEXT)');
    my $writes = Selecto::Engine->new(adapter => $adapter,
        domain => TestSelecto::writable_domain(name => 'Stored', table => 'stored', fields => {
            id => 'integer', quantity => 'integer', amount => 'decimal', label => 'string', exact_text => 'string',
        }));
    my $exact = '9007199254740993.000001';
    $dbh->{sqlite_see_if_its_a_number} = 1;
    $writes->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'stored',
        assignments => {id => 1, quantity => 2, amount => 3.5, label => '001', exact_text => $exact}));
    is_deeply($dbh->selectall_arrayref('SELECT id,quantity,amount,label,exact_text,typeof(quantity),typeof(amount),typeof(label),typeof(exact_text) FROM stored'),
        [[1,2,3.5,'001',$exact,'integer','real','text','text']], 'public DML stores numeric values and exact text with host guessing enabled');
    $dbh->begin_work;
    $writes->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'stored',
        assignments => {amount => -0.25, label => '0002', exact_text => '1.23000000000000000009'}, predicate => $x->eq('id', 1)));
    is_deeply($dbh->selectall_arrayref('SELECT amount,label,exact_text FROM stored'),
        [[-0.25,'0002','1.23000000000000000009']], 'public UPDATE uses the same typed bindings without losing decimal text');
    ok(!$dbh->sqlite_get_autocommit, 'public DML preserves the caller transaction');
    $dbh->rollback;
    is_deeply($dbh->selectall_arrayref('SELECT amount,label,exact_text FROM stored'),
        [[3.5,'001',$exact]], 'caller rollback restores its stored row');
    $writes->execute_batch(Selecto::Write::Batch->new(map {
        Selecto::Write::Command->new(operation => 'insert', relation => 'stored',
            assignments => {id => $_, quantity => 2, amount => -0.25, label => '0003', exact_text => '3.500'})
    } 2, 3));
    is_deeply($dbh->selectall_arrayref('SELECT id,amount,label,exact_text FROM stored WHERE id>1 ORDER BY id'),
        [[2,-0.25,'0003','3.500'],[3,-0.25,'0003','3.500']], 'public batch preserves number/string parameters for every statement');
    $dbh->{sqlite_see_if_its_a_number} = 0;
    my $number = $x->literal(2)->as('number');
    my $text = $x->literal('2')->as('text');
    my $rollup = $engine->query->select($number, $text, $x->count->as('n'),
        $x->grouping($number, $text)->as('mask'))->group_by_rollup($number, $text)->order_by('mask');
    is($json->encode($engine->all($rollup)->{rows}), $json->encode([
        [2, '2', 3, 0], [2, undef, 3, 1], [undef, undef, 3, 3],
    ]), 'numeric literal dimensions still drop out and numeric/string markers remain distinct');
    my $composed = $engine->query->select('id', $x->gte($x->count, 1)->as('positive'),
        $x->lt($x->sum('amount'), 0)->as('negative'), $x->grouping('id')->as('mask'))->group_by_rollup('id')->order_by('id');
    is_deeply($engine->all($composed)->{rows}, [[undef,1,0,1], [1,1,0,0], [2,1,0,0], [3,1,1,0]],
        'aggregate comparisons compose correctly in every rollup branch');
    my $stream = $engine->stream($query);
    is_deeply($stream->next, $expected->[0], 'streaming uses the same typed compiler parameters');
    $stream->close;
    ok(@{$adapter->{native_handles}} > 0, 'real statement handles were recorded');
    is_deeply([grep { $_->{class} ne 'DBI::st' || $_->{driver} ne 'SQLite' } @{$adapter->{native_handles}}], [],
        'all native query, stream and DML evidence uses actual SQLite DBI statement handles');
    is($dbh->selectrow_array('PRAGMA temp_store'), 2, 'TEMP remains MEMORY');
    is_deeply([map { $_->[2] } @{$dbh->selectall_arrayref('PRAGMA database_list')}], ['', ''], 'main/TEMP have no file paths');
    is($dbh->selectrow_array('PRAGMA query_only'), 0, 'read guard restores caller query_only');
    ok($dbh->sqlite_get_autocommit, 'queries do not open or close a caller transaction');
    $dbh->disconnect;
};

done_testing;
