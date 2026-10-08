use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use DBI;
use Selecto;
use Selecto::BoundedQuery;
use Selecto::Limits;
use Selecto::API::EngineHandler;

plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };

sub error_code {
    my ($run) = @_;
    my $ok = eval { $run->(); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : die $@;
}
sub statement { Selecto::Statement->new(sql => $_[0], columns => ['id'], adapter_name => 'sqlite') }
sub memory_db {
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1});
}
my $dbh = memory_db();
my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
my $x = 'Selecto::Expression';

subtest 'full SQLite version gates' => sub {
    {
        package Local::SQLiteVersion;
        sub new { bless {version => $_[1]}, $_[0] }
        sub selectrow_array { return $_[0]{version} }
    }
    for my $case (
        ['3.8.2', 'cte', 0], ['3.8.3', 'cte', 1], ['3.8.3', 'recursive_cte', 1],
        ['3.25.0', 'window_functions', 0], ['3.27.9', 'window_functions', 0],
        ['3.28.0', 'window_functions', 1], ['3.34.9', 'returning', 0],
        ['3.35.0', 'returning', 1], ['4.0.0', 'cte', 1], ['3.8', 'cte', 0],
    ) {
        my ($version, $feature, $expected) = @$case;
        my $old = Selecto->adapter(sqlite => dbh => Local::SQLiteVersion->new($version));
        is($old->supports($feature), $expected, "$feature gate for $version");
    }
    my $old = Selecto->adapter(sqlite => dbh => Local::SQLiteVersion->new('3.34.9'));
    is(error_code(sub { $old->bounded_result_statement(statement('SELECT 1 AS id'), max_cell_bytes => 10, max_rows => 1) }),
        'unsupported_feature', 'materialization is refused before SQLite 3.35.0');
};

subtest 'read-only query and stream boundaries preserve caller state' => sub {
    $dbh->do('CREATE TABLE writes (id INTEGER PRIMARY KEY, value TEXT)');
    $dbh->do(q{INSERT INTO writes VALUES (1, 'before')});
    for my $sql (
        q{UPDATE writes SET value = 'after' RETURNING id},
        q{WITH selected AS (SELECT 1) UPDATE writes SET value = 'after' RETURNING id},
        q{PRAGMA query_only = OFF}, q{ATTACH ':memory:' AS attached},
        q{SELECT 1; UPDATE writes SET value = 'after'},
    ) {
        is(error_code(sub { $adapter->execute_query(statement($sql)) }), 'query_error', 'crafted non-read query is refused');
        is(error_code(sub { $adapter->stream_query(statement($sql)) }), 'query_error', 'crafted non-read stream is refused');
    }
    is($dbh->selectrow_array('SELECT value FROM writes'), 'before', 'none of the query probes mutate data');
    for my $raw (0, 1) {
        $raw ? $dbh->do('BEGIN') : $dbh->begin_work;
        $dbh->do(q{UPDATE writes SET value = 'host'});
        for my $prior (0, 1) {
            $dbh->do('PRAGMA query_only = ' . $prior);
            is_deeply($adapter->execute_query(statement("/* comment */ SELECT ';' AS id; -- tail"))->{rows}, [[';']],
                'quoted semicolon and trailing comments remain valid');
            is($dbh->selectrow_array('PRAGMA query_only'), $prior, 'successful query preserves query_only');
            is(error_code(sub { $adapter->execute_query(statement('SELECT missing_column FROM writes')) }), 'query_error',
                'failed query remains normalized');
            is($dbh->selectrow_array('PRAGMA query_only'), $prior, 'failed query preserves query_only');
            my $stream = $adapter->stream_query(statement('SELECT id FROM writes'));
            is_deeply($stream->next, [1], 'guarded stream fetch works');
            $stream->close;
            is($dbh->selectrow_array('PRAGMA query_only'), $prior, 'stream fetch and close preserve query_only');
            ok(!$dbh->sqlite_get_autocommit, 'host transaction remains open');
        }
        $dbh->do('PRAGMA query_only = OFF');
        $raw ? $dbh->do('ROLLBACK') : $dbh->rollback;
        is($dbh->selectrow_array('SELECT value FROM writes'), 'before', 'host work was never committed by a query');
    }
    $dbh->sqlite_create_function('attempt_write', 0, sub { $dbh->do(q{UPDATE writes SET value = 'function'}); return 1 });
    is(error_code(sub { $adapter->execute_query(statement('SELECT attempt_write()')) }), 'query_error',
        'read guard blocks a scalar function database mutation');
    is($dbh->selectrow_array('PRAGMA query_only'), 0, 'function failure restores writable host state');
    is($dbh->selectrow_array('SELECT value FROM writes'), 'before', 'function mutation rolls back before executing');
    $adapter->execute_query_unsafe(statement(q{UPDATE writes SET value = 'trusted' RETURNING id}));
    is($dbh->selectrow_array('SELECT value FROM writes'), 'trusted', 'explicit trusted query tooling remains available');
    $dbh->{RaiseError} = 0;
    is(error_code(sub {$adapter->execute_query(statement('SELECT missing_readonly_column FROM writes'))}),
        'query_error','nonthrowing DBI preparation failures remain normalized');
    is(error_code(sub {$adapter->stream_query(statement('SELECT missing_readonly_column FROM writes'))}),
        'query_error','nonthrowing DBI stream preparation failures remain normalized');
    $dbh->{RaiseError} = 1;
};

