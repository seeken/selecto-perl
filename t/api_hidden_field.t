use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();

# A query that names a field the domain withholds (internal or redacted) is
# refused as hidden_field, 403 through Selecto::API, before any SQL runs. An
# unknown field keeps its own refusal; writes keep field_not_public.

sub refusal {
    my ($code) = @_;
    return {code => 'ok'} if eval { $code->(); 1 };
    my $e = $@;
    return {code => "died: $e"} unless blessed($e) && $e->isa('Selecto::Error');
    return {code => $e->code, details => $e->details};
}

sub relation {
    my ($table, %cols) = @_;
    return {
        source_table => $table, primary_key => 'id', fields => [sort keys %cols],
        columns => {map { ($_ => (ref $cols{$_} ? $cols{$_} : {type => $cols{$_}})) } keys %cols},
        associations => {},
    };
}

package Capture::PG {
    use parent -norequire, 'Selecto::PostgreSQL';
    sub execute_query { my ($s, $st) = @_; $s->{executed}++; return {columns => $st->columns, rows => []} }
}
package main;
require Selecto::PostgreSQL;
@Capture::PG::ISA = ('Selecto::PostgreSQL');

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'People', domain_version => '1.0.0',
    domain_fingerprint => 'sha256:hidden-field-test',
    source => {
        %{relation('people', id => 'integer', name => 'string', joined_on => 'date',
            secret => {type => 'string', internal => 1}, ssn => 'string')},
        associations => {orders => {queryable => 'order', owner_key => 'id',
            related_key => 'person_id', cardinality => 'many'}},
    },
    schemas => {
        order => relation('orders', id => 'integer', person_id => 'integer', total => 'decimal',
            margin => {type => 'decimal', internal => 1}),
    },
    joins => {},
    redact_fields => ['ssn'],
    query_library => {
        projections => {public => {fields => ['id', 'name']}, hidden => {fields => ['id', 'secret']}},
        segments => {
            named => {filters => [['not_null', 'name']]},
            secretive => {filters => [['eq', 'secret', 'x']]},
        },
        orderings => {by_name => {order_by => [['name', 'asc']]}, by_secret => {order_by => [['secret', 'asc']]}},
        views => {
            hidden_listing => {projection => 'hidden'},
            secret_segment => {projection => 'public', segments => ['secretive']},
            secret_order => {projection => 'public', ordering => 'by_secret'},
        },
    },
    writes => {operations => {update => {enabled => JSON::PP::true}}},
});
my $adapter = Capture::PG->new(dbh => bless({}, 'Offline::DBH'));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $handler = Selecto::API::EngineHandler->new;
my $query = sub { my ($body) = @_; refusal(sub { $handler->query($engine, $body) }) };
my $hidden = sub { {code => 'hidden_field', details => {field => $_[0]}} };

subtest 'every place a query can name a hidden field' => sub {
    my @cases = (
        ['select', {select => ['id', 'secret']}, 'secret'],
        ['select object entry', {select => ['id', {field => 'secret', alias => 'shown'}]}, 'secret'],
        ['select redacted field', {select => ['id', 'ssn']}, 'ssn'],
        ['subtable selection', {select => ['id', ['orders.id', 'orders.margin']]}, 'orders.margin'],
        ['subtable of hidden fields only', {select => ['id', ['orders.margin']]}, 'orders.margin'],
        # Type and association checks never run on a hidden field, so their
        # outcome cannot reveal its type or where it lives.
        ['date format on a hidden text field', {select => ['id', {field => 'secret', format => 'iso8601'}]}, 'secret'],
        ['hidden field outside the subtable association', {select => ['id', ['orders.id', 'secret']]}, 'secret'],
        ['projection', {projection => 'hidden'}, 'secret'],
        ['view projection', {view => 'hidden_listing'}, 'secret'],
        ['segment', {select => ['id'], segments => ['secretive']}, 'secret'],
        ['view segment', {view => 'secret_segment'}, 'secret'],
        ['named ordering', {select => ['id'], ordering => 'by_secret'}, 'secret'],
        ['view ordering', {view => 'secret_order'}, 'secret'],
        ['order_by', {select => ['id'], order_by => [{field => 'secret'}]}, 'secret'],
        ['filter', {select => ['id'], filters => [{field => 'secret', op => 'eq', value => 'x'}]}, 'secret'],
        ['filter on redacted field', {select => ['id'], filters => [{field => 'ssn', op => 'is_null'}]}, 'ssn'],
        ['filter on association field', {select => ['id'],
            filters => [{field => 'orders.margin', op => 'gt', value => 1}]}, 'orders.margin'],
    );
    for my $case (@cases) {
        my ($name, $body, $field) = @$case;
        is_deeply($query->($body), $hidden->($field), "$name: 403 hidden_field naming $field");
    }
    ok(!$adapter->{executed}, 'no refused query reached the database');
    is($query->({select => ['id', 'name', ['orders.id', 'orders.total']],
        segments => ['named'], ordering => 'by_name'})->{code}, 'ok', 'public fields still query');
    is($adapter->{executed}, 1, 'the accepted query executed once');
};

