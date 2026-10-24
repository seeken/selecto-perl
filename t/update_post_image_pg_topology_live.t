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

# PostgreSQL TW-09 post-image topologies beyond the written relation. A
# deferrable constraint trigger fires at commit, after the re-read, so one
# anywhere in the database is refused: on a leaf partition or an
# inheritance child (it fires for rows the update reaches through the
# parent), or on another table a row trigger writes to (an audit table whose
# deferred trigger rewrites the updated row). Statement-level update
# triggers and rules are refused on the relation and every partition or
# child below it. Ordinary partitioned updates, row triggers caught by the
# re-read, and deferrable foreign keys (internal triggers) keep working.
#
# Each case builds its tables inside a host transaction and rolls it back,
# so no other session sees its deferrable triggers; the audit case also runs
# once in a write-owned transaction to show the committed effect.
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('SET client_min_messages TO warning');
my $x = 'Selecto::Expression';
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

my $ops = {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}};
my $fields = {note => {updatable => 1}};
my $source = relation('selecto_topo', id => 'integer', org_key => 'string', name => 'string', note => 'string');
my %modes = (
    'engine tenant' => sub {
        (Selecto::Engine->new(adapter => $adapter, scope => {tenant => 't1'}, domain => Selecto::Domain->parse({schema_version => 1,
            name => 'Topo', source => {%$source, tenant_field => 'org_key'}, schemas => {}, joins => {},
            writes => {operations => $ops, fields => $fields}})), {})
    },
    'writes.scope' => sub {
        (Selecto::Engine->new(adapter => $adapter, scope => {tenant => 't1'}, domain => Selecto::Domain->parse({schema_version => 1,
            name => 'Topo', source => $source, schemas => {}, joins => {},
            writes => {operations => $ops, fields => $fields,
                scope => {tenant => {field => 'org_key', satisfied_by => ['trusted_context']}}}})), {})
    },
    'host scope' => sub {
        (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse({schema_version => 1,
            name => 'Topo', source => $source, schemas => {}, joins => {}, writes => {operations => $ops, fields => $fields}})),
            {scope_predicate => $x->eq('org_key', 't1')})
    },
);

my $move = q{CREATE OR REPLACE FUNCTION pg_temp.selecto_topo_move() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN UPDATE selecto_topo SET org_key = 't2' WHERE id = NEW.id AND org_key <> 't2'; RETURN NULL; END $$};
my $state = sub { join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_topo ORDER BY id')} };
my %setup = (
    'deferred trigger on a leaf partition' => sub {
        $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))'
            . ' PARTITION BY RANGE (id)');
        $dbh->do('CREATE TABLE selecto_topo_a PARTITION OF selecto_topo FOR VALUES FROM (0) TO (100)');
        $dbh->do($move);
        $dbh->do('CREATE CONSTRAINT TRIGGER selecto_topo_deferred AFTER UPDATE ON selecto_topo_a DEFERRABLE INITIALLY DEFERRED'
            . ' FOR EACH ROW EXECUTE FUNCTION pg_temp.selecto_topo_move()');
    },
    'deferred trigger on an inheritance child' => sub {
        $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
        $dbh->do('CREATE TABLE selecto_topo_c () INHERITS (selecto_topo)');
        $dbh->do($move);
        $dbh->do('CREATE CONSTRAINT TRIGGER selecto_topo_deferred AFTER UPDATE ON selecto_topo_c DEFERRABLE INITIALLY DEFERRED'
            . ' FOR EACH ROW EXECUTE FUNCTION pg_temp.selecto_topo_move()');
    },
    'deferred trigger on an audit table' => sub {
        $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
        $dbh->do('CREATE TABLE selecto_topo_audit (id INT)');
        $dbh->do(q{CREATE OR REPLACE FUNCTION pg_temp.selecto_topo_audit() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN INSERT INTO selecto_topo_audit VALUES (NEW.id); RETURN NULL; END $$});
        $dbh->do('CREATE TRIGGER selecto_topo_audit AFTER UPDATE ON selecto_topo FOR EACH ROW EXECUTE FUNCTION pg_temp.selecto_topo_audit()');
        $dbh->do($move);
        $dbh->do('CREATE CONSTRAINT TRIGGER selecto_topo_deferred AFTER INSERT ON selecto_topo_audit DEFERRABLE INITIALLY DEFERRED'
            . ' FOR EACH ROW EXECUTE FUNCTION pg_temp.selecto_topo_move()');
    },
    'statement trigger on a leaf partition' => sub {
        $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))'
            . ' PARTITION BY RANGE (id)');
        $dbh->do('CREATE TABLE selecto_topo_a PARTITION OF selecto_topo FOR VALUES FROM (0) TO (100)');
        $dbh->do(q{CREATE OR REPLACE FUNCTION pg_temp.selecto_topo_noop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$});
        $dbh->do('CREATE TRIGGER selecto_topo_stmt AFTER UPDATE ON selecto_topo_a FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.selecto_topo_noop()');
    },
    'rule on the relation' => sub {
        $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
        $dbh->do('CREATE TABLE selecto_topo_log (id INT)');
        $dbh->do('CREATE RULE selecto_topo_rule AS ON UPDATE TO selecto_topo DO ALSO INSERT INTO selecto_topo_log VALUES (NEW.id)');
    },
);
my %expected = (
    'statement trigger on a leaf partition' => 'write_capability_missing',
);

