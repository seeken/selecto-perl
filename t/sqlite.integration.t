use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
});
$dbh->do('CREATE TABLE selecto_perl_test_items (id integer primary key, name text not null, amount decimal(12,2))');
$dbh->do(q{INSERT INTO selecto_perl_test_items VALUES (1, 'Renée 東京', 10.50)});

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'selecto_perl_test_items',
    fields => { id => 'integer', name => 'string', amount => 'decimal' },
);
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $result = $engine->all($engine->query->select('id', 'name', 'amount')->order_by('id'));
is_deeply(
    $result,
    { columns => ['id', 'name', 'amount'], rows => [[1, 'Renée 東京', 10.5]] },
    'public query API executes through DBD::SQLite',
);

is($adapter->placeholder(2), '?', 'SQLite uses DBI positional placeholders');
is($adapter->normalize_type('datetime'), 'naive_datetime', 'SQLite types normalize portably');
ok($adapter->supports('transactions'), 'SQLite declares transaction support');
ok(!$adapter->supports('returning'), 'SQLite does not overclaim unimplemented returning support');

my $unsupported = $engine->query->select(Selecto::Expression->datetime_format('name', 'month'));
eval { $engine->compile($unsupported) };
is($@->code, 'invalid_query', 'dialect-specific expressions fail closed until SQLite translations exist');

my $first = Selecto::Write::Command->new(
    operation => 'insert', relation => 'selecto_perl_test_items',
    assignments => { id => 2, name => 'must-roll-back', amount => 20 },
);
my $second = Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_test_items', assignments => { name => 'never' },
    predicate => Selecto::Expression->eq('id', 999),
);
eval { $engine->execute_batch(Selecto::Write::Batch->new($first, $second)) };
is($@->code, 'cardinality_mismatch', 'live batch reports a portable cardinality error');
is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_test_items'), 1, 'failed live batch rolls back atomically');

$dbh->do('CREATE TABLE selecto_perl_test_invoices (id integer primary key, tenant_id integer not null)');
$dbh->do('CREATE TABLE selecto_perl_test_tags (id integer primary key, tenant_id integer not null, label text not null)');
$dbh->do('CREATE TABLE selecto_perl_test_invoice_tags (invoice_id integer not null, tag_id integer not null, tenant_id integer not null)');
$dbh->do('INSERT INTO selecto_perl_test_invoices VALUES (1, 10), (2, 20)');
$dbh->do(q{INSERT INTO selecto_perl_test_tags VALUES (5, 10, 'valid'), (6, 20, 'cross-tenant')});
$dbh->do('INSERT INTO selecto_perl_test_invoice_tags VALUES (1, 5, 10), (1, 6, 10), (1, 6, 20)');
my $through_domain = Selecto::Domain->new(
    name => 'Scoped invoice tags',
    table => 'selecto_perl_test_invoices',
    primary_key => 'id',
    tenant_field => 'tenant_id',
    fields => {id => 'integer', tenant_id => 'integer'},
    associations => {
        tags => {
            table => 'selecto_perl_test_tags',
            fields => {id => 'integer', tenant_id => 'integer', label => 'string'},
            owner_key => 'id', related_key => 'id', target_primary_key => 'id',
            cardinality => 'many', join_type => 'left',
            through => {
                table => 'selecto_perl_test_invoice_tags',
                owner_key => 'invoice_id', related_key => 'tag_id',
                source_scope_key => 'tenant_id', through_scope_key => 'tenant_id',
                target_scope_key => 'tenant_id',
            },
        },
    },
);
my $through_engine = Selecto::Engine->new(
    domain => $through_domain,
    adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
);
my $joined = $through_engine->all(
    $through_engine->query->select('id', 'tags.label')
        ->where(Selecto::Expression->eq('id', 1)),
);
is_deeply(
    $joined->{rows},
    [[1, 'valid']],
    'live through join rejects bridge rows outside root or target scope',
);
my $collected = $through_engine->all(
    $through_engine->query->select(
        'id', Selecto::Expression->related_collection('tags', ['label'])->as('tags'),
    )->where(Selecto::Expression->eq('id', 1)),
);
is_deeply(
    $collected->{rows},
    [[1, '[{"label":"valid"}]']],
    'live related collection traverses the scoped keyless bridge once',
);

$dbh->disconnect;
done_testing;
