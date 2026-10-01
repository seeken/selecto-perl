use 5.034;
use strict;
use warnings;

use Test::More;
use Scalar::Util qw(blessed);
use Selecto::CannedPage ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

# A canned page is a public surface: no part of its definition may name a
# field the domain withholds (redact_fields or an internal column).

my $E = 'Selecto::Expression';

sub relation {
    my ($table, $columns, %extra) = @_;
    return {
        source_table => $table, primary_key => 'id', fields => [sort keys %$columns],
        columns => {map { ($_ => (ref $columns->{$_} ? $columns->{$_} : {type => $columns->{$_}})) } keys %$columns},
        associations => {}, %extra,
    };
}

sub contract {
    my (%options) = @_;
    return {
        schema_version => 1, name => 'Products',
        source => {
            %{relation('products', {
                id => 'integer', name => 'string', price => 'decimal', maker_id => 'integer',
                secret_token => 'string', cost => 'integer',
                shop_id => {type => 'integer', internal => 1},
            }, redact_fields => ['cost'])},
            associations => {
                notes => {queryable => 'note', owner_key => 'id', related_key => 'product_id', cardinality => 'many'},
                maker => {queryable => 'maker', owner_key => 'maker_id', related_key => 'id'},
            },
        },
        schemas => {
            note => relation('notes', {id => 'integer', product_id => 'integer', body => 'string',
                private_body => 'string'}, redact_fields => ['private_body']),
            maker => relation('makers', {id => 'integer', name => 'string', code => 'string',
                margin => 'decimal'}, redact_fields => ['margin']),
        },
        joins => {},
        redact_fields => ['secret_token', 'maker.code', @{$options{redact} // []}],
    };
}

my $domain = Selecto::Domain->parse(contract());
my $engine = Selecto::Engine->new(
    domain => $domain,
    adapter => Selecto::PostgreSQL->new(dbh => bless({}, 'Test::CannedPageDBH')),
);
my $query = $engine->query;

sub definition {
    my (%override) = @_;
    return (
        id => 'products', domain => $domain,
        dataset => {query => $query->where($E->not_null('name')), entity_key => ['id']},
        views => [
            {id => 'list', kind => 'detail', query => $query->select('id', 'name', 'maker.name',
                $E->related_collection('notes', ['body'], order_by => [['body', 'asc']])->as('notes'))
                ->order_by('price', 'desc')},
            {id => 'makers', kind => 'aggregate', query => $query->select('maker.name',
                $E->count_distinct('id')->as('items'))->group_by('maker.name')
                ->order_by($E->count_distinct('id'), 'desc')},
        ],
        controls => [
            {id => 'maker', kind => 'facet', field => 'maker_id', label_field => 'maker.name',
                values => {searchable => 1}},
            {id => 'note', kind => 'facet', field => 'notes.body'},
            {id => 'price', kind => 'range', field => 'price'},
            {id => 'name', kind => 'text', field => 'name'},
        ],
        %override,
    );
}

sub refusal {
    my (@args) = @_;
    my $page = eval { Selecto::CannedPage->new(@args) };
    return 'built' if $page;
    my $error = $@;
    return "died: $error" unless blessed($error) && $error->isa('Selecto::Error');
    return {code => $error->code, message => $error->message, details => $error->details};
}

sub view {
    my ($id, $kind, $view_query) = @_;
    return [{id => $id, kind => $kind, query => $view_query}];
}

my $page = Selecto::CannedPage->new(definition());
isa_ok $page, 'Selecto::CannedPage', 'a page using only public fields';

my @cases = (
    ['detail selection', [views => view('list', 'detail', $query->select('id', 'secret_token'))],
        'view list references redacted field secret_token', {field => 'secret_token', view => 'list'}],
    ['aliased selection', [views => view('list', 'detail', $query->select('id', $E->field('secret_token')->as('token')))],
        'view list references redacted field secret_token', {field => 'secret_token', view => 'list'}],
    ['source.redact_fields root field', [views => view('list', 'detail', $query->select('id', 'cost'))],
        'view list references redacted field cost', {field => 'cost', view => 'list'}],
    ['dotted top-level redaction', [views => view('list', 'detail', $query->select('id', 'maker.code'))],
        'view list references redacted field maker.code', {field => 'maker.code', view => 'list'}],
    ['schema redaction of a to-one field', [views => view('list', 'detail', $query->select('id', 'maker.margin'))],
        'view list references redacted field maker.margin', {field => 'maker.margin', view => 'list'}],
    ['collection child', [views => view('list', 'detail',
        $query->select('id', $E->related_collection('notes', ['body', 'private_body'])->as('notes')))],
        'view list references redacted field notes.private_body', {field => 'notes.private_body', view => 'list'}],
    ['collection ordering', [views => view('list', 'detail',
        $query->select('id', $E->related_collection('notes', ['body'], order_by => [['private_body', 'asc']])->as('notes')))],
        'view list references redacted field notes.private_body', {field => 'notes.private_body', view => 'list'}],
    ['detail ordering', [views => view('list', 'detail', $query->select('id')->order_by('secret_token'))],
        'view list references redacted field secret_token', {field => 'secret_token', view => 'list'}],
    ['aggregate group', [views => view('costs', 'aggregate',
        $query->select('cost', $E->count_distinct('id')->as('n'))->group_by('cost'))],
        'view costs references redacted field cost', {field => 'cost', view => 'costs'}],
    ['aggregate ordering expression', [views => view('names', 'aggregate',
        $query->select('name', $E->count_distinct('id')->as('n'))->group_by('name')
            ->order_by($E->max('secret_token'), 'desc'))],
        'view names references redacted field secret_token', {field => 'secret_token', view => 'names'}],
    ['internal column', [views => view('list', 'detail', $query->select('id', 'shop_id'))],
        'view list references internal field shop_id', {field => 'shop_id', view => 'list'}],
    ['dataset predicate', [dataset => {query => $query->where($E->not_null('secret_token')), entity_key => ['id']}],
        'dataset query references redacted field secret_token', {field => 'secret_token', dataset => 'query'}],
    ['dataset field comparison', [dataset => {query => $query->where(
        $E->all([$E->eq('name', 'x'), $E->gt('price', $E->field('maker.margin'))])), entity_key => ['id']}],
        'dataset query references redacted field maker.margin', {field => 'maker.margin', dataset => 'query'}],
    ['dataset value expression', [dataset => {query => $query->where(
        $E->eq($E->value(['upper', ['field', 'secret_token']]), 'X')), entity_key => ['id']}],
        'dataset query references redacted field secret_token', {field => 'secret_token', dataset => 'query'}],
    ['dataset internal predicate', [dataset => {query => $query->where($E->eq('shop_id', 1)), entity_key => ['id']}],
        'dataset query references internal field shop_id', {field => 'shop_id', dataset => 'query'}],
    ['facet field', [controls => [{id => 'token', kind => 'facet', field => 'secret_token'}]],
        'control token references redacted field secret_token', {field => 'secret_token', control => 'token'}],
    ['facet label field', [controls => [{id => 'maker', kind => 'facet', field => 'maker_id', label_field => 'maker.code'}]],
        'control maker references redacted field maker.code', {field => 'maker.code', control => 'maker'}],
    ['facet on a redacted child', [controls => [{id => 'note', kind => 'facet', field => 'notes.private_body'}]],
        'control note references redacted field notes.private_body', {field => 'notes.private_body', control => 'note'}],
    ['range control', [controls => [{id => 'cost', kind => 'range', field => 'cost'}]],
        'control cost references redacted field cost', {field => 'cost', control => 'cost'}],
    ['text control', [controls => [{id => 'token', kind => 'text', field => 'secret_token'}]],
        'control token references redacted field secret_token', {field => 'secret_token', control => 'token'}],
    ['internal facet', [controls => [{id => 'shop', kind => 'facet', field => 'shop_id'}]],
        'control shop references internal field shop_id', {field => 'shop_id', control => 'shop'}],
    ['dataset is checked before views', [
        dataset => {query => $query->where($E->not_null('cost')), entity_key => ['id']},
        views => view('list', 'detail', $query->select('id', 'secret_token'))],
        'dataset query references redacted field cost', {field => 'cost', dataset => 'query'}],
);
for my $case (@cases) {
    my ($label, $override, $message, $details) = @$case;
    is_deeply refusal(definition(@$override)),
        {code => 'invalid_canned_page', message => $message, details => $details}, $label;
}

my $keyed = Selecto::Domain->parse(contract(redact => ['id']));
is_deeply refusal(definition(domain => $keyed)),
    {code => 'invalid_canned_page', message => 'dataset entity_key references redacted field id',
        details => {field => 'id', dataset => 'entity_key'}},
    'a redacted primary key cannot be the entity key';

# Structural errors still come first.
is refusal(definition(views => view('list', 'detail', $query->select('id', 'secret_token')),
    controls => [{id => 'bad', kind => 'slider', field => 'name'}]))->{message},
    'control kind must be text, range, or facet', 'structural validation runs before the redaction check';

# Constructor-form domains carry no redaction metadata.
my $plain = Selecto::Domain->new(name => 'Plain', table => 'plain',
    fields => {id => 'integer', secret_token => 'string'});
ok(Selecto::CannedPage->new(id => 'plain', domain => $plain,
    dataset => {query => Selecto::Query->new, entity_key => ['id']},
    views => view('list', 'detail', Selecto::Query->new->select('id', 'secret_token'))),
    'constructor-form domains are unaffected');

# Request state only picks authored views, controls and values, so no
# planned query of a clean page can reach a withheld column.
my $plan = $page->plan({
    view => 'list',
    filters => {maker => ['1'], note => ['x'], price => {min => 1, max => 9}, name => 'A'},
    facet_search => {maker => 'Ac'},
    drilldown => {view => 'makers', values => ['Acme']},
});
my @queries = ($plan->{query}, $plan->{total_query}, values %{$plan->{facet_queries}},
    values %{$plan->{selected_facet_queries}});
is scalar(@queries), 6, 'result, total, two facet and two selected-facet queries';
for my $planned (@queries) {
    unlike $engine->compile($planned)->sql, qr/secret_token|\bcost\b|\bcode\b|margin|private_body|shop_id/,
        'planned SQL names no withheld column';
}
for my $state (
    {view => 'secret'}, {filters => {secret_token => ['x']}},
    {drilldown => {view => 'list', values => []}}, {facet_search => {note => 'x'}},
) {
    ok !eval { $page->plan($state); 1 }, 'state cannot name anything outside the definition';
}

done_testing;
