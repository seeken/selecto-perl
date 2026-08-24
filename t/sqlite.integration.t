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

my $mutation_result = $engine->execute_write(Selecto::Write::Command->new(
    operation => 'update', relation => 'selecto_perl_test_items',
    assignments => {
        amount => Selecto::Write::Expression->increment('amount', 1.25),
    },
    predicate => Selecto::Expression->eq('id', 1),
));
is($mutation_result->affected_rows, 1, 'SQLite executes an adapter-independent mutation expression');
is($dbh->selectrow_array('SELECT amount FROM selecto_perl_test_items WHERE id = 1'), 11.75,
    'the live mutation reads and updates the governed field atomically');

my $set_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))
        ->union_all(
            $engine->query->select('id')->where(Selecto::Expression->eq('id', 1)),
        )
        ->order_by('id'),
);
is_deeply($set_result->{rows}, [[1], [1]], 'SQLite executes a parameterized UNION ALL query');

my $union_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))
        ->union($engine->query->select('id')->where(Selecto::Expression->eq('id', 1))),
);
is_deeply($union_result->{rows}, [[1]], 'SQLite executes UNION with duplicate elimination');

my $intersect_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))
        ->intersect($engine->query->select('id')->where(Selecto::Expression->eq('id', 1))),
);
is_deeply($intersect_result->{rows}, [[1]], 'SQLite executes INTERSECT');

my $except_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))
        ->except($engine->query->select('id')->where(Selecto::Expression->eq('id', 999))),
);
is_deeply($except_result->{rows}, [[1]], 'SQLite executes EXCEPT');

my $mixed_set_result = $engine->all(
    $engine->query->select('id')->where(Selecto::Expression->eq('id', 1))
        ->union_all($engine->query->select('id')->where(Selecto::Expression->eq('id', 1)))
        ->intersect($engine->query->select('id')->where(Selecto::Expression->eq('id', 999))),
);
is_deeply($mixed_set_result->{rows}, [],
    'mixed SQLite set operations preserve the builder\'s left-to-right semantics');

my $window_result = $engine->all(
    $engine->query->select(
        'id', Selecto::Expression->row_number(order_by => [['id', 'asc']])->as('position'),
    ),
);
is_deeply($window_result->{rows}, [[1, 1]], 'SQLite executes a governed window function');

my $cte_source = $engine->query->select('id', 'name')
    ->where(Selecto::Expression->eq('id', 1));
my $cte_result = $engine->all(
    $engine->query
        ->with_cte(
            'selected_items', $domain, $cte_source,
            columns => [qw(id name)],
            join => {owner_key => 'id', related_key => 'id', type => 'inner'},
        )
        ->select('id', 'selected_items.name'),
);
is_deeply($cte_result->{rows}, [[1, 'Renée 東京']], 'SQLite executes a governed CTE');

my $stream = $engine->stream($engine->query->select('id', 'name')->order_by('id'), fetch_size => 1);
is_deeply($stream->next, [1, 'Renée 東京'], 'SQLite streams and decodes one row at a time');
is($stream->next, undef, 'SQLite streaming closes at exhaustion');
ok($stream->closed, 'the live stream releases its statement handle');

$dbh->do('CREATE TABLE selecto_perl_test_employees (id integer primary key, manager_id integer, name text not null)');
$dbh->do(q{INSERT INTO selecto_perl_test_employees VALUES (1, NULL, 'CEO'), (2, 1, 'Lead'), (3, 2, 'Engineer')});
my $employees = Selecto::Domain->new(
    name => 'Employees', table => 'selecto_perl_test_employees',
    fields => {id => 'integer', manager_id => 'integer', name => 'string'},
);
my $employee_engine = Selecto::Engine->new(domain => $employees, adapter => $adapter);
my $anchor = $employee_engine->query->select(qw(id manager_id name))
    ->where(Selecto::Expression->is_null('manager_id'));
