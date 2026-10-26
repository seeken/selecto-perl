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

# PostgreSQL guarded writes and isolation. Under REPEATABLE READ or
# SERIALIZABLE, catalog queries read the transaction snapshot while trigger
# firing uses the latest catalog: a trigger another session commits after
# the snapshot passed admission and the post-DML recheck and still fired
# (a deferred trigger moving an updated row to t2; a BEFORE INSERT trigger
# storing 'T1'). A guarded write (bound-scope update or delete, guarded
# insert) inside a non-READ COMMITTED transaction is refused with
# query_rule_not_evaluable (reason isolation_level). A managed transaction
# begins READ COMMITTED explicitly, so a handle whose
# default_transaction_isolation is 'repeatable read' gets the checks it
# relies on.
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $connect = sub {
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
};
my ($dbh, $other) = ($connect->(), $connect->());
$dbh->{AutoInactiveDestroy} = 1;
my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Iso',
    source => {source_table => 'selecto_iso', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}, tenant_field => 'org_key'},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}, insert => {enabled => 1},
        delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {id => {insertable => 1}, name => {insertable => 1}, note => {insertable => 1, updatable => 1}, org_key => {insertable => 1}}}});
my $reset = sub {
    $dbh->do('DROP TABLE IF EXISTS selecto_iso, selecto_iso_audit CASCADE');
    $dbh->do('CREATE TABLE selecto_iso (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_iso_audit (id INT)');
    $dbh->do(q{INSERT INTO selecto_iso VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
};
$dbh->do(q{CREATE OR REPLACE FUNCTION selecto_iso_move() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN UPDATE selecto_iso SET org_key = 't2' WHERE id = NEW.id AND org_key <> 't2'; RETURN NULL; END $$});
$dbh->do(q{CREATE OR REPLACE FUNCTION selecto_iso_audit() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN INSERT INTO selecto_iso_audit VALUES (NEW.id); RETURN NULL; END $$});
$dbh->do(q{CREATE OR REPLACE FUNCTION selecto_iso_upper() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN NEW.org_key := upper(NEW.org_key); RETURN NEW; END $$});
$dbh->do(q{CREATE OR REPLACE FUNCTION selecto_iso_pwn() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN UPDATE selecto_iso SET note = 'pwned' WHERE org_key = 't2'; RETURN NULL; END $$});
my $state = sub { join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_iso ORDER BY id')} };
my %writes = (
    update => sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_iso',
        assignments => {note => 'changed'}, predicate => $x->eq('name', 'x')) },
    insert => sub { Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_iso',
        assignments => {id => 3, org_key => 't1', name => 'y', note => 'n'}) },
    delete => sub { Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_iso', predicate => $x->eq('name', 'x')) },
);
my %cases = (
    'a deferred trigger on an audit table' => ['update', 'CREATE CONSTRAINT TRIGGER selecto_iso_deferred AFTER INSERT ON selecto_iso_audit'
        . ' DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION selecto_iso_move()', 1],
    'a deferred trigger on the table' => ['update', 'CREATE CONSTRAINT TRIGGER selecto_iso_deferred AFTER UPDATE ON selecto_iso'
        . ' DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION selecto_iso_move()'],
    'a BEFORE INSERT upper() trigger' => ['insert', 'CREATE TRIGGER selecto_iso_upper BEFORE INSERT ON selecto_iso FOR EACH ROW'
        . ' EXECUTE FUNCTION selecto_iso_upper()'],
    'a statement-level DELETE trigger' => ['delete', 'CREATE TRIGGER selecto_iso_pwn AFTER DELETE ON selecto_iso FOR EACH STATEMENT'
        . ' EXECUTE FUNCTION selecto_iso_pwn()'],
);
sub outcome {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return 'applied' if $ok;
    my $error = $@;
    return blessed($error) && $error->can('code') ? $error->code . (($error->details // {})->{reason} ? '/' . $error->details->{reason} : '')
        : "died: $error";
}

# Host transactions at REPEATABLE READ / SERIALIZABLE, with the trigger
# committed by another session after the host's snapshot.
for my $mode ('managed', 'external') {
    for my $level ('REPEATABLE READ', 'SERIALIZABLE') {
        for my $case (sort keys %cases) {
            my ($operation, $ddl, $audit) = @{$cases{$case}};
            my $label = "$mode, host $level, $case ($operation)";
            $reset->();
            $dbh->do('CREATE TRIGGER selecto_iso_audit AFTER UPDATE ON selecto_iso FOR EACH ROW EXECUTE FUNCTION selecto_iso_audit()')
                if $audit;
            my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh, transaction_mode => $mode)),
                domain => $domain, scope => {tenant => 't1'});
            $dbh->begin_work;
            $dbh->do("SET TRANSACTION ISOLATION LEVEL $level");
            $dbh->do('SELECT 1 FROM selecto_iso_audit LIMIT 1');
            $other->do($ddl);
            my $code = outcome(sub { $engine->execute_write($writes{$operation}->()) });
            eval { $dbh->commit; 1 } or eval { $dbh->rollback };
            is($code, 'query_rule_not_evaluable/isolation_level', "$label: refused");
            is($state->(), '1:t1:n 2:t2:n', "$label: nothing left its tenant");
        }
    }
}
# A READ COMMITTED host transaction still runs ordinary guarded writes.
for my $operation (sort keys %writes) {
    $reset->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh, transaction_mode => 'external')),
        domain => $domain, scope => {tenant => 't1'});
    $dbh->begin_work;
    $dbh->do('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
    is(outcome(sub { $engine->execute_write($writes{$operation}->()) }), 'applied', "host READ COMMITTED: a guarded $operation applies");
    $dbh->commit;
}