subtest 'unknown and hidden fields together' => sub {
    $adapter->{executed} = 0;
    is($query->({select => ['nope']})->{code}, 'unknown_field', 'an unknown field keeps its refusal');
    is($query->({select => ['id'], filters => [{field => 'nope', op => 'is_null'}]})->{code},
        'unknown_field', 'an unknown filter field keeps its refusal');
    is($query->({select => ['secret', 'nope']})->{code}, 'unknown_field',
        'within select, an unknown field after a hidden one wins');
    is($query->({select => ['nope', 'secret']})->{code}, 'unknown_field',
        'within select, an unknown field before a hidden one wins');
    is($query->({select => ['secret', {field => 'id', format => 'bogus'}]})->{code}, 'invalid_api_query',
        'within select, an invalid entry wins over a hidden field');
    is_deeply($query->({select => ['secret', 'ssn']}), $hidden->('secret'),
        'the first hidden selection is named');
    is_deeply($query->({select => ['secret'], filters => [{field => 'nope', op => 'is_null'}]}),
        $hidden->('secret'), 'a hidden selection precedes an unknown filter');
    is($query->({select => ['id'], filters => [{field => 'nope', op => 'is_null'}],
        order_by => [{field => 'secret'}]})->{code}, 'unknown_field',
        'an unknown filter precedes a hidden order_by');
    is_deeply($query->({select => ['id'], filters => [{field => 'secret', op => 'is_null'}],
        order_by => [{field => 'nope'}]}), $hidden->('secret'), 'a hidden filter precedes an unknown order_by');
    ok(!$adapter->{executed}, 'no refused query reached the database');
};

subtest 'Selecto::API answers hidden_field with 403' => sub {
    is(Selecto::API::error_status('hidden_field'), 403, 'hidden_field maps to 403');
    is(Selecto::API::error_status($_), 422, "$_ stays 422")
        for qw(unknown_field field_not_public invalid_api_query);
    is(Selecto::API::error_status('missing_tenant_scope'), 403, 'missing_tenant_scope maps to 403');
    is(Selecto::API::error_status(undef), 422, 'no code stays 422');
    my $api = Selecto::API->new(domain => $domain, base_path => '/api');
    my $run = sub {
        my ($body, $with_status) = @_;
        return $api->request({method => 'POST', path => '/api/query', body => $body}, {query => sub {
            my $data = eval { $handler->query($engine, $_[0]) };
            return ['ok', $data] unless $@;
            my $e = $@;
            return ['error', {
                ($with_status ? (status => Selecto::API::error_status($e->code)) : ()),
                code => $e->code, message => $e->message, details => $e->details,
            }];
        }});
    };
    for my $with_status (0, 1) {
        my $label = $with_status ? 'a guard using error_status' : 'a handler error without a status';
        my $response = $run->({select => ['id', 'secret']}, $with_status);
        is($response->{status}, 403, "$label: hidden field is 403");
        is_deeply(JSON::PP->new->decode($response->{body}), {ok => JSON::PP::false, error => {
            code => 'hidden_field', details => {field => 'secret'}, message => 'Canonical API operation rejected',
        }}, "$label: the body names the code and field only");
        $response = $run->({select => ['nope']}, $with_status);
        is($response->{status}, 422, "$label: unknown field stays 422");
        is(JSON::PP->new->decode($response->{body})->{error}{code}, 'unknown_field', "$label: unknown_field code");
    }
    my $explicit = $api->request({method => 'POST', path => '/api/query', body => {}}, {query => sub {
        ['error', {status => 422, code => 'hidden_field'}];
    }});
    is($explicit->{status}, 422, 'a handler-chosen status still wins');
};

subtest 'surfaces that keep field_not_public' => sub {
    is_deeply(refusal(sub { $handler->write_command($engine, {operation => 'update',
        assignments => {secret => 'x'}, filters => [{field => 'id', op => 'eq', value => 1}]}) }),
        {code => 'field_not_public', details => {field => 'secret'}}, 'a write assignment keeps field_not_public');
    is(refusal(sub { $handler->write_command($engine, {operation => 'update',
        assignments => {name => 'x'}, filters => [{field => 'secret', op => 'eq', value => 1}]}) })->{code},
        'field_not_public', 'a write filter keeps field_not_public');
    ok(!$domain->field_is_public('secret') && !$domain->field_is_public('ssn'),
        'the domain still reports both fields as not public');
};

done_testing;
