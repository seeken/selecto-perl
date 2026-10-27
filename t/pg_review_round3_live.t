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
    is_deeply($statement->can("relations") ? $statement->relations : undef, [sort 'public.r3b_acc', 'public.r3b_items', 'public.r3b_link'],
        'the compiled statement records the bridge among its relations, schema-qualified');
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
            'query_rule_not_evaluable/deferred_triggers',
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

subtest 'R14: a deferrable trigger created during the write cannot fire after the check' => sub {
    $admin->do($_) for 'DROP SCHEMA IF EXISTS r3m_evil CASCADE', 'DROP TABLE IF EXISTS r3m_w, r3m_audit, r3m_items CASCADE',
        'DROP FUNCTION IF EXISTS r3m_mk() CASCADE', 'DROP FUNCTION IF EXISTS r3m_evilf() CASCADE',
        'CREATE TABLE r3m_items (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)',
        q{INSERT INTO r3m_items VALUES (1, 't1', 'mine'), (2, 't2', 'SECRET')},
        'CREATE SCHEMA r3m_evil', q{CREATE VIEW r3m_evil.r3m_items AS SELECT id, 't1'::text AS org_key, note FROM public.r3m_items},
        'CREATE TABLE r3m_audit (id SERIAL PRIMARY KEY, item INT)',
        'CREATE TABLE r3m_w (id INT PRIMARY KEY, note TEXT)', q{INSERT INTO r3m_w VALUES (1, 'n')},
        q{CREATE FUNCTION r3m_evilf() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
            PERFORM set_config('search_path', 'r3m_evil,public', false); RETURN NULL; END $$},
        q{CREATE FUNCTION r3m_mk() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'r3m_def') THEN
              EXECUTE 'CREATE CONSTRAINT TRIGGER r3m_def AFTER INSERT ON public.r3m_audit DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION r3m_evilf()';
            END IF;
            INSERT INTO public.r3m_audit (item) VALUES (NEW.id); RETURN NEW; END $$},
        'CREATE TRIGGER r3m_a AFTER UPDATE ON r3m_w FOR EACH ROW EXECUTE FUNCTION r3m_mk()';
    my $reads = Selecto::Domain->parse({schema_version => 1, name => 'R',
        source => {source_table => 'r3m_items', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}});
    for my $mode (qw(own host)) {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
        my $writer = Selecto::Engine->new(domain => $writable->('r3m_w', 'id', id => 'integer', note => 'string'), adapter => $adapter);
        my $reader = Selecto::Engine->new(domain => $reads, adapter => $adapter)->with_scope(tenant => 't1');
        my $read = sub { join ',', map { $_->[1] } @{$reader->all($reader->query->select('id', 'note')->order_by('id'))->{rows}} };
        $dbh->begin_work if $mode eq 'host';
        my $result = $outcome->(sub { $writer->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3m_w',
            assignments => {note => 'u'}, predicate => $x->eq('id', 1)))->affected_rows });
        like($result, qr{\Aquery_rule_not_evaluable/deferred_triggers\z},
            "$mode transaction: the write is refused ($result)");
        $dbh->commit if $mode eq 'host';
        is($rows->($dbh, 'SHOW search_path'), '"$user", public', "$mode transaction: the session keeps its search_path");
        is($outcome->($read), 'applied mine', "$mode transaction: the next tenant read sees only its own rows");
        is($rows->($admin, 'SELECT note FROM r3m_w'), 'n', "$mode transaction: and the write was rolled back");
        is($rows->($admin, q{SELECT count(*) FROM pg_catalog.pg_trigger WHERE tgname = 'r3m_def'}), '0',
            "$mode transaction: the trigger the write created was rolled back with it");
    }
    $admin->do($_) for 'DROP TABLE r3m_w, r3m_audit, r3m_items CASCADE', 'DROP SCHEMA r3m_evil CASCADE',
        'DROP FUNCTION r3m_mk() CASCADE', 'DROP FUNCTION r3m_evilf() CASCADE';
};

