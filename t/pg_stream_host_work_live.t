use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Statement;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# A bounded stream inside the host's transaction: the host writes between fetches, and
# keeps its own savepoints. A stream's failure ends the stream, never the host's work.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP VIEW IF EXISTS sw_bad', 'DROP TABLE IF EXISTS sw_t, sw_l CASCADE', 'DROP FUNCTION IF EXISTS public.sw_boom(int)');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE sw_t (id INT PRIMARY KEY, org TEXT NOT NULL)', q{INSERT INTO sw_t SELECT i, 't1' FROM generate_series(1, 5) i}, 'CREATE TABLE sw_l (hit INT PRIMARY KEY)',
    q{CREATE FUNCTION public.sw_boom(i int) RETURNS int LANGUAGE plpgsql AS $$ BEGIN IF i = 4 THEN RAISE EXCEPTION 'row four'; END IF; RETURN i; END $$},
    q{CREATE VIEW sw_bad AS SELECT public.sw_boom(id) AS id, org FROM (SELECT * FROM sw_t ORDER BY id OFFSET 0) s};
my $domain = sub { Selecto::Domain->parse({schema_version => 1, name => "D$_[0]", source => {source_table => $_[0], primary_key => 'id', tenant_field => 'org', fields => [qw(id org)],
    columns => {id => {type => 'integer'}, org => {type => 'string'}}, associations => {}}, schemas => {}, joins => {}}) };
