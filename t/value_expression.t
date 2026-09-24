use 5.034;
use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::PostgreSQL ();
use Selecto::SQLite ();
use Selecto::DuckDB ();
use Selecto::ValueExpression ();

sub contract {
    my (%columns) = @_;
    my %base_columns = (
        id => {type => 'integer'},
        name => {type => 'string'},
        status => {type => 'string'},
        site_id => {type => 'integer'},
        location_text => {type => 'string'},
        rate_cents => {type => 'integer'},
        retired_at => {type => 'utc_datetime'},
        metadata => {type => 'jsonb'},
    );
    my %all = (%base_columns, %columns);
    return {
        name => 'Equipment',
        source => {
            source_table => 'equipment',
            primary_key => 'id',
            fields => [sort keys %all],
            columns => \%all,
            associations => {
                site => {queryable => 'site', owner_key => 'site_id', related_key => 'id'},
            },
        },
        schemas => {
            site => {
                source_table => 'sites', primary_key => 'id',
                fields => [qw(id name code)],
                columns => {id => {type => 'integer'}, name => {type => 'string'}, code => {type => 'string'}},
                associations => {},
            },
        },
        joins => {site => {type => 'left', name => 'Site'}},
    };
}

my %COLUMNS = (
    effective_location => {
        type => 'string',
        computed => {kind => 'expression', expression =>
            ['coalesce', ['field', 'site.name'], ['field', 'location_text'], ['literal', 'Location unknown']]},
    },
    attention_state => {
        type => 'string',
        computed => {kind => 'expression', expression => [
            'case',
            [['not_null', 'retired_at'], ['literal', 'Retired']],
            [['in', 'status', ['maintenance', 'missing']], ['literal', 'Needs attention']],
            ['else', ['literal', 'Ready to reserve']],
        ]},
    },
    rate_dollars => {
        type => 'decimal',
        computed => {kind => 'expression', expression =>
            ['divide', ['field', 'rate_cents'], ['literal', 100]]},
    },
    manufacturer => {
        type => 'string',
        computed => {kind => 'expression', expression => ['json_text', 'metadata', ['manufacturer']]},
    },
    shouting_name => {
        type => 'string',
        computed => {kind => 'expression', expression => ['upper', ['field', 'name']]},
    },
    label => {
        type => 'string',
        computed => {kind => 'expression', expression =>
            ['concat', ['field', 'shouting_name'], ['literal', ' #'], ['field', 'id']]},
    },
);

my $domain = Selecto::Domain->parse(contract(%COLUMNS));
my $engine = Selecto::Engine->new(
    domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new),
);

is_deeply(
    $domain->field_metadata('rate_dollars')->{computed}{expression},
    ['divide', ['field', 'rate_cents'], ['literal', 100, 'integer']],
    'literal types are inferred and stored in the normalized contract',
);

my $statement = $engine->compile($engine->query->select('id', 'effective_location')->order_by('id'));
like($statement->sql,
    qr/COALESCE\("j_site"\."name", "s0"\."location_text", CAST\(\$1 AS TEXT\)\) AS "effective_location"|\(COALESCE\("j_site"\."name", "s0"\."location_text", CAST\(\$1 AS TEXT\)\)\)/,
    'coalesce compiles over governed fields with a typed bound literal');
like($statement->sql, qr/LEFT JOIN "sites" AS "j_site" ON "s0"\."site_id" = "j_site"\."id"/,
    'a computed field introduces the association join its expression reads');
is_deeply($statement->params, ['Location unknown'], 'the fallback literal is bound, never interpolated');
like($statement->sql, qr/\)\) AS "effective_location" FROM/, 'selected computed fields carry their result name');

my $filtered = $engine->compile(
    $engine->query->select('id')->where(Selecto::Expression->eq('effective_location', 'North')),
);
like($filtered->sql, qr/LEFT JOIN "sites"/, 'filtering by a computed field also brings its joins');
like($filtered->sql, qr/WHERE \(COALESCE\(.*\)\) = \$2\z/, 'computed fields compose with ordinary predicates');

