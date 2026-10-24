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

# Any write that can be refused after its statement must be atomic: an
# update expecting 1 row that matches 2, and a bound-scope update moved out
# of its scope, must leave every row unchanged in managed mode on an idle
# handle (its own transaction), in managed or external mode inside a host
# transaction (a savepoint), and under a transaction_handler. A handler that
# runs the work outside a transaction (on an autocommit handle) used to let
# the change commit before the refusal; it is now refused before any DML
# (transaction_unavailable, reason autocommit).
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
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Atomic',
    source => {source_table => 'selecto_atomic', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {org_key => {updatable => 1}, note => {updatable => 1}}}});

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $my = $name eq 'mysql' || $name eq 'mariadb';
    my $transactional = sub {
        my ($work) = @_;
        $dbh->begin_work;
        my $value = eval { $work->() };
        if (my $error = $@) { $dbh->rollback; die $error }
        $dbh->commit;
        return $value;
    };
    my %modes = (
        'managed, idle handle' => [{}, 0],
        'managed, host transaction' => [{}, 1],
        'external, host transaction' => [{transaction_mode => 'external'}, 1],
        'transactional handler' => [{transaction_handler => $transactional}, 0],
        'autocommit handler' => [{transaction_handler => sub { $_[0]->() }}, 0],
    );
    my %writes = (
        'an unguarded update expecting 1 that matches 2' => sub { $_[0]->execute_write_unsafe(Selecto::Write::Command->new(
            operation => 'update', relation => 'selecto_atomic', assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'),
            expected_count => 1)) },
        'a bound-scope update moved out of its scope' => sub { Selecto::Engine->new(adapter => $_[0], domain => $domain)->execute_write(
            Selecto::Write::Command->new(operation => 'update', relation => 'selecto_atomic', assignments => {org_key => 'T1'},
            predicate => $x->eq('id', 1), scope_predicate => $x->eq('org_key', 't1'))) },
    );
    for my $mode (sort keys %modes) {
        my ($options, $host) = @{$modes{$mode}};
        for my $write (sort keys %writes) {
            $dbh->do('DROP TABLE IF EXISTS selecto_atomic');
            $dbh->do('CREATE TABLE selecto_atomic (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))'
                . ($my ? ' ENGINE=InnoDB' : ''));
            $dbh->do(q{INSERT INTO selecto_atomic VALUES (1, 't1', 'x', 'n'), (2, 't1', 'x', 'n')});
            my $adapter = Selecto->adapter($name => (dbh => $dbh, %$options));
            $dbh->begin_work if $host;
            my $code = eval { $writes{$write}->($adapter); 'applied' } // do {
                my $e = $@; blessed($e) ? $e->code . (($e->details // {})->{reason} ? '/' . $e->details->{reason} : '') : "died: $e" };
            $dbh->commit if $host;
            if ($mode eq 'autocommit handler') {
                is($code, 'transaction_unavailable/autocommit', "$name $mode: $write is refused before any DML");
            } else {
                isnt($code, 'applied', "$name $mode: $write is refused ($code)");
            }
            is_deeply($dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_atomic ORDER BY id'), [[1, 't1', 'n'], [2, 't1', 'n']],
                "$name $mode: $write leaves every row unchanged");
        }
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_atomic');
}
done_testing;
