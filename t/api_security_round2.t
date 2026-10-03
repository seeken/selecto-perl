use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use DBI ();
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::API::ResponsePolicy ();
use Selecto::API::ResultFormatter ();
use Selecto::Domain ();
use Selecto::Limits ();
use Selecto::Engine ();
use Selecto::SQLite ();

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', domain_fingerprint => 'sha256:privacy',
    name => 'Privacy', source => {source_table => 'records', primary_key => 'id',
        fields => [qw(id label)], columns => {id => {type => 'integer'}, label => {type => 'string'}},
        associations => {}}, schemas => {}, joins => {},
    writes => {operations => {insert => {enabled => JSON::PP::true}},
        fields => {label => {insertable => JSON::PP::true}}},
});
my $request = {method => 'POST', path => '/api/v1/selecto/query', body => {debug_sql => 1}, debug_sql => 1};
my $payload = {columns => ['sql'], rows => [{sql => 'business value'}],
    sql => 'SELECT secret FROM private', params => ['secret'],
    metadata => {compiled_sql => 'SELECT internal', debug => {sql => 'SELECT internal'}}};
my $api = Selecto::API->new(domain => $domain);
my $response = $api->request($request, {query => sub { ['ok', $payload] }});
is $response->{status}, 200, 'normal query succeeds';
unlike $response->{body}, qr/SELECT|secret/, 'SQL and parameters removed recursively by default';
like $response->{body}, qr/business value/, 'a business column named sql is preserved';
ok exists($payload->{sql}), 'sanitization does not mutate handler-owned data';
for my $mode (1, sub { 1 }) {
    my $debug = Selecto::API->new(domain => $domain, debug_sql => $mode);
    like $debug->request($request, {query => sub { ['ok', $payload] }})->{body},
        qr/SELECT secret/, 'trusted explicit debug configuration retains diagnostics';
}
for my $mode (sub { 0 }, sub { die 'unavailable' }, sub { return {yes => 1} }) {
    my $debug = Selecto::API->new(domain => $domain, debug_sql => $mode);
    unlike $debug->request($request, {query => sub { ['ok', $payload] }})->{body},
        qr/SELECT secret/, 'debug authorization fails closed';
}
my $error = $api->request($request, {query => sub { ['error', {
    code => 'query_failed', message => 'SELECT secret',
    details => {cause => 'SELECT secret', sql => 'SELECT secret', maximum => 12},
}] }});
unlike $error->{body}, qr/SELECT|secret/, 'ordinary handler errors redact driver diagnostic text';
like $error->{body}, qr/"maximum":12/, 'public structured limit metadata remains';
my $domain_request = {method => 'GET', path => '/api/v1/selecto/domain', publish_domain => 1};
is $api->request($domain_request)->{status}, 403, 'full domain publication is denied by default';
for my $mode (1, sub { 1 }) {
    my $published = Selecto::API->new(domain => $domain, publish_domain => $mode)->request($domain_request);
    is $published->{status}, 200, 'trusted publication opt-in permits full contract';
    is $published->{body}, Selecto::API::canonical_json($domain->contract), 'authorized contract bytes are unchanged';
}
is(Selecto::API->new(domain => $domain, publish_domain => sub { die 'no' })
    ->request($domain_request)->{status}, 403, 'publication exception denies access');

my $small = {columns => ['id'], rows => [[7]]};
for my $format (qw(json csv tsv xlsx)) {
    my $normal = $api->request({%$request, response_format => $format}, {query => sub { ['ok', $small] }});
    is $normal->{status}, 200, "$format baseline succeeds";
    my $size = length($normal->{body});
    # Admission also charges result structure. CSV/TSV bodies can be smaller
    # than that structure; the XLSX regression isolates final encoded bytes.
    if ($format eq 'json' || $format eq 'xlsx') {
        my $at = Selecto::API->new(domain => $domain, limits => Selecto::Limits->new(max_response_bytes => $size));
        is $at->request({%$request, response_format => $format}, {query => sub { ['ok', $small] }})->{status}, 200,
            "$format exact encoded byte boundary accepted";
        my $under = Selecto::API->new(domain => $domain, limits => Selecto::Limits->new(max_response_bytes => $size - 1));
        is $under->request({%$request, response_format => $format}, {query => sub { ['ok', $small] }})->{status}, 422,
            "$format one byte beyond encoded boundary rejected";
    }
}
my $tighter = Selecto::API::ResponsePolicy->bind_limits({%$small}, Selecto::Limits->new(max_response_bytes => 500));
is $api->request({%$request, response_format => 'xlsx'}, {query => sub { ['ok', $tighter] }})->{status}, 422,
    'handler-associated tighter limit applies after XLSX encoding';
my $temp = Selecto::API->new(domain => $domain, limits => Selecto::Limits->new(max_response_temp_bytes => 100));
is $temp->request({%$request, response_format => 'xlsx'}, {query => sub { ['ok', $small] }})->{status}, 422,
    'XLSX temporary reservation rejected before workbook allocation';
my $cycle = []; push @$cycle, $cycle;
is $api->request($request, {query => sub { ['ok', {rows => $cycle}] }})->{status}, 422,
    'cyclic custom result rejected before copying';

