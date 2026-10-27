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

# PostgreSQL findings of the round-3 review (R2, R8, R9, R10, R13, item 58):
# - every relation a statement names, including a through-association
#   bridge inside a parenthesised join and an INSERT target, is checked for
#   temp shadows (the list is recorded while compiling);
# - a deferred constraint trigger cannot change the session after the
#   write's own check: in Selecto's own transaction it is fired before
#   COMMIT and checked, in a host's transaction the write is refused;
# - post-image re-reads name the written rows by (tableoid, ctid), so a key
#   renumbering trigger with a decoy cannot pass and keys of any type work;
# - guarded inserts keep ordinary row triggers (updated_at, audit) and are
#   re-read under their full guard;
# - catalog checks resolve their operators in pg_catalog only.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $connect = sub {
    my $dbh = TestPostgreSQL->connect;
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
};
my $x = 'Selecto::Expression';
my $admin = $connect->();
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

subtest 'R2: a temp relation shadowing a through-association bridge is refused' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3b_items, r3b_link, r3b_acc CASCADE',
        'CREATE TABLE r3b_items (id INT PRIMARY KEY, org_key TEXT)', q{INSERT INTO r3b_items VALUES (1, 't1'), (2, 't2')},
        'CREATE TABLE r3b_acc (id INT PRIMARY KEY, label TEXT)', q{INSERT INTO r3b_acc VALUES (10, 't1-acc'), (20, 't2-SECRET')},
        'CREATE TABLE r3b_link (item_id INT, acc_id INT)', 'INSERT INTO r3b_link VALUES (1, 10), (2, 20)';
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Bridge',
        source => {source_table => 'r3b_items', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}},
            associations => {accs => {queryable => 'acc', owner_key => 'id', related_key => 'id', cardinality => 'many',
                through => {table => 'r3b_link', owner_key => 'item_id', related_key => 'acc_id'}}}},
        schemas => {acc => {source_table => 'r3b_acc', primary_key => 'id', fields => [qw(id label)],
            columns => {id => {type => 'integer'}, label => {type => 'string'}}, associations => {}}},
        joins => {accs => {type => 'left'}}});
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)))
        ->with_scope(tenant => 't1');
    my $query = $engine->query->select('id', 'accs.label')->order_by('id');
    my $statement = $engine->compile($query);
    is_deeply($statement->can("relations") ? $statement->relations : undef, [sort '"r3b_acc"', '"r3b_items"', '"r3b_link"'],
        'the compiled statement records the bridge among its relations');
    my $flat = sub { join ',', map { $_->[1] // 'NULL' } @{$engine->all($query)->{rows}} };
    my $stream = sub { my $s = $engine->stream($query); my @l; while (my $r = $s->next) { push @l, $r->[1] } join ',', @l };
    is($outcome->($flat), 'applied t1-acc', 'control: the bridge read');
    $dbh->do('CREATE TEMP VIEW r3b_link AS SELECT 1 AS item_id, acc_id FROM public.r3b_link');
    is($outcome->($flat), 'query_rule_not_evaluable/temporary_shadow', 'a read through a shadowed bridge is refused');
    is($outcome->($stream), 'query_rule_not_evaluable/temporary_shadow', 'so is a stream');
    $dbh->do('DROP VIEW pg_temp.r3b_link');
    is($outcome->($flat), 'applied t1-acc', 'and reads again once the shadow is gone');
};

subtest 'R10: a temp table shadowing an INSERT target is refused' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3i CASCADE',
        'CREATE TABLE r3i (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)', q{INSERT INTO r3i VALUES (1, 't1', 'a')};
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(domain => $writable->('r3i', 'id', id => 'integer', org_key => 'string', note => 'string'),
        adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
    my $insert = sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'r3i',
        assignments => {id => $_[0], org_key => 't1', note => 'n'}))->affected_rows };
    $dbh->do('CREATE TEMP TABLE r3i (id INT PRIMARY KEY, org_key TEXT, note TEXT)');
    is($outcome->(sub { $insert->(10) }), 'query_rule_not_evaluable/temporary_shadow', 'the insert is refused');
    is($rows->($dbh, 'SELECT count(*) FROM pg_temp.r3i'), '0', 'nothing went into the temp table');
    $dbh->do('DROP TABLE pg_temp.r3i');
    is($outcome->(sub { $insert->(11) }), 'applied 1', 'an unshadowed insert applies');
};

