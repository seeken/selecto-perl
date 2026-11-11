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
use lib 't/lib';
use TestPostgreSQL ();

# PostgreSQL findings of the round-3 review (R9, R13, R17, R33, item 58):
# - post-image re-reads name the written rows by (tableoid, ctid), so a key
#   renumbering trigger with a decoy cannot pass and keys of any type work;
# - guarded inserts keep ordinary row triggers (updated_at, audit) and are
#   re-read under their full guard;
# - catalog checks resolve their operators in pg_catalog only;
# - deferred foreign keys keep their deferral, and a CTE named like a real
#   relation never hides it.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $connect = sub {
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
};
my $x = 'Selecto::Expression';
my $admin = $connect->();
END {
    eval {
        $admin->do($_) for 'DROP SCHEMA IF EXISTS r3d_evil CASCADE', 'DROP TABLE IF EXISTS r3b_acc, r3b_items, r3b_link, r3d_items, r3d_w, r3i CASCADE',
            map { "DROP FUNCTION IF EXISTS public.$_ CASCADE" } qw(r3k_a r3k_b r3t_aud r3t_upd);
    } if $admin;
}
my $outcome = sub {
    my ($work) = @_;
    my $value = eval { $work->() };
    return 'applied' . (defined($value) && !ref($value) ? " $value" : '') unless $@;
    my $error = $@;
    return blessed($error) && $error->can('code')
        ? $error->code . (ref($error->details) eq 'HASH' && $error->details->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
};
my $rows = sub { my ($dbh, $sql) = @_; join ' ', map { join ':', map { $_ // 'NULL' } @$_ } @{$dbh->selectall_arrayref($sql)} };
my $writable = sub {
    my ($table, $key, %columns) = @_;
    return Selecto::Domain->parse({schema_version => 1, name => 'R3',
        source => {source_table => $table, primary_key => $key, fields => [sort keys %columns],
            columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}, update => {enabled => 1}},
            fields => {map { ($_ => {insertable => 1, ($_ eq 'note' ? (updatable => 1) : ())}) } keys %columns}}});
};

# citext in its own schema, off the search path, unless it is installed
# already (then it is left alone).
my ($r3k_ext, $ci);
# Remove what this file installed even if it dies part-way, so a later
# run never mistakes a leftover for a preinstalled extension.
END { eval { $admin->do($_) for 'DROP EXTENSION IF EXISTS citext CASCADE', 'DROP SCHEMA IF EXISTS r3kext CASCADE' } if $r3k_ext }
subtest 'R9: re-reads by (tableoid, ctid): a renumbering trigger cannot hide a moved row; keys of any type work' => sub {
    $r3k_ext = !($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
    $admin->do($_) for $r3k_ext ? ('CREATE SCHEMA IF NOT EXISTS r3kext', 'CREATE EXTENSION citext SCHEMA r3kext') : ();
    $ci = qq{"$_".citext} for $admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'});
    $admin->do($_) for 'DROP TABLE IF EXISTS r3k, r3k_p, r3k_q, r3k_c CASCADE', 'DROP FUNCTION IF EXISTS r3k_b() CASCADE',
        'DROP FUNCTION IF EXISTS r3k_a() CASCADE',
        'CREATE TABLE r3k (id INT PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT)', q{INSERT INTO r3k VALUES (1, 't1', 'x', 'n')},
        q{CREATE FUNCTION r3k_b() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
            IF NEW.note = 'move' THEN NEW.id := 99; NEW.org_key := 't2'; END IF; RETURN NEW; END $$},
        q{CREATE FUNCTION r3k_a() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
            IF NEW.note = 'move' THEN INSERT INTO r3k VALUES (OLD.id, 't1', 'decoy', 'd'); END IF; RETURN NULL; END $$},
        'CREATE TRIGGER r3k_b BEFORE UPDATE ON r3k FOR EACH ROW EXECUTE FUNCTION r3k_b()',
        'CREATE TRIGGER r3k_a AFTER UPDATE ON r3k FOR EACH ROW EXECUTE FUNCTION r3k_a()',
        'CREATE TABLE r3k_p (id INT NOT NULL, created_at TIMESTAMPTZ NOT NULL, org_key TEXT NOT NULL, name TEXT, note TEXT,'
            . ' PRIMARY KEY (id, created_at)) PARTITION BY RANGE (created_at)',
        q{CREATE TABLE r3k_p_2024 PARTITION OF r3k_p FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')},
        q{INSERT INTO r3k_p VALUES (1, '2024-05-01', 't1', 'x', 'n')},
        'CREATE TABLE r3k_q (account_id INT, period DATE, org_key TEXT NOT NULL, name TEXT, note TEXT, PRIMARY KEY (account_id, period))',
        q{INSERT INTO r3k_q VALUES (1, '2024-01-01', 't1', 'x', 'n')},
        "CREATE TABLE r3k_c (id $ci PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT)", q{INSERT INTO r3k_c VALUES ('a', 't1', 'x', 'n')};
    my %columns = (org_key => 'string', name => 'string', note => 'string');
    my $update = sub {
        my ($table, $key, $types, $note) = @_;
        my $engine = Selecto::Engine->new(domain => $writable->($table, $key, %columns, %$types),
            adapter => Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $connect->())));
        return $outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => $table,
            assignments => {note => $note}, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1')))->affected_rows });
    };
    is($update->('r3k', 'id', {id => 'integer'}, 'move'), 'query_rule_violation', 'a row renumbered out of scope behind a decoy is refused');
    is($rows->($admin, 'SELECT id, org_key, name FROM r3k ORDER BY id'), '1:t1:x', 'and rolled back, decoy included');
    is($update->('r3k_p', ['id', 'created_at'], {id => 'integer', created_at => 'utc_datetime'}, 'kept'), 'applied 1',
        'a time-partitioned (id, created_at) key applies');
    is($update->('r3k_p', 'id', {id => 'integer', created_at => 'utc_datetime'}, 'kept'), 'applied 1',
        'a non-unique declared key applies');
    is($update->('r3k_q', ['account_id', 'period'], {account_id => 'integer', period => 'date'}, 'kept'), 'applied 1',
        'a composite (int, date) key applies');
    is($update->('r3k_c', 'id', {id => 'string'}, 'kept'), 'applied 1', 'a citext key applies');
    $admin->do('DROP TABLE r3k, r3k_p, r3k_q, r3k_c CASCADE');
};

subtest 'R13: guarded inserts keep ordinary row triggers' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3t, r3t_audit CASCADE', 'DROP FUNCTION IF EXISTS r3t_upd() CASCADE',
        'DROP FUNCTION IF EXISTS r3t_aud() CASCADE',
        'CREATE TABLE r3t (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT, updated_at TIMESTAMPTZ)',
        'CREATE TABLE r3t_audit (id SERIAL PRIMARY KEY, row_id INT)',
        q{CREATE FUNCTION r3t_upd() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := now(); RETURN NEW; END $$},
        q{CREATE FUNCTION r3t_aud() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO r3t_audit (row_id) VALUES (NEW.id); RETURN NULL; END $$},
        'CREATE TRIGGER r3t_upd BEFORE INSERT OR UPDATE ON r3t FOR EACH ROW EXECUTE FUNCTION r3t_upd()',
        'CREATE TRIGGER r3t_aud AFTER INSERT OR UPDATE ON r3t FOR EACH ROW EXECUTE FUNCTION r3t_aud()';
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'T',
        source => {source_table => 'r3t', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}}, fields => {id => {insertable => 1}, org_key => {insertable => 1}, note => {insertable => 1}}}});
    for my $mode (qw(own host)) {
        my $dbh = $connect->();
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh)))
            ->with_scope(tenant => 't1');
        my $id = $mode eq 'own' ? 1 : 2;
        $dbh->begin_work if $mode eq 'host';
        is($outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'r3t',
            assignments => {id => $id, org_key => 't1', note => 'i'}))->affected_rows }), 'applied 1',
            "$mode transaction: a tenant-guarded insert on a table with updated_at and audit triggers applies");
        $dbh->commit if $mode eq 'host';
        is($rows->($admin, "SELECT org_key, updated_at IS NOT NULL FROM r3t WHERE id = $id"), 't1:1', "$mode transaction: the trigger ran");
    }
    is($rows->($admin, 'SELECT row_id FROM r3t_audit ORDER BY row_id'), '1 2', 'and audited both rows');
    $admin->do('DROP TABLE r3t, r3t_audit CASCADE');
};

