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

# PostgreSQL: a concurrent session that creates or enables a deferrable
# constraint trigger (on the written table, or on an audit table a row
# trigger writes to) while a bound-scope update waits for a row lock must not
# let the row commit out of scope. The update locks the table (ROW
# EXCLUSIVE) before reading the catalog, so DDL on the written table waits
# for it (and here deadlocks against the row lock the other session holds,
# so one side is aborted), and it re-reads the catalog after the UPDATE, so
# a deferrable trigger created elsewhere in the meantime is refused and the
# write rolls back. Whatever happens, row 1 stays in t1.
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
my $flags = File::Temp->newdir;
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Race',
    source => {source_table => 'selecto_race', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}, tenant_field => 'org_key'},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});

my $n = 0;
for my $case ('create on the written table', 'create on an audit table', 'enable a disabled trigger on the written table') {
    $dbh->do('DROP TABLE IF EXISTS selecto_race, selecto_race_audit CASCADE');
    $dbh->do('CREATE TABLE selecto_race (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_race_audit (id INT)');
    $dbh->do(q{INSERT INTO selecto_race VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
    $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_race_move() RETURNS trigger LANGUAGE plpgsql AS
        $$ BEGIN UPDATE selecto_race SET org_key = 't2' WHERE id = NEW.id AND org_key <> 't2'; RETURN NULL; END $$});
    if ($case =~ /audit/) {
        $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_race_audit() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN INSERT INTO selecto_race_audit VALUES (NEW.id); RETURN NULL; END $$});
        $dbh->do('CREATE TRIGGER selecto_race_audit AFTER UPDATE ON selecto_race FOR EACH ROW EXECUTE FUNCTION selecto_race_audit()');
    }
    if ($case =~ /enable/) {
        $dbh->do('CREATE CONSTRAINT TRIGGER selecto_race_deferred AFTER UPDATE ON selecto_race DEFERRABLE INITIALLY DEFERRED'
            . ' FOR EACH ROW EXECUTE FUNCTION selecto_race_move()');
        $dbh->do('ALTER TABLE selecto_race DISABLE TRIGGER selecto_race_deferred');
    }
    my $flag = "$flags/locked" . ++$n;
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        my $other = $connect->();
        $other->begin_work;
        $other->do('SELECT 1 FROM selecto_race WHERE id = 1 FOR UPDATE');
        open my $fh, '>', $flag or die; close $fh;
        Time::HiRes::sleep(1.5);
        eval {
            if ($case =~ /enable/) { $other->do('ALTER TABLE selecto_race ENABLE TRIGGER selecto_race_deferred') }
            else {
                my $on = $case =~ /audit/ ? 'AFTER INSERT ON selecto_race_audit' : 'AFTER UPDATE ON selecto_race';
                $other->do("CREATE CONSTRAINT TRIGGER selecto_race_deferred $on DEFERRABLE INITIALLY DEFERRED"
                    . ' FOR EACH ROW EXECUTE FUNCTION selecto_race_move()');
            }
            $other->commit;
            1;
        } or eval { $other->rollback };
        $other->disconnect;
        require POSIX; POSIX::_exit(0);
    }
    Time::HiRes::sleep(0.05) until -e $flag;
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)), domain => $domain, scope => {tenant => 't1'});
    my $code = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_race',
        assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'))); 'applied' } // (blessed($@) ? $@->code : "error");
    waitpid $pid, 0;
    my ($org, $note) = $dbh->selectrow_array('SELECT org_key, note FROM selecto_race WHERE id = 1');
    is($org, 't1', "$case: the row stays in its tenant ($code, note $note)");
    is_deeply($dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_race WHERE id = 2'), [[2, 't2', 'n']],
        "$case: the other tenant's row is untouched");
    ok($code eq 'applied' ? $note eq 'changed' : $note eq 'n', "$case: the write applied or rolled back as a whole");
}
$dbh->do('DROP TABLE IF EXISTS selecto_race, selecto_race_audit CASCADE');
$dbh->do('DROP FUNCTION IF EXISTS selecto_race_move(), selecto_race_audit()');
done_testing;
