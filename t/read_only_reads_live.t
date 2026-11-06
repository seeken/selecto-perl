use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R55: a read is READ ONLY or ends in ROLLBACK, on every path, so nothing it
# reaches outlives it. What that newly refuses is a view that writes: one using
# nextval, or an audit function.
my $domain = sub {
    my ($table, %options) = @_;
    Selecto::Domain->parse({schema_version => 1, name => "D$table", source => {source_table => $table, primary_key => 'id', ($options{untenanted} ? () : (tenant_field => 'org')),
        fields => [qw(id org note)], columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}});
};
my $read_only = sub {
    my ($error) = @_;
    return blessed($error) && $error->code eq 'query_error' && ($error->details->{category} // '') eq 'read_only_transaction';
};

subtest postgresql => sub {
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
    my @clean = ('DROP VIEW IF EXISTS r55_seq_v, r55_audit_v', 'DROP FUNCTION IF EXISTS public.r55_audit(text)', 'DROP SEQUENCE IF EXISTS r55_seq',
        'DROP TABLE IF EXISTS r55_t, r55_log');
    my $admin = TestPostgreSQL->connect;
    $admin->do('SET client_min_messages TO warning');
    $admin->do($_) for @clean, 'CREATE TABLE r55_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT)', 'CREATE TABLE r55_log (note TEXT)',
        q{INSERT INTO r55_t SELECT g, 't1', 'n' FROM generate_series(1, 6) g}, 'CREATE SEQUENCE r55_seq',
        q{CREATE VIEW r55_seq_v AS SELECT id, org, pg_catalog.nextval('public.r55_seq')::text AS note FROM public.r55_t},
        q{CREATE FUNCTION public.r55_audit(s text) RETURNS text LANGUAGE plpgsql AS $$ BEGIN INSERT INTO public.r55_log VALUES (s); RETURN s; END $$},
        q{CREATE VIEW r55_audit_v AS SELECT id, org, public.r55_audit(note) AS note FROM public.r55_t};
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO error');
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    my $engine = sub { Selecto::Engine->new(domain => $domain->($_[0]), adapter => $adapter)->with_scope(tenant => 't1') };
    my $count = sub { ($admin->selectrow_array('SELECT count(*) FROM public.r55_log'))[0] };
    my $next = sub { ($admin->selectrow_array('SELECT last_value FROM public.r55_seq'))[0] };
    my $seq = $next->();
    for my $table (qw(r55_seq_v r55_audit_v)) {
        my $e = $engine->($table);
        my $query = $e->query->select('id', 'note')->order_by('id');
        ok(!eval { $e->all($query); 1 } && $read_only->($@), "$table: a read through a view that writes refuses");
        ok(!eval { my $s = $e->stream($query); while ($s->next) { } 1 } && $read_only->($@), "$table: so does a stream");
        ok(!eval { my $s = $e->stream($query, bounded => 1, fetch_size => 2); while ($s->next) { } 1 } && $read_only->($@), "$table: so does a bounded stream");
        $dbh->begin_work;
        $dbh->do(q{INSERT INTO r55_log VALUES ('host')});
        ok(!eval { $e->all($query); 1 } && $read_only->($@), "$table: in a host transaction it refuses too");
        my $s = $e->stream($query, bounded => 1, fetch_size => 2);
        ok(!eval { $s->next; 1 } && $read_only->($@), "$table: a bounded stream in one refuses");
        is(($dbh->selectrow_array(q{SELECT count(*) FROM public.r55_log WHERE note = 'host'}))[0], 1, "$table: the host's transaction lives on, with its write");
        is(($dbh->selectrow_array(q{SELECT count(*) FROM public.r55_log WHERE note = 'n'}))[0], 0, "$table: the read wrote nothing");
        $dbh->rollback;
    }
    is($count->(), 0, 'nothing a read did is left');
    is($next->(), $seq, 'and the sequence did not move');
    # Between a bounded stream's fetches the host writes as it pleases.
    {
        my $e = $engine->('r55_t');
        $dbh->begin_work;
        my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 2);
        my @seen = ($s->next);
        $dbh->do(q{INSERT INTO r55_log VALUES ('between')});
        while (my $row = $s->next) { push @seen, $row }
        is_deeply([map { $_->[0] } @seen], [1 .. 6], "a stream's batches do not lose its place, or the host's read-write transaction");
        $dbh->do(q{INSERT INTO r55_log VALUES ('after')});
        $dbh->commit;
        is($count->(), 2, "the host's writes between fetches commit");
        $admin->do('DELETE FROM r55_log');
    }
    # A locking read inside the host's transaction keeps its lock.
    my $e = $engine->('r55_t');
    $dbh->begin_work;
    $e->all($e->query->select('id')->where(Selecto::Expression->eq('id', 1))->for_share);
    $admin->do(q{SET lock_timeout = '100ms'});
    ok(!eval { $admin->do('UPDATE r55_t SET note = 1::text WHERE id = 1'); 1 }, 'a for_share read keeps its row lock in the host transaction');
    $dbh->rollback;
    $admin->do('SET lock_timeout = 0');
    # ... and its own read still works, then releases.
    ok(eval { $e->all($e->query->select('id')->for_share); 1 }, 'a locking read on its own runs') or diag $@;
    ok(eval { $admin->do('UPDATE r55_t SET note = 2::text WHERE id = 1'); 1 }, 'and holds nothing afterwards');
    $dbh->disconnect;
    $admin->do($_) for @clean;
    $admin->disconnect;
};

