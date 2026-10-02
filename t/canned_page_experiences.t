use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::CannedPage;
use DBI;
my $domain = Selecto::Domain->new(name => 'Products', table => 'products',
    fields => {id => 'integer', name => 'string'}, experiences => {
        products => {kind => 'canned_page', version => 1, definition => 'catalog'},
        other => {kind => 'dashboard'},
    });
is_deeply(Selecto::CannedPage->experiences($domain),
    [{id => 'products', definition => 'catalog', version => 1}], 'discover without executing factories');
SKIP: {
    skip 'DBD::SQLite is not installed', 4 unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1});
    $dbh->do('CREATE TABLE products (id integer primary key, name text)');
    $dbh->do("INSERT INTO products VALUES (1, 'Alpha')");
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my $factory = sub {
        my ($e) = @_;
        Selecto::CannedPage->new(id => 'products', domain => $e->domain,
            dataset => {query => $e->query, entity_key => ['id']},
            views => [{id => 'detail', kind => 'detail', query => $e->query->select('id', 'name')}], controls => []);
    };
    my $page = Selecto::CannedPage->from_experience($engine, 'products', {catalog => $factory});
    is($page->run($engine, {})->{total}, 1, 'resolved page executes native query');
    for my $case (['missing', {}], ['products', {}], ['products', {catalog => sub { return undef }}]) {
        eval { Selecto::CannedPage->from_experience($engine, @$case) };
        like("$@", qr/(unknown|unbound|factory)/, 'invalid resolution rejected');
    }
}
my $bad = Selecto::Domain->new(name => 'Bad', table => 'products', fields => {id => 'integer'},
    experiences => {products => {kind => 'canned_page', version => 2, definition => 'catalog'}});
eval { Selecto::CannedPage->experiences($bad) };
like("$@", qr/invalid canned-page experience/, 'unsupported version rejected');
done_testing;
