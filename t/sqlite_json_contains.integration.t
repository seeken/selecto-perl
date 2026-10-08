use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use Selecto;

plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
$dbh->do('CREATE TABLE documents (id INTEGER PRIMARY KEY, body TEXT)');
my @documents = (
    '[1,"1",true,false,null,"foo"]', '["foo","bar"]', '"bar"', '[[1,3]]',
    '{"a":[1,3]}', '{"a":1,"a":2}', '{"a":true,"a":1}',
    '{"nested":{"a":1,"a":2}}', '[{"a":1,"a":2}]',
    '[9223372036854775807]', '[1.2300]', '[]', '{"a":null}', '{}', 'null',
);
for my $index (0 .. $#documents) {
    $dbh->do('INSERT INTO documents VALUES (?, ?)', undef, $index + 1, $documents[$index]);
}
my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'JSON documents', source => {
    source_table => 'documents', primary_key => 'id', fields => [qw(id body)],
    columns => {id => {type => 'integer'}, body => {type => 'jsonb'}}, associations => {},
}, schemas => {}, joins => {}});
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $x = 'Selecto::Expression';
sub ids {
    my ($needle) = @_;
    my $query = $engine->query->select('id')->where($x->json_contains('body', $needle))->order_by('id');
    return [map { $_->[0] } @{$engine->all($query)->{rows}}];
}
is_deeply(ids('bar'), [2,3], 'root arrays may contain a primitive string');
is_deeply(ids(["bar"]), [2], 'primitive-to-array containment is not reciprocal');
is_deeply(ids(1), [1], 'root array matches only the numeric primitive');
is_deeply(ids('1'), [1], 'string primitive retains its JSON type');
is_deeply(ids(JSON::PP::true), [1], 'root array supports Boolean primitives without numeric equality');
is_deeply(ids(JSON::PP::false), [1], 'false is distinct from numeric zero');
is_deeply(ids(undef), [1,15], 'JSON null is contained by a root array or identical JSON null');
is_deeply(ids(9223372036854775807), [10], 'root primitive exception retains wide integer precision');
is_deeply(ids(1.23), [11], 'numeric representations compare by value');
is_deeply(ids([1]), [1], 'matching does not flatten a nested array');
is_deeply(ids([[1,3]]), [4], 'nested arrays require a matching nested RHS structure');
is_deeply(ids({a => 1}), [7], 'an object member array cannot contain a primitive member');
is_deeply(ids({a => [1]}), [5], 'object-member arrays retain structural containment');
is_deeply(ids({a => 2}), [6], 'last duplicate object key replaces the earlier key');
is_deeply(ids({a => JSON::PP::true}), [], 'duplicate key replacement preserves the final numeric type');
is_deeply(ids({nested => {a => 2}}), [8], 'last duplicate keys apply recursively');
is_deeply(ids([{a => 2}]), [9], 'duplicate object keys inside arrays use their final value');
is_deeply(ids({a => undef}), [13], 'null object values remain distinct from absent keys');
is_deeply(ids([]), [1,2,4,9,10,11,12], 'empty arrays only match arrays');
is_deeply(ids({}), [5,6,7,8,13,14], 'empty objects only match objects');
my $statement = $engine->compile($engine->query->select('id')->where($x->json_contains('body', 'bar')));
ok(@{$statement->params}, 'primitive JSON needle remains a bound value');
my $databases = $dbh->selectall_arrayref('PRAGMA database_list');
is_deeply([map { $_->[2] } @$databases], [''], 'native fixture remains entirely in memory');
$dbh->disconnect;
done_testing;