$dbh->do('CREATE TABLE assets(id INTEGER PRIMARY KEY, metadata TEXT, tags TEXT, score INTEGER, name TEXT, at TEXT, ep INTEGER)');
my $json = JSON::PP->new->canonical(1);
my @documents = (
    {a => undef, b => JSON::PP::true, n => 1, arr => [{v => JSON::PP::true, x => 9}, 1], empty => {},
        nested => {v => undef}, items => [{sku => 'α', quantity => 2, flag => JSON::PP::true}, {sku => 'β', quantity => 4}]},
    {a => JSON::PP::false, b => 1, n => 1.0, arr => [{v => 1}], empty => [], nested => {}, items => []},
    {b => 'true', n => '1', nested => {v => JSON::PP::false}},
);
$dbh->do('INSERT INTO assets VALUES (?,?,?,?,?,?,?)', undef, @$_) for
    [1, $json->encode($documents[0]), '["a","b"]', -1, 'The Oak', '2021-01-01 10:20:30.123', 1609496430],
    [2, $json->encode($documents[1]), '[]', 10, 'an Elm', '2020-12-31 00:00:00', 1609372800],
    [3, $json->encode($documents[2]), undef, undef, '', undef, undef],
    [4, undef, '["b"]', 20, 'Apple', '2024-04-01 00:00:00', 1711929600],
    [5, '{invalid', '["c"]', 3, undef, '2024-12-30 00:00:00', 1735516800];
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Assets', source => {
    source_table => 'assets', primary_key => 'id', fields => [qw(id metadata tags score name at ep)],
    columns => {id => {type => 'integer'}, metadata => {type => 'jsonb'}, tags => {type => 'array', items => 'string'},
        score => {type => 'integer'}, name => {type => 'string'}, at => {type => 'utc_datetime'}, ep => {type => 'epoch_datetime'}},
    associations => {},
}, schemas => {}, joins => {}});
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
sub ids {
    my ($expression) = @_;
    return [map { $_->[0] } @{$engine->all($engine->query->select('id')->where($expression)->order_by('id'))->{rows}}];
}