my $member = $employee_engine->query->select(qw(id manager_id name));
my $tree = $employee_engine->all(
    $employee_engine->query
        ->with_recursive_cte(
            'employee_tree', $employees, $anchor, $member,
            columns => [qw(id manager_id name)],
            join => {owner_key => 'id', related_key => 'id', type => 'inner'},
            recursive_join => {owner_key => 'manager_id', related_key => 'id', type => 'inner'},
        )
        ->select('id', 'employee_tree.name')
        ->order_by('id'),
);
is_deeply($tree->{rows}, [[1, 'CEO'], [2, 'Lead'], [3, 'Engineer']],
    'SQLite executes the recursive member until the three-level hierarchy is complete');

$dbh->do('CREATE TABLE selecto_perl_test_deep_roots (id integer primary key, child_id integer not null)');
$dbh->do('CREATE TABLE selecto_perl_test_deep_children (id integer primary key, grandchild_id integer not null)');
$dbh->do('CREATE TABLE selecto_perl_test_deep_grandchildren (id integer primary key, label text not null)');
$dbh->do('INSERT INTO selecto_perl_test_deep_roots VALUES (1, 10)');
$dbh->do('INSERT INTO selecto_perl_test_deep_children VALUES (10, 100)');
$dbh->do(q{INSERT INTO selecto_perl_test_deep_grandchildren VALUES (100, 'deep-value')});
my $deep_domain = Selecto::Domain->new(
    name => 'Deep roots', table => 'selecto_perl_test_deep_roots',
    fields => {id => 'integer', child_id => 'integer'},
    associations => {
        child => {
            table => 'selecto_perl_test_deep_children',
            fields => {id => 'integer', grandchild_id => 'integer'},
            owner_key => 'child_id', related_key => 'id',
            associations => {
                grandchild => {
                    table => 'selecto_perl_test_deep_grandchildren',
                    fields => {id => 'integer', label => 'string'},
                    owner_key => 'grandchild_id', related_key => 'id',
                },
            },
        },
    },
);
my $deep_engine = Selecto::Engine->new(domain => $deep_domain, adapter => $adapter);
my $deep_rows = $deep_engine->all(
    $deep_engine->query->select('id', 'child.grandchild.label'),
);
is_deeply($deep_rows->{rows}, [[1, 'deep-value']],
    'SQLite executes a relationship path deeper than one hop');

$dbh->do('CREATE TABLE selecto_perl_test_invoices (id integer primary key, tenant_id integer not null)');
$dbh->do('CREATE TABLE selecto_perl_test_tags (id integer primary key, tenant_id integer not null, label text not null)');
$dbh->do('CREATE TABLE selecto_perl_test_invoice_tags (invoice_id integer not null, tag_id integer not null, tenant_id integer not null)');
$dbh->do('CREATE TABLE selecto_perl_test_invoice_notes (id integer primary key, invoice_id integer not null, tenant_id integer not null, body text not null)');
$dbh->do('INSERT INTO selecto_perl_test_invoices VALUES (1, 10), (2, 20)');
$dbh->do(q{INSERT INTO selecto_perl_test_tags VALUES (5, 10, 'valid'), (6, 20, 'cross-tenant')});
$dbh->do('INSERT INTO selecto_perl_test_invoice_tags VALUES (1, 5, 10), (1, 6, 10), (1, 6, 20)');
$dbh->do(q{INSERT INTO selecto_perl_test_invoice_notes VALUES (7, 1, 10, 'valid'), (8, 1, 20, 'cross-tenant')});
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
        notes => {
            table => 'selecto_perl_test_invoice_notes',
            fields => {
                id => 'integer', invoice_id => 'integer', tenant_id => 'integer',
                body => 'string',
            },
            owner_key => 'id', related_key => 'invoice_id', target_primary_key => 'id',
            cardinality => 'many', join_type => 'left',
            source_scope_key => 'tenant_id', target_scope_key => 'tenant_id',
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
my $direct_collected = $through_engine->all(
    $through_engine->query->select(
        'id', Selecto::Expression->related_collection('notes', ['body'])->as('notes'),
    )->where(Selecto::Expression->eq('id', 1)),
);
is_deeply(
    $direct_collected->{rows},
    [[1, '[{"body":"valid"}]']],
    'live direct related collection rejects a cross-tenant child row',
);

$dbh->disconnect;
done_testing;