my $open = sub {
    my ($table) = @_;
    my $dbh = TestPostgreSQL->connect;
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    return ($dbh, $adapter, Selecto::Engine->new(domain => $domain->($table // 'sw_t'), adapter => $adapter)->with_scope(tenant => 't1'));
};
my $stored = sub { join ',', map { $_->[0] } @{$admin->selectall_arrayref('SELECT hit FROM sw_l ORDER BY hit')} };
my $locked = sub {
    my $other = TestPostgreSQL->connect;
    my $free = eval { $other->begin_work; $other->do('SELECT 1 FROM sw_t WHERE id = 1 FOR UPDATE NOWAIT'); 1 };
    eval { $other->rollback };
    $other->disconnect;
    return !$free;
};

subtest 'a generated stream that locks rows holds them' => sub {
    my ($dbh, $adapter, $e) = $open->();
    $dbh->begin_work;
    my $s = $e->stream($e->query->select('id')->order_by('id')->for_share, bounded => 1, fetch_size => 2);
    ok($s->next, 'it answers');
    ok($locked->(), 'the row is locked during the stream');
    1 while $s->next;
    $s->close;
    ok($locked->(), 'and after it, to the host\'s commit');
    $dbh->rollback;
    ok(!$locked->(), 'and no further');
    my $alone = $e->stream($e->query->select('id')->order_by('id')->for_share, bounded => 1, fetch_size => 2);
    my $n = 0;
    $n++ while $alone->next;
    is($n, 5, 'on its own it answers too');
    # A statement built on it keeps it.
    $dbh->begin_work;
    my $wrapped = $adapter->bounded_result_statement($e->compile($e->query->select('id')->order_by('id')->for_share), max_cell_bytes => 1000, max_rows => 10);
    ok(eval { $adapter->execute_query($wrapped); 1 }, 'a bounded result over it answers') or diag $@;
    ok($locked->(), 'and holds the lock');
    $dbh->rollback;
    $dbh->disconnect;
};

subtest 'a stream that fails leaves what the host wrote between fetches' => sub {
    # (A temporary relation that shadows the stream's is a changed session: the pin does
    # not reach it. A setting the host changes does not change what the stream reads.)
    for my $case (['an error row', 'sw_bad', sub {}], ['a changed session', 'sw_t', sub { $_[0]->do('CREATE TEMP TABLE sw_t (id INT)') }]) {
        my ($label, $table, $between) = @$case;
        $admin->do('DELETE FROM sw_l');
        my ($dbh, $adapter, $e) = $open->($table);
        $dbh->begin_work;
        $dbh->do('INSERT INTO sw_l VALUES (1)');
        my $s = $e->stream($e->query->select('id'), bounded => 1, fetch_size => 1);
        $s->next;
        $dbh->do('INSERT INTO sw_l VALUES (2)');
        $between->($dbh);
        ok(!eval { 1 while $s->next; 1 }, "$label: the stream fails");
        ok(blessed($@), "$label: typed");
        is($dbh->pg_ping, 3, "$label: the transaction is healthy");
        $dbh->do('INSERT INTO sw_l VALUES (3)');
        ok($dbh->commit, "$label: and commits");
        is($stored->(), '1,2,3', "$label: all of the host's work is there");
        $dbh->disconnect;
    }
};

subtest "a host's setting changed between fetches does not change what the stream reads" => sub {
    $admin->do('DELETE FROM sw_l');
    my ($dbh, $adapter, $e) = $open->();
    my $all = [map { $_->[0] } @{$e->all($e->query->select('id')->order_by('id'))->{rows}}];
    $dbh->begin_work;
    my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
    my @ids = map { $_->[0] } grep { defined } $s->next;
    $dbh->do(q{SET TimeZone = 'Asia/Tokyo'});
    $dbh->do('INSERT INTO sw_l VALUES (1)');
    ok(eval { while (my $row = $s->next) { push @ids, $row->[0] } $s->close; 1 }, 'the stream answers') or diag $@;
    is_deeply(\@ids, $all, 'every row, as a read gives them');
    is($dbh->selectrow_array(q{SELECT pg_catalog.current_setting('TimeZone')}), 'Asia/Tokyo', "the host's setting stands");
    ok($dbh->commit, 'and the host commits');
    is($stored->(), '1', "with its write");
    $dbh->disconnect;
};

subtest "a host's own savepoints are its own" => sub {
    my %host = ('RELEASE of an older savepoint' => sub { $_[0]->do('RELEASE SAVEPOINT h') }, 'ROLLBACK TO an older savepoint' => sub { $_[0]->do('ROLLBACK TO SAVEPOINT h') });
    for my $label (sort keys %host) {
        for my $how (qw(close drain drop)) {
            for my $hand (0, 1) {
                $admin->do('DELETE FROM sw_l');
                my ($dbh, $adapter, $e) = $open->();
                my @warnings;
                local $SIG{__WARN__} = sub { push @warnings, @_ };
                $dbh->begin_work;
                $dbh->do('INSERT INTO sw_l VALUES (1)');
                $dbh->do('SAVEPOINT h');
                my $s = $hand ? $adapter->stream_query(Selecto::Statement->new(sql => 'SELECT id FROM sw_t ORDER BY id', params => [], columns => ['id'], adapter_name => 'postgresql'), bounded => 1, fetch_size => 1)
                    : $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
                $s->next;
                $host{$label}->($dbh);
                eval { $how eq 'close' ? $s->close : $how eq 'drain' ? do { 1 while $s->next; $s->close } : undef($s) };
                my $case = "$label, $how" . ($hand ? ', hand-built' : '');
                is($dbh->pg_ping, 3, "$case: the transaction is healthy");
                is_deeply(\@warnings, [], "$case: nothing to warn of");
                $dbh->do('INSERT INTO sw_l VALUES (2)');
                ok($dbh->commit, "$case: it commits");
                is($stored->(), '1,2', "$case: and the host's work is there");
                $dbh->disconnect;
            }
        }
    }
    # One the host opens during a stream stays open after it.
    my ($dbh, $adapter, $e) = $open->();
    $dbh->begin_work;
    my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
    $s->next;
    $dbh->do('SAVEPOINT late');
    $s->close;
    ok(eval { $dbh->do('ROLLBACK TO SAVEPOINT late'); 1 }, "a savepoint opened during the stream survives its close") or diag $@;
    $dbh->rollback;
    $dbh->disconnect;
};

my $failing = sub {
    my ($match, $times, $work) = @_;
    no warnings 'redefine';
    my $do = \&DBD::Pg::db::do;
    my $left = $times;
    local *DBD::Pg::db::do = sub {
        my ($h, $sql) = @_;
        if (defined($sql) && $sql =~ $match && $left-- > 0) {
            eval { local $h->{PrintError} = 0; local $h->{RaiseError} = 1; $do->($h, q{DO $$ BEGIN RAISE EXCEPTION 'cancelled' USING ERRCODE = '57014'; END $$}) };
            die "DBD::Pg::db do failed: ERROR:  canceling statement due to user request\n";
        }
        return $do->(@_);
    };
    return $work->();
};

subtest 'a cancel on its ending is tried again, and costs nothing' => sub {
    for my $match (qr/\ACLOSE selecto_stream/, qr/\ARELEASE SAVEPOINT selecto_stream\w+_end/) {
        for my $how (qw(close drop)) {
            $admin->do('DELETE FROM sw_l');
            my ($dbh, $adapter, $e) = $open->();
            my @warnings;
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $dbh->begin_work;
            $dbh->do('INSERT INTO sw_l VALUES (1)');
            my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
            $s->next;
            ok(eval { $failing->($match, 1, sub { $how eq 'close' ? $s->close : undef($s); 1 }) }, "$how, $match: ended") or diag $@;
            is_deeply(\@warnings, [], 'without a warning');
            is($dbh->pg_ping, 3, 'the transaction is healthy');
            my $next = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
            ok($next->next, 'and the next bounded stream opens: the handle is not poisoned');
            $next->close;
            $dbh->commit;
            is($stored->(), '1', "the host's work is there");
            $dbh->disconnect;
        }
    }
};

subtest 'an ending that cannot be finished never ends in a false OK' => sub {
    for my $how (qw(close drop)) {
        $admin->do('DELETE FROM sw_l');
        my ($dbh, $adapter, $e) = $open->();
        local $SIG{__WARN__} = sub {};
        $dbh->begin_work;
        $dbh->do('INSERT INTO sw_l VALUES (1)');
        my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
        $s->next;
        my $closed = eval { $failing->(qr/selecto_stream\w*_end/, 1000, sub { $how eq 'close' ? $s->close : undef($s); 1 }) };
        ok(!$dbh->{Active}, "$how: the connection is closed");
        ok(!eval { $dbh->commit; 1 } || !$dbh->{Active} && !$stored->(), "$how: no commit reports the host's work stored");
        is($stored->(), '', "$how: and nothing is claimed that is not there");
    }
};

subtest 'a read of its own does not wait for a safe snapshot' => sub {
    my $writer = TestPostgreSQL->connect;
    $writer->do('BEGIN ISOLATION LEVEL SERIALIZABLE');
    $writer->do('UPDATE sw_t SET org = org WHERE id = 2');
    my ($dbh, $adapter) = $open->();
    $dbh->do(q{SET default_transaction_isolation = 'serializable'});
    $dbh->do('SET default_transaction_deferrable = on');
    $dbh->do(q{SET statement_timeout = '1500ms'});
    ok(eval { $adapter->execute_query(Selecto::Statement->new(sql => 'SELECT 1', params => [], adapter_name => 'postgresql')); 1 }, 'a hand-built read answers at once') or diag $@;
    $writer->do('ROLLBACK');
    $_->disconnect for $dbh, $writer;
};

$admin->do($_) for @clean;
done_testing;