subtest 'JSON retains structure, missing values and scalar types' => sub {
    for my $feature (qw(json_contains json_text json_rowset array_rowset array_predicates value_expressions)) {
        ok($adapter->supports($feature), "$feature reflects connected live support");
    }
    for my $case (
        [{a => undef}, [1]], [{b => JSON::PP::true}, [1]], [{b => 1}, [2]], [{b => 'true'}, [3]],
        [{n => 1}, [1,2]], [{n => '1'}, [3]], [{empty => {}}, [1]], [{empty => []}, [2]],
        [{nested => {v => undef}}, [1]], [{arr => [{v => JSON::PP::true}]}, [1]], [{arr => [{v => 1}]}, [2]],
        [{arr => [1]}, [1]], [{}, [1,2,3]], [[], []],
    ) {
        is_deeply(ids($x->json_contains('metadata', $case->[0])), $case->[1], 'structural JSON containment matches only correct typed documents');
    }
    my @expressions = map { $x->value(['json_text', 'metadata', [$_]])->as($_) } qw(a b n missing);
    is_deeply($engine->all($engine->query->select('id', @expressions)->where($x->lt('id', 4))->order_by('id'))->{rows},
        [[1, undef, 'true', '1', undef], [2, 'false', '1', '1', undef], [3, undef, 'true', '1', undef]],
        'JSON text extraction distinguishes booleans and renders scalar text, with null/missing SQL NULL');
    $dbh->do('UPDATE assets SET metadata = ? WHERE id = 5', undef, '{"wide":9223372036854775807,"bool":false}');
    is_deeply(ids($x->json_contains('metadata', {wide => 9223372036854775807})), [5], 'wide JSON integer retains all bits');
    is_deeply(ids($x->json_contains('metadata', {bool => 0})), [], 'JSON false never equals numeric zero');
    is_deeply(ids($x->array_contains('tags', ['b'])), [1,4], 'JSON-backed typed arrays support contains');
    is_deeply(ids($x->array_overlap('tags', ['c'])), [5], 'JSON-backed typed arrays support overlap');
    is_deeply(ids($x->array_contained('tags', ['a','b'])), [1,2,4], 'empty arrays are contained by a valid typed array');
    my $rowset = $engine->query->json_rowset('metadata', 'items', {sku => 'string', quantity => 'integer', flag => 'boolean'}, path => '$.items[*]')
        ->select('id','items.sku','items.quantity','items.flag')->where($x->lt('id',4))->order_by('id');
    is_deeply($engine->all($rowset)->{rows}, [[1,'α',2,1],[1,'β',4,undef],[2,undef,undef,undef],[3,undef,undef,undef]],
        'left JSON record rowset expands nested records, preserving roots with empty/missing arrays');
    my $cross = $engine->query->json_rowset('metadata','items',{sku=>'string'},path=>'$.items',type=>'cross')
        ->select('id','items.sku')->order_by('id');
    is_deeply($engine->all($cross)->{rows}, [[1,'α'],[1,'β']], 'cross JSON rowset omits empty/missing arrays');
    my $arrays = $engine->query->array_rowset('tags','tag',type=>'left',ordinality=>'position')
        ->select('id','tag.value','tag.position')->order_by('id')->order_by('tag.position');
    is_deeply($engine->all($arrays)->{rows}, [[1,'a',1],[1,'b',2],[2,undef,undef],[3,undef,undef],[4,'b',1],[5,'c',1]],
        'array rowsets provide one-based ordinality and preserve left roots');
    my $typed_domain = Selecto::Domain->parse({schema_version=>1,name=>'Typed arrays',source=>{
        source_table=>'typed_arrays',primary_key=>'id',fields=>[qw(id numbers flags)],
        columns=>{id=>{type=>'integer'},numbers=>{type=>'array',items=>'integer'},flags=>{type=>'array',items=>'boolean'}},associations=>{}},schemas=>{},joins=>{}});
    $dbh->do('CREATE TABLE typed_arrays(id INTEGER PRIMARY KEY,numbers TEXT,flags TEXT)');
    $dbh->do(q{INSERT INTO typed_arrays VALUES(1,'[1.0,9223372036854775807]','[true,false]')});
    my $typed_engine = Selecto::Engine->new(domain=>$typed_domain,adapter=>$adapter);
    is_deeply($typed_engine->all($typed_engine->query->select('id')->where($x->array_overlap('numbers',[1])))->{rows},[[1]],
        'typed numeric array overlap compares JSON real and integer values numerically');
    is_deeply($typed_engine->all($typed_engine->query->select('id')->where($x->array_contains('numbers',[9223372036854775807])))->{rows},[[1]],
        'typed integer arrays preserve wide bound integers');
    is_deeply($typed_engine->all($typed_engine->query->select('id')->where($x->array_contains('flags',[0])))->{rows},[[1]],
        'typed boolean arrays bind canonical false as JSON false');
    is(error_code(sub {$typed_engine->compile($typed_engine->query->select('id')->where($x->array_contains('flags',['false'])))}),
        'invalid_query','noncanonical boolean array input is refused before coercion');
};

