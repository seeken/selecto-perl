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

# A host transaction the driver did not open (a raw BEGIN, a session
# autocommit=0 before or after its first statement, a pooled handle returned
# with one left open) must never be committed by the adapter's own
# transaction: a write there is refused before any DML, so a later host
# ROLLBACK undoes all of the host's work. A host transaction opened with
# begin_work runs the write in a savepoint and keeps working.
my $x = 'Selecto::Expression';
my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;

my $domain = Selecto::Domain->parse({schema_version => 1, name => 'OutsideDriver',
    source => {source_table => 'selecto_outside_rows', primary_key => 'id', fields => [qw(id org_key note)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {note => {updatable => 1}}}});

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
    my $reset = sub {
        $dbh->do('SET autocommit = 1');
        $dbh->do('DROP TABLE IF EXISTS selecto_outside_rows');
        $dbh->do('CREATE TABLE selecto_outside_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), note VARCHAR(16)) ENGINE=InnoDB');
        $dbh->do(q{INSERT INTO selecto_outside_rows VALUES (1, 't1', 'a'), (2, 't1', 'b'), (3, 't2', 'c')});
    };
    my $state = sub { join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, note FROM selecto_outside_rows ORDER BY id')} };
    my $write = sub {
        return eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_outside_rows',
            assignments => {note => 'x'}, predicate => $x->eq('id', 1))); 'applied' }
            // (blessed($@) ? $@->code . '/' . (ref($@->details) eq 'HASH' ? $@->details->{reason} // '' : '') : "died: $@");
    };
    my %opens = (
        'raw BEGIN' => sub { $dbh->do('BEGIN'); $dbh->do(q{UPDATE selecto_outside_rows SET note = 'host' WHERE id = 3}) },
        'START TRANSACTION' => sub { $dbh->do('START TRANSACTION'); $dbh->do(q{UPDATE selecto_outside_rows SET note = 'host' WHERE id = 3}) },
        'autocommit=0 before any statement' => sub { $dbh->do('SET autocommit = 0') },
        'autocommit=0 after a statement' => sub { $dbh->do('SET autocommit = 0'); $dbh->do(q{UPDATE selecto_outside_rows SET note = 'host' WHERE id = 3}) },
        'leftover pooled transaction' => sub { $dbh->do('START TRANSACTION WITH CONSISTENT SNAPSHOT') },
    );
    for my $label (sort keys %opens) {
        $reset->();
        $opens{$label}->();
        is($write->(), 'invalid_adapter/transaction_outside_driver', "$name $label: the write is refused");
        $dbh->do('ROLLBACK');
        $dbh->do('SET autocommit = 1');
        is($state->(), '1:a 2:b 3:c', "$name $label: a host ROLLBACK undoes everything");
    }
    # Controls: an idle handle and a begin_work host transaction.
    $reset->();
    is($write->(), 'applied', "$name idle: the write runs in its own transaction");
    is($state->(), '1:x 2:b 3:c', "$name idle: and commits");
    $reset->();
    $dbh->begin_work;
    $dbh->do(q{UPDATE selecto_outside_rows SET note = 'host' WHERE id = 3});
    is($write->(), 'applied', "$name begin_work: the write runs in a savepoint");
    $dbh->rollback;
    is($state->(), '1:a 2:b 3:c', "$name begin_work: the host ROLLBACK undoes it with the host's work");
    $dbh->do('DROP TABLE IF EXISTS selecto_outside_rows');
}
done_testing;