my $case = $engine->compile($engine->query->select('attention_state'));
like($case->sql,
    qr/CASE WHEN "s0"\."retired_at" IS NOT NULL THEN CAST\(\$1 AS TEXT\) WHEN "s0"\."status" IN \(\$2, \$3\) THEN CAST\(\$4 AS TEXT\) ELSE CAST\(\$5 AS TEXT\) END/,
    'case conditions reuse the portable filter AST');
is_deeply($case->params, ['Retired', 'maintenance', 'missing', 'Needs attention', 'Ready to reserve'],
    'case literals and condition values stay bound in order');

my $divide = $engine->compile($engine->query->select('rate_dollars'));
like($divide->sql, qr/\(CAST\("s0"\."rate_cents" AS NUMERIC\) \/ CAST\(CAST\(\$1 AS BIGINT\) AS NUMERIC\)\)/,
    'division is always decimal so integer operands never truncate');

my $json = $engine->compile($engine->query->select('manufacturer'));
like($json->sql, qr/JSONB_EXTRACT_PATH_TEXT\(CAST\("s0"\."metadata" AS JSONB\), \$1\)/,
    'JSON text extraction binds its path segments');
is_deeply($json->params, ['manufacturer'], 'JSON path segments are parameters');

my $nested = $engine->compile($engine->query->select('label'));
like($nested->sql, qr/CONCAT\(CAST\(\(UPPER\("s0"\."name"\)\) AS TEXT\), CAST\(CAST\(\$1 AS TEXT\) AS TEXT\), CAST\("s0"\."id" AS TEXT\)\)/,
    'computed fields may build on other computed fields');

my $grouped = $engine->compile(
    $engine->query
        ->select('attention_state', Selecto::Expression->count->as('assets'))
        ->group_by('attention_state')
        ->order_by('attention_state'),
);
like($grouped->sql, qr/GROUP BY \(CASE WHEN .* END\) ORDER BY \(CASE WHEN .* END\) ASC\z/,
    'computed fields can be grouped and ordered');

my $adhoc = $engine->compile($engine->query->select(
    'id',
    Selecto::Expression->value(['multiply', ['field', 'rate_cents'], ['literal', 2]])->as('double_rate'),
    Selecto::Expression->value(['lower', ['field', 'site.code']])->as('site_code'),
));
like($adhoc->sql, qr/\(\("s0"\."rate_cents" \* CAST\(\$1 AS BIGINT\)\)\) AS "double_rate"/,
    'query-time value expressions compile with the same rules');
like($adhoc->sql, qr/LEFT JOIN "sites"/, 'query-time value expressions introduce their joins');

eval { $engine->compile($engine->query->select(
    Selecto::Expression->value(['upper', ['field', 'rate_cents']])->as('bad'),
)) };
is($@->code, 'invalid_value_expression', 'query-time value expressions are type-checked against the domain');

eval { $engine->compile($engine->query->select(
    Selecto::Expression->value(['field', 'site.missing'])->as('bad'),
)) };
is($@->code, 'unknown_field', 'query-time value expressions reference only governed paths');

sub domain_error {
    my (%columns) = @_;
    my $ok = eval { Selecto::Domain->parse(contract(%COLUMNS, %columns)); 1 };
    return $ok ? 'accepted' : ref($@) ? $@->code . ': ' . ($@->details->{reason} // $@->message) : "$@";
}

like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression => ['sql', 'now()']}}),
    qr/invalid_domain: unsupported value expression operator sql/, 'unknown operators are rejected');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression => ['literal', undef]}}),
    qr/must not be null/, 'null literals are rejected');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression => ['cast', ['field', 'id'], 'bytea']}}),
    qr/cast type must be one of/, 'cast targets are allowlisted');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression => ['json_text', 'metadata', ["a'b"]]}}),
    qr/segments must be/, 'JSON path segments are restricted');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression =>
    ['case', ['else', ['literal', 'x']], [['eq', 'status', 'a'], ['literal', 'y']]]}}),
    qr/else must be the last branch/, 'case else must be last');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression =>
    ['coalesce', ['field', 'name'], ['field', 'id']]}}),
    qr/does not type-check.*|coalesce values must share one type/, 'coalesce operands must share a type');
