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
use Selecto::Write ();
use Selecto::PostgreSQL ();
use lib 't/lib';
use TestPostgreSQL ();

# R64: between fetches, session code run by anything else on the connection can
# close a bounded stream's cursor and declare another of the same name. A plant
# reached from a view or a trigger made a t1 stream return t2's rows. Each batch
# verifies its cursor before any of its rows is handed out.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $x = 'Selecto::Expression';
my @clean = ('DROP VIEW IF EXISTS r64_v, r64_short, r64_decoy', 'DROP TABLE IF EXISTS r64_t, r64_audit CASCADE', 'DROP FUNCTION IF EXISTS public.r64_swap(varchar) CASCADE',
    'DROP FUNCTION IF EXISTS public.r64_trigger() CASCADE', 'DROP FUNCTION IF EXISTS public.r64_short_swap(varchar) CASCADE',
    'DROP FUNCTION IF EXISTS public.r64_decoy(varchar) CASCADE', 'DROP FUNCTION IF EXISTS public.r64_tick() CASCADE', 'DROP SEQUENCE IF EXISTS r64_ticks');
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE TABLE r64_t (id INT PRIMARY KEY, org TEXT NOT NULL, note TEXT, slug VARCHAR(20))',
    q{INSERT INTO r64_t SELECT g, 't1', 'n', 'Slug' FROM generate_series(1, 10) g},
    q{INSERT INTO r64_t SELECT g, 't2', 'SECRET', 'Slug' FROM generate_series(11, 20) g},
    'CREATE TABLE r64_audit (id INT, slug TEXT)',
    q{CREATE FUNCTION public.r64_swap(s varchar) RETURNS text LANGUAGE plpgsql AS $$ DECLARE nm text; BEGIN
        FOR nm IN SELECT name FROM pg_catalog.pg_cursors LOOP
          BEGIN
            EXECUTE format('CLOSE %I', nm);
            EXECUTE format('DECLARE %I NO SCROLL CURSOR FOR SELECT id, org, note FROM public.r64_t WHERE org = ''t2'' ORDER BY id', nm);
          EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;
        RETURN s; END $$},
    'CREATE VIEW r64_v AS SELECT id, org, public.r64_swap(slug) AS note FROM r64_t',
    q{CREATE FUNCTION public.r64_trigger() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO r64_audit VALUES (NEW.id, public.r64_swap(NEW.slug)); RETURN NULL; END $$},
    'CREATE TRIGGER r64_tg AFTER UPDATE ON r64_t FOR EACH ROW EXECUTE FUNCTION public.r64_trigger()',
    'CREATE SEQUENCE r64_ticks',
    q{CREATE FUNCTION public.r64_tick() RETURNS bigint LANGUAGE sql AS $$ SELECT nextval('r64_ticks') $$},
    # A replacement that finishes in one batch, and counts being fetched.
    q{CREATE FUNCTION public.r64_short_swap(s varchar) RETURNS text LANGUAGE plpgsql AS $$ DECLARE nm text; BEGIN
        FOR nm IN SELECT name FROM pg_catalog.pg_cursors WHERE name LIKE 'selecto_stream%' LOOP
          BEGIN
            EXECUTE format('CLOSE %I', nm);
            EXECUTE format('DECLARE %I NO SCROLL CURSOR FOR SELECT 11, ''t2''::text, public.r64_tick()', nm);
          EXCEPTION WHEN OTHERS THEN NULL; END;
        END LOOP;
        RETURN s; END $$},
    'CREATE VIEW r64_short AS SELECT id, org, public.r64_short_swap(slug) AS note FROM r64_t',
    # A same-text decoy opened during the stream's own statement.
    q{CREATE FUNCTION public.r64_decoy(s varchar) RETURNS text LANGUAGE plpgsql AS $$ DECLARE d refcursor; q text; BEGIN
        SELECT c.statement INTO q FROM pg_catalog.pg_cursors c WHERE c.name LIKE 'selecto_stream%' LIMIT 1;
        IF q IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_cursors c WHERE c.name LIKE 'decoy%') THEN
          d := 'decoy_' || pg_catalog.txid_current()::text;
          BEGIN OPEN d FOR EXECUTE regexp_replace(q, '^DECLARE .* FOR ', '') USING 't1'::text; EXCEPTION WHEN OTHERS THEN NULL; END;
        END IF;
        RETURN s; END $$},
    'CREATE VIEW r64_decoy AS SELECT id, org, public.r64_decoy(slug) AS note FROM r64_t';