for my $family (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($name, $env) = @$family;
    subtest $name => sub {
        plan skip_all => "$env is not set" unless ($ENV{$env} // '') ne '';
        plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };
        require Mojo::URL;
        my $url = Mojo::URL->new($ENV{$env});
        my $connect = sub {
            my ($user, $password) = split /:/, $url->userinfo // '', 2;
            my $db = $url->path->to_string =~ s{\A/}{}r;
            my $dbh = DBI->connect('dbi:MariaDB:database=' . $db . ';host=' . $url->host . ';port=' . $url->port, $user, $password,
                {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_multi_statements => 0});
            $dbh->do(q{SET SESSION time_zone = '+00:00', sql_mode = 'STRICT_TRANS_TABLES', NAMES utf8mb4});
            return $dbh;
        };
        my @clean = ('DROP VIEW IF EXISTS r55_audit_v', 'DROP FUNCTION IF EXISTS r55_audit', 'DROP TABLE IF EXISTS r55_t, r55_log');
        my $admin = $connect->();
        $admin->do($_) for @clean, 'CREATE TABLE r55_t (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL, note VARCHAR(10)) ENGINE=InnoDB',
            'CREATE TABLE r55_log (note VARCHAR(10)) ENGINE=InnoDB', q{INSERT INTO r55_t VALUES (1, 't1', 'n'), (2, 't1', 'n'), (3, 't1', 'n')},
            q{CREATE FUNCTION r55_audit(s VARCHAR(10)) RETURNS VARCHAR(10) DETERMINISTIC MODIFIES SQL DATA BEGIN INSERT INTO r55_log VALUES (s); RETURN s; END},
            q{CREATE VIEW r55_audit_v AS SELECT id, org, r55_audit(note) AS note FROM r55_t};
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        # (A tenant scope on this view would refuse first: its columns are not proven.)
        my $e = Selecto::Engine->new(domain => $domain->('r55_audit_v', untenanted => 1), adapter => $adapter);
        my $query = $e->query->select('id', 'note')->order_by('id');
        ok(!eval { $e->all($query); 1 } && $read_only->($@), 'a read through a view that writes refuses');
        ok(!eval { my $s = $e->stream($query); while ($s->next) { } 1 } && $read_only->($@), 'so does a stream');
        is(($admin->selectrow_array('SELECT count(*) FROM r55_log'))[0], 0, 'and nothing is written');
        $dbh->begin_work;
        $dbh->do(q{INSERT INTO r55_log VALUES ('host')});
        my $rows = eval { $e->all($query)->{rows} };
        ok($rows && @$rows == 3, 'in a host transaction the read returns its rows') or diag $@;
        my $s = $e->stream($query);
        my @seen;
        while (my $row = $s->next) { push @seen, $row }
        is(scalar(@seen), 3, 'so does a stream');
        is_deeply([map { $_->[0] } @{$dbh->selectall_arrayref('SELECT note FROM r55_log')}], ['host'], 'the host keeps its write, and the read has none');
        $dbh->commit;
        is_deeply([map { $_->[0] } @{$admin->selectall_arrayref('SELECT note FROM r55_log')}], ['host'], 'and commits it');
        # A non-transactional table is the limit of a rollback: on its own the
        # read refuses, and in the host's transaction the write stays.
        $admin->do($_) for 'DELETE FROM r55_log', 'ALTER TABLE r55_log ENGINE=MyISAM';
        ok(!eval { $e->all($query); 1 } && $read_only->($@), 'a read writing to MyISAM refuses on its own');
        is(($admin->selectrow_array('SELECT count(*) FROM r55_log'))[0], 0, 'and writes nothing');
        $dbh->begin_work;
        ok(eval { $e->all($query); 1 }, 'in a host transaction it runs') or diag $@;
        $dbh->rollback;
        is(($admin->selectrow_array('SELECT count(*) FROM r55_log'))[0], 3, 'and its writes cannot be undone');
        my $plain = Selecto::Engine->new(domain => $domain->('r55_t'), adapter => $adapter)->with_scope(tenant => 't1');
        is(scalar(@{$plain->all($plain->query->select('id'))->{rows}}), 3, 'an ordinary read reads');
        $dbh->disconnect;
        $admin->do($_) for @clean;
        $admin->disconnect;
    };
}

