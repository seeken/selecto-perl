use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use DBI;
use Mojo::URL;
use Selecto;
use Selecto::API::RemoteQuery;

sub exercise {
    my ($driver, $dbh) = @_;
    my $temporary = $driver eq 'postgresql' ? 'TEMP ' : '';
    $dbh->do("CREATE ${temporary}TABLE remote_items (id INTEGER, tenant_id INTEGER,
        name TEXT, amount " . ($driver eq 'postgresql' ? 'NUMERIC' : 'TEXT') . ",
        active BOOLEAN, note TEXT, large_integer BIGINT, due_on DATE, secret TEXT)");
    for my $row (
        [1, 1, 'Alpha One', '12.5', 1, undef, '9007199254740993', '2026-10-01', 'alpha-secret'],
        [2, 1, 'Alpha Two', '0.1', 0, 'second', '9007199254740994', '2026-10-02', 'alpha-secret-2'],
        [3, 1, 'Alpha Three', '9007199254740993.123456', 1, 'third', '9007199254740995', '2026-10-03', 'alpha-secret-3'],
        [1, 2, 'Beta One', '77.7', 0, undef, '9007199254740996', '2026-10-04', 'beta-secret'],
    ) {
        $dbh->do('INSERT INTO remote_items VALUES (?,?,?,?,?,?,?,?,?)', undef, @$row);
    }
    my @fields = qw(id tenant_id name amount active note large_integer due_on secret);
    my %types = (id => 'integer', tenant_id => 'integer', name => 'string',
        amount => 'decimal', active => 'boolean', note => 'string',
        large_integer => 'integer', due_on => 'date', secret => 'string');
    my $domain = Selecto::Domain->parse({schema_version => 1, domain_version => '1',
        domain_fingerprint => 'sha256:remote-items-test-v1', name => 'Remote items',
        source => {source_table => 'remote_items', tenant_field => 'tenant_id',
            primary_key => 'id', fields => \@fields,
            columns => {map { $_ => {type => $types{$_}, nullable => $_ eq 'note' ? 1 : 0,
                ($_ eq 'tenant_id' || $_ eq 'secret' ? (internal => 1) : ())} } @fields},
            associations => {}}, schemas => {}, joins => {}}, strict => 1);
    my $adapter = Selecto->adapter($driver => dbh => $dbh);
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 1});
    my $host = Selecto::API::RemoteQuery->new(base_path => '/api/items',
        max_limit => 10, default_limit => 2, field_encodings => {large_integer => 'decimal-string'});
    my $envelope = sub {
        return {format => 'selecto.remote-query', format_version => 1,
            domain => {fingerprint => $domain->fingerprint}, request_id => 'test-1',
            query => {select => [qw(id name amount active note large_integer due_on)],
                order_by => [{field => 'id', direction => 'asc'}], limit => 2, offset => 0}};
    };
    my $call = sub {
        my ($body, $type) = @_;
        my $response = $host->request($engine, {method => 'POST', path => '/api/items/query',
            content_type => $type // 'application/json', body => $body});
        return ($response->{status}, JSON::PP->new->utf8->decode($response->{body}));
    };
    my ($status, $result) = $call->($envelope->());
    is $status, 200, 'native bounded query succeeds';
    is_deeply $result->{data}{rows}, [
        [1, 'Alpha One', '12.5', JSON::PP::true, undef, '9007199254740993', '2026-10-01'],
        [2, 'Alpha Two', '0.1', JSON::PP::false, 'second', '9007199254740994', '2026-10-02'],
    ], 'exact decimals, unsafe integers, booleans, dates and NULL survive the wire';
    is_deeply $result->{data}{page}, {limit => 2, offset => 0, has_more => JSON::PP::true},
        'one lookahead row establishes a next page';
    is $result->{meta}{request_id}, 'test-1', 'safe correlation retained';
    is_deeply [map { $_->{encoding} } @{$result->{data}{columns}}],
        [qw(json string decimal-string json string decimal-string string)], 'typed encodings are explicit';
    my $page = $envelope->(); $page->{query}{offset} = 2;
    ($status, $result) = $call->($page);
    is_deeply $result->{data}{rows}, [[3, 'Alpha Three', '9007199254740993.123456',
        JSON::PP::true, 'third', '9007199254740995', '2026-10-03']], 'last native page stays exact';
    ok !$result->{data}{page}{has_more}, 'last page has no continuation';
    $page->{query}{offset} = 20;
    ($status, $result) = $call->($page);
    is_deeply $result->{data}{rows}, [], 'empty page';
    is $result->{data}{columns}[5]{encoding}, 'decimal-string', 'empty page retains declared unsafe-integer codec';
    my $objects = $envelope->(); $objects->{query}{row_format} = 'objects';
    ($status, $result) = $call->($objects);
    is $result->{data}{rows}[0]{large_integer}, '9007199254740993', 'object rows retain exact integer';
    my $sorted = $envelope->();
    $sorted->{query}{order_by} = [{field => 'active', direction => 'asc'}];
    $sorted->{query}{limit} = 1; $sorted->{query}{offset} = 1;
    ($status, $result) = $call->($sorted);
    is $status, 200, 'nonunique ordering is admitted with a public key';
    is $result->{data}{rows}[0][0], 1, 'nonunique ordering has deterministic root-key tie break';
    $sorted->{query}{order_by} = [{field => 'id', direction => 'desc'}];
    $sorted->{query}{offset} = 0;
    ($status, $result) = $call->($sorted);
    is $result->{data}{rows}[0][0], 3, 'explicit descending public key is preserved';
    for my $policy (qw(required_selected required_order_by)) {
        my $document = JSON::PP->new->decode(JSON::PP->new->encode($domain->contract));
        $document->{$policy} = $policy eq 'required_selected' ? ['id'] : [['id', 'desc']];
        my $governed = Selecto::Engine->new(domain => Selecto::Domain->parse($document, strict => 1),
            adapter => $adapter, scope => {tenant => 1});
        my $governed_request = $envelope->();
        $governed_request->{domain}{fingerprint} = $governed->domain->fingerprint;
        is $host->request($governed, {method => 'POST', path => '/api/items/query',
            content_type => 'application/json', body => $governed_request})->{status}, 501,
            "$policy is refused instead of silently changing the wire intent";
    }
    for my $case (
        ['stale', sub { $_[0]{domain}{fingerprint} = 'stale' }, 409, 'stale_domain_fingerprint'],
        ['unknown select', sub { $_[0]{query}{select} = ['__selecto_missing__'] }, 422, 'invalid_field'],
        ['hidden select', sub { $_[0]{query}{select} = ['secret'] }, 403, 'hidden_field'],
        ['hidden filter', sub { $_[0]{query}{filters} = [{field => 'secret', op => 'eq', value => 'x'}] }, 403, 'hidden_field'],
        ['hidden order', sub { $_[0]{query}{order_by} = [{field => 'secret', direction => 'asc'}] }, 403, 'hidden_field'],
        ['forged tenant', sub { $_[0]{query}{tenant} = 2 }, 422, 'invalid_query'],
        ['zero page', sub { $_[0]{query}{limit} = 0 }, 422, 'invalid_query'],
        ['text page', sub { $_[0]{query}{limit} = '2' }, 422, 'invalid_query'],
        ['oversized page', sub { $_[0]{query}{limit} = 11 }, 422, 'invalid_query'],
        ['unknown protocol', sub { $_[0]{format_version} = 2 }, 400, 'unsupported_protocol_version'],
        ['text protocol', sub { $_[0]{format_version} = '1' }, 400, 'unsupported_protocol_version'],
        ['unsupported aggregate', sub { $_[0]{query}{group_by} = ['name'] }, 501, 'operation_unsupported'],
        ['duplicate alias', sub { $_[0]{query}{select} = [{field => 'id', alias => 'x'}, {field => 'name', alias => 'x'}] }, 422, 'invalid_query'],
        ['malformed ordering', sub { $_[0]{query}{order_by} = {} }, 422, 'invalid_query'],
    ) {
        my $body = $envelope->(); $case->[1]->($body);
        ($status, $result) = $call->($body);
        is $status, $case->[2], "$case->[0] status";
        is $result->{error}{code}, $case->[3], "$case->[0] code";
        is_deeply $result->{error}{details}, {}, 'refusal has no trusted or native details';
    }
    ($status) = $call->($envelope->(), 'text/plain'); is $status, 415, 'media type checked';
    for my $path ('/api/items', '/api/items/') {
        my $manifest = $host->request($engine, {method => 'GET', path => $path});
        is_deeply(JSON::PP->new->decode($manifest->{body})->{profiles}, ['remote_query.v1'], 'manifest advertises the implemented envelope');
    }
    my $denied = $host->request($engine, {method => 'GET', path => '/api/items/domain'});
    is $denied->{status}, 403, 'complete domain publication is opt-in';
    my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    is $host->request($unscoped, {method => 'POST', path => '/api/items/query',
        content_type => 'application/json', body => $envelope->()})->{status}, 403,
        'missing trusted tenant scope is forbidden';
    my $other = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 2});
    my $other_response = $host->request($other, {method => 'POST', path => '/api/items/query',
        content_type => 'application/json', body => $envelope->()});
    is(JSON::PP->new->decode($other_response->{body})->{data}{rows}[0][1], 'Beta One',
        'a fresh trusted engine changes the tenant without changing caller intent');
}

subtest 'SQLite native scalar transport controls (no decimal comparison claim)' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    exercise('sqlite', $dbh);
    $dbh->disconnect;
};

subtest 'PostgreSQL native scalar transport' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    if (!$url) {
        die "PostgreSQL is required for this run\n" if $ENV{SELECTO_REMOTE_REQUIRE_POSTGRES};
        plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL not configured';
    }
    my $connection = Mojo::URL->new($url);
    my $database = substr($connection->path, 1);
    die 'Expected an owned PostgreSQL test URL' unless $database =~ /\A[A-Za-z0-9_]+\z/;
    my $dbh = DBI->connect('dbi:Pg:dbname=' . $database . ';host=' . $connection->host
        . ';port=' . $connection->port, $connection->username, $connection->password // '',
        {RaiseError => 1, PrintError => 0, pg_enable_utf8 => 1});
    exercise('postgresql', $dbh);
    $dbh->disconnect;
};

done_testing;
