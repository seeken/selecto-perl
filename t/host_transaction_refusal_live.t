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

# A guarded write refused after its DML ran (a post-image violation: the
# update assigned the scoped column out of its host scope) inside a
# host-owned transaction must undo its own DML: the write runs inside a
# savepoint and rolls back to it on refusal, in external mode as in managed
# mode, so a host that commits after the error never persists the row,
# while the host's own earlier work is kept.
my $x = 'Selecto::Expression';
my @backends = (['sqlite', sub {
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1})
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
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
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HostRefusal',
    source => {source_table => 'selecto_host_rows', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {org_key => {updatable => 1}, note => {updatable => 1}}}});

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $my = $name eq 'mysql' || $name eq 'mariadb';
    for my $mode (qw(external managed)) {
        for my $returning (0, 1) {
            next if $returning && $name eq 'sqlite' && !eval { $dbh->{sqlite_version} ge '3.35' };
            my $label = "$name $mode" . ($returning ? ' RETURNING' : '');
            $dbh->do('DROP TABLE IF EXISTS selecto_host_rows');
            $dbh->do('CREATE TABLE selecto_host_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))'
                . ($my ? ' ENGINE=InnoDB' : ''));
            $dbh->do(q{INSERT INTO selecto_host_rows VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
            my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh, transaction_mode => $mode)), domain => $domain);
            $dbh->begin_work;
            $dbh->do(q{INSERT INTO selecto_host_rows VALUES (9, 'host', 'h', 'h')});
            my $code = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_host_rows',
                assignments => {org_key => 'T1', note => 'moved'}, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1'),
                ($returning ? (metadata => {returning => ['id']}) : ()))); 'applied' } // (blessed($@) ? $@->code : "died: $@");
            ok($code ne 'applied', "$label: the write is refused after its DML ($code)");
            my $committed = eval { $dbh->commit; 1 } ? 1 : do { eval { $dbh->rollback }; 0 };
            ok($committed, "$label: the host can still commit");
            is_deeply($dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_host_rows ORDER BY id'),
                [[1, 't1', 'n'], [2, 't2', 'n'], [9, 'host', 'h']], "$label: the refused write's DML is undone, the host's work kept");
        }
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_host_rows');
}
done_testing;
