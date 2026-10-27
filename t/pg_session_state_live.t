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
use Selecto::Query;
use Selecto::Write ();

# PostgreSQL session state around Selecto writes and reads (brief items
# 54, 54a, 54b, 56, 56b, 56c, 57, 59, 61). An allowed row trigger, or a
# function a domain view calls, can change session state that later SQL
# depends on: set_config('search_path' | 'TimeZone' | 'DateStyle', ..., true),
# a TEMP relation or type (pg_temp is searched first), DDL in an earlier
# search_path schema. Each write compares a pg_catalog-qualified snapshot of
# that state before its DML with one taken as the first statement after it,
# re-reads through the relation it resolved before the DML, and refuses
# (rolled back) on any change; reads do the same around their statement,
# under a savepoint in a host transaction. Ordinary triggers and a host's
# own TEMP tables keep working (item 19).
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $connect = sub {
    my (%options) = @_;
    my $dbh = DBI->connect($dsn, $user, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => $options{host} ? 0 : 1});
    $dbh->do('SET client_min_messages TO warning');
    $dbh->commit if $options{host};
    return $dbh;
};
my $x = 'Selecto::Expression';
my $admin = $connect->();

my $code = sub {
    my ($work) = @_;
    my $error = eval { $work->(); 1 } ? undef : $@;
    return 'applied' unless defined $error;
    return blessed($error) && $error->can('code')
        ? $error->code . (($error->details // {})->{reason} ? '/' . $error->details->{reason} : '') : "died: $error";
};

my $reset = sub {
    $admin->do($_) for (
        'DROP SCHEMA IF EXISTS selecto_ss_evil CASCADE', 'DROP SCHEMA IF EXISTS selecto_ss_early CASCADE',
        'DROP TABLE IF EXISTS selecto_ss, selecto_ss_d CASCADE',
        'DROP FUNCTION IF EXISTS selecto_ss_flip(integer) CASCADE',
        'CREATE SCHEMA selecto_ss_evil', 'CREATE SCHEMA selecto_ss_early',
        'CREATE TABLE selecto_ss (id INTEGER PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT, ts TIMESTAMPTZ)',
        q{INSERT INTO selecto_ss VALUES (1, 't1', 'x', 'n', '2023-12-31 23:00:00+00'), (2, 't2', 'x', 'n', '2023-12-31 23:00:00+00')},
        'CREATE TABLE selecto_ss_evil.selecto_ss (id INTEGER PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT, ts TIMESTAMPTZ)',
        q{INSERT INTO selecto_ss_evil.selecto_ss VALUES (1, 't1', 'evil', 'evil', '2023-01-01 00:00:00+00'), (7, 't1', 'evil', 'evil', '2023-01-01 00:00:00+00')},
        'CREATE TABLE selecto_ss_d (d DATE PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT)',
        q{INSERT INTO selecto_ss_d VALUES ('2024-02-03', 't1', 'x', 'n'), ('2024-03-02', 't1', 'y', 'n')},
    );
};
my $trigger = sub {
    my ($table, $timing, $body) = @_;
    $admin->do("CREATE OR REPLACE FUNCTION ${table}_trigger() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN $body RETURN NEW; END \$\$");
    $admin->do("CREATE TRIGGER ${table}_trigger $timing UPDATE ON $table FOR EACH ROW EXECUTE FUNCTION ${table}_trigger()");
};

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => (exists $columns{id} ? 'id' : 'd'), fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}
my $document = sub {
    my ($table) = @_;
    my %columns = $table eq 'selecto_ss_d'
        ? (d => 'date', org_key => 'string', name => 'string', note => 'string')
        : (id => 'integer', org_key => 'string', name => 'string', note => 'string', ts => 'utc_datetime');
    return Selecto::Domain->parse({schema_version => 1, name => 'SessionState', source => relation($table, %columns),
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {note => {updatable => 1}}}});
};
my $engine = sub {
    my ($dbh, %options) = @_;
    my $adapter = Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh,
        ($options{external} ? (transaction_mode => 'external') : ())));
    return Selecto::Engine->new(adapter => $adapter, domain => $document->($options{table} // 'selecto_ss'));
};
my $update = sub {
    my ($engine, %options) = @_;
    my $command = Selecto::Write::Command->new(operation => 'update', relation => $options{table} // 'selecto_ss',
        assignments => {note => $options{note} // 'move'}, predicate => (($options{table} // 'selecto_ss') eq 'selecto_ss_d' ? $x->eq('name', 'x') : $x->eq('id', 1)),
        (exists $options{scope} ? (defined $options{scope} ? (scope_predicate => $options{scope}) : ())
            : (scope_predicate => $x->eq('org_key', 't1'))));
    return $code->(sub { $engine->execute_write($command) });
};
my $read = sub {
    my ($engine) = @_;
    my $rows = $engine->all(Selecto::Query->new->select('id', 'name')->order_by('id'))->{rows};
    return join ' ', map { "$_->[0]:$_->[1]" } @$rows;
};
my $state = sub { join ' ', map { "$_->[0]:$_->[1]:$_->[2]" }
    @{$admin->selectall_arrayref('SELECT id, org_key, note FROM public.selecto_ss ORDER BY id')} };

subtest 'item 54/54a/51: a trigger switching search_path cannot steer the post-image re-read' => sub {
    $reset->();
    $trigger->('selecto_ss', 'BEFORE', q{IF NEW.note = 'move' THEN NEW.org_key := 't9'; END IF;
        PERFORM set_config('search_path', 'selecto_ss_evil, public', true);});
    my $dbh = $connect->();
    is($update->($engine->($dbh)), 'query_rule_violation/session_state_changed', 'own transaction: refused');
    is($state->(), '1:t1:n 2:t2:n', 'own transaction: nothing changed');
    my $host = $connect->(host => 1);
    $host->do('SELECT 1');
    is($update->($engine->($host, external => 1)), 'query_rule_violation/session_state_changed', 'host transaction: refused');
    is(($host->selectrow_array('SHOW search_path'))[0], '"$user", public', 'host transaction: its search_path is restored');
    $host->commit;
    is($state->(), '1:t1:n 2:t2:n', 'host transaction committed: nothing changed');
    $host->disconnect;
};

subtest 'item 54: a batch and a graph are refused as a unit in a host transaction' => sub {
    $reset->();
    $trigger->('selecto_ss', 'AFTER', q{IF NEW.id = 2 THEN PERFORM set_config('search_path', 'selecto_ss_evil, public', true); END IF;});
    my $host = $connect->(host => 1);
    $host->do('SELECT 1');
    my $engine = $engine->($host, external => 1);
    my $command = sub {
        my ($id) = @_;
        return Selecto::Write::Command->new(operation => 'update', relation => 'selecto_ss',
            assignments => {note => "b$id"}, predicate => $x->eq('id', $id));
    };
    is($code->(sub { $engine->execute_batch(Selecto::Write::Batch->new($command->(1), $command->(2))) }),
        'query_rule_violation/session_state_changed', 'batch: the second node is refused');
    is($code->(sub { $engine->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'a', command => $command->(1)},
        {id => 'b', command => $command->(2)}])) }), 'query_rule_violation/session_state_changed', 'graph: the second node is refused');
    $host->commit;
    is($state->(), '1:t1:n 2:t2:n', 'the host committed: neither node persisted');
    $host->disconnect;
};

