use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
use JSON::PP ();
use Storable qw(dclone);
use Selecto;
use Selecto::CoDomain;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }

my $x = 'Selecto::Expression';
sub error_code {
    my ($run) = @_;
    return 'ok' if eval { $run->(); 1 };
    my $error = $@;
    return ref($error) && $error->can('code') ? $error->code : die $error;
}
sub contract {
    return {schema_version => 1, name => 'Items', source => {
        source_table => 'items', primary_key => 'id', fields => [qw(id title body tenant)],
        columns => {id => {type => 'integer'}, title => {type => 'string'},
            body => {type => 'string'}, tenant => {type => 'integer'}}, associations => {},
        fts5_index => {table => 'items_search', key => 'id'},
    }, schemas => {}, joins => {}, query_library => {
        projections => {lookup => {fields => ['id', 'title']}},
        orderings => {title => {order_by => [['title', 'asc'], ['id', 'asc']]}},
    }, co_domains => {items => {
        domain => 'items', projection => 'lookup', ordering => 'title',
        search => {fields => ['title'], mode => 'prefix', configuration => 'simple', rank => JSON::PP::true},
        result => {value_field => 'id', label_field => 'title'},
    }}};
}
sub memory {
    my ($run, %options) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    my $adapter = Selecto->adapter(sqlite => dbh => $db);
    unless ($adapter->supports('text_search')) { $db->disconnect; plan skip_all => 'connected SQLite lacks FTS5' }
    $db->do($options{root} // 'CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT, body TEXT, tenant INTEGER)');
    $db->do('CREATE TABLE other(id INTEGER PRIMARY KEY, title TEXT, body TEXT, tenant INTEGER)');
    $db->do($options{index} // q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='items', content_rowid='id')});
    unless ($options{empty}) {
        $db->do('INSERT INTO items VALUES(?,?,?,?)', undef, @$_) for
            [1, 'Oak', 'red lamp', 10], [2, 'Oak Oak Oak', 'blue lamp', 10],
            [3, 'Oaken tree', 'red bell', 20], [4, 'Elm', 'oak in body', 10];
        $db->do(q{INSERT INTO items_search(items_search) VALUES('rebuild')});
    }
    $run->($db, $adapter);
    $db->disconnect;
}
sub engine { Selecto::Engine->new(domain => Selecto::Domain->parse($_[0], strict => 1), adapter => $_[1]) }
sub ids {
    my ($engine, $predicate) = @_;
    return $engine->all($engine->query->select('id')->where($predicate)->order_by('id'))->{rows};
}
sub native_trace {
    my ($run) = @_;
    my $prepare = \&DBI::db::prepare;
    my @sql;
    no warnings 'redefine';
    local *DBI::db::prepare = sub { push @sql, $_[1]; return $prepare->(@_) };
    my $result = error_code($run);
    return ($result, [grep { /\bFROM\s+"items"\s/i } @sql], \@sql);
}

subtest 'ordinary content executes governed search, bound prefixes and native ranking' => sub { memory(sub {
    my ($db, $adapter) = @_;
    my $engine = engine(contract(), $adapter);
    my ($result, $business, $native) = native_trace(sub { ids($engine, $x->text_search(['title'], 'Oak')) });
    is($result, 'ok', 'positive native preparation trace observes successful read');
    ok(@$business && @$native > @$business, 'positive trace sees business preparation and catalog calls');
    is_deeply(ids($engine, $x->text_search(['title'], 'Oak')), [[1], [2]], 'plain term matches only indexed selected column');
    is_deeply(ids($engine, $x->text_search(['title', 'body'], 'red lamp', mode => 'phrase')), [[1]], 'phrase matches selected indexed column set');
    my $prefix = $x->text_search(['title'], 'oak:*', mode => 'prefix');
    my $compiled = $engine->compile($engine->query->select('id')->where($prefix));
    ok((grep { defined($_) && $_ eq 'oak:*' } @{$compiled->params}), 'canonical prefix is retained as a bound value');
    unlike($compiled->sql, qr/oak:\*/, 'search data is absent from SQL');
    is_deeply(ids($engine, $prefix), [[1], [2], [3]], 'native prefix executes on external index');
    my $rank = $x->text_rank(['title'], 'Oak')->as('rank');
    my $rows = $engine->all($engine->query->select('id', $rank)->where($x->text_search(['title'], 'Oak'))
        ->order_by($x->text_rank(['title'], 'Oak'), 'asc'))->{rows};
    is_deeply([map { $_->[0] } @$rows], [2, 1], 'stronger repeated match has first native BM25 score');
    ok($rows->[0][1] < $rows->[1][1] && $rows->[1][1] < 0, 'public raw rank retains actual negative BM25');
    my $scoped = Selecto::Engine->new(domain => $engine->domain->with_required_predicate($x->eq('tenant', 10)), adapter => $adapter);
    my $lookup = Selecto::CoDomain->lookup(source_domain => $engine->domain, engine => $scoped,
        co_domain => 'items', query => q{Oak'); --}, limit => 1);
    is_deeply($lookup->{results}, [{value => '2', label => 'Oak Oak Oak'}], 'co-domain strongest result wins before named ordering and limit');
    my $excluded = Selecto::CoDomain->lookup(source_domain => $engine->domain, engine => $scoped,
        co_domain => 'items', query => 'Oak', predicate => $x->eq('id', 3));
    is_deeply($excluded->{results}, [], 'required tenant scope and request predicate both survive lookup');
    is_deeply(Selecto::CoDomain->lookup(source_domain => $engine->domain, engine => $scoped,
        co_domain => 'items', query => '---')->{results}, [], 'tokenless lookup performs no search');
    $db->do(q{UPDATE items SET title='Birch' WHERE id=1});
    $db->do(q{INSERT INTO items_search(items_search) VALUES('rebuild')});
    is_deeply(ids($engine, $x->text_search(['title'], 'Oak')), [[2]], 'stored content/index counter changes actual result');
    is_deeply(ids($engine, $x->text_search(['title'], 'Birch')), [[1]], 'new stored text becomes searchable');
    is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP stays in memory');
    ok(!(grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}), 'every SQLite database stays in memory');
}) };

subtest 'index declaration is copied, fingerprinted and sealed' => sub { memory(sub {
    my ($db, $adapter) = @_;
    my $raw = contract();
    my $domain = Selecto::Domain->parse($raw);
    $raw->{source}{fts5_index}{table} = 'changed';
    is($domain->fts5_index->{table}, 'items_search', 'input declaration cannot mutate parsed metadata');
    my $returned = $domain->fts5_index;
    $returned->{table} = 'changed';
    is($domain->fts5_index->{table}, 'items_search', 'returned declaration cannot mutate domain');
    is_deeply(Selecto::Domain->parse($domain->as_contract)->fts5_index, $domain->fts5_index, 'index survives canonical projection');
    my $simple = Selecto::Domain->new(name => 'Items', table => 'items', fields => {id => 'integer', title => 'string'}, primary_key => 'id');
    my $indexed = Selecto::Domain->new(name => 'Items', table => 'items', fields => {id => 'integer', title => 'string'}, primary_key => 'id', fts5_index => {table => 'items_search', key => 'id'});
    isnt($simple->fingerprint, $indexed->fingerprint, 'native domain fingerprint includes supplied index');
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    $domain->{fts5_index}{table} = 'other';
    is(error_code(sub { ids($engine, $x->text_search(['title'], 'Oak')) }), 'domain_modified_after_configuration', 'private seal detects edited index declaration');
    {
        package FtsTest::CloneHook;
        our $calls = 0;
        sub STORABLE_freeze { $calls++; die 'untrusted clone hook invoked' }
    }
    my $untrusted = contract();
    $untrusted->{source}{fts5_index} = bless {table => 'items_search', key => 'id'}, 'FtsTest::CloneHook';
    is(error_code(sub { Selecto::Domain->parse($untrusted) }), 'invalid_query_library', 'nonplain index metadata refuses before canonical clone');
    is($FtsTest::CloneHook::calls, 0, 'index metadata cannot invoke clone hooks');
}) };

for my $case (
    ['wrong content', q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='other', content_rowid='id')}],
    ['wrong key', q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='items', content_rowid='tenant')}],
    ['unindexed field', q{CREATE VIRTUAL TABLE items_search USING fts5(title UNINDEXED, body, content='items', content_rowid='id')}],
    ['wrong tokenizer', q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='items', content_rowid='id', tokenize='porter')}],
    ['reduced detail', q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='items', content_rowid='id', detail='none')}],
    ['ordinary index impostor', 'CREATE TABLE items_search(title TEXT, body TEXT)'],
    ['comment syntax', q{CREATE VIRTUAL TABLE items_search USING fts5(title /* declaration comment */, body, content='items', content_rowid='id')}],
) {
    subtest $case->[0] => sub { memory(sub {
        my ($db, $adapter) = @_;
        my $engine = engine(contract(), $adapter);
        my ($result, $business, $native) = native_trace(sub { ids($engine, $x->text_search(['title'], 'Oak')) });
        is($result, 'unsupported_feature', 'mismatched native index refuses');
        is(scalar(@$business), 0, 'native mismatch prepares no business statement');
        ok(@$native, 'native mismatch inspects catalog before refusal');
        is($db->selectrow_array('SELECT count(*) FROM items'), 0, 'ordinary business state remains unchanged');
        is($db->selectrow_array('PRAGMA query_only'), 0, 'refusal restores prior read-only state');
    }, index => $case->[1], empty => 1) };
}
for my $case (
    ['nonalias key', 'CREATE TABLE items(id INT PRIMARY KEY, title TEXT, body TEXT, tenant INTEGER)'],
    ['descending key', 'CREATE TABLE items(id INTEGER PRIMARY KEY DESC, title TEXT, body TEXT, tenant INTEGER)'],
    ['without rowid', 'CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT, body TEXT, tenant INTEGER) WITHOUT ROWID'],
    ['generated field', q{CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT GENERATED ALWAYS AS ('Oak') STORED, body TEXT, tenant INTEGER)}],
    ['numeric storage', 'CREATE TABLE items(id INTEGER PRIMARY KEY, title INTEGER, body TEXT, tenant INTEGER)'],
) {
    subtest $case->[0] => sub { memory(sub {
        my ($db, $adapter) = @_;
        my ($result, $business, $native) = native_trace(sub { ids(engine(contract(), $adapter), $x->text_search(['title'], 'Oak')) });
        is($result, 'unsupported_feature', 'native root storage mismatch refuses');
        is(scalar(@$business), 0, 'storage mismatch prepares no business statement');
        is($db->selectrow_array('SELECT count(*) FROM items'), 0, 'root storage preserved');
    }, root => $case->[1], empty => 1) };
}