subtest 'typed values, calendar expressions and buckets execute' => sub {
    my $values = $engine->query->select('id', $x->value(['divide',['field','score'],['literal',2]])->as('half'),
        $x->value(['concat',['lower',['field','name']],['literal','!']])->as('label'))->order_by('id');
    is_deeply($engine->all($values)->{rows}, [[1,-0.5,'the oak!'],[2,5,'an elm!'],[3,undef,'!'],[4,10,'apple!'],[5,1.5,'!']],
        'division uses real arithmetic and concatenation handles nullable text without provider CONCAT');
    my @formats = qw(iso_week iso_week_date quarter day_of_week day_of_week_num rfc3339_millis epoch_milliseconds);
    my $calendar = $engine->query->select(map { $x->datetime_format('at',$_)->as($_) } @formats)->where($x->eq('id',1));
    is_deeply($engine->all($calendar)->{rows}, [['2020-W53','2020-W53-5','2021-Q1','Friday',5,'2021-01-01T10:20:30.123Z',1609496430123]],
        'calendar lowering handles ISO year crossing, milliseconds, UTC and weekday numbers');
    is_deeply($engine->all($engine->query->select($x->datetime_format('at','iso_week')->as('week'))->where($x->eq('id',5)))->{rows},
        [['2025-W01']], 'ISO week handles December crossing into the next ISO year');
    is_deeply($engine->all($engine->query->select($x->datetime_format($x->epoch_datetime('ep'),'iso8601')->as('instant'))
        ->where($x->eq('id',1)))->{rows}, [['2021-01-01T10:20:30Z']], 'numeric epoch fields normalize to UTC instants');
    my $bucket = $engine->query->select('id',$x->bucket('score',{kind=>'numeric_increment',increment=>10})->as('bucket'))->order_by('id');
    is_deeply($engine->all($bucket)->{rows}, [[1,'-10--1'],[2,'10-19'],[3,'Other'],[4,'20-29'],[5,'0-9']],
        'numeric buckets floor negative numbers and propagate null into Other');
    is_deeply($engine->all($engine->query->select('id',$x->bucket('name',{kind=>'text_prefix',prefix_length=>2,exclude_articles=>1})->as('prefix'))->order_by('id'))->{rows},
        [[1,'OA'],[2,'EL'],[3,'Other'],[4,'AP'],[5,'Other']], 'text prefix buckets trim articles and empty values');
    my $ranges = $x->bucket('score',{kind=>'numeric_ranges',ranges=>[{minimum=>0,maximum=>10,label=>'low'},{minimum=>11,label=>'high'}]})->as('bucket');
    is_deeply($engine->all($engine->query->select('id',$ranges)->order_by('id'))->{rows},
        [[1,'Other'],[2,'low'],[3,'Other'],[4,'high'],[5,'low']], 'range buckets bind boundaries and labels in SQL occurrence order');
    is_deeply($engine->all($engine->query->select($x->count_bucket('score',0,10)->as('count')))->{rows}, [[2]],
        'count buckets aggregate only values within both bounds');
    is_deeply($engine->all($engine->query->select('id')->order_by('id')->offset(3))->{rows}, [[4],[5]], 'ordinary offset-only query uses unlimited SQLite LIMIT');
    is_deeply($engine->all($engine->query->select('id')->where($x->eq('id',1))
        ->union($engine->query->select('id')->where($x->eq('id',2)))->order_by('id')->offset(1))->{rows}, [[2]],
        'compound offset-only query uses unlimited SQLite LIMIT');
};

subtest 'native FTS5 executes predicates and ranking' => sub {
    plan skip_all => 'connected SQLite lacks FTS5' unless $adapter->supports('text_search');
    $dbh->do('CREATE VIRTUAL TABLE search USING fts5(title, body)');
    $dbh->do('INSERT INTO search(rowid,title,body) VALUES (?,?,?)',undef,@$_) for
        [1,'Urgent order','red lamp'],[2,'Normal order','blue lamp'],[3,'Urgent lamp','order'];
    my $fts_domain = Selecto::Domain->new(name=>'Search',table=>'search',primary_key=>'rowid',
        fields=>{rowid=>'integer',title=>'fts5',body=>'fts5'});
    my $fts = Selecto::Engine->new(domain=>$fts_domain,adapter=>$adapter);
    my $predicate = $x->text_search(['title'],'urgent order',mode=>'plain');
    my $query = $fts->query->select('rowid',$x->text_rank(['title'],'urgent order',mode=>'plain')->as('rank'))->where($predicate);
    my $rows = $fts->all($query)->{rows};
    is(scalar(@$rows),1,'plain FTS terms are conjunctive on the governed column');
    is($rows->[0][0],1,'FTS predicate selects the matching row');
    ok($rows->[0][1] < 0,'BM25 rank comes from the matched FTS cursor');
    is_deeply($fts->all($fts->query->select('rowid')->where($x->text_search(['title','body'],'red lamp',mode=>'phrase')))->{rows},
        [[1]],'phrase search may target an allowlisted FTS column set');
    is(error_code(sub {$engine->compile($engine->query->select('id')->where($x->text_search(['name'],'Oak')))}),
        'unsupported_feature','ordinary text fields cannot masquerade as FTS indexes');
};