subtest 'item 54b: an unscoped write in a host transaction cannot hijack the next read' => sub {
    $reset->();
    $trigger->('selecto_ss', 'AFTER', q{PERFORM set_config('search_path', 'selecto_ss_evil, public', true);});
    my $host = $connect->(host => 1);
    $host->do('SELECT 1');
    my $engine = $engine->($host, external => 1);
    is($update->($engine, scope => undef, note => 'plain'), 'query_rule_violation/session_state_changed', 'the write is refused');
    is($read->($engine), '1:x 2:x', 'the next read still reads the domain relation');
    $host->rollback;
    $host->disconnect;
};

subtest 'items 56/56b: trigger-created TEMP views and host TEMP shadows' => sub {
    $reset->();
    $trigger->('selecto_ss', 'AFTER', q{EXECUTE 'CREATE TEMP VIEW selecto_ss AS SELECT 99 AS id, ''t1''::text AS org_key, ''evil''::text AS name, NULL::text AS note, NULL::timestamptz AS ts';});
    my $dbh = $connect->();
    my $engine = $engine->($dbh);
    is($update->($engine, scope => undef, note => 'plain'), 'query_rule_violation/session_state_changed', 'the write is refused');
    is($read->($engine), '1:x 2:x', 'no TEMP view survived to answer the next read');
    $dbh->do(q{CREATE TEMP TABLE selecto_ss AS SELECT 99 AS id, 't1'::text AS org_key, 'evil'::text AS name});
    # R38a: Selecto names the domain relation by its schema, so a TEMP
    # namesake can no longer answer reads or take writes.
    is($read->($engine), '1:x 2:x', 'a TEMP table shadowing the domain relation never answers a read');
    # (The write's own trigger still tries to create the TEMP view, which
    # now collides with the TEMP table, so the write fails and rolls back.)
    like($update->($engine, scope => undef, note => 'plain'), qr/\A(?:query_error|query_rule)/, 'a write fails without touching it');
    is(join(',', map { $_->[0] } @{$dbh->selectall_arrayref('SELECT id FROM pg_temp.selecto_ss')}), '99', 'leaving the TEMP table alone');
    $dbh->do('DROP TABLE pg_temp.selecto_ss');
    # The host's own TEMP relation with no namesake is the host's domain (item 19).
    $dbh->do(q{CREATE TEMP TABLE selecto_ss_own (id INTEGER PRIMARY KEY, org_key TEXT NOT NULL, name TEXT, note TEXT, ts TIMESTAMPTZ)});
    $dbh->do(q{INSERT INTO selecto_ss_own VALUES (1, 't1', 'x', 'n', NULL)});
    my $own = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh)),
        domain => Selecto::Domain->parse({schema_version => 1, name => 'Own',
            source => relation('selecto_ss_own', id => 'integer', org_key => 'string', name => 'string', note => 'string', ts => 'utc_datetime'),
            schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
                fields => {note => {updatable => 1}}}}));
    is($read->($own), '1:x', 'a host TEMP domain relation reads');
    is($update->($own, table => 'selecto_ss_own', note => 'kept'), 'applied', 'and writes under a bound scope');
};

