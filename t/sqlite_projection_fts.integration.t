use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Domain::Projection;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
    {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
$db->do('PRAGMA temp_store=MEMORY');
my $adapter = Selecto->adapter(sqlite => dbh => $db);
plan skip_all => 'connected SQLite lacks FTS5' unless $adapter->supports('text_search');
$db->do('CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT, tenant INTEGER)');
$db->do(q{CREATE VIRTUAL TABLE items_search USING fts5(title, content='items', content_rowid='id')});
$db->do('INSERT INTO items VALUES(?,?,?)', undef, @$_) for [1, 'Oak', 10], [2, 'Oaken', 20], [3, 'Elm', 10];
$db->do(q{INSERT INTO items_search(items_search) VALUES('rebuild')});
my $raw = {schema_version => 1, name => 'Projected Items', source => {
    source_table => 'items', primary_key => 'id', fields => [qw(id title tenant)],
    columns => {id => {type => 'integer'}, title => {type => 'string'}, tenant => {type => 'integer'}},
    associations => {}, fts5_index => {table => 'items_search', key => 'id'},
}, schemas => {}, joins => {}, required_filters => [['tenant', 10]],
    columns => {title => {detail_selectable => JSON::PP::false}}, redact_fields => ['title']};
my $json = JSON::PP->new->canonical;
my $before = $json->encode($raw);
my $projected = Selecto::Domain->project($raw, 'query');
is_deeply($projected->{source}{fts5_index}, {table => 'items_search', key => 'id'},
    'query projection preserves the complete declared external-index metadata');
ok(!exists($projected->{columns}) && !exists($projected->{redact_fields}),
    'query projection keeps the original presentation section boundary');
# The portable projection also carries domain_data/extensions metadata that the
# native strict parser does not enroll. Its existing permissive import mode
# accepts the complete projected declaration without altering source or scope.
my $domain = Selecto::Domain->parse($projected, strict => 0);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $search = Selecto::Expression->text_search(['title'], 'oak:*', mode => 'prefix');
my $query = $engine->query->select('id', 'title')->where($search)->order_by('id');
is_deeply($engine->all($query)->{rows}, [[1, 'Oak']],
    'public projected domain executes native prefix lookup with required tenant predicate');
$projected->{source}{fts5_index}{table} = 'other';
$projected->{source}{fts5_index}{key} = 'tenant';
is_deeply($domain->fts5_index, {table => 'items_search', key => 'id'},
    'editing the projected declaration cannot mutate parsed native index metadata');
my $returned = $domain->fts5_index;
$returned->{table} = 'other';
is_deeply($engine->all($query)->{rows}, [[1, 'Oak']],
    'editing returned index metadata leaves configured native lookup intact');
is($json->encode($raw), $before, 'projection, parsing and returned-metadata edits leave full raw input unchanged');
my $ui = Selecto::Domain->project($raw, 'ui');
${$ui->{columns}{title}{detail_selectable}} = 1;
ok(!$raw->{columns}{title}{detail_selectable}, 'composed Boolean copy remains isolated');
my $rows = $db->selectall_arrayref('SELECT * FROM main.items ORDER BY id');
is_deeply($rows, [[1,'Oak',10],[2,'Oaken',20],[3,'Elm',10]], 'cross-feature reads leave all physical values unchanged');
is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP remains in memory');
ok(!(grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}), 'all actual databases remain in memory');
$db->disconnect;
done_testing;
