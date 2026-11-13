use 5.034;
use strict;
use warnings;
use feature qw(signatures);
no warnings qw(experimental::signatures);

use Test::More;
use DBI ();
use JSON::PP ();
use Selecto ();
use Selecto::API::Spa ();
use Selecto::Domain ();
use Selecto::Engine ();

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# The selecto.spa.*/v1 explorer protocol over the canonical query handler,
# on an independently authored in-memory orchard.

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', name => 'Orchard',
    source => {
        source_table => 'trees', primary_key => 'id',
        fields => [qw(id name grove_id height age tag)],
        columns => {
            id => {type => 'integer'}, name => {type => 'string'}, grove_id => {type => 'integer'},
            height => {type => 'integer'}, age => {type => 'integer'}, tag => {type => 'string', internal => 1},
        },
        associations => {grove => {queryable => 'groves', owner_key => 'grove_id', related_key => 'id', cardinality => 'one'}},
    },
    schemas => {groves => {source_table => 'groves', primary_key => 'id', fields => [qw(id name)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}}},
    joins => {grove => {type => 'left'}},
});

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do($_) for (
    'CREATE TABLE groves (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
    'CREATE TABLE trees (id INTEGER PRIMARY KEY, name TEXT NOT NULL, grove_id INTEGER, height INTEGER, age INTEGER, tag TEXT)',
    "INSERT INTO groves VALUES (1, 'North'), (2, 'South')",
    "INSERT INTO trees VALUES (1, 'Pear', 1, 4, 12, 'x'), (2, 'Plum', 1, 3, 7, 'x'), (3, 'Quince', 1, 5, 20, 'x'),"
        . " (4, 'Apple', 2, 6, 30, 'x'), (5, 'Cherry', 2, 7, 15, 'x'), (6, 'Medlar', 2, 2, 3, 'x')",
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));

my @operators = qw(equals not_equals greater_than greater_than_or_equal less_than less_than_or_equal between in not_in);
sub field ($id, $label, $type, %extra) {
    return {id => $id, label => $label, type => $type, selectable => JSON::PP::true, sortable => JSON::PP::true,
        groupable => JSON::PP::true, aggregatable => JSON::PP::true, filterOperators => [@operators],
        aggregateFunctions => $type eq 'integer' ? [qw(count count_distinct sum avg min max)] : [qw(count count_distinct min max)], %extra};
}
my $descriptor = {
    schema => 'selecto.spa.domain-descriptor/v1', schemaVersion => 1, id => 'trees', name => 'Orchard',
    source => 'trees', primaryKey => 'id',
    fields => [field('source.id', 'Id', 'integer'), field('source.name', 'Name', 'text'), field('grove.name', 'Grove', 'text'),
        field('source.height', 'Height', 'integer'), field('source.age', 'Age', 'integer', sortable => JSON::PP::false)],
};
my $spa = Selecto::API::Spa->new(domains => [{descriptor => $descriptor, engine => $engine}]);

sub request ($view, $state, %extra) {
    return {schema => 'selecto.spa.query-request/v1', domainId => 'trees', view => $view, state => $state,
        filters => {conjunction => 'and', items => []}, page => {number => 1, size => 30}, %extra};
}
sub post ($body) { return $spa->request({method => 'POST', path => '/api/selecto/query', body => $body}) }
sub refused ($body, $name) {
    my $response = post($body);
    is $response->{status}, 422, "$name: 422";
    is_deeply $response->{json}, {schema => 'selecto.spa.error/v1',
        error => {code => 'invalid_query', message => 'Unsupported or invalid query', issues => []}}, "$name: error body";
}

subtest 'descriptor routes' => sub {
    is_deeply $spa->request({method => 'GET', path => '/api/selecto/domains'}), {status => 200, json => [$descriptor]};
    is_deeply $spa->request({method => 'GET', path => '/api/selecto/domains/trees'}), {status => 200, json => $descriptor};
    is $spa->request({method => 'GET', path => '/api/selecto/domains/other'})->{status}, 404;
    is $spa->request({method => 'GET', path => '/api/selecto/query'})->{status}, 404;
};