subtest 'R17: deferred foreign keys keep their deferral around Selecto writes' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3f_child, r3f_parent, r3f_w CASCADE',
        'CREATE TABLE r3f_parent (id INT PRIMARY KEY)',
        'CREATE TABLE r3f_child (id INT PRIMARY KEY, parent_id INT REFERENCES r3f_parent (id) DEFERRABLE INITIALLY DEFERRED)',
        'CREATE TABLE r3f_w (id INT PRIMARY KEY, note TEXT)', q{INSERT INTO r3f_w VALUES (1, 'n')};
    my $dbh = $connect->();
    my $writer = Selecto::Engine->new(domain => $writable->('r3f_w', 'id', id => 'integer', note => 'string'),
        adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
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
subtest 'R29/R30: relations resolve by the reset search_path; search_path is pinned for every statement' => sub {
    $admin->do($_) for 'DROP SCHEMA IF EXISTS r3q_evil CASCADE', 'DROP TABLE IF EXISTS r3q CASCADE',
        'CREATE TABLE r3q (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)',
        q{INSERT INTO r3q VALUES (1, 't1', 'mine'), (2, 't2', 'SECRET')},
        'CREATE SCHEMA r3q_evil', q{CREATE VIEW r3q_evil.r3q AS SELECT id, 't1'::text AS org_key, note FROM public.r3q},
        q{CREATE FUNCTION r3q_evil.yes(text, text) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true'},
        'CREATE OPERATOR r3q_evil.= (LEFTARG = text, RIGHTARG = text, FUNCTION = r3q_evil.yes)';
    my $dbh = $connect->();
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    my $tenanted = Selecto::Domain->parse({schema_version => 1, name => 'R3T',
        source => {source_table => 'r3q', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}}}});
    my $writer = Selecto::Engine->new(domain => $tenanted, adapter => $adapter)->with_scope(tenant => 't1');
    my $update = sub { $writer->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3q',
        assignments => {note => $_[0]}, predicate => $x->eq('id', $_[1] // 1)))->affected_rows };
    my $reads = Selecto::Domain->parse({schema_version => 1, name => 'R',
        source => {source_table => 'r3q', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}});
    my $reader = Selecto::Engine->new(domain => $reads, adapter => $adapter)->with_scope(tenant => 't1');
    my $query = $reader->query->select('id', 'note')->order_by('id');
    my $ids = sub { join ',', map { $_->[0] } @{$reader->all($query)->{rows}} };
    like($reader->compile($query)->sql, qr/ FROM public\.r3q AS /, 'a read names its relation by schema');
    like($adapter->preview_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3q',
        assignments => {note => 'x'}, predicate => $x->eq('id', 1)))->{sql}, qr/\AUPDATE public\.r3q SET /,
        'a write names its target by schema');
    is($outcome->($ids), 'applied 1', 'control: the tenant read');
    # A session-level switch made before Selecto's call: the relation still
    # resolves through the reset search_path, and the evil = operator ahead
    # of pg_catalog cannot answer the tenant compare.
    $dbh->do('SET search_path TO r3q_evil, pg_catalog, public');
    is($outcome->($ids), 'applied 1', 'a persisted search_path switch redirects neither relation nor operator');
    like($outcome->(sub { $update->('t2-row', 2) }), qr/\A(?:applied 0|cardinality_mismatch)/, 'nor lets the tenant write reach another tenant');
    is($rows->($admin, 'SELECT note FROM r3q WHERE id = 2'), 'SECRET', "the other tenant's row is unchanged");
    is($rows->($dbh, 'SHOW search_path'), 'r3q_evil, pg_catalog, public', "and the host's search_path is restored after each call");
    $dbh->do('RESET search_path');
    for my $level ('REPEATABLE READ', 'SERIALIZABLE') {
        $dbh->begin_work;
        $dbh->do("SET TRANSACTION ISOLATION LEVEL $level");
        my $plain = Selecto::Engine->new(domain => $writable->('r3q', 'id', id => 'integer', org_key => 'string', note => 'string'),
            adapter => $adapter);
        is($outcome->(sub { $plain->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3q',
            assignments => {note => 'rr'}, predicate => $x->eq('id', 1)))->affected_rows }), 'applied 1',
            "an unscoped write in a host $level transaction applies (no R19 isolation refusal)");
        $dbh->rollback;
    }
    $admin->do($_) for 'DROP SCHEMA r3q_evil CASCADE', 'DROP TABLE r3q CASCADE';
};