subtest 'catalog identity, TEMP shadows and caller transactions remain authoritative' => sub { memory(sub {
    my ($db, $adapter) = @_;
    my $engine = engine(contract(), $adapter);
    $db->sqlite_create_collation('NOCASE', sub { 0 });
    is_deeply(ids($engine, $x->text_search(['title'], 'Oak')), [[1], [2]], 'host NOCASE cannot change native catalog identity');
    $db->do('BEGIN');
    $db->do(q{UPDATE items SET body='host work' WHERE id=4});
    for my $prior (0, 1) {
        $db->do('PRAGMA query_only=' . $prior);
        is_deeply(ids($engine, $x->text_search(['title'], 'Oak')), [[1], [2]], 'search succeeds inside caller transaction');
        is($db->selectrow_array('PRAGMA query_only'), $prior, 'search preserves caller query_only exactly');
        ok(!$db->sqlite_get_autocommit, 'caller transaction remains open');
    }
    $db->do('PRAGMA query_only=OFF');
    $db->do('ROLLBACK');
    is($db->selectrow_array('SELECT body FROM items WHERE id=4'), 'oak in body', 'caller work was never committed');
    for my $table ('ITEMS', 'ITEMS_SEARCH') {
        $db->do("CREATE TEMP TABLE $table(id INTEGER, title TEXT)");
        is(error_code(sub { ids($engine, $x->text_search(['title'], 'Oak')) }), 'unsupported_feature', 'case-insensitive TEMP shadow refuses main identity');
        is($db->selectrow_array("SELECT count(*) FROM temp.$table"), 0, 'TEMP shadow remains unchanged');
        $db->do("DROP TABLE temp.$table");
    }
    $db->do('DROP TABLE items_search');
    $db->do(q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='other', content_rowid='id')});
    is(error_code(sub { ids($engine, $x->text_search(['title'], 'Oak')) }), 'unsupported_feature', 'catalog proof is repeated after host replacement');
}) };