subtest 'item 58: catalog checks resolve operators in pg_catalog only' => sub {
    $admin->do($_) for 'DROP SCHEMA IF EXISTS r3o_evil CASCADE', 'DROP TABLE IF EXISTS r3o CASCADE',
        'DROP FUNCTION IF EXISTS r3o_stmt() CASCADE', 'CREATE SCHEMA r3o_evil',
        q{CREATE FUNCTION r3o_evil.never(a "char", b "char") RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT false'},
        q{CREATE OPERATOR r3o_evil.<> (LEFTARG = "char", RIGHTARG = "char", FUNCTION = r3o_evil.never)},
        'CREATE TABLE r3o (id INT PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT)', q{INSERT INTO r3o VALUES (1, 't1', 'x', 'n')},
        q{CREATE FUNCTION r3o_stmt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$},
        'CREATE TRIGGER r3o_stmt AFTER UPDATE ON r3o FOR EACH STATEMENT EXECUTE FUNCTION r3o_stmt()';
    my $dbh = $connect->();
    # An operator schema ahead of pg_catalog on the host's own search path.
    $dbh->do('SET search_path TO r3o_evil, pg_catalog, public');
    my $engine = Selecto::Engine->new(domain => $writable->('r3o', 'id', id => 'integer', org_key => 'string', name => 'string', note => 'string'),
        adapter => Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh)));
    is($outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3o',
        assignments => {note => 'u'}, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1')))->affected_rows }),
        'write_capability_missing', 'the statement-level trigger is still seen and refused');
    is($rows->($admin, 'SELECT note FROM r3o'), 'n', 'nothing changed');
    $admin->do($_) for 'DROP TABLE r3o CASCADE', 'DROP FUNCTION r3o_stmt() CASCADE', 'DROP SCHEMA r3o_evil CASCADE';
};

