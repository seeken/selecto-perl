use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::SQLite ();

# The engine-API query handler returns a selected boolean field as JSON true
# or false, whatever the driver returns for it (DBD::SQLite and DBD::Pg give 1
# and 0), as the explorer does; NULL stays null. Aggregates over a boolean
# field and exports are unchanged.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}, sub { Selecto::SQLite->new(dbh => $_[0]) }]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages = warning');
    $dbh;
}, sub { require Selecto::PostgreSQL; Selecto::PostgreSQL->new(dbh => $_[0]) }] if $db && eval { require DBD::Pg; 1 };

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', name => 'Flags',
    source => {source_table => 'selecto_test_flags', primary_key => 'id', fields => [qw(id paid label)],
        columns => {id => {type => 'integer'}, paid => {type => 'boolean', nullable => JSON::PP::true},
            label => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {},
}, strict => 1);
my $json = JSON::PP->new->canonical;

for my $backend (@backends) {
    my ($name, $connect, $adapter) = @$backend;
    my $dbh = $connect->();
    my $bool = $name eq 'postgresql' ? 'BOOLEAN' : 'INTEGER';
    my ($true, $false) = $name eq 'postgresql' ? ('TRUE', 'FALSE') : (1, 0);
    $dbh->do('DROP TABLE IF EXISTS selecto_test_flags');
    $dbh->do("CREATE TABLE selecto_test_flags (id INTEGER PRIMARY KEY, paid $bool NULL, label TEXT NOT NULL)");
    $dbh->do("INSERT INTO selecto_test_flags VALUES (1, $true, 'a'), (2, $false, 'b'), (3, NULL, 'c')");
    my $engine = Selecto::Engine->new(adapter => $adapter->($dbh), domain => $domain);
    my $handler = Selecto::API::EngineHandler->new(aggregate_selections => 1);

    my $rows = $handler->query($engine, {select => [qw(id paid)], order_by => [{field => 'id'}]})->{rows};
    is $json->encode($rows), '[[1,true],[2,false],[3,null]]', "$name: booleans are JSON true/false";
    $rows = $handler->query($engine, {select => [{field => 'paid', alias => 'settled'}, 'id'],
        order_by => [{field => 'id'}], row_format => 'objects'})->{rows};
    is $json->encode($rows->[0]), '{"id":1,"settled":true}', "$name: an aliased boolean, as objects";
    $rows = $handler->query($engine, {select => ['paid', {aggregate => 'count', alias => 'n'}],
        group_by => ['paid'], rollup => JSON::PP::true})->{rows};
    my @keys = sort map { $json->encode($_->[0]) } grep { $_->[2] == 0 } @$rows;
    is_deeply \@keys, [qw(false null true)], "$name: boolean group keys in subtotal rows";
    $dbh->do('DROP TABLE selecto_test_flags');
    $dbh->disconnect;
}

done_testing;
