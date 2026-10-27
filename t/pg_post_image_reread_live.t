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

# PostgreSQL post-image re-reads of bound-scope updates (brief items 34, 40,
# 43, 47, 51, 51a). The re-read and the post-statement trigger/rule checks
# address the relation by the oid and schema-qualified name resolved under
# the write's lock before the DML (a trigger's DDL or search_path switch
# cannot substitute another relation), and name the written rows by the
# (tableoid, ctid) the statement returned (R9), so no key type, collation or
# session setting can let a decoy row stand in for a moved one, and keys of
# any type (dates, floats, collated text) work again.
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $connect = sub {
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
};
my $x = 'Selecto::Expression';
my $admin = $connect->();
my $clean = sub {
    $admin->do($_) for ('DROP SCHEMA IF EXISTS selecto_rr_early CASCADE', 'DROP TABLE IF EXISTS selecto_rr CASCADE',
        'DROP FUNCTION IF EXISTS selecto_rr_trigger() CASCADE');
};
# A table keyed by $key_sql, rows (key 1: t1/x) and (key 2: t1/y), and a
# BEFORE UPDATE trigger that moves the updated row out of scope and runs $extra.
my $setup = sub {
    my ($key_sql, $one, $two, $extra) = @_;
    $clean->();
    $admin->do('CREATE SCHEMA selecto_rr_early');
    $admin->do("CREATE TABLE selecto_rr (k $key_sql, org_key TEXT NOT NULL, name TEXT, note TEXT)");
    $admin->do('INSERT INTO selecto_rr VALUES (?, ?, ?, ?), (?, ?, ?, ?)', undef, $one, 't1', 'x', 'n', $two, 't1', 'y', 'n');
    $admin->do(qq{CREATE FUNCTION selecto_rr_trigger() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN
        IF NEW.note = 'move' THEN NEW.org_key := 't9'; END IF; $extra RETURN NEW; END \$\$});
    $admin->do('CREATE TRIGGER selecto_rr_trigger BEFORE UPDATE ON selecto_rr FOR EACH ROW EXECUTE FUNCTION selecto_rr_trigger()');
};
my $update = sub {
    my ($dbh, $type, $note) = @_;
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Reread',
        source => {source_table => 'selecto_rr', primary_key => 'k', fields => [qw(k org_key name note)],
            columns => {k => {type => $type}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
            associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}}}});
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)), domain => $domain);
    my $command = Selecto::Write::Command->new(operation => 'update', relation => 'selecto_rr',
        assignments => {note => $note}, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1'));
    return eval { $engine->execute_write($command); 'applied' } // (blessed($@) ? $@->code : "died: $@");
};
my $state = sub { join ' ', map { "$_->[0]:$_->[1]" } @{$admin->selectall_arrayref('SELECT name, org_key FROM public.selecto_rr ORDER BY name')} };

subtest 'item 51: a trigger creating a namesake earlier on the search_path cannot answer the re-read' => sub {
    $setup->('INTEGER PRIMARY KEY', 1, 2,
        q{EXECUTE 'CREATE TABLE IF NOT EXISTS selecto_rr_early.selecto_rr AS SELECT 1 AS k, ''t1''::text AS org_key';});
    my $dbh = $connect->();
    $dbh->do('SET search_path TO selecto_rr_early, public');
    is($update->($dbh, 'integer', 'move'), 'query_rule_violation', 'the qualified re-read refuses the moved row');
    is($state->(), 'x:t1 y:t1', 'nothing changed');
    is($update->($dbh, 'integer', 'kept'), 'applied', 'an ordinary update through the same path applies');
};

subtest 'item 47: a date key re-read never depends on DateStyle' => sub {
    $setup->('DATE PRIMARY KEY', '2024-02-03', '2024-03-02', q{PERFORM set_config('DateStyle', 'SQL, MDY', true);});
    my $dbh = $connect->();
    $dbh->do(q{SET DateStyle TO 'SQL, DMY'});
    is($update->($dbh, 'date', 'move'), 'query_rule_violation', 'the moved row is caught whatever DateStyle says');
    is($state->(), 'x:t1 y:t1', 'nothing changed');
};

subtest 'item 34: a float key never lets a decoy answer the re-read' => sub {
    $setup->('DOUBLE PRECISION PRIMARY KEY', '0.10000000000000002', '0.1', '');
    my $dbh = $connect->();
    $dbh->do('SET extra_float_digits TO 0');
    isnt($update->($dbh, 'float', 'move'), 'applied', 'not applied');
    is($state->(), 'x:t1 y:t1', 'nothing changed');
    my $exact = $connect->();
    is($update->($exact, 'float', 'move'), 'query_rule_violation', 'refused under the default extra_float_digits too')
        ;
    is($update->($exact, 'float', 'kept'), 'applied', 'an ordinary update on a float key applies');
};

subtest 'item 40: a unique index under another collation does not name rows' => sub {
    $admin->do('DROP COLLATION IF EXISTS selecto_rr_ci');
    $admin->do(q{CREATE COLLATION selecto_rr_ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false)});
    $setup->('TEXT COLLATE selecto_rr_ci NOT NULL', 'a', 'A', '');
    $admin->do('CREATE UNIQUE INDEX selecto_rr_k ON selecto_rr (k COLLATE "C")');
    my $dbh = $connect->();
    is($update->($dbh, 'string', 'move'), 'query_rule_violation', 'refused');
    is($state->(), 'x:t1 y:t1', 'nothing changed');
    is($update->($dbh, 'string', 'kept'), 'applied', 'an ordinary update applies');
    $clean->();
    $admin->do('DROP COLLATION selecto_rr_ci');
};

subtest 'keys of every type work' => sub {
    for my $case (['INTEGER PRIMARY KEY', 'integer', 1, 2], ['BIGINT PRIMARY KEY', 'integer', 1, 2],
        ['DATE PRIMARY KEY', 'date', '2024-02-03', '2024-03-02'],
        ['TIMESTAMPTZ PRIMARY KEY', 'utc_datetime', '2024-05-01 10:00:00.123456+00', '2024-05-01 10:00:00.123457+00'],
        ['DOUBLE PRECISION PRIMARY KEY', 'float', '0.10000000000000002', '0.1'],
        ['INET PRIMARY KEY', 'string', '10.0.0.1/24', '10.0.0.1/32'],
        ['TEXT PRIMARY KEY', 'string', 'a', 'b'], ['NUMERIC(10,2) PRIMARY KEY', 'decimal', '1.50', '2.50'],
        ['UUID PRIMARY KEY', 'string', '6f1c1d2e-0000-4000-8000-000000000001', '6f1c1d2e-0000-4000-8000-000000000002']) {
        my ($sql, $type, $one, $two) = @$case;
        $setup->($sql, $one, $two, '');
        my $dbh = $connect->();
        is($update->($dbh, $type, 'kept'), 'applied', "$sql: an ordinary update applies");
        is($update->($dbh, $type, 'move'), 'query_rule_violation', "$sql: a row moved out of scope is refused");
        is($state->(), 'x:t1 y:t1', "$sql: and rolled back");
    }
};

$clean->();
done_testing;
