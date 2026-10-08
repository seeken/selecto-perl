use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto;
use Selecto::API::EngineHandler;

{
    package AdversarialFieldRoles::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;
    sub execute_query ($self, $statement) {
        $self->{executions}++;
        $self->{last_sql} = $statement->sql;
        return {columns => $statement->columns,
            rows => $self->{rows} // [[map {$_ eq 'id' ? 1 : 'public'} @{$statement->columns}]]};
    }
}

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0',
    domain_fingerprint => 'sha256:adversarial-field-roles', name => 'Adversarial field roles',
    source => {
        source_table => 'records', primary_key => 'id', fields => [qw(id name)],
        columns => {id => {type => 'integer'}, name => {
            type => 'string', filterable => JSON::PP::false, sortable => JSON::PP::false,
            groupable => JSON::PP::false,
        }}, associations => {},
    }, schemas => {}, joins => {},
    query_library => {
        projections => {public => {fields => [qw(id name)]}},
        segments => {name_probe => {filters => [['eq', 'name', 'private']]}},
        orderings => {name_probe => {order_by => [['name', 'asc']]}},
        views => {name_probe => {projection => 'public', ordering => 'name_probe'}},
    },
}, strict => 1);
my $adapter = AdversarialFieldRoles::Adapter->new(dbh => bless({}, 'AdversarialFieldRoles::DBH'));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $handler = Selecto::API::EngineHandler->new;
for my $probe (
    ['filter', {select => ['id'], filters => [{field => 'name', op => 'eq', value => 'private'}]}],
    ['sort', {select => ['id'], order_by => [{field => 'name'}]}],
    ['group', {select => ['name'], group_by => ['name']}],
    ['named segment', {select => ['id'], segments => ['name_probe']}],
    ['named ordering', {select => ['id'], ordering => 'name_probe'}],
    ['named view', {view => 'name_probe'}],
) {
    my ($label, $intent) = @$probe;
    my $ok = eval {$handler->query($engine, $intent); 1};
    my $error = $@;
    ok !$ok, "$label cannot bypass disabled field role";
    is ref($error) && $error->can('code') ? $error->code : undef, 'invalid_field',
        "$label fails with the stable public field refusal";
}
is $adapter->{executions} // 0, 0, 'disabled-role refusals happen before database execution';
my $result = $handler->query($engine, {select => [qw(id name)]});
is_deeply $result->{rows}, [[1, 'public']], 'disabled filtering and sorting still allow public selection';
$result = $handler->query($engine, {select => ['id'], group_by => ['id'], order_by => [{field => 'id'}]});
is_deeply $result->{rows}, [[1]], 'public groupable field remains available';
like $adapter->{last_sql}, qr/GROUP BY .*"id"/, 'public grouping compiles a real group operation';
my $ok = eval {$handler->query($engine, {select => [qw(id name)], group_by => ['id']}); 1};
ok !$ok, 'a nongrouped selection is rejected before a database error';
is ref($@) ? $@->code : undef, 'invalid_api_query', 'invalid grouped projection has a stable refusal';
my $api = Selecto::API->new(domain => $domain);
$handler->describe_openapi($api);
is $api->openapi_document->{components}{schemas}{SelectoQuery}{properties}{group_by}{minItems}, 1,
    'OpenAPI publishes bounded grouping';
$adapter->{rows} = [[1], [2], [3]];
$result = $handler->query($engine, {select => ['id'], order_by => [{field => 'id'}], limit => 2});
is_deeply $result->{rows}, [[1], [2]], 'the extra pagination row is withheld';
is $result->{returned}, 2, 'returned count excludes the extra row';
ok $result->{has_more}, 'has_more is based on an observed additional row';
like $adapter->{last_sql}, qr/LIMIT 3\b/, 'the native query fetches one bounded extra row';
$adapter->{rows} = [[4]];
$result = $handler->query($engine, {select => ['id'], order_by => [{field => 'id'}], limit => 2, offset => 3});
ok !$result->{has_more}, 'a final partial page has no further matching row';
my $executions = $adapter->{executions};
$result = $handler->query($engine, {select => ['id'], limit => 0});
is_deeply $result->{rows}, [], 'zero-sized page returns no rows';
ok !$result->{has_more}, 'zero-sized page reports no observed continuation';
is $adapter->{executions}, $executions, 'zero-sized page avoids database execution';
my $hidden_contract = dclone($domain->contract);
$hidden_contract->{source}{columns}{name}{hidden} = JSON::PP::true;
my $hidden_domain = Selecto::Domain->parse($hidden_contract, strict => 1);
ok !$hidden_domain->field_is_public('name'), 'an explicit hidden marker withholds a field';
my $hidden_engine = Selecto::Engine->new(domain => $hidden_domain, adapter => $adapter);
for my $intent (
    {select => ['name']},
    {select => ['id'], filters => [{field => 'name', op => 'eq', value => 'private'}]},
    {select => ['id'], order_by => [{field => 'name'}]},
    {select => ['name'], group_by => ['name']},
    {projection => 'public'},
    {select => ['id'], segments => ['name_probe']},
    {select => ['id'], ordering => 'name_probe'},
    {view => 'name_probe'},
) {
    my $accepted = eval {$handler->query($hidden_engine, $intent); 1};
    my $error = $@;
    ok !$accepted, 'hidden marker refuses public query role or named route';
    is ref($error) ? $error->code : undef, 'hidden_field', 'hidden marker uses the public secrecy code';
}
done_testing;