subtest 'Detail' => sub {
    my $response = post(request('detail', {selected => ['source.name', 'source.height'],
        columns => [{field => 'source.name'}, {field => 'source.height', format => 'number'}, {field => 'source.name', alias => 'Again'}],
        orderBy => [{field => 'source.height', direction => 'desc'}]}, page => {number => 2, size => 2}));
    is $response->{status}, 200;
    is_deeply $response->{json}{columns}, [{id => 'source.name', label => 'Name', type => 'text'},
        {id => 'source.height', label => 'Height', type => 'integer', format => 'number'},
        {id => 'source.name~2', label => 'Again', type => 'text', field => 'source.name', occurrence => 2}], 'repeated columns';
    is_deeply $response->{json}{rows}, [{'source.name' => 'Quince', 'source.height' => 5, 'source.name~2' => 'Quince'},
        {'source.name' => 'Pear', 'source.height' => 4, 'source.name~2' => 'Pear'}], 'second page by height';
    is_deeply $response->{json}{page}, {number => 2, size => 2, totalRows => 6}, 'total count';

    my $filtered = post(request('detail', {selected => ['source.id']}, filters => {conjunction => 'and', items => [
        {field => 'grove.name', operator => 'in', value => ['North', 'South']},
        {conjunction => 'or', items => [
            {field => 'source.age', operator => 'between', value => 10, valueTo => '20'},
            {field => 'source.name', operator => 'equals', value => 'Medlar'},
            {conjunction => 'and', items => []},
        ]},
        {field => 'source.id', operator => 'not_in', value => [3]},
    ]}));
    is_deeply [map { $_->{'source.id'} } @{$filtered->{json}{rows}}], [1, 5, 6], 'nested AND/OR filters, empty groups dropped';
    is $filtered->{json}{page}{totalRows}, 3;
};

subtest 'Aggregate, rollup, grid and Graph' => sub {
    my $rollup = post(request('aggregate', {groupBy => ['grove.name'], rollup => JSON::PP::true,
        aggregates => [{field => 'source.id', function => 'count', alias => 'Trees'}, {field => 'source.age', function => 'avg'}]}));
    is_deeply $rollup->{json}{columns}, [{id => 'grove.name', label => 'Grove', type => 'text'},
        {id => 'Trees', label => 'Trees', type => 'integer'}, {id => 'avg_source_age', label => 'Average of Age', type => 'decimal'}];
    is_deeply $rollup->{json}{rows}, [{'grove.name' => 'North', Trees => 3, avg_source_age => 13},
        {'grove.name' => 'South', Trees => 3, avg_source_age => 16}, {'grove.name' => undef, Trees => 6, avg_source_age => 14.5}],
        'groups then the grand total';
    is_deeply $rollup->{json}{rowMeta}[0], {rollupLevel => 1, rollupKind => 'detail',
        drilldowns => [{columnId => 'grove.name', constraints => [{field => 'grove.name', operator => 'equals', value => 'North'}]}]};
    is_deeply $rollup->{json}{rowMeta}[2], {rollupLevel => 0, rollupKind => 'total', drilldowns => []};

    my $grid = post(request('aggregate', {groupBy => ['grove.name'], rollup => JSON::PP::true, aggregateGrid => JSON::PP::true,
        aggregates => [{field => 'source.height', function => 'max', alias => 'tallest'}],
        orderBy => [{field => 'tallest', direction => 'desc'}, {field => 'source.id'}]}));
    is_deeply $grid->{json}{rows}, [{'grove.name' => 'South', tallest => 7}, {'grove.name' => 'North', tallest => 5}],
        'the grid has no rollup and sorts by an aggregate, ignoring a Detail sort';

    my $totals = post(request('graph', {groupBy => [], aggregates => [{field => 'source.height', function => 'sum', alias => 'h'}]},
        filters => {conjunction => 'and', items => [{field => 'source.age', operator => 'greater_than', value => 10}]}));
    is_deeply $totals->{json}, {schema => 'selecto.spa.query-response/v1', columns => [{id => 'h', label => 'h', type => 'integer'}],
        rows => [{h => 22}], page => {number => 1, size => 30, totalRows => 1}}, 'a totals-only Graph';

    my $groups_only = post(request('aggregate', {groupBy => ['grove.name', 'source.height'], aggregates => [], rollup => JSON::PP::true},
        page => {number => 1, size => 3}));
    is $groups_only->{json}{page}{totalRows}, 9, 'six details, two subtotals and a total';
    is_deeply $groups_only->{json}{rows}[2], {'grove.name' => 'North', 'source.height' => 5}, 'paged after sorting';
};

