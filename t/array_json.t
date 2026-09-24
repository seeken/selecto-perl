use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;

sub code_of {
    my ($code) = @_;
    return eval { $code->(); 'ok' } // do {
        my $error = $@;
        blessed($error) && $error->isa('Selecto::Error') ? $error->code : die $error;
    };
}

sub contract {
    my (%columns) = @_;
    return {
        schema_version => 1, name => 'Assets',
        source => {
            source_table => 'assets', primary_key => 'id',
            fields => [sort qw(id tags scores metadata name), keys %columns],
            columns => {
                id => {type => 'integer'}, name => {type => 'string'},
                tags => {type => 'array', items => 'string'},
                scores => {type => 'array', items => 'integer'},
                metadata => {type => 'jsonb'},
                %columns,
            },
            associations => {},
        },
        schemas => {}, joins => {},
    };
}

my $domain = Selecto::Domain->parse(contract(untyped => {type => 'array'}));
my $offline = bless {}, 'Offline::Handle';
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $offline)));
my $x = 'Selecto::Expression';

# --- contract --------------------------------------------------------------------
is(code_of(sub { Selecto::Domain->parse(contract(bad => {type => 'string', items => 'string'})) }),
    'invalid_domain', 'items is only valid on array columns');
is(code_of(sub { Selecto::Domain->parse(contract(bad => {type => 'array', items => 'blob'})) }),
    'invalid_domain', 'array element types are allowlisted');

# --- predicates ------------------------------------------------------------------
my %sql = (
    array_contains => '@>', array_contained => '<@', array_overlap => '&&',
);
for my $kind (sort keys %sql) {
    my $statement = $engine->compile($engine->query->select('id')->where($x->$kind('tags', ['a', 'b'])));
    like($statement->sql, qr/"tags" \Q$sql{$kind}\E CAST\(ARRAY\[\$1, \$2\] AS TEXT\[\]\)/,
        "$kind binds each value and casts to the declared element type");
    is_deeply($statement->params, ['a', 'b'], "$kind values are parameters");
}
like($engine->compile($engine->query->select('id')->where($x->array_overlap('scores', 1, 2)))->sql,
    qr/AS BIGINT\[\]/, 'integer arrays cast to BIGINT[]');

my $contains = $engine->compile($engine->query->select('id')
    ->where($x->json_contains('metadata', {power => 'three_phase'})));
like($contains->sql, qr/CAST\("s0"\."metadata" AS JSONB\) @> CAST\(\$1 AS JSONB\)/,
    'json_contains binds the document');
is_deeply($contains->params, ['{"power":"three_phase"}'], 'the document is canonical JSON text');

my $from_ast = $engine->compile($engine->query->select('id')->where($x->from_filter_ast(
    ['and', ['array_contains', 'tags', ['a']], ['json_contains', 'metadata', {k => 1}]],
)));
is_deeply($from_ast->params, ['a', '{"k":1}'], 'filter AST accepts array and JSON containment');

is(code_of(sub { $x->array_contains('tags', []) }), 'invalid_query', 'an empty value list is rejected');
is(code_of(sub { $x->array_contains('tags', [['nested']]) }), 'invalid_query', 'values must be scalars');
is(code_of(sub { $x->json_contains('metadata', 'text') }), 'invalid_query', 'documents are objects or arrays');
is(code_of(sub { $engine->compile($engine->query->select('id')->where($x->array_overlap('name', ['a']))) }),
    'invalid_query', 'array predicates require an array field');
is(code_of(sub { $engine->compile($engine->query->select('id')->where($x->array_overlap('untyped', ['a']))) }),
    'invalid_query', 'array predicates require a declared element type');
is(code_of(sub { $engine->compile($engine->query->select('id')->where($x->json_contains('name', {a => 1}))) }),
    'invalid_query', 'json_contains requires a JSON field');

# --- rowsets ----------------------------------------------------------------------
my $rows = $engine->compile($engine->query
    ->array_rowset('tags', 'tag_rows', ordinality => 'position')
    ->select('id', 'tag_rows.value', 'tag_rows.position')
    ->order_by('id', 'asc')->order_by('tag_rows.position', 'asc'));
like($rows->sql, qr/CROSS JOIN LATERAL UNNEST\("s0"\."tags"\) WITH ORDINALITY AS "tag_rows" \("value", "position"\)/,
    'array_rowset expands with ordinality');
like($engine->compile($engine->query->array_rowset('tags', 'tag_rows', type => 'left')->select('tag_rows.value'))->sql,
    qr/LEFT JOIN LATERAL UNNEST\("s0"\."tags"\) AS "tag_rows" \("value"\) ON TRUE/,
    'a left rowset keeps rows with empty or NULL arrays');
is(code_of(sub { $engine->compile($engine->query->array_rowset('tags', 'tag_rows')->select('tag_rows.position')) }),
    'unknown_field', 'the ordinality column exists only when requested');
is(code_of(sub { $engine->query->array_rowset('tags', 'tag_rows', ordinality => 'value') }),
    'invalid_query', 'the ordinality column cannot shadow value');
is(code_of(sub { $engine->compile($engine->query->array_rowset('name', 'bad')->select('bad.value')) }),
    'invalid_query', 'array rowsets require an array field');

# --- fail closed ------------------------------------------------------------------
my $sqlite = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $offline)));
is(code_of(sub { $sqlite->compile($sqlite->query->select('id')->where($x->array_overlap('tags', ['a']))) }),
    'unsupported_feature', 'adapters without array predicates fail closed');
is(code_of(sub { $sqlite->compile($sqlite->query->select('id')->where($x->json_contains('metadata', {a => 1}))) }),
    'unsupported_feature', 'adapters without JSON containment fail closed');
is(code_of(sub { $sqlite->compile($sqlite->query->array_rowset('tags', 't')->select('t.value')) }),
    'unsupported_feature', 'adapters without array rowsets fail closed');

done_testing;