subtest 'schema metadata, query plans and value fidelity' => sub {
    my $schema = $adapter->introspect_schema;
    my ($assets) = grep {$_->{name} eq 'assets'} @{$schema->{tables}};
    ok($assets && @{$assets->{columns}} == 7, 'structured schema reports real SQLite columns');
    my ($id) = grep {$_->{name} eq 'id'} @{$assets->{columns}};
    is($id->{normalized_type},'integer','schema affinity normalizes declared integer');
    ok($id->{pk},'schema keeps actual primary-key information');
    my $query = $engine->query->select('id')->where($x->eq('id',1));
    my $plan = $adapter->explain_query($engine->compile($query));
    is_deeply($plan->{columns},[qw(id parent notused detail)],'query plan has structured SQLite columns');
    like($plan->{rows}[0][3],qr/SEARCH s0 USING INTEGER PRIMARY KEY/i,'live query plan executes original bound parameters');
    $dbh->do('UPDATE assets SET name = ? WHERE id = 5',undef,"a\0b");
    is_deeply($engine->all($engine->query->select('name')->where($x->eq('id',5)))->{rows},[["a\0b"]],
        'SQLite query returns the whole embedded-NUL text');
    is_deeply(ids($x->eq('name',"a\0b")),[5],'SQLite query binds the whole embedded-NUL text');
};