subtest 'structural fields, bounds and fabricated catalog wrappers refuse before search' => sub { memory(sub {
    my ($db, $adapter) = @_;
    for my $change (sub { $_[0]{source}{columns}{title}{internal} = JSON::PP::true },
        sub { $_[0]{source}{columns}{title}{type} = 'integer' }) {
        my $raw = contract(); $change->($raw);
        my ($result, $business, $native) = native_trace(sub { ids(engine($raw, $adapter), $x->text_search(['title'], 'Oak')) });
        is($result, 'unsupported_feature', 'nonpublic/nontext field refuses');
        is(scalar(@$native), 0, 'structural field mismatch performs zero native prepares');
    }
    my ($result, $business, $native) = native_trace(sub { ids(engine(contract(), $adapter), $x->text_search(['title'], 'x' x 4097)) });
    is($result, 'invalid_query', 'search literal byte ceiling is enforced');
    is(scalar(@$native), 0, 'oversized search text never reaches native catalog');
    {
        no warnings 'redefine';
        local *DBI::db::selectall_arrayref = sub { die 'fabricated convenience catalog invoked' };
        is_deeply(ids(engine(contract(), $adapter), $x->text_search(['title'], 'Oak')), [[1], [2]], 'native catalog bypasses fabricated convenience result methods');
    }
    $db->do('CREATE VIRTUAL TABLE root_search USING fts5(title, body)');
    $db->do(q{INSERT INTO root_search(rowid,title,body) VALUES(1,'Oak','lamp'),(2,'Oaken','bell')});
    my $root = Selecto::Engine->new(domain => Selecto::Domain->new(name => 'Root FTS', table => 'root_search', primary_key => 'rowid',
        fields => {rowid => 'integer', title => 'fts5', body => 'fts5'}), adapter => $adapter);
    my $q = $root->query->select('rowid')->where($x->text_search(['title'], 'oak:*', mode => 'prefix'))->order_by('rowid');
    is_deeply($root->all($q)->{rows}, [[1], [2]], 'root virtual FTS also executes normalized prefix search');
    ok((grep { $_ eq 'oak:*' } @{$root->compile($q)->params}), 'root virtual prefix remains bound');
    $db->do('CREATE TEMP TABLE ROOT_SEARCH(rowid INTEGER,title TEXT)');
    is(error_code(sub { $root->all($q) }), 'unsupported_feature', 'root virtual FTS refuses native TEMP shadow');
    is($db->selectrow_array('SELECT count(*) FROM temp.ROOT_SEARCH'), 0, 'root shadow preserves TEMP business state');
}) };

