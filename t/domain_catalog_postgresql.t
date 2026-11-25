use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestPostgreSQL;
use Selecto::DomainCatalog;
use Selecto::DomainCatalog::MemoryStore;
use Selecto::DomainCatalog::Source::Store;
use Selecto::Expression;
use Selecto::Engine;
use Selecto::PostgreSQL;

plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless TestPostgreSQL::configured();
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $dbh = TestPostgreSQL->connect;
$dbh->do('CREATE TEMP TABLE orders (id integer PRIMARY KEY, account_id integer NOT NULL)');
$dbh->do('INSERT INTO orders VALUES (1, 11), (2, 22)');
my $document = {schema_version => 1, name => 'Orders',
    source => {source_table => 'orders', primary_key => 'id', fields => [qw(id account_id)],
        columns => {id => {type => 'integer'}, account_id => {type => 'integer'}}, associations => {}},
    schemas => {}, joins => {},
    extensions => {catalog => {id => 'orders', adapter => 'postgresql', scope_policy => 'by_account'}}};
my $store = Selecto::DomainCatalog::MemoryStore->new->put('orders', 'one', $document);
my $catalog = Selecto::DomainCatalog->new(
    sources => [Selecto::DomainCatalog::Source::Store->new(store => $store)],
    allowed_sources => ['orders'], scope_policies => {by_account => sub {
        return {tenant_field => 'account_id', required_predicate => Selecto::Expression->eq('account_id', 11)};
    }});
is($catalog->report('orders')->{status}, 'ok', 'PostgreSQL static admission passes');
my $engine = Selecto::Engine->new(domain => $catalog->get('orders'), adapter => Selecto::PostgreSQL->new(dbh => $dbh));
is_deeply($engine->all($engine->query->select('id'))->{rows}, [[1]], 'PostgreSQL applies the host policy');
is_deeply($engine->all($engine->query->select('id')->where(Selecto::Expression->eq('account_id', 22)))->{rows}, [],
    'caller predicate cannot replace host scope');
$dbh->disconnect;
done_testing;
