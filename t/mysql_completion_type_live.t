use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();

# A bare COMMIT or ROLLBACK obeys the session's completion_type: 1 chains a new
# transaction, so a later write was never committed, and 2 closes the connection.
# Selecto's own transactions must end the same way whatever it says (R66).
my $x = 'Selecto::Expression';
for my $family (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($name, $env) = @$family;
    subtest $name => sub {
        plan skip_all => "$env is not set" unless ($ENV{$env} // '') ne '';
        plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };
        my $url = Mojo::URL->new($ENV{$env});
        my $connect = sub {
            my ($user, $password) = split /:/, $url->userinfo // '', 2;
            my $db = $url->path->to_string =~ s{\A/}{}r;
            my $dbh = DBI->connect("dbi:MariaDB:database=$db;host=" . $url->host . ';port=' . $url->port, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
            $dbh->do(q{SET SESSION time_zone = '+00:00', sql_mode = 'STRICT_TRANS_TABLES', NAMES utf8mb4});
            return $dbh;
        };
        my @clean = ('DROP TABLE IF EXISTS ctp_t, ctp_log');
        my $admin = $connect->();
        $admin->do($_) for @clean, 'CREATE TABLE ctp_t (id INT PRIMARY KEY, org VARCHAR(10) NOT NULL, note VARCHAR(20)) ENGINE=InnoDB',
            'CREATE TABLE ctp_log (id INT) ENGINE=InnoDB';
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'CTP', source => {source_table => 'ctp_t', primary_key => 'id', tenant_field => 'org',
            fields => [qw(id org note)], columns => {id => {type => 'integer'}, org => {type => 'string'}, note => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
            writes => {scope => {tenant => {field => 'org'}}, operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
                fields => {id => {insertable => 1}, org => {insertable => 1}, note => {insertable => 1, updatable => 1}}}});
        my $update = sub { my ($id, $note) = @_; Selecto::Write::Command->new(operation => 'update', relation => 'ctp_t', assignments => {note => $note},
            predicate => $x->eq('id', $id), expected_count => undef) };
        my $insert = sub { my ($id) = @_; Selecto::Write::Command->new(operation => 'insert', relation => 'ctp_t', assignments => {id => $id, org => 't1', note => 'new'}) };
        my %work = (
            write => sub { $_[0]->execute_write($update->(1, 'one')) },
            batch => sub { $_[0]->execute_batch(Selecto::Write::Batch->new($update->(1, 'one'), $update->(2, 'one'))) },
            graph => sub { $_[0]->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'a', command => $update->(1, 'one')}, {id => 'b', command => $update->(2, 'one')}])) },
        );
        for my $type (0, 1, 2) {
            for my $kind (sort keys %work) {
                my $label = "completion_type $type, $kind";
                $admin->do($_) for 'DELETE FROM ctp_t', 'DELETE FROM ctp_log', q{INSERT INTO ctp_t VALUES (1, 't1', 'old'), (2, 't1', 'old')};
                my $dbh = $connect->();
                $dbh->do("SET SESSION completion_type = $type");
                my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)))->with_scope(tenant => 't1');
                ok(eval { $work{$kind}->($engine); 1 }, "$label: applied") or diag $@;
                is(($admin->selectrow_array(q{SELECT count(*) FROM ctp_t WHERE note = 'one'}))[0], $kind eq 'write' ? 1 : 2, "$label: committed, as another connection sees");
                ok($dbh->{Active} && eval { $dbh->ping }, "$label: the connection stands");
                ok(!eval { $dbh->{BegunWork} } && $dbh->{AutoCommit}, "$label: DBI's state is back");
                # A second write reported as done must be there after close.
                ok(eval { $engine->execute_write($update->(2, 'two')); 1 }, "$label: a second write applies") or diag $@;
                # The host's own autocommit write, on the same connection.
                ok(eval { $dbh->do('INSERT INTO ctp_log VALUES (1)'); 1 }, "$label: a host write runs") or diag $@;
                is(($admin->selectrow_array('SELECT count(*) FROM ctp_log'))[0], 1, "$label: and commits by itself");
                $dbh->disconnect;
                is(($admin->selectrow_array('SELECT note FROM ctp_t WHERE id = 2'))[0], 'two', "$label: the second write survives close");
                is(($admin->selectrow_array('SELECT count(*) FROM ctp_log'))[0], 1, "$label: so does the host's");
            }
            # A refused write ends in the same state, and undoes everything.
            my $label = "completion_type $type, refused";
            $admin->do($_) for 'DELETE FROM ctp_t', 'DELETE FROM ctp_log', q{INSERT INTO ctp_t VALUES (1, 't1', 'old'), (2, 't1', 'old')};
            my $dbh = $connect->();
            $dbh->do("SET SESSION completion_type = $type");
            my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)))->with_scope(tenant => 't1');
            ok(!eval { $engine->execute_batch(Selecto::Write::Batch->new($update->(1, 'gone'), $insert->(2))); 1 }, "$label: a batch with a duplicate key fails");
            is(($admin->selectrow_array(q{SELECT count(*) FROM ctp_t WHERE note = 'gone'}))[0], 0, "$label: nothing of it stays");
            ok($dbh->{Active} && eval { $dbh->ping }, "$label: the connection stands");
            ok(!eval { $dbh->{BegunWork} } && $dbh->{AutoCommit}, "$label: DBI's state is back");
            ok(eval { $dbh->do('INSERT INTO ctp_log VALUES (1)'); 1 }, "$label: a host write runs") or diag $@;
            is(($admin->selectrow_array('SELECT count(*) FROM ctp_log'))[0], 1, "$label: and commits by itself");
            ok(eval { $engine->execute_write($update->(1, 'after')); 1 }, "$label: and so does Selecto's next write") or diag $@;
            $dbh->disconnect;
            is(($admin->selectrow_array('SELECT note FROM ctp_t WHERE id = 1'))[0], 'after', "$label: which survives close");
        }
        $admin->do($_) for @clean;
        $admin->disconnect;
    };
}

done_testing;