subtest 'item 56c: temp types' => sub {
    $reset->();
    $trigger->('selecto_ss', 'AFTER', q{EXECUTE 'CREATE TYPE pg_temp.selecto_ss_mood AS ENUM (''a'')';});
    my $dbh = $connect->();
    my $engine = $engine->($dbh);
    is($update->($engine, scope => undef, note => 'plain'), 'query_rule_violation/session_state_changed', 'a trigger creating a temp type is refused');
    $dbh->do('CREATE DOMAIN pg_temp.text AS pg_catalog.varchar');
    like($code->(sub { $read->($engine) }), qr/\Aquery_rule_not_evaluable/, 'a temp type named like a catalog type is refused on reads');
};

subtest 'item 59: a trigger changing TimeZone cannot reinterpret the scope literal' => sub {
    $reset->();
    $trigger->('selecto_ss', 'BEFORE', q{IF NEW.note = 'move' THEN NEW.ts := '2024-01-01 03:00:00+00'; END IF;
        PERFORM set_config('TimeZone', 'Etc/GMT+5', true);});
    my $dbh = $connect->();
    $dbh->do(q{SET TimeZone TO 'UTC'});
    is($update->($engine->($dbh), scope => $x->lt('ts', '2024-01-01 00:00:00')), 'query_rule_violation/session_state_changed', 'refused');
    is(($admin->selectrow_array(q{SELECT ts = '2023-12-31 23:00:00+00' FROM selecto_ss WHERE id = 1}))[0], 1, 'nothing changed');
};