subtest duckdb => sub {
    plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do($_) for 'CREATE SEQUENCE r55_seq', 'CREATE TABLE r55_t (id INTEGER PRIMARY KEY, org VARCHAR NOT NULL, note VARCHAR)',
        q{INSERT INTO r55_t SELECT i, 't1', 'n' FROM range(1, 5001) tbl(i)},
        q{CREATE VIEW r55_seq_v AS SELECT id, org, CAST(nextval('r55_seq') AS VARCHAR) AS note FROM r55_t};
    my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
    my $e = Selecto::Engine->new(domain => $domain->('r55_seq_v'), adapter => $adapter)->with_scope(tenant => 't1');
    my $query = $e->query->select('id', 'note')->order_by('id');
    ok(!eval { $e->all($query); 1 } && $read_only->($@), 'a read through a view using nextval refuses');
    ok(!eval { my $s = $e->stream($query); while ($s->next) { } 1 } && $read_only->($@), 'so does a stream');
    is(($dbh->selectrow_array(q{SELECT nextval('r55_seq')}))[0], 1, 'and the sequence did not move');
    my $plain = Selecto::Engine->new(domain => $domain->('r55_t'), adapter => $adapter)->with_scope(tenant => 't1');
    my $s = $plain->stream($plain->query->select('id')->order_by('id'));
    my $n = 0;
    $n++ while $s->next;
    is($n, 5000, 'a stream of several driver chunks reads to the end');
    # Nothing to wrap the read in here: see _read_transaction.
    $dbh->do('BEGIN');
    is(scalar(@{$plain->all($plain->query->select('id'))->{rows}}), 5000, 'in a raw host transaction the read runs');
    $dbh->do(q{INSERT INTO r55_t VALUES (9001, 't1', 'n')});
    $dbh->do('COMMIT');
    is(($dbh->selectrow_array('SELECT count(*) FROM r55_t'))[0], 5001, 'and the host transaction stayed whole');
    $dbh->begin_work;
    is(scalar(@{$plain->all($plain->query->select('id'))->{rows}}), 5001, 'under begin_work too');
    $dbh->rollback;
    $dbh->disconnect;
};

done_testing;
