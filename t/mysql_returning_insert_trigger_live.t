use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Write ();

# MySQL/MariaDB emulate RETURNING by re-reading an inserted (or upserted)
# row by its assigned key or conflict target. A BEFORE INSERT trigger that
# rewrites the key (NEW.id := 1000) made the re-read return another row's
# values (5, 't2', 'secret'), unscoped or not, on the engine path and on
# execute_write_unsafe. A RETURNING insert or upsert on a table with any
# BEFORE INSERT trigger is refused; AFTER INSERT and BEFORE UPDATE triggers,
# and inserts without RETURNING, are unaffected.
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

my $domain = Selecto::Domain->parse({schema_version => 1, name => 'RetIns',
    source => {source_table => 'selecto_retins', primary_key => 'id', fields => [qw(id note org_key title)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}, title => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {insert => {enabled => 1}},
        fields => {id => {insertable => 1}, org_key => {insertable => 1}, note => {insertable => 1}, title => {insertable => 1}}}});
my @returning = qw(id org_key note title);

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my $reset = sub {
        my ($trigger) = @_;
        $dbh->do('DROP TABLE IF EXISTS selecto_retins');
        $dbh->do('CREATE TABLE selecto_retins (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, org_key VARCHAR(16), note VARCHAR(16),'
            . ' title VARCHAR(16)) ENGINE=InnoDB');
        $dbh->do(q{INSERT INTO selecto_retins VALUES (1, 't1', 'n', 'a'), (5, 't2', 'secret', 'theirs')});
        $dbh->do("CREATE TRIGGER selecto_retins_tr $trigger ON selecto_retins FOR EACH ROW "
            . ($trigger eq 'BEFORE INSERT' ? q{BEGIN IF NEW.title = 'evil' THEN SET NEW.id = 1000; END IF; END}
                : $trigger eq 'AFTER INSERT' ? 'SET @selecto_retins = NEW.id' : q{SET NEW.note = NEW.note})) if $trigger;
    };
    my $state = sub { join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, org_key, note, title FROM selecto_retins ORDER BY id')} };
    my %paths = (
        'engine insert' => sub { Selecto::Engine->new(adapter => $adapter, domain => $domain)->execute_write(Selecto::Write::Command->new(
            operation => 'insert', relation => 'selecto_retins', assignments => {id => 5, org_key => 't1', note => 'mine', title => 'evil'},
            metadata => {returning => [@returning]})) },
        'unsafe insert' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_retins',
            assignments => {id => 5, org_key => 't1', note => 'mine', title => 'evil'},
            metadata => {returning => [@returning], __selecto_primary_key => 'id', __selecto_tenant_fields => []})) },
        'unsafe upsert' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'upsert', relation => 'selecto_retins',
            assignments => {id => 7, org_key => 't1', note => 'mine', title => 'evil'},
            metadata => {returning => [@returning], conflict_target => ['id'], upsert_update_fields => ['note'],
                __selecto_primary_key => 'id', __selecto_tenant_fields => []})) },
    );
    for my $path (sort keys %paths) {
        $reset->('BEFORE INSERT');
        my $values;
        my $code = eval { $values = $paths{$path}->()->values; 'applied' } // (blessed($@) ? $@->code : "died: $@");
        is($code, 'write_capability_missing', "$name $path: RETURNING on a BEFORE INSERT trigger table is refused");
        ok(!$values, "$name $path: and returns no row");
        is($state->(), '1:t1:n:a 5:t2:secret:theirs', "$name $path: and inserts nothing");
    }
    # Controls: other triggers and no RETURNING.
    for my $trigger ('AFTER INSERT', 'BEFORE UPDATE', '') {
        $reset->($trigger);
        my $values = eval { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_retins',
            assignments => {id => 7, org_key => 't1', note => 'mine', title => 'ok'},
            metadata => {returning => [@returning], __selecto_primary_key => 'id', __selecto_tenant_fields => []}))->values };
        is_deeply($values, {id => 7, org_key => 't1', note => 'mine', title => 'ok'},
            "$name " . ($trigger || 'no trigger') . ': a RETURNING insert returns its own row') or diag $@;
    }
    $reset->('BEFORE INSERT');
    ok(eval { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_retins',
        assignments => {id => 7, org_key => 't1', note => 'mine', title => 'ok'})); 1 },
        "$name: an insert without RETURNING on a BEFORE INSERT trigger table still runs") or diag $@;
    $dbh->do('DROP TABLE IF EXISTS selecto_retins');
}
done_testing;