subtest 'SQLite handler input and generated parameter budgets' => sub {
    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto::SQLite->new(dbh => $dbh),
        limits => Selecto::Limits->new(max_value_bytes => 4, max_parameter_bytes => 6));
    my $handler = Selecto::API::EngineHandler->new;
    for my $filters (
        [{field => 'label', op => 'eq', value => '12345'}],
        [{field => 'label', op => 'between', value => '1', end => '12345'}],
        [{field => 'label', op => 'in', value => ['1234']}, {field => 'label', op => 'eq', value => '567'}],
        [{field => 'label', op => 'eq', value => "東京"}],
    ) {
        eval { $handler->query($engine, {select => ['id'], filters => $filters, limit => 0}) };
        isa_ok $@, 'Selecto::Error';
        is $@->code, 'invalid_api_query', 'scalar and whole-operation input refused before execution';
    }
    my $valid = $handler->query($engine, {select => ['id'], filters => [
        {field => 'label', op => 'eq', value => '1234'}, {field => 'label', op => 'eq', value => '56'},
    ], limit => 0});
    is $valid->{returned}, 0, 'exact input byte boundary accepted without counting identifiers';
    eval { $handler->write_command($engine, {operation => 'insert', assignments => {label => '12345'}}) };
    is $@->code, 'invalid_api_write', 'write assignments obey scalar byte limits before write validation';

    my $conditional_domain = Selecto::Domain->parse({schema_version => 1, name => 'Conditional budget',
        source => {source_table => 'records', primary_key => 'id', fields => [qw(id flag a b)],
            columns => {map { $_ => {type => 'integer'} } qw(id flag a b)}, associations => {}}, schemas => {}, joins => {},
        components => {filter_choices => {choice => {label => 'Choice', choices => [{value => 14, label => 'Fourteen'}],
            conditional => {when_field => 'flag', present_field => 'a', absent_field => 'b'}}}}}, strict => 1);
    my $loose_engine = Selecto::Engine->new(domain => $conditional_domain, adapter => Selecto::SQLite->new(dbh => $dbh));
    my $tight_handler = Selecto::API::EngineHandler->new(limits => Selecto::Limits->new(max_parameter_bytes => 3));
    eval { $tight_handler->query($loose_engine, {select => ['id'], limit => 0,
        filters => [{field => 'choice', op => 'eq', value => 14}]}) };
    isa_ok $@, 'Selecto::Error';
    is $@->code, 'invalid_query', 'generated repeated parameters honor tighter handler policy';
    is $loose_engine->limits->get('max_parameter_bytes'), 65_536, 'request does not mutate original engine policy';
    done_testing;
};

for my $value (undef, JSON::PP::true, JSON::PP::false, 0, 123, '123', "é\"\n", pack('C', 233),
    {"control\x01" => [1, '2', "\x01\x08\t\n\r\f\\\"", {rows => []}]}) {
    my $wire = Selecto::API::canonical_json($value);
    my $limits = Selecto::Limits->new(max_response_bytes => length($wire));
    is(Selecto::API::ResponsePolicy->check_json($value, $limits), length($wire),
        'JSON admission exactly matches native numbers, strings, UTF-8 and escaping');
}
my $escaped_payload = {columns => ['label'], rows => [[chr(1) x 100]]};
my $escaped_api = Selecto::API->new(domain => $domain, limits => Selecto::Limits->new(max_response_bytes => 200));
my $success_encodes = 0;
my $canonical = \&Selecto::API::canonical_json;
{
    no warnings 'redefine';
    local *Selecto::API::canonical_json = sub {
        $success_encodes++ if ref($_[0]) eq 'HASH' && exists $_[0]{data};
        return $canonical->(@_);
    };
    is $escaped_api->request($request, {query => sub { ['ok', $escaped_payload] }})->{status}, 422,
        'escaping expansion refused before success encoding';
}
is $success_encodes, 0, 'oversized escaped success is never materialized';
my $error_limited = $escaped_api->request($request, {query => sub { ['error', {
    code => 'query_failed', details => {field => chr(1) x 100},
}] }});
is(JSON::PP->new->decode($error_limited->{body})->{error}{code}, 'api_result_limit_exceeded',
    'error metadata encoding is also bounded');
{
    my @paths;
    my $newdir = \&File::Temp::newdir;
    my $tempfile = \&File::Temp::new;
    no warnings 'redefine';
    local *File::Temp::newdir = sub { my $dir = $newdir->(@_); push @paths, "$dir"; return $dir };
    local *File::Temp::new = sub { my $handle = $tempfile->(@_); push @paths, $handle->filename; return $handle };
    my $limited = Selecto::API->new(domain => $domain, limits => Selecto::Limits->new(max_response_bytes => 500));
    is $limited->request({%$request, response_format => 'xlsx'}, {query => sub { ['ok', $small] }})->{status}, 422,
        'XLSX final-size failure occurs after bounded workbook generation';
    cmp_ok scalar(@paths), '>=', 2, 'workbook temporary directory and output file were observed';
    ok !-e $_, "temporary artifact removed on final-size failure: $_" for @paths;
}
done_testing;