subtest 'R8: a deferred constraint trigger cannot change the session after the check' => sub {
    $admin->do($_) for 'DROP SCHEMA IF EXISTS r3d_evil CASCADE', 'DROP TABLE IF EXISTS r3d_w, r3d_items CASCADE',
        'DROP FUNCTION IF EXISTS r3d_f() CASCADE',
        'CREATE TABLE r3d_items (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)',
        q{INSERT INTO r3d_items VALUES (1, 't1', 'mine'), (2, 't2', 'SECRET')},
        'CREATE SCHEMA r3d_evil', q{CREATE VIEW r3d_evil.r3d_items AS SELECT id, 't1'::text AS org_key, note FROM public.r3d_items},
        'CREATE TABLE r3d_w (id INT PRIMARY KEY, note TEXT)', q{INSERT INTO r3d_w VALUES (1, 'n')},
        q{CREATE FUNCTION r3d_f() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
            PERFORM set_config('search_path', 'r3d_evil,public', false); RETURN NULL; END $$},
        'CREATE CONSTRAINT TRIGGER r3d_t AFTER UPDATE ON r3d_w DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION r3d_f()';
    my $reads = Selecto::Domain->parse({schema_version => 1, name => 'R',
        source => {source_table => 'r3d_items', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}});
    for my $mode (qw(own host)) {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
        my $writer = Selecto::Engine->new(domain => $writable->('r3d_w', 'id', id => 'integer', note => 'string'), adapter => $adapter);
        my $reader = Selecto::Engine->new(domain => $reads, adapter => $adapter)->with_scope(tenant => 't1');
        my $read = sub { join ',', map { $_->[1] } @{$reader->all($reader->query->select('id', 'note')->order_by('id'))->{rows}} };
        $dbh->begin_work if $mode eq 'host';
        is($outcome->(sub { $writer->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3d_w',
            assignments => {note => 'u'}, predicate => $x->eq('id', 1)))->affected_rows }),
            $mode eq 'own' ? 'query_rule_violation/session_state_changed' : 'query_rule_not_evaluable/deferred_trigger',
            "$mode transaction: the unscoped write is refused");
        $dbh->commit if $mode eq 'host';
        is($rows->($dbh, 'SHOW search_path'), '"$user", public', "$mode transaction: the session keeps its search_path");
        is($outcome->($read), 'applied mine', "$mode transaction: the next tenant read sees only its own rows");
        is($rows->($admin, 'SELECT note FROM r3d_w'), 'n', "$mode transaction: and the write was rolled back");
    }
    $admin->do($_) for 'DROP TABLE r3d_w CASCADE', 'DROP FUNCTION r3d_f() CASCADE';
};

subtest 'R9: re-reads by (tableoid, ctid): a renumbering trigger cannot hide a moved row; keys of any type work' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3k, r3k_p, r3k_q, r3k_c CASCADE', 'DROP FUNCTION IF EXISTS r3k_b() CASCADE',
        'DROP FUNCTION IF EXISTS r3k_a() CASCADE', 'CREATE EXTENSION IF NOT EXISTS citext',
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
        'CREATE TABLE r3k_c (id citext PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT)', q{INSERT INTO r3k_c VALUES ('a', 't1', 'x', 'n')};
    my %columns = (org_key => 'string', name => 'string', note => 'string');
    my $update = sub {
        my ($table, $key, $types, $note) = @_;
        my $engine = Selecto::Engine->new(domain => $writable->($table, $key, %columns, %$types),
            adapter => Selecto->adapter(postgresql => (dbh => $connect->())));
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
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)))
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
        adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
    is($outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3o',
        assignments => {note => 'u'}, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1')))->affected_rows }),
        'write_capability_missing', 'the statement-level trigger is still seen and refused');
    is($rows->($admin, 'SELECT note FROM r3o'), 'n', 'nothing changed');
    $admin->do($_) for 'DROP TABLE r3o CASCADE', 'DROP FUNCTION r3o_stmt() CASCADE', 'DROP SCHEMA r3o_evil CASCADE';
};

done_testing;