sub code_of {
    my ($code) = @_;
    return eval { $code->(); 'applied' } // (blessed($@) ? $@->code : "died: $@");
}

for my $case (sort keys %setup) {
    for my $mode (sort keys %modes) {
        for my $returning (0, 1) {
            my $label = "$case, $mode" . ($returning ? ', RETURNING' : '');
            $dbh->begin_work;
            $setup{$case}->();
            my $child = $case =~ /inheritance child/;
            $dbh->do(q{INSERT INTO } . ($child ? 'selecto_topo_c' : 'selecto_topo') . q{ VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
            my ($engine, $extra) = $modes{$mode}->();
            my $code = code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
                relation => 'selecto_topo', assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'), %$extra,
                ($returning ? (metadata => {returning => ['id']}) : ()))) });
            is($code, $expected{$case} // 'query_rule_not_evaluable', "$label: refused before the update");
            is($state->(), '1:t1:n 2:t2:n', "$label: and nothing changed");
            if ($code eq 'applied') {
                # Show what the host commit would leave behind.
                $dbh->commit;
                is($state->(), '1:t1:changed 2:t2:n', "$label: after commit the row is still in scope");
                $dbh->do('DROP TABLE IF EXISTS selecto_topo, selecto_topo_audit, selecto_topo_log CASCADE');
            } else {
                $dbh->rollback;
            }
        }
    }
}

# The audit topology in a write-owned transaction: the deferred trigger
# would fire at the write's own commit.
{
    $dbh->do('DROP TABLE IF EXISTS selecto_topo, selecto_topo_audit CASCADE');
    $setup{'deferred trigger on an audit table'}->();
    $dbh->do(q{INSERT INTO selecto_topo VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
    my ($engine) = $modes{'engine tenant'}->();
    is(code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_topo',
        assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'))) }), 'query_rule_not_evaluable',
        'write-owned transaction: a deferred trigger on an audit table is refused');
    is($state->(), '1:t1:n 2:t2:n', 'write-owned transaction: and nothing changed');
    $dbh->do('DROP TABLE IF EXISTS selecto_topo, selecto_topo_audit CASCADE');
}

# What keeps working: an ordinary update of a partitioned table, a leaf
# partition's row trigger moving the row (caught by the re-read), and a
# deferrable foreign key, whose triggers are internal.
for my $mode (sort keys %modes) {
    $dbh->begin_work;
    $setup{'deferred trigger on a leaf partition'}->();
    $dbh->do('DROP TRIGGER selecto_topo_deferred ON selecto_topo_a');
    $dbh->do(q{INSERT INTO selecto_topo VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
    my ($engine, $extra) = $modes{$mode}->();
    my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_topo',
        assignments => {note => $_[0]}, predicate => $x->eq('name', 'x'), %$extra) };
    is(code_of(sub { $engine->execute_write($update->('changed')) }), 'applied', "partitioned, $mode: an ordinary update applies");
    is($state->(), '1:t1:changed 2:t2:n', "partitioned, $mode: to the scoped row only");
    $dbh->do(q{CREATE OR REPLACE FUNCTION pg_temp.selecto_topo_before() RETURNS trigger LANGUAGE plpgsql AS
        $$ BEGIN NEW.org_key := 't2'; RETURN NEW; END $$});
    $dbh->do('CREATE TRIGGER selecto_topo_before BEFORE UPDATE ON selecto_topo_a FOR EACH ROW EXECUTE FUNCTION pg_temp.selecto_topo_before()');
    is(code_of(sub { $engine->execute_write($update->('again')) }), 'query_rule_violation',
        "partitioned, $mode: a leaf row trigger moving the row is caught by the re-read");
    is($state->(), '1:t1:changed 2:t2:n', "partitioned, $mode: and rolled back");
    $dbh->rollback;

    $dbh->begin_work;
    $dbh->do('CREATE TABLE selecto_topo_parent (id INT PRIMARY KEY)');
    $dbh->do('INSERT INTO selecto_topo_parent VALUES (1)');
    $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16),'
        . ' parent_id INT REFERENCES selecto_topo_parent (id) DEFERRABLE INITIALLY DEFERRED)');
    $dbh->do(q{INSERT INTO selecto_topo VALUES (1, 't1', 'x', 'n', 1), (2, 't2', 'x', 'n', 1)});
    ($engine, $extra) = $modes{$mode}->();
    is(code_of(sub { $engine->execute_write($update->('changed')) }), 'applied', "deferrable foreign key, $mode: the update applies");
    is($state->(), '1:t1:changed 2:t2:n', "deferrable foreign key, $mode: to the scoped row only");
    $dbh->rollback;
}

