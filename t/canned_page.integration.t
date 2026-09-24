use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::CannedPage;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do('CREATE TABLE products (id integer primary key, name text, category text, brand text, price integer, visible integer)');
$dbh->do('CREATE TABLE product_tags (id integer primary key, product_id integer, label text)');
$dbh->do(q{INSERT INTO products VALUES
    (1, 'Alpha shoe', 'shoes', 'Acme', 20, 1),
    (2, 'Beta shoe', 'shoes', 'North', 40, 1),
    (3, 'Gamma shoe', 'shoes', 'Acme', 50, 1),
    (4, 'Delta hat', 'hats', 'North', 10, 1),
    (5, 'Hidden shoe', 'shoes', 'Secret', 20, 0),
    (6, 'Epsilon toy', 'toys', NULL, 5, 1)});
$dbh->do(q{INSERT INTO product_tags VALUES
    (1,1,'sale'), (2,1,'sale'), (3,1,'new'),
    (4,2,'new'), (5,3,'sale'), (6,4,'sale')});
my $domain = Selecto::Domain->new(
    name => 'Products', table => 'products',
    fields => {id => 'integer', name => 'string', category => 'string',
        brand => 'string', price => 'integer', visible => 'integer'},
    associations => {tags => {
        table => 'product_tags', fields => {id => 'integer', product_id => 'integer', label => 'string'},
        owner_key => 'id', related_key => 'product_id', target_primary_key => 'id',
        cardinality => 'many', join_type => 'left',
    }},
);
my $engine = Selecto::Engine->new(domain => $domain,
    adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
my $page = Selecto::CannedPage->new(
    id => 'products', domain => $domain,
    dataset => {query => $engine->query->where(Selecto::Expression->eq('visible', 1)),
        entity_key => ['id']},
    views => [
        {id => 'list', kind => 'detail', query => $engine->query
            ->select('id', 'name', 'brand')->order_by('price')},
        {id => 'categories', kind => 'aggregate', query => $engine->query
            ->select('category', Selecto::Expression->count_distinct('id')->as('items'))
            ->group_by('category')->order_by('category')},
    ],
    controls => [
        {id => 'brand', field => 'brand', kind => 'facet', values => {limit => 20, searchable => 1}},
        {id => 'tags', field => 'tags.label', kind => 'facet', values => {limit => 20}},
        {id => 'category', field => 'category', kind => 'facet',
            values => {source => 'fixed', options => [
                {value => 'shoes', label => 'Shoes'},
                {value => 'hats', label => 'Hats'},
                {value => 'bags', label => 'Bags'},
            ]}},
        {id => 'price', field => 'price', kind => 'range'},
        {id => 'search', field => 'name', kind => 'text'},
    ],
    initial_state => {view => 'list', filters => {category => ['shoes']}},
);

my $initial = $page->run($engine, {});
is($initial->{total}, 3, 'defaults and fixed visibility scope apply');
is_deeply($initial->{rows}, [
    [1, 'Alpha shoe', 'Acme'], [2, 'Beta shoe', 'North'], [3, 'Gamma shoe', 'Acme'],
], 'initial detail view is useful immediately');
is_deeply([map { [$_->{value}, $_->{count}] } @{$initial->{facets}{brand}{options}}],
    [['Acme', 2], ['North', 1]], 'brand counts use matching entity IDs');
is_deeply([map { [$_->{label}, $_->{count}] } @{$initial->{facets}{category}{options}}],
    [['Shoes', 3], ['Hats', 1], ['Bags', 0]], 'fixed choices retain order, labels, and zero buckets');

my $filtered = $page->run($engine, {filters => {
    category => ['shoes'], brand => ['Acme'], tags => ['sale', 'new'],
}});
is($filtered->{total}, 2, 'OR within tags, AND across controls, with duplicate join rows removed');
is_deeply($filtered->{rows}, [[1, 'Alpha shoe', 'Acme'], [3, 'Gamma shoe', 'Acme']],
    'detail pagination grain stays one row per product');
is_deeply([map { [$_->{value}, $_->{count}] } @{$filtered->{facets}{brand}{options}}],
    [['Acme', 2], ['North', 1]], 'brand facet removes only its own selection');
is_deeply([map { [$_->{value}, $_->{count}] } @{$filtered->{facets}{tags}{options}}],
    [['sale', 2], ['new', 1]], 'tag counts deduplicate repeated matching tags');

my $aggregate = $page->run($engine, {view => 'categories', filters => {
    brand => ['Acme'], tags => ['sale', 'new'],
}});
is_deeply($aggregate->{rows}, [['shoes', 2]],
    'aggregate view counts the same filtered entities');
is($aggregate->{total}, 2, 'total remains matching entities in aggregate view');
my $drilled = $page->run($engine, {view => 'list',
    drilldown => {view => 'categories', values => ['shoes']},
    filters => {brand => ['Acme']}});
is_deeply($drilled->{rows}, [[1, 'Alpha shoe', 'Acme'], [3, 'Gamma shoe', 'Acme']],
    'aggregate drilldown narrows the detail view while retaining brand filter');
my $null_drilldown = $page->run($engine, {view => 'list',
    drilldown => {view => 'categories', values => [undef]}});
is($null_drilldown->{total}, 0, 'null aggregate group uses an IS NULL drilldown predicate');

my $cleared = $page->run($engine, {filters => {category => []}});
is($cleared->{total}, 5, 'explicitly cleared defaults stay cleared');
is_deeply([map { $_->{value} } @{$cleared->{facets}{brand}{options}}],
    ['Acme', 'North'], 'unsupported null facet bucket does not consume a bounded option slot');
my $second = $page->run($engine, {page => 2, limit => 1, filters => {category => ['shoes']}});
is_deeply($second->{rows}, [[2, 'Beta shoe', 'North']],
    'detail pagination is deterministic after joining and deduplicating');
ok($second->{has_more}, 'bounded detail query reports a following page');
my $last = $page->run($engine, {page => 3, limit => 1, filters => {category => ['shoes']}});
ok(!$last->{has_more}, 'last page does not offer a spurious next page');
my $restricted = $page->run($engine, {filters => {category => ['shoes'], brand => ['Secret']}});
is($restricted->{total}, 0, 'hidden records never enter results');
is_deeply([map { $_->{value} } @{$restricted->{facets}{brand}{options}}],
    ['Acme', 'North', 'Secret'], 'selected zero option remains visible without exposing hidden label');
my $searched = $page->run($engine, {facet_search => {brand => 'No'}, filters => {brand => ['Acme']}});
is_deeply([map { $_->{value} } @{$searched->{facets}{brand}{options}}],
    ['North', 'Acme'], 'option search narrows catalogue while retaining a selected value');
is($searched->{total}, 2, 'option search does not change result membership');
my $scoped = $page->run($engine, {filters => {brand => ['Acme']}},
    Selecto::Expression->eq('brand', 'North'));
is($scoped->{total}, 0, 'request scope intersects the selected facet');
is_deeply([map { $_->{value} } @{$scoped->{facets}{brand}{options}}],
    ['North', 'Acme'], 'self-excluding facet counts retain request scope');
is($scoped->{facets}{brand}{options}[1]{count}, 0,
    'selected value outside request scope has zero count');
my $injected = q{Acme' OR 1=1};
my $statement = $engine->compile($page->plan({filters => {brand => [$injected]}})->{query});
unlike($statement->sql, qr/Acme' OR 1=1/, 'facet input never enters SQL text');
ok(scalar(grep { defined($_) && $_ eq $injected } @{$statement->params}),
    'facet input is bound as a value');
my $small_controls = $page->controls;
$small_controls->[0]{values} = {limit => 1};
my $small = Selecto::CannedPage->new(
    id => 'small', domain => $domain,
    dataset => {query => $engine->query->where(Selecto::Expression->eq('visible', 1)),
        entity_key => ['id']},
    views => $page->views, controls => $small_controls,
);
my $limited = $small->run($engine, {filters => {brand => ['North'], category => ['shoes']}});
is_deeply([map { [$_->{value}, $_->{count}] } @{$limited->{facets}{brand}{options}}],
    [['Acme', 2], ['North', 1]], 'selected option outside bounded top buckets gets exact count');
ok($limited->{facets}{brand}{truncated}, 'bounded option list reports truncation');

for my $bad (
    {filters => {unknown => ['x']}},
    {view => 'unknown'},
    {filters => {brand => 'Acme'}},
    {limit => 9999},
    {filters => {category => ['secret']}},
    {facet_search => {category => 'sh'}},
    {filters => {price => {min => 'not-a-number'}}},
    {drilldown => {view => 'list', values => ['shoes']}},
    {drilldown => {view => 'categories', values => []}},
) {
    eval { $page->plan($bad) };
    is($@->code, 'invalid_canned_page', 'invalid client state fails before execution');
}

done_testing;