subtest 'bounded child collections execute with tenant guards and complete-result refusal' => sub {
    $dbh->do('CREATE TABLE parents(id INTEGER PRIMARY KEY, tenant INTEGER)');
    $dbh->do('CREATE TABLE children(id INTEGER PRIMARY KEY, parent_id INTEGER, tenant INTEGER, label TEXT, active BOOLEAN)');
    $dbh->do('INSERT INTO parents VALUES (1,10),(2,10),(3,20)');
    $dbh->do(q{INSERT INTO children VALUES (3,1,10,'third',1),(1,1,10,'first',0),(2,1,20,'foreign',1),(4,3,20,'hidden',1)});
    my $parents = Selecto::Domain->new(name=>'Parents',table=>'parents',primary_key=>'id',fields=>{id=>'integer',tenant=>'integer'},
        associations=>{children=>{table=>'children',fields=>{id=>'integer',parent_id=>'integer',tenant=>'integer',label=>'string',active=>'boolean'},
            owner_key=>'id',related_key=>'parent_id',cardinality=>'many',target_primary_key=>'id',
            source_scope_key=>'tenant',target_scope_key=>'tenant'}})->with_required_predicate($x->eq('tenant',10));
    my $parent_engine = Selecto::Engine->new(domain=>$parents,adapter=>$adapter);
    my $query = $parent_engine->query->select('id',$x->related_collection('children',['label','active'])->as('children'))->order_by('id');
    my $limits = Selecto::Limits->new(max_collection_rows=>2,max_total_collection_rows=>3);
    my $rows = Selecto::BoundedQuery->all($parent_engine,$query,limits=>$limits)->{rows};
    is_deeply($rows, [[1,[{label=>'first',active=>JSON::PP::false},{label=>'third',active=>JSON::PP::true}]],[2,[]]],
        'bounded collection remains ordered, typed, tenant-scoped and complete for empty roots');
    $dbh->do(q{INSERT INTO children VALUES (5,1,10,'overflow',1)});
    is(error_code(sub { Selecto::BoundedQuery->all($parent_engine,$query,limits=>$limits) }), 'result_limit_exceeded',
        'one extra child refuses the whole result rather than silently truncating');
    $dbh->do('DELETE FROM children WHERE id=5');
    my $ordered = $parent_engine->query->select($x->related_collection('children',['label'],order_by=>[['label','desc']],limit=>1)->as('children'))
        ->where($x->eq('id',1));
    is_deeply($json->decode($parent_engine->all($ordered)->{rows}[0][0]),[{label=>'third'}], 'per-parent limit follows authored stable ordering');
    my $cursor = $parent_engine->query->select($x->related_collection('children',['label'],order_by=>[['label','asc']],limit=>2,
        after=>{parent_key=>1,values=>['first',1]})->as('children'))->where($x->eq('id',1));
    is_deeply($json->decode($parent_engine->all($cursor)->{rows}[0][0]),[{label=>'third'}],
        'per-parent cursor follows child order plus the primary-key tie breaker');
    my $handler = Selecto::API::EngineHandler->new(limits=>$limits);
    my $api = $handler->query($parent_engine,{select=>['id',['children.label','children.active']],limit=>1,row_format=>'objects'});
    is_deeply($api->{rows},[{id=>1,children=>[{'children.label'=>'first','children.active'=>JSON::PP::false},
        {'children.label'=>'third','children.active'=>JSON::PP::true}]}], 'API returns typed bounded SQLite subtables');
    is_deeply($api->{subtables}{children},{columns=>['children.label','children.active'],limit=>2,complete=>JSON::PP::true},
        'successful API collection publishes accurate complete/limit metadata');
    $dbh->do(q{INSERT INTO children VALUES (5,1,10,'overflow',1)});
    is(error_code(sub {$handler->query($parent_engine,{select=>['id',['children.label']],limit=>1})}),
        'related_collection_limit_exceeded','API child overflow refuses the complete response');
    $dbh->do('CREATE TABLE parent_children(parent_id INTEGER, child_id INTEGER, tenant INTEGER, enabled INTEGER)');
    $dbh->do('INSERT INTO parent_children VALUES (1,3,10,1),(1,2,10,1),(1,2,20,1),(1,1,10,1),(1,5,10,0)');
    my $through_domain = Selecto::Domain->new(name=>'Through parents',table=>'parents',primary_key=>'id',fields=>{id=>'integer',tenant=>'integer'},
        associations=>{tags=>{table=>'children',fields=>{id=>'integer',tenant=>'integer',label=>'string',active=>'boolean'},
            owner_key=>'id',related_key=>'id',cardinality=>'many',target_primary_key=>'id',where=>{active=>1},
            through=>{table=>'parent_children',owner_key=>'parent_id',related_key=>'child_id',
                source_scope_key=>'tenant',through_scope_key=>'tenant',target_scope_key=>'tenant',where=>{enabled=>1}}}})
        ->with_required_predicate($x->eq('tenant',10));
    my $through_engine = Selecto::Engine->new(domain=>$through_domain,adapter=>$adapter);
    my $through_query = $through_engine->query->select('id',$x->related_collection('tags',['label'])->as('tags'))->order_by('id');
    is_deeply(Selecto::BoundedQuery->all($through_engine,$through_query,limits=>$limits)->{rows},
        [[1,[{label=>'third'}]],[2,[]]], 'bounded through collections retain bridge/target policies and all tenant guards');
    $dbh->do('CREATE TABLE child_details(id INTEGER PRIMARY KEY, child_id INTEGER, tenant INTEGER, body TEXT)');
    $dbh->do(q{INSERT INTO child_details VALUES (1,3,10,'inner'),(2,3,20,'foreign')});
    my $nested_domain = Selecto::Domain->new(name=>'Nested parents',table=>'parents',fields=>{id=>'integer',tenant=>'integer'},
        associations=>{children=>{table=>'children',fields=>{id=>'integer',parent_id=>'integer',tenant=>'integer',label=>'string'},
            owner_key=>'id',related_key=>'parent_id',cardinality=>'many',target_primary_key=>'id',
            source_scope_key=>'tenant',target_scope_key=>'tenant',associations=>{
                details=>{table=>'child_details',fields=>{id=>'integer',child_id=>'integer',tenant=>'integer',body=>'string'},
                    owner_key=>'id',related_key=>'child_id',cardinality=>'many',target_primary_key=>'id',
                    source_scope_key=>'tenant',target_scope_key=>'tenant'}}}});
    my $nested_engine = Selecto::Engine->new(domain=>$nested_domain,adapter=>$adapter);
    my $nested = $nested_engine->all($nested_engine->query->select($x->related_collection('children',[
        'label',{key=>'details',expression=>$x->related_collection('children.details',['body'])}],filters=>[['id',3]])->as('children'))
        ->where($x->eq('id',1)))->{rows}[0][0];
    is_deeply($json->decode($nested),[{label=>'third',details=>[{body=>'inner'}]}],
        'nested collections retain JSON arrays and enforce inner tenant guards');
};

$dbh->disconnect;
done_testing;