# A managed write on a handle whose default isolation is REPEATABLE READ runs
# READ COMMITTED: a deferred trigger created on an audit table while the
# update waits for a row lock is seen by the recheck and refused.
{
    my $flags = File::Temp->newdir;
    $reset->();
    $dbh->do('CREATE TRIGGER selecto_iso_audit AFTER UPDATE ON selecto_iso FOR EACH ROW EXECUTE FUNCTION selecto_iso_audit()');
    $dbh->do(q{SET default_transaction_isolation = 'repeatable read'});
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        my $locker = $connect->();
        $locker->begin_work;
        $locker->do('SELECT 1 FROM selecto_iso WHERE id = 1 FOR UPDATE');
        open my $fh, '>', "$flags/locked" or die; close $fh;
        Time::HiRes::sleep(1.5);
        eval { $locker->do($cases{'a deferred trigger on an audit table'}[1]); $locker->commit; 1 } or eval { $locker->rollback };
        $locker->disconnect;
        require POSIX; POSIX::_exit(0);
    }
    Time::HiRes::sleep(0.05) until -e "$flags/locked";
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)), domain => $domain, scope => {tenant => 't1'});
    my $code = outcome(sub { $engine->execute_write($writes{update}->()) });
    waitpid $pid, 0;
    isnt($code, 'applied', "managed write on a repeatable-read default handle: the raced deferred trigger is refused ($code)");
    is($state->(), '1:t1:n 2:t2:n', 'managed write on a repeatable-read default handle: the row stays in its tenant');
    # And ordinary managed guarded writes still apply on such a handle.
    $reset->();
    for my $operation (qw(update insert delete)) {
        is(outcome(sub { $engine->execute_write($writes{$operation}->()) }), 'applied',
            "managed write on a repeatable-read default handle: a guarded $operation applies");
    }
    $dbh->do('SET default_transaction_isolation TO DEFAULT');
}
$dbh->do('DROP TABLE IF EXISTS selecto_iso, selecto_iso_audit CASCADE');
$dbh->do("DROP FUNCTION IF EXISTS $_()") for qw(selecto_iso_move selecto_iso_audit selecto_iso_upper selecto_iso_pwn);
done_testing;
