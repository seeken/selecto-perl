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

# MySQL/MariaDB: a bound-scope update reads its table's kind and unique key
# from information_schema. The table is read first in the write's
# transaction, so its shared metadata lock keeps a concurrent CREATE
# TRIGGER (or ALTER, DROP INDEX) from changing the definition between those
# checks and commit. The DDL is attempted from a second connection while the
# key check runs; it must wait for the lock and time out.
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

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my ($dbh, $other) = ($connect->(), $connect->());
    $dbh->do('DROP TABLE IF EXISTS selecto_mdl_rows');
    $dbh->do('CREATE TABLE selecto_mdl_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), note VARCHAR(16)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO selecto_mdl_rows VALUES (1, 't1', 'n'), (2, 't2', 'n')});
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), scope => {tenant => 't1'},
        domain => Selecto::Domain->parse({schema_version => 1, name => 'Mdl',
            source => {source_table => 'selecto_mdl_rows', primary_key => 'id', fields => [qw(id note org_key)],
                columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}},
                associations => {}, tenant_field => 'org_key'},
            schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}}}}));
    my $ddl;
    {
        no warnings 'redefine';
        my $original = \&Selecto::MySQLFamily::_unique_key_columns;
        local *Selecto::MySQLFamily::_unique_key_columns = sub {
            $other->do('SET SESSION lock_wait_timeout = 1');
            $ddl = eval {
                $other->do(q{CREATE TRIGGER selecto_mdl_move BEFORE UPDATE ON selecto_mdl_rows FOR EACH ROW SET NEW.note = 'raced'});
                'created';
            } // ($@ =~ /lock wait timeout/i ? 'blocked' : "failed: $@");
            return $original->(@_);
        };
        my $code = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_mdl_rows',
            assignments => {note => 'changed'}, predicate => $x->eq('id', 1))); 'applied' } // (blessed($@) ? $@->code : "died: $@");
        is($code, 'applied', "$name: the bound-scope update applies");
    }
    is($ddl, 'blocked', "$name: a concurrent CREATE TRIGGER waits for the write's metadata lock");
    is_deeply($dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_mdl_rows ORDER BY id'),
        [[1, 't1', 'changed'], [2, 't2', 'n']], "$name: the update is as written");
    $dbh->do('DROP TRIGGER IF EXISTS selecto_mdl_move');
    $dbh->do('DROP TABLE IF EXISTS selecto_mdl_rows');
}

done_testing;