subtest 'item 61: a domain view function changing the session during a read' => sub {
    for my $local (1, 0) {
        $reset->();
        $admin->do(qq{CREATE FUNCTION selecto_ss_flip(integer) RETURNS boolean LANGUAGE plpgsql VOLATILE AS
            \$\$ BEGIN IF \$1 = 2 THEN PERFORM set_config('search_path', 'selecto_ss_evil, public', } . ($local ? 'true' : 'false') . q{); END IF; RETURN true; END $$});
        $admin->do('CREATE VIEW selecto_ss_v AS SELECT * FROM selecto_ss WHERE selecto_ss_flip(id)');
        my $dbh = $connect->(host => $local);
        $dbh->do('SELECT 1') if $local;
        my $view = $engine->($dbh, ($local ? (external => 1) : ()), table => 'selecto_ss');
        my $flip = Selecto::Engine->new(adapter => $view->{adapter}, domain => Selecto::Domain->parse({schema_version => 1, name => 'View',
            source => relation('selecto_ss_v', id => 'integer', org_key => 'string', name => 'string', note => 'string', ts => 'utc_datetime'),
            schemas => {}, joins => {}}));
        my $label = $local ? 'host transaction' : 'autocommit';
        is($code->(sub { $read->($flip) }), 'query_rule_violation/session_state_changed', "$label: the read is refused");
        is($read->($view), '1:x 2:x', "$label: the next read is not hijacked");
        is(($dbh->selectrow_array('SHOW search_path'))[0], '"$user", public', "$label: search_path restored");
        my $stream = eval { $flip->stream(Selecto::Query->new->select('id')->order_by('id'), bounded => 1, fetch_size => 1) };
        my $streamed = $code->(sub { die $@ unless $stream; 1 while $stream->next; });
        is($streamed, 'query_rule_violation/session_state_changed', "$label: a bounded stream refuses the batch that changed it");
        is($read->($view), '1:x 2:x', "$label: after the stream too");
        $dbh->rollback if $local;
        $admin->do('DROP VIEW selecto_ss_v');
    }
};

subtest 'item 57: a bounded stream proves its own transaction without a forgeable GUC' => sub {
    $reset->();
    $admin->do(q{CREATE FUNCTION selecto_ss_flip(integer) RETURNS boolean LANGUAGE plpgsql VOLATILE AS
        $$ BEGIN PERFORM set_config('selecto.guard', 'forged', true); RETURN true; END $$});
    $admin->do('CREATE VIEW selecto_ss_v AS SELECT * FROM selecto_ss WHERE selecto_ss_flip(id)');
    my $dbh = $connect->();
    my $flip = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (temporary_relations => 1,dbh => $dbh)), domain => Selecto::Domain->parse({schema_version => 1, name => 'View',
        source => relation('selecto_ss_v', id => 'integer', org_key => 'string', name => 'string', note => 'string', ts => 'utc_datetime'),
        schemas => {}, joins => {}}));
    my $stream = $flip->stream(Selecto::Query->new->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
    my $result = $code->(sub { my @rows; while (my $row = $stream->next) { push @rows, $row->[0] } die "rows @rows\n" unless "@rows" eq '1 2'; });
    is($result, 'applied', 'the stream reads its rows and closes');
    is($dbh->pg_ping, 1, 'and its own transaction is not left open');
    $dbh->disconnect;
    $admin->do('DROP VIEW selecto_ss_v');
};

subtest 'item 19: ordinary row triggers still apply' => sub {
    $reset->();
    $trigger->('selecto_ss', 'BEFORE', q{NEW.ts := '2023-12-31 22:00:00+00';});
    my $dbh = $connect->();
    is($update->($engine->($dbh), note => 'stamped'), 'applied', 'an updated_at-style trigger under a bound scope');
    is($state->(), '1:t1:stamped 2:t2:n', 'applied to the scoped row');
    my $host = $connect->(host => 1);
    $host->do('SELECT 1');
    $host->do('CREATE TEMP TABLE selecto_ss_scratch (v integer)');
    is($update->($engine->($host, external => 1), note => 'again'), 'applied', 'in a host transaction holding an ordinary TEMP table');
    is($read->($engine->($host, external => 1)), '1:x 2:x', 'and reads still run');
    $host->rollback;
    $host->disconnect;
};

$admin->do($_) for ('DROP SCHEMA IF EXISTS selecto_ss_evil CASCADE', 'DROP SCHEMA IF EXISTS selecto_ss_early CASCADE',
    'DROP TABLE IF EXISTS selecto_ss, selecto_ss_d CASCADE', 'DROP FUNCTION IF EXISTS selecto_ss_flip(integer) CASCADE',
    'DROP FUNCTION IF EXISTS selecto_ss_trigger() CASCADE', 'DROP FUNCTION IF EXISTS selecto_ss_d_trigger() CASCADE');
done_testing;
