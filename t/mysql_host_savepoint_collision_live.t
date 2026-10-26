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

# MySQL/MariaDB: a SAVEPOINT that reuses a name replaces the older one, and
# RELEASE then deletes it. Selecto's savepoint names used to be
# selecto_write_<pid>_<n>, so a host savepoint of that shape was replaced by
# the write's own and deleted by its cleanup. Names now carry a random nonce:
# host savepoints of the old shape survive a refused write, and the host can
# still roll back to them.
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
my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HostSavepoint',
    source => {source_table => 'selecto_host_sp', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {org_key => {updatable => 1}, note => {updatable => 1}}}});
my @host = map { "selecto_write_${$}_$_" } 1 .. 30;

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    for my $mode (qw(managed external)) {
        $dbh->do('DROP TABLE IF EXISTS selecto_host_sp');
        $dbh->do('CREATE TABLE selecto_host_sp (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16)) ENGINE=InnoDB');
        $dbh->do(q{INSERT INTO selecto_host_sp VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh, transaction_mode => $mode)), domain => $domain);
        $dbh->begin_work;
        $dbh->do(q{UPDATE selecto_host_sp SET note = 'host' WHERE id = 2});
        $dbh->do("SAVEPOINT $_") for @host;
        my $code = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_host_sp',
            assignments => {org_key => 'T1'}, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1'))); 'applied' }
            // (blessed($@) ? $@->code : "died: $@");
        is($code, 'query_rule_violation', "$name $mode: the write is refused after its DML");
        my @missing = grep { !eval { $dbh->do("ROLLBACK TO SAVEPOINT $_"); 1 } } reverse @host;
        is_deeply(\@missing, [], "$name $mode: every host savepoint of the old naming shape survives");
        $dbh->commit;
        is_deeply($dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_host_sp ORDER BY id'), [[1, 't1', 'n'], [2, 't2', 'host']],
            "$name $mode: the refused write is undone and the host's work is kept");
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_host_sp');
}
done_testing;
