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

# Item 28: an external-mode graph runs as one unit (one outer savepoint), so
# a later node's refusal undoes the earlier nodes and a host COMMIT keeps
# nothing. Item 29: a handle with AutoCommit off and nothing pending (an
# implicit transaction) counts as a host transaction for external mode and
# for a transaction_handler: writes run, and a refused one is undone.
my $x = 'Selecto::Expression';
my @backends = (['sqlite', sub {
    my (%o) = @_;
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1})
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        my (%o) = @_;
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => $o{autocommit} // 1});
        $dbh->do('SET client_min_messages TO warning');
        $dbh->commit unless $o{autocommit} // 1;
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my (%o) = @_;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => $o{autocommit} // 1,
            mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        $dbh->commit unless $o{autocommit} // 1;
        return $dbh;
    }];
}
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Units',
    source => {source_table => 'selecto_units', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {org_key => {updatable => 1}, note => {updatable => 1}}}});
my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_units', assignments => {note => $_[1]},
    predicate => $x->eq('id', $_[0])) };
my $graph = sub { Selecto::Write::Graph->new(nodes => [{id => 'a', command => $update->(1, 'g')}, {id => 'b', command => $update->(99, 'g')}]) };
my $moved = sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_units', assignments => {org_key => 'T1'},
    predicate => $x->eq('id', 1), scope_predicate => $x->eq('org_key', 't1')) };
my $outcome = sub { my ($code) = @_; eval { $code->(); 'applied' } // (blessed($@) ? $@->code : "died: $@") };

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $setup = $connect->();
    my $my = $name eq 'mysql' || $name eq 'mariadb';
    my $reset = sub {
        $setup->do('DROP TABLE IF EXISTS selecto_units');
        $setup->do('CREATE TABLE selecto_units (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))'
            . ($my ? ' ENGINE=InnoDB' : ''));
        $setup->do(q{INSERT INTO selecto_units VALUES (1, 't1', 'x', 'n'), (2, 't1', 'x', 'n')});
    };
    my $rows = sub { $setup->selectall_arrayref('SELECT id, org_key, note FROM selecto_units ORDER BY id') };
    my $clean = [[1, 't1', 'n'], [2, 't1', 'n']];

    # 28: one outer savepoint for an external graph inside a host transaction.
    $reset->();
    {
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $setup, transaction_mode => 'external')), domain => $domain);
        $setup->begin_work;
        is($outcome->(sub { $engine->execute_graph($graph->()) }), 'cardinality_mismatch', "$name external graph: the second node is refused");
        $setup->commit;
        is_deeply($rows->(), $clean, "$name external graph: the first node is undone with it, the host commit keeps nothing");
    }

    # 29: implicit transactions (AutoCommit => 0, nothing pending).
    for my $mode ('external', 'handler') {
        $reset->();
        # SQLite: the same in-memory handle, switched to AutoCommit off.
        my $dbh = $name eq 'sqlite' ? $setup : $connect->(autocommit => 0);
        $dbh->{AutoCommit} = 0 if $name eq 'sqlite';
        my %options = $mode eq 'external' ? (transaction_mode => 'external') : (transaction_handler => sub { $_[0]->() });
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh, %options)), domain => $domain);
        is($outcome->(sub { $engine->execute_write($update->(2, 'ok')) }), 'applied', "$name $mode on an implicit transaction: a write runs");
        is($outcome->(sub { $engine->execute_write($moved->()) }), 'query_rule_violation', "$name $mode on an implicit transaction: a moved row is refused");
        $dbh->commit;
        is_deeply($rows->(), [[1, 't1', 'n'], [2, 't1', 'ok']], "$name $mode on an implicit transaction: the refused write is undone, the other kept");
        if ($name eq 'sqlite') { $dbh->{AutoCommit} = 1 } else { $dbh->disconnect }
    }
    $setup->do('DROP TABLE IF EXISTS selecto_units');
}
done_testing;