subtest 'R17: deferred foreign keys keep their deferral around Selecto writes' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3f_child, r3f_parent, r3f_w CASCADE',
        'CREATE TABLE r3f_parent (id INT PRIMARY KEY)',
        'CREATE TABLE r3f_child (id INT PRIMARY KEY, parent_id INT REFERENCES r3f_parent (id) DEFERRABLE INITIALLY DEFERRED)',
        'CREATE TABLE r3f_w (id INT PRIMARY KEY, note TEXT)', q{INSERT INTO r3f_w VALUES (1, 'n')};
    my $dbh = $connect->();
    my $writer = Selecto::Engine->new(domain => $writable->('r3f_w', 'id', id => 'integer', note => 'string'),
        adapter => Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh)));
    my $update = sub { $writer->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3f_w',
        assignments => {note => $_[0]}, predicate => $x->eq('id', 1)))->affected_rows };
    $dbh->begin_work;
    $dbh->do('INSERT INTO r3f_child VALUES (1, 7)');
    is($outcome->(sub { $update->('host') }), 'applied 1', 'a write in a host transaction with a pending deferred FK applies');
    $dbh->do('INSERT INTO r3f_parent VALUES (7)');
    ok(eval { $dbh->commit; 1 }, 'and the host commits once the parent exists');
    is($outcome->(sub { $update->('own') }), 'applied 1', 'a write in its own transaction applies with deferred FKs present');
    is($rows->($admin, 'SELECT note FROM r3f_w'), 'own', 'both writes applied');
    $admin->do('DROP TABLE r3f_child, r3f_parent, r3f_w CASCADE');
};
subtest 'R33: a CTE named like a real relation never hides it' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3c, r3c_other CASCADE',
        'CREATE TABLE r3c (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)', q{INSERT INTO r3c VALUES (1, 't1', 'mine'), (2, 't2', 'SECRET')},
        'CREATE TABLE r3c_other (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)', q{INSERT INTO r3c_other VALUES (2, 't1', 'decoy')};
    my $dbh = $connect->();
    my $adapter = Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh));
    my $parse = sub {
        my ($table) = @_;
        Selecto::Domain->parse({schema_version => 1, name => "D$table",
            source => {source_table => $table, primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key note)],
                columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
            schemas => {}, joins => {}});
    };
    my $engine = Selecto::Engine->new(domain => $parse->('r3c'), adapter => $adapter)->with_scope(tenant => 't1');
    my $query = eval { $engine->query->with_cte('r3c', $parse->('r3c_other'), Selecto::Query->new->select('id', 'org_key', 'note'),
        columns => [qw(id org_key note)])->select('id', 'note')->order_by('id') };
    if (!$query) {
        pass('a CTE may not take the root relation\'s name: ' . (blessed($@) ? $@->code : $@));
        return;
    }
    my $result = $outcome->(sub { join ',', map { "$_->[0]:$_->[1]" } @{$engine->all($query)->{rows}} });
    # Selecto refuses a query source named like a relation the domain reads;
    # either way the root never reads the CTE's rows.
    is($result, 'invalid_query', 'a CTE named like the root relation is refused, never read in its place');
    $admin->do('DROP TABLE r3c, r3c_other CASCADE');
};

done_testing;