my $domain = sub {
    my ($table) = @_;
    my @f = qw(id org note);
    Selecto::Domain->parse({schema_version => 1, name => "D$table", source => {source_table => $table, primary_key => 'id', tenant_field => 'org', fields => \@f,
        columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
};
my $case = sub {
    my ($name, $between, %options) = @_;
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO error');
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    my $t = Selecto::Engine->new(domain => $domain->('r64_t'), adapter => $adapter)->with_scope(tenant => 't1');
    my $v = Selecto::Engine->new(domain => $domain->('r64_v'), adapter => $adapter)->with_scope(tenant => 't1');
    $dbh->begin_work if $options{transaction};
    my $stream = $t->stream($t->query->select('id', 'org')->order_by('id'), bounded => 1, fetch_size => 2);
    my @rows = ($stream->next, $stream->next);
    eval { $between->($t, $v, $dbh) };
    my $error;
    my $ok = eval { while (my $row = $stream->next) { push @rows, $row } 1 };
    $error = $@ unless $ok;
    is(scalar(grep { $_->[1] ne 't1' } @rows), 0, "$name: no other tenant's row reaches the caller");
    ok(blessed($error) && $error->code eq 'query_rule_not_evaluable' && $error->details->{reason} eq 'stream_cursor_replaced', "$name: the stream refuses, typed");
    is(eval { ($dbh->selectrow_array('SELECT 1'))[0] }, 1, "$name: the handle still works") unless $options{transaction};
    if ($options{transaction}) { eval { $dbh->rollback } }
    $dbh->disconnect;
};
my $read = sub { my ($t, $v) = @_; $v->all($v->query->select('id')) };
my $host = sub { $_[2]->selectrow_array('SELECT count(*) FROM public.r64_v') };
my $write = sub { my ($t) = @_; $t->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r64_t', assignments => {note => 'seen'},
    predicate => $x->eq('id', 1), expected_count => undef)) };
$case->('a read between fetches', $read);
$case->('a host select between fetches', $host);
$case->('a read in a host transaction', $read, transaction => 1);
$case->('a host select in a host transaction', $host, transaction => 1);
$case->('a guarded write in a host transaction', $write, transaction => 1);

# A replaced cursor is never fetched: the check runs before each FETCH, so a
# replacement that would finish in one batch is not read at all.
{
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO error');
    my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
    my $t = Selecto::Engine->new(domain => $domain->('r64_t'), adapter => $adapter)->with_scope(tenant => 't1');
    $dbh->begin_work;
    my $stream = $t->stream($t->query->select('id', 'org', 'note')->order_by('id'), bounded => 1, fetch_size => 2);
    my @rows = ($stream->next, $stream->next);
    $dbh->selectrow_array('SELECT count(*) FROM public.r64_short');
    my $ok = eval { while (my $row = $stream->next) { push @rows, $row } 1 };
    my $error = $@;
    ok(!$ok && $error->details->{reason} eq 'stream_cursor_replaced', 'a one-batch replacement is refused');
    is(scalar(grep { $_->[1] ne 't1' } @rows), 0, 'and none of its rows arrives');
    eval { $dbh->rollback };
    is($admin->selectrow_array(q{SELECT last_value FROM r64_ticks WHERE is_called}) // 0, 0, 'it was never fetched');
    $dbh->disconnect;
}

# A same-text decoy opened during the stream's own statement changes nothing:
# the cursor is known by the name Selecto declared, not by searching for it.
{
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO error');
    my $v = Selecto::Engine->new(domain => $domain->('r64_decoy'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1');
    $dbh->begin_work;
    my $stream = $v->stream($v->query->select('id', 'org')->order_by('id'), bounded => 1, fetch_size => 2);
    my @rows = ($stream->next, $stream->next);
    $dbh->selectrow_array('SELECT count(*) FROM public.r64_v');
    my $ok = eval { while (my $row = $stream->next) { push @rows, $row } 1 };
    my $error = $@;
    ok(!$ok && $error->details->{reason} eq 'stream_cursor_replaced', 'a real cursor swapped beside a decoy is still refused');
    is(scalar(grep { $_->[1] ne 't1' } @rows), 0, 'and no other tenant arrives');
    eval { $dbh->rollback };
    $dbh->disconnect;
}

# A name declared ahead of the stream fails closed: the stream does not open.
{
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain->('r64_t'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1');
    no warnings 'redefine';
    local *Selecto::SQL::_savepoint_name = sub { 'selecto_stream_taken' };
    $dbh->begin_work;
    $dbh->do(q{DECLARE selecto_stream_taken NO SCROLL CURSOR FOR SELECT 11, 't2'});
    my $stream = eval { $e->stream($e->query->select('id', 'org')->order_by('id'), bounded => 1, fetch_size => 2) };
    ok(!$stream, 'a pre-declared cursor name refuses the stream');
    eval { $dbh->rollback };
    $dbh->disconnect;
}

# Untouched streams are unchanged: bounded, in and out of a host transaction.
for my $transaction (0, 1) {
    my $dbh = TestPostgreSQL->connect;
    my $e = Selecto::Engine->new(domain => $domain->('r64_t'), adapter => Selecto::PostgreSQL->new(dbh => $dbh))->with_scope(tenant => 't1');
    $dbh->begin_work if $transaction;
    my $stream = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 3);
    my @ids; while (my $row = $stream->next) { push @ids, $row->[0] }
    is(join(',', @ids), '1,2,3,4,5,6,7,8,9,10', "an untouched stream reads to the end (transaction $transaction)");
    $dbh->rollback if $transaction;
    $dbh->disconnect;
}

done_testing;
