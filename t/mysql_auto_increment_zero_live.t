use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Write ();

# An AUTO_INCREMENT key assigned any value the server reads as zero ('0',
# '00', ' 0', '0.0', '-0', 0, FALSE) gets a generated value, so the RETURNING
# re-read and the stored-row check must never look the row up by that value:
# it would return id 0's row (another tenant's SECRET) as the inserted one.
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

my $domain = Selecto::Domain->parse({schema_version => 1, name => 'AutoZero',
    source => {source_table => 'selecto_auto_zero', primary_key => 'id', fields => [qw(id note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {insert => {enabled => 1}},
        fields => {id => {insertable => 1}, org_key => {insertable => 1}, note => {insertable => 1}}}});

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
    my $reset = sub {
        $dbh->do('DROP TABLE IF EXISTS selecto_auto_zero');
        $dbh->do('CREATE TABLE selecto_auto_zero (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, org_key VARCHAR(16),'
            . ' note VARCHAR(16)) ENGINE=InnoDB');
        $dbh->do(q{SET @selecto_mode = @@SESSION.sql_mode});
        $dbh->do(q{SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_AUTO_VALUE_ON_ZERO')});
        $dbh->do(q{INSERT INTO selecto_auto_zero VALUES (0, 't2', 'SECRET')});
        $dbh->do(q{SET SESSION sql_mode = @selecto_mode});
    };
    my $state = sub { join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_auto_zero ORDER BY id')} };
    my $insert = sub {
        my ($id) = @_;
        my $values;
        my $code = eval { $values = $engine->execute_write(Selecto::Write::Command->new(operation => 'insert',
            relation => 'selecto_auto_zero', assignments => {id => $id, org_key => 't1', note => 'mine'},
            metadata => {returning => [qw(id org_key note)]}))->values; 'applied' } // (blessed($@) ? $@->code : "died: $@");
        return ($code, $values);
    };
    for my $zero ('0', '00', ' 0', '0.0', '-0', '+0', 0, 0.0, JSON::PP::false) {
        my $label = "$name id " . (ref($zero) ? 'FALSE' : "'$zero'");
        $reset->();
        my ($code, $values) = $insert->($zero);
        isnt($code, 'applied', "$label: the zero-valued AUTO_INCREMENT insert is refused ($code)");
        ok(!$values || ($values->{note} // '') ne 'SECRET', "$label: id 0's row is never returned");
        is($state->(), '0:t2:SECRET', "$label: nothing is inserted");
    }
    # Controls: a canonical assigned key and a generated key keep working.
    $reset->();
    my ($code, $values) = $insert->(7);
    is($code, 'applied', "$name: a canonical assigned AUTO_INCREMENT key is accepted");
    is_deeply($values, {id => 7, org_key => 't1', note => 'mine'}, "$name: and returns its own row");
    ($code, $values) = $insert->(undef);
    is($code, 'applied', "$name: a generated key is accepted");
    is($values->{note}, 'mine', "$name: and returns its own row");
    $dbh->do('DROP TABLE IF EXISTS selecto_auto_zero');
}
done_testing;