# An inheritance parent's key is not unique across its children: a BEFORE
# UPDATE trigger that rewrites the key (and the tenant) let the re-read by
# the old key find a decoy row in a child. A bound-scope update of a
# relation with (non-partition) inheritance children is refused; a child
# without children of its own is updated as before.
for my $mode ('engine tenant', 'host scope') {
    for my $returning (0, 1) {
        my $label = "inheritance decoy, $mode" . ($returning ? ', RETURNING' : '');
        $dbh->begin_work;
        $dbh->do('CREATE TABLE selecto_topo (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
        $dbh->do('CREATE TABLE selecto_topo_c () INHERITS (selecto_topo)');
        $dbh->do(q{INSERT INTO selecto_topo VALUES (5, 't1', 'evil', 'n'), (6, 't2', 'other', 'n')});
        $dbh->do(q{INSERT INTO selecto_topo_c VALUES (5, 't1', 'decoy', 'n')});
        $dbh->do(q{CREATE OR REPLACE FUNCTION pg_temp.selecto_topo_rekey() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN IF NEW.name = 'evil' THEN NEW.id := 1000; NEW.org_key := 't2'; END IF; RETURN NEW; END $$});
        $dbh->do('CREATE TRIGGER selecto_topo_rekey BEFORE UPDATE ON selecto_topo FOR EACH ROW EXECUTE FUNCTION pg_temp.selecto_topo_rekey()');
        my ($engine, $extra) = $modes{$mode}->();
        my $rows = sub { join ' ', map { join ':', @$_ }
            @{$dbh->selectall_arrayref('SELECT tableoid::regclass, id, org_key, name, note FROM selecto_topo ORDER BY 1, 2')} };
        is(code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_topo',
            assignments => {note => 'changed'}, predicate => $x->eq('name', 'evil'), %$extra,
            ($returning ? (metadata => {returning => ['id']}) : ()))) }), 'query_rule_not_evaluable',
            "$label: an update of a relation with inheritance children is refused");
        is($rows->(), 'selecto_topo:5:t1:evil:n selecto_topo:6:t2:other:n selecto_topo_c:5:t1:decoy:n', "$label: and nothing changed");
        $dbh->rollback;
    }
}
{
    $dbh->begin_work;
    $dbh->do('CREATE TABLE selecto_topo_base (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_topo (PRIMARY KEY (id)) INHERITS (selecto_topo_base)');
    $dbh->do(q{INSERT INTO selecto_topo VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
    my ($engine, $extra) = $modes{'host scope'}->();
    is(code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_topo',
        assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'), %$extra)) }), 'applied',
        'an inheritance child without children of its own is updated');
    is($state->(), '1:t1:changed 2:t2:n', 'inheritance child: to the scoped row only');
    $dbh->rollback;
}

done_testing;