subtest 'R32: internal deferrable rechecks count unless they run only pg_catalog code' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3u_w, r3u_parent, r3u_child, r3u_x CASCADE',
        'DROP OPERATOR CLASS IF EXISTS r3u_ops USING btree CASCADE',
        'CREATE TABLE r3u_w (id INT PRIMARY KEY, note TEXT)', q{INSERT INTO r3u_w VALUES (1, 'n')},
        'CREATE TABLE r3u_parent (id INT PRIMARY KEY)',
        'CREATE TABLE r3u_child (id INT PRIMARY KEY, p INT REFERENCES r3u_parent (id) DEFERRABLE INITIALLY DEFERRED,'
            . ' k INT, UNIQUE (k) DEFERRABLE INITIALLY DEFERRED)';
    my $dbh = $connect->();
    my $writer = Selecto::Engine->new(domain => $writable->('r3u_w', 'id', id => 'integer', note => 'string'),
        adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
    my $update = sub { $writer->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r3u_w',
        assignments => {note => $_[0]}, predicate => $x->eq('id', 1)))->affected_rows };
    is($outcome->(sub { $update->('a') }), 'applied 1', 'deferred foreign keys and pg_catalog unique rechecks do not block writes');
    $admin->do($_) for q{CREATE OPERATOR CLASS r3u_ops FOR TYPE int4 USING btree AS OPERATOR 1 <, OPERATOR 2 <=,
            OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >, FUNCTION 1 btint4cmp(int4, int4)},
        'CREATE TABLE r3u_x (k INT, CONSTRAINT r3u_x_k EXCLUDE USING btree (k r3u_ops WITH =) DEFERRABLE INITIALLY DEFERRED)';
    is($outcome->(sub { $update->('b') }), 'query_rule_not_evaluable/deferred_triggers',
        'a deferrable exclusion recheck under a user operator class refuses writes');
    is($rows->($admin, 'SELECT note FROM r3u_w'), 'a', 'and the refused write left nothing');
    # R32a: an expression index, or a user collation, in a pg_catalog opclass
    # recheck can run user code too.
    $admin->do($_) for 'DROP TABLE r3u_x', 'DROP FUNCTION IF EXISTS r3u_f(int)',
        q{CREATE FUNCTION r3u_f(int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN $1; END $$},
        'CREATE TABLE r3u_x (k INT, CONSTRAINT r3u_x_k EXCLUDE USING btree ((r3u_f(k)) WITH =) DEFERRABLE INITIALLY DEFERRED)';
    is($outcome->(sub { $update->('c') }), 'query_rule_not_evaluable/deferred_triggers',
        'a deferrable exclusion recheck over a user function expression refuses writes');
    $admin->do($_) for 'DROP TABLE r3u_x', 'DROP COLLATION IF EXISTS r3u_c',
        q{CREATE COLLATION r3u_c (provider = icu, locale = 'und')},
        'CREATE TABLE r3u_x (k TEXT, CONSTRAINT r3u_x_k EXCLUDE USING btree ((k COLLATE r3u_c) WITH =) DEFERRABLE INITIALLY DEFERRED)';
    is($outcome->(sub { $update->('d') }), 'query_rule_not_evaluable/deferred_triggers',
        'and so does one under a user collation');
    $admin->do($_) for 'DROP TABLE r3u_x', 'DROP COLLATION r3u_c', 'DROP FUNCTION r3u_f(int)',
        'CREATE TABLE r3u_x (k INT)';
    $admin->do($_) for 'DROP TABLE r3u_w, r3u_parent, r3u_child, r3u_x CASCADE', 'DROP OPERATOR CLASS r3u_ops USING btree CASCADE';
};

subtest 'R33: a CTE named like a real relation never hides it' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3c, r3c_other CASCADE',
        'CREATE TABLE r3c (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)', q{INSERT INTO r3c VALUES (1, 't1', 'mine'), (2, 't2', 'SECRET')},
        'CREATE TABLE r3c_other (id INT PRIMARY KEY, org_key TEXT NOT NULL, note TEXT)', q{INSERT INTO r3c_other VALUES (2, 't1', 'decoy')};
    my $dbh = $connect->();
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
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

subtest 'R35: result-affecting settings are pinned for every statement' => sub {
    $admin->do($_) for 'DROP TABLE IF EXISTS r3z CASCADE',
        'CREATE TABLE r3z (id INT PRIMARY KEY, ts TIMESTAMPTZ NOT NULL, d DATE NOT NULL)',
        q{INSERT INTO r3z VALUES (1, '2024-01-02 00:00:00+00', '2024-03-01'), (2, '2023-12-31 12:00:00+00', '2024-01-02')};
    my $dbh = $connect->();
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Z',
        source => {source_table => 'r3z', primary_key => 'id', fields => [qw(id ts d)],
            columns => {id => {type => 'integer'}, ts => {type => 'utc_datetime'}, d => {type => 'date'}}, associations => {}},
        schemas => {}, joins => {}});
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    my $ids = sub {
        my ($required) = @_;
        my $engine = Selecto::Engine->new(domain => $domain->with_required_predicate($required), adapter => $adapter);
        return join ',', map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}};
    };
    # A setting that persisted before Selecto's call (a masked set_config in
    # an earlier trigger, say) cannot change what a scope literal means.
    $dbh->do(q{SET TimeZone = 'Pacific/Kiritimati'});
    is($outcome->(sub { $ids->($x->gte('ts', '2024-01-01 00:00:00')) }), 'applied 1', 'a timestamptz scope literal is read in UTC');
    $dbh->do(q{SET DateStyle = 'SQL, DMY'});
    is($outcome->(sub { $ids->($x->gte('d', '02/01/2024')) }), 'applied 1', 'a date scope literal is read MDY');
    is($rows->($dbh, 'SHOW TimeZone'), 'Pacific/Kiritimati', "the host's TimeZone is restored");
    is($rows->($dbh, 'SHOW DateStyle'), 'SQL, DMY', "and its DateStyle");
    $admin->do('DROP TABLE r3z CASCADE');
};

done_testing;