like(domain_error(bad => {type => 'integer', computed => {kind => 'expression', expression => ['field', 'name']}}),
    qr/invalid_domain: computed value expression type does not match/, 'declared types must match the inferred type');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression => ['json_text', 'name', ['x']]}}),
    qr/json_text requires a JSON field/, 'JSON extraction requires a JSON field');
like(domain_error(bad => {type => 'decimal', computed => {kind => 'expression', expression => ['add', ['field', 'name'], ['literal', 1]]}}),
    qr/requires numeric operands/, 'arithmetic requires numeric operands');
like(domain_error(bad => {type => 'string', computed => {kind => 'expression', expression => ['field', 'site.missing']}}),
    qr/invalid_domain/, 'unknown paths are rejected when the domain is parsed');
like(domain_error(bad => {type => 'decimal', computed => {kind => 'expression', expression => ['field', 'rate_cents']}}),
    qr/\Aaccepted\z/, 'an integer result satisfies a declared decimal column');
like(domain_error(
    loop_a => {type => 'string', computed => {kind => 'expression', expression => ['upper', ['field', 'loop_b']]}},
    loop_b => {type => 'string', computed => {kind => 'expression', expression => ['lower', ['field', 'loop_a']]}},
), qr/cycle/, 'computed dependency cycles are rejected');

my $writable = contract(%COLUMNS);
$writable->{writes} = {
    operations => {update => {enabled => 1}},
    fields => {effective_location => {updatable => 1}},
};
eval { Selecto::Domain->parse($writable) };
is($@->code, 'invalid_domain', 'write contracts cannot make computed fields writable');

eval {
    $engine->preview_write(Selecto::Write::Command->new(
        operation => 'update', relation => 'equipment',
        assignments => {attention_state => 'Retired'},
        predicate => Selecto::Expression->eq('id', 1),
    ));
};
is($@->code, 'write_field_not_writable', 'computed fields are read-only for governed writes');

my $changed = contract(%COLUMNS);
$changed->{source}{columns}{rate_dollars}{computed}{expression}[2] = ['literal', 1000];
isnt(Selecto::Domain->parse($changed)->fingerprint, $domain->fingerprint,
    'the domain fingerprint covers computed expressions');
is(Selecto::Domain->parse($domain->contract)->fingerprint, $domain->fingerprint,
    'normalized contracts round-trip to the same fingerprint');

my $sqlite = Selecto::Engine->new(
    domain => $domain, adapter => Selecto::SQLite->new(dbh => TestSelecto::DBH->new),
);
eval { $sqlite->compile($sqlite->query->select('effective_location')) };
is($@->code, 'unsupported_feature', 'adapters without value expressions fail closed');

my $duckdb = Selecto::Engine->new(
    domain => $domain, adapter => Selecto::DuckDB->new(dbh => TestSelecto::DBH->new),
);
my $duck_json = $duckdb->compile($duckdb->query->select('manufacturer', 'rate_dollars'));
like($duck_json->sql, qr/JSON_EXTRACT_STRING\("s0"\."metadata", \$1\)/, 'DuckDB extracts JSON text with a bound path');
like($duck_json->sql, qr/AS DECIMAL\(38, 10\)/, 'DuckDB divides at a wide fixed decimal scale');
is($duck_json->params->[0], '$.manufacturer', 'DuckDB binds its JSON path');

is(Selecto::ValueExpression->category('utc_datetime'), 'datetime', 'type categories normalize timestamps');
is_deeply([Selecto::ValueExpression->dependencies($domain->field_metadata('attention_state')->{computed}{expression})],
    [qw(retired_at status)], 'dependencies include case condition fields');

done_testing;