subtest 'SQLite identity folds ASCII only' => sub { memory(sub {
    my ($db, $adapter) = @_;
    $db->do('DROP TABLE items_search');
    $db->do(q{CREATE VIRTUAL TABLE items_search USING fts5(title, body, content='ITEMS', content_rowid='ID')});
    $db->do(q{INSERT INTO items_search(items_search) VALUES('rebuild')});
    is_deeply(ids(engine(contract(), $adapter), $x->text_search(['title'], 'Oak')), [[1], [2]], 'native case-insensitive content/key identifiers stay supported');
    $db->do('CREATE TABLE bookitems(id INTEGER PRIMARY KEY,title TEXT,body TEXT,tenant INTEGER)');
    $db->do('INSERT INTO bookitems SELECT * FROM items');
    $db->do(q{CREATE VIRTUAL TABLE bookitems_idx USING fts5(title, body, content='bookitems', content_rowid='id')});
    $db->do(q{INSERT INTO bookitems_idx(bookitems_idx) VALUES('rebuild')});
    my $raw = contract();
    $raw->{source}{source_table} = 'bookitems';
    $raw->{source}{fts5_index}{table} = 'bookitems_idx';
    my $engine = engine($raw, $adapter);
    $db->do(q{CREATE TEMP TABLE "booKitems"(id INTEGER)});
    $db->do(q{CREATE TEMP TABLE "booKitems_idx"(id INTEGER)});
    is_deeply(ids($engine, $x->text_search(['title'], 'Oak')), [[1], [2]], 'Unicode Kelvin lookalikes are different native identities');
    $db->do('CREATE TEMP TABLE BOOKITEMS(id INTEGER)');
    is(error_code(sub { ids($engine, $x->text_search(['title'], 'Oak')) }), 'unsupported_feature', 'actual ASCII-fold TEMP shadow still refuses');
}) };

done_testing;
