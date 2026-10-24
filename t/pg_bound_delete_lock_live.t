use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use File::Temp ();
use Scalar::Util qw(blessed);
use Time::HiRes ();
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();
use Selecto::QueryEnforcement ();

# PostgreSQL bound-scope deletes: the statement-trigger check runs after
# LOCK TABLE ... IN ROW EXCLUSIVE MODE, so a statement-level DELETE trigger
# another session creates while the delete waits for a row lock cannot fire
# (here the creating session deadlocks against its own row lock and is
# aborted); before, it was created after the check and rewrote the other
# tenant's row ('pwned'). A DELETE rule on the relation is refused too, and
# the check requires READ COMMITTED (t/pg_guarded_write_isolation_live.t).
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $connect = sub {
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
};
my $dbh = $connect->();
$dbh->{AutoInactiveDestroy} = 1;
my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'DelLock',
    source => {source_table => 'selecto_del', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}, tenant_field => 'org_key'},
    schemas => {}, joins => {},
    writes => {operations => {delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {}}});
my $reset = sub {
    $dbh->do('DROP TABLE IF EXISTS selecto_del CASCADE');
    $dbh->do('CREATE TABLE selecto_del (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
    $dbh->do(q{INSERT INTO selecto_del VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
};
$dbh->do(q{CREATE OR REPLACE FUNCTION selecto_del_pwn() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN UPDATE selecto_del SET note = 'pwned' WHERE org_key = 't2'; RETURN NULL; END $$});
my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)), domain => $domain, scope => {tenant => 't1'});
my $delete = sub {
    eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_del',
        predicate => $x->eq('name', 'x'))); 'applied' } // (blessed($@) ? $@->code : "died: $@");
};
my $other_row = sub { $dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_del WHERE id = 2') };

{
    my $flags = File::Temp->newdir;
    $reset->();
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        my $locker = $connect->();
        $locker->begin_work;
        $locker->do('SELECT 1 FROM selecto_del WHERE id = 1 FOR UPDATE');
        open my $fh, '>', "$flags/locked" or die; close $fh;
        Time::HiRes::sleep(1.5);
        eval { $locker->do('CREATE TRIGGER selecto_del_pwn AFTER DELETE ON selecto_del FOR EACH STATEMENT'
            . ' EXECUTE FUNCTION selecto_del_pwn()'); $locker->commit; 1 } or eval { $locker->rollback };
        $locker->disconnect;
        require POSIX; POSIX::_exit(0);
    }
    Time::HiRes::sleep(0.05) until -e "$flags/locked";
    my $code = $delete->();
    waitpid $pid, 0;
    is_deeply($other_row->(), [[2, 't2', 'n']], "a statement trigger raced in during the delete's row-lock wait does not fire ($code)");
}
{
    $reset->();
    $dbh->do(q{CREATE RULE selecto_del_rule AS ON DELETE TO selecto_del DO ALSO UPDATE selecto_del SET note = 'pwned' WHERE org_key = 't2'});
    is($delete->(), 'write_capability_missing', 'a DELETE rule on the relation is refused');
    is_deeply($dbh->selectall_arrayref('SELECT id, note FROM selecto_del ORDER BY id'), [[1, 'n'], [2, 'n']], 'and nothing changed');
}
# A delete bounded only by query enforcement is a bound-scope delete too: a
# statement-level DELETE trigger is refused. (A plain required filter alone
# is not a bound scope; t/upsert_scope_live.t keeps that.)
{
    my $plain = Selecto::Domain->parse({schema_version => 1, name => 'DelLockPlain',
        source => {source_table => 'selecto_del', primary_key => 'id', fields => [qw(id name note org_key)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
            associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {}}});
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    my %bounds = (
        'query enforcement only' => sub {
            my $e = Selecto::Engine->new(adapter => $adapter, domain => $plain);
            return ($e, query_enforcement => Selecto::QueryEnforcement->capture($plain, $e->query->where($x->eq('org_key', 't1'))));
        },
    );
    for my $bound (sort keys %bounds) {
        $reset->();
        $dbh->do('CREATE TRIGGER selecto_del_pwn AFTER DELETE ON selecto_del FOR EACH STATEMENT EXECUTE FUNCTION selecto_del_pwn()');
        my ($e, %extra) = $bounds{$bound}->();
        my $code = eval { $e->execute_write(Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_del',
            predicate => $x->eq('name', 'x'), %extra)); 'applied' } // (blessed($@) ? $@->code : "died: $@");
        is($code, 'write_capability_missing', "a delete bounded by $bound refuses a statement-level DELETE trigger");
        is_deeply($dbh->selectall_arrayref('SELECT id, note FROM selecto_del ORDER BY id'), [[1, 'n'], [2, 'n']], "$bound: and nothing changed");
    }
}
{
    $reset->();
    is($delete->(), 'applied', 'an ordinary bound-scope delete applies');
    is_deeply($dbh->selectall_arrayref('SELECT id FROM selecto_del ORDER BY id'), [[2]], 'to the tenant row only');
}
$dbh->do('DROP TABLE IF EXISTS selecto_del CASCADE');
$dbh->do('DROP FUNCTION IF EXISTS selecto_del_pwn()');
done_testing;
