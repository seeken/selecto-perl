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

# MySQL/MariaDB: MEMORY, MyISAM and Aria apply each statement at once, so a
# write refused after its statement (a post-image violation, a cardinality
# mismatch, a later batch or graph command) could not be rolled back: the
# moved or changed rows stayed. Every write now requires an InnoDB table,
# checked after the table's metadata lock, on the single, batch, graph,
# delete and unsafe paths; a session TEMPORARY table shadowing the base
# table is refused too.
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
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Engines',
    source => {source_table => 'selecto_engine_rows', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}, tenant_field => 'org_key'},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}, delete => {enabled => 1, bulk => 1}},
        fields => {note => {updatable => 1}}}});
my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_engine_rows', assignments => {note => $_[1]},
    predicate => $x->eq('id', $_[0])) };
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain, scope => {tenant => 't1'});
    my %cases = (
        'an update moved out of its tenant by a trigger' => sub { $engine->execute_write($update->(1, 'evil')) },
        'a batch whose second update matches nothing' => sub { $engine->execute_batch(Selecto::Write::Batch->new($update->(1, 'b'), $update->(99, 'b'))) },
        'a graph whose second node matches nothing' => sub { $engine->execute_graph(Selecto::Write::Graph->new(nodes => [
            {id => 'a', command => $update->(1, 'g')}, {id => 'b', command => $update->(99, 'g')}])) },
        'an unsafe update expecting 1 that matches 2' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'update',
            relation => 'selecto_engine_rows', assignments => {note => 'u'}, predicate => $x->eq('org_key', 't1'), expected_count => 1)) },
        'a batch inserting, then updating nothing' => sub { $adapter->execute_batch_unsafe(Selecto::Write::Batch->new(
            Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_engine_rows', assignments => {id => 9, org_key => 't1', name => 'y', note => 'i'}),
            Selecto::Write::Command->new(operation => 'update', relation => 'selecto_engine_rows', assignments => {note => 'b'}, predicate => $x->eq('id', 99)))) },
        'an unsafe delete expecting 1 that matches 2' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'delete',
            relation => 'selecto_engine_rows', predicate => $x->eq('org_key', 't1'), expected_count => 1)) },
    );
    for my $storage ($name eq 'mariadb' ? qw(InnoDB MyISAM MEMORY Aria) : qw(InnoDB MyISAM MEMORY), 'temporary MEMORY shadow') {
        for my $case (sort keys %cases) {
            $dbh->do('DROP TEMPORARY TABLE IF EXISTS selecto_engine_rows');
            $dbh->do('DROP TABLE IF EXISTS selecto_engine_rows');
            my $engine_name = $storage =~ /shadow/ ? 'InnoDB' : $storage;
            $dbh->do("CREATE TABLE selecto_engine_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16)) ENGINE=$engine_name");
            if ($storage =~ /shadow/) {
                $dbh->do('CREATE TEMPORARY TABLE selecto_engine_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16)) ENGINE=MEMORY');
            }
            $dbh->do(q{INSERT INTO selecto_engine_rows VALUES (1, 't1', 'x', 'n'), (2, 't1', 'x', 'n'), (3, 't2', 'x', 'n')});
            $dbh->do(q{CREATE TRIGGER selecto_engine_tr BEFORE UPDATE ON selecto_engine_rows FOR EACH ROW
                BEGIN IF NEW.note = 'evil' THEN SET NEW.org_key = 't2'; END IF; END}) if $storage !~ /shadow/;
            my $code = eval { $cases{$case}->(); 'applied' } // (blessed($@) ? $@->code : "died: $@");
            my $state = join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_engine_rows ORDER BY id')};
            if ($storage eq 'InnoDB') {
                isnt($code, 'applied', "$name InnoDB: $case is refused after its statement ($code)");
            } else {
                like($code, $storage =~ /shadow/ ? qr/\A(?:write_capability_missing|query_rule_not_evaluable)\z/ : qr/\Awrite_capability_missing\z/,
                    "$name $storage: $case is refused before any DML");
            }
            is($state, '1:t1:n 2:t1:n 3:t2:n', "$name $storage: $case leaves every row unchanged");
        }
    }
    $dbh->do('DROP TEMPORARY TABLE IF EXISTS selecto_engine_rows');
    $dbh->do('DROP TABLE IF EXISTS selecto_engine_rows');
}
done_testing;