subtest 'refusals' => sub {
    refused(request('detail', {selected => ['source.tag']}), 'an undescribed field');
    refused({%{request('detail', {selected => ['source.id']})}, view => 'pivot'}, 'an unknown view');
    refused(request('detail', {selected => ['source.id'], orderBy => [{field => 'source.age'}]}), 'a field that is not sortable');
    refused(request('aggregate', {groupBy => ['grove.name'], aggregates => [{field => 'source.name', function => 'sum'}]}),
        'a function the field does not advertise');
    refused(request('aggregate', {groupBy => [], aggregates => [{field => 'source.id', function => 'count', alias => 'source.age'}]}),
        'an aggregate alias that is a field');
    refused(request('graph', {groupBy => [], aggregates => []}), 'nothing to aggregate');
    refused(request('detail', {selected => ['source.id']}, filters => {conjunction => 'and',
        items => [{field => 'source.name', operator => 'contains', value => 'P'}]}), 'an operator the field does not advertise');
    refused(request('detail', {selected => ['source.id']}, filters => {conjunction => 'and',
        items => [{field => 'source.id', operator => 'equals', value => '1.5'}]}), 'a non-integer for an integer field');
    my $deep = {field => 'source.id', operator => 'equals', value => 1};
    $deep = {conjunction => 'and', items => [$deep]} for 1 .. 4;
    is post(request('detail', {selected => ['source.id']}, filters => $deep))->{status}, 200, 'a root group and three nested groups';
    $deep = {conjunction => 'and', items => [$deep]};
    refused(request('detail', {selected => ['source.id']}, filters => $deep), 'filters nested too deeply');
    refused(request('detail', {selected => ['source.id']}, page => {number => 0, size => 30}), 'page 0');
    refused('not an object', 'a body that is not an object');
};

subtest 'host configuration' => sub {
    my $hidden = {%$descriptor, fields => [field('source.tag', 'Tag', 'text')]};
    eval { Selecto::API::Spa->new(domains => [{descriptor => $hidden, engine => $engine}]) };
    is $@->code, 'invalid_spa_host', 'a descriptor cannot advertise an internal field';
    eval { Selecto::API::Spa->new(domains => [{descriptor => $descriptor, engine => $engine}], limits => {selectd => 2}) };
    is $@->code, 'invalid_spa_host', 'unknown limits are refused';
    my $narrow = Selecto::API::Spa->new(domains => [{descriptor => $descriptor, engine => $engine}], limits => {selected => 1});
    is $narrow->request({method => 'POST', path => '/api/selecto/query',
        body => request('detail', {selected => ['source.id', 'source.name']})})->{status}, 422, 'limits apply';
    my @contexts;
    my $factory = Selecto::API::Spa->new(base_path => '/spa', domains => [{descriptor => $descriptor, domain => $domain,
        engine => sub ($context) { push @contexts, $context; $engine }}]);
    is $factory->request({method => 'POST', path => '/spa/query', body => request('detail', {selected => ['source.id']}),
        context => 'request-7'})->{status}, 200, 'an engine factory';
    is_deeply \@contexts, ['request-7'], 'receives the request context';
};

subtest 'a database failure is 503' => sub {
    $dbh->do('DROP TABLE trees');
    is_deeply post(request('detail', {selected => ['source.id']})), {status => 503, json => {error => 'The database is unavailable'}};
};

done_testing;
