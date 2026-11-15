use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use Selecto;
use Selecto::API::Explorer;
use Selecto::API::NestedDetail;
use Mojo::URL;

my $json = JSON::PP->new->utf8->canonical;
open my $file, '<:raw', 't/fixtures/canonical_nested_detail_v1.json' or die $!;
my $input = $json->decode(do { local $/; <$file> });
sub header { my $s = encode_base64($json->encode($_[0]), ''); $s =~ tr!+/!-_!; $s =~ s/=+\z//; $s }
sub exercise {
    my ($backend, $dbh) = @_;
    my $d = $input->{domain};
    $dbh->do('CREATE TEMP TABLE selecto_cert_nd_parents (id INTEGER,tenant_id INTEGER,name TEXT,visible INTEGER,secret TEXT)');
    $dbh->do('CREATE TEMP TABLE selecto_cert_nd_children (id INTEGER,tenant_id INTEGER,parent_id INTEGER,name TEXT,price '
        . ($backend eq 'postgresql' ? 'NUMERIC' : 'TEXT') . ',visible INTEGER,secret TEXT)');
    for my $role (qw(parents children)) {
        my $rows = $input->{dataset}{$role};
        my $sth = $dbh->prepare("INSERT INTO selecto_cert_nd_$role VALUES (" . join(',', ('?') x @{$rows->[0]}) . ')');
        $sth->execute(@$_) for @$rows;
    }
    my $domain = Selecto::Domain->parse($d, strict => 1);
    my $adapter = Selecto->adapter($backend => dbh => $dbh, temporary_relations => 1);
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7});
    my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    my $host = Selecto::API::Explorer->new(base_path => '/nd', id => 'nested', publication => 'pub-1',
        clock => '2026-11-14T00:00:00Z', nested_detail => {collection => 'children'}, publish_domain => 1);
    my $get = sub { $json->decode($host->request($engine, {method => 'GET', path => '/nd' . $_[0]})->{body}) };
    # Discovery composes with lazy canonical documents: a sidecar needs neither,
    # the manifest needs only itself, and OpenAPI is materialized on demand.
    my ($manifest_builds, $openapi_builds) = (0, 0);
    my $manifest_builder = \&Selecto::API::_manifest;
    my $openapi_builder = \&Selecto::API::_openapi;
    no warnings 'redefine';
    local *Selecto::API::_manifest = sub { $manifest_builds++; $manifest_builder->(@_) };
    local *Selecto::API::_openapi = sub { $openapi_builds++; $openapi_builder->(@_) };
    my $features = $get->('/nested-detail-features');
    is_deeply [$manifest_builds, $openapi_builds], [0, 0], 'sidecar builds neither canonical document';
    is_deeply [map { $_->{path} } @{$features->{collections}[0]{fields}}],
        [qw(children.id children.name children.price)], 'hidden child metadata stays absent';
    is_deeply $get->('/nested-detail-features'), $features, 'stable revision and inventory';
    ok scalar(grep { $_->{operation_id} eq 'getNestedDetailFeatures' } @{$get->('')->{routes}}), 'canonical manifest publishes nested discovery';
    is_deeply [$manifest_builds, $openapi_builds], [1, 0], 'nested manifest builds only its lazy manifest';
    my $openapi = $get->('/openapi.json');
    is_deeply [$manifest_builds, $openapi_builds], [1, 1], 'OpenAPI route builds its lazy document';
    ok exists($openapi->{paths}{'/nd/query'}), 'lazy OpenAPI retains the canonical query route';
    is_deeply $get->('/nested-detail-features'), $features, 'OpenAPI access preserves the nested sidecar';
    my $context = {profile => $features->{profile}, fingerprint => $features->{domain}{fingerprint},
        publication => 'pub-1', revision => $features->{revision}};
    my $call = sub {
        my ($q, %options) = @_;
        my $raw = $options{raw} // $json->encode({format => 'selecto.remote-query', format_version => 1,
            domain => {fingerprint => $options{fingerprint} // $domain->contract->{domain_fingerprint}}, query => $q});
        my $r = $host->request($options{engine} // $engine, {method => 'POST', path => '/nd/query',
            content_type => $options{type} // 'application/json', raw_body => $raw,
            headers => {'Selecto-Nested-Detail-Context' => $options{header} // header($context)}});
        return [$r->{status}, $json->decode($r->{body})];
    };
    my $query = {select => ['id', ['children.id', 'children.name', 'children.price']],
        filters => [{field => 'id', op => 'lte', value => '2'}]};
    my $r = $call->($query);
    is $r->[0], 200, 'nested governed query succeeds';
    is_deeply [$manifest_builds, $openapi_builds], [1, 1], 'nested execution builds neither document';
    is_deeply $r->[1]{data}{rows}, [[1, [[11, 'Child eleven', '0.100000'], [12, 'Child twelve', '2.500000']]], [2, []]],
        'root tenant, child tenant, fixed child policy, order, decimals and empties';
    is_deeply $r->[1]{meta}{selecto_nested_detail}, $context, 'admitted context echoed';
    is_deeply $r->[1]{data}{subtables}{children}, {columns => $query->{select}[1], limit => 20, complete => JSON::PP::true}, 'complete bounded schema';
    $r = $call->({%$query, row_format => 'objects'});
    is_deeply $r->[1]{data}{rows}[0]{children}[0],
        {'children.id' => 11, 'children.name' => 'Child eleven', 'children.price' => '0.100000'}, 'object children retain full paths';
    # A returned first page must not fetch the next parent's oversized children.
    $r = $call->({select => ['id', ['children.id']], filters => [{field => 'id', op => 'gte', value => '5'}], limit => 1});
    is $r->[0], 200, 'oversized collection on an unreturned lookahead parent is irrelevant';
    ok $r->[1]{data}{page}{has_more}, 'parent lookahead still reports next page';
    $r = $call->({select => ['id', ['children.id']], filters => [{field => 'id', op => 'eq', value => '6'}]});
    is $r->[0], 422, 'returned child overflow refuses instead of truncating';
    for my $case (
        [{%$query, select => ['id', ['children.secret']], limit => 0}, {}, 403, 'hidden_field'],
        [{%$query, filters => [{field => 'children.secret', op => 'eq', value => 'secret'}]}, {}, 403, 'hidden_field'],
        [{%$query, order_by => [{field => 'children.secret', direction => 'asc'}]}, {}, 403, 'hidden_field'],
        [{%$query, select => ['id', ['children.secret']]}, {engine => $unscoped}, 403, 'missing_tenant_scope'],
        [$query, {header => header({%$context, revision => 'old'})}, 409, 'stale_nested_detail_context'],
        [$query, {fingerprint => 'old', header => 'bad'}, 409, 'stale_domain_fingerprint'],
        [$query, {header => 'padding='}, 400, 'malformed_request'],
        [$query, {header => header({%$context, extra => 1})}, 400, 'malformed_request'],
        [$query, {type => 'text/plain', raw => '{'}, 415, 'unsupported_media_type'],
        [$query, {raw => '{"x":1,"\\u0078":2}'}, 400, 'malformed_request'],
        [$query, {raw => "\xEF\xBB\xBF{}"}, 400, 'malformed_request'],
        [$query, {raw => "\xFF"}, 400, 'malformed_request'],
        [$query, {raw => '{"x":"\\ud800"}'}, 400, 'malformed_request'],
        [{%$query, select => [{field => 'id', alias => 'secret'}, ['children.id']]}, {}, 422, 'invalid_query'],
        [{%$query, limit => undef}, {}, 422, 'invalid_query'],
        [{%$query, row_format => undef}, {}, 422, 'invalid_query'],
        [{%$query, filters => [{field => 'id', op => 'eq', value => 1.5}]}, {}, 422, 'invalid_query'],
        [{%$query, filters => [{field => 'id', op => 'eq', value => '9223372036854775808'}]}, {}, 422, 'invalid_query'],
    ) {
        my $budget_calls = 0;
        my $budget_method = ref($adapter) . '::begin_query_budget';
        my $original_budget = $adapter->can('begin_query_budget');
        {
            no strict 'refs'; no warnings 'redefine';
            local *{$budget_method} = sub { $budget_calls++; $original_budget->(@_) };
            $r = $call->($case->[0], %{$case->[1]});
        }
        is $budget_calls, 0, 'pre-execution refusal does not open a query budget';
        is "$r->[0] $r->[1]{error}{code}", "$case->[2] $case->[3]", 'ordered fail-closed refusal';
        is_deeply $r->[1]{error}{details}, {}, 'no trusted diagnostic details';
    }
    for my $p (1000 .. 1025) {
        $dbh->do('INSERT INTO selecto_cert_nd_parents VALUES (?,7,?,1,?)', undef, $p, "Parent $p", 'secret');
        for my $c (1 .. ($p == 1025 ? 21 : 20)) {
            $dbh->do('INSERT INTO selecto_cert_nd_children VALUES (?,7,?,?,1,1,?)', undef,
                $p * 100 + $c, $p, "Child $c", 'secret');
        }
    }
    my $many = {select => ['id', ['children.id']], filters => [{field => 'id', op => 'gte', value => '1000'}]};
    $r = $call->($many);
    is $r->[0], 200, '500 returned children fit with an oversized next parent';
    is scalar(@{$r->[1]{data}{rows}}), 25, 'full parent page';
    is scalar(map { @{$_->[1]} } @{$r->[1]{data}{rows}}), 500, 'exact total child cap';
    ok $r->[1]{data}{page}{has_more}, '26th parent exists';
    $dbh->do('UPDATE selecto_cert_nd_children SET name=? WHERE parent_id IN (1000,1001)', undef, 'x' x 8000);
    $r = $call->({%$many, select => ['id', ['children.id','children.name']]});
    is $r->[0], 422, 'whole encoded response is bounded even when individual scalars fit';
    $dbh->do('UPDATE selecto_cert_nd_children SET name=? WHERE parent_id=1 AND tenant_id=7', undef, 'x' x 17000);
    $r = $call->($query);
    is $r->[0], 422, 'oversized child scalar refuses';
    if ($backend eq 'sqlite') {
        $dbh->do('UPDATE selecto_cert_nd_children SET name=? WHERE parent_id=1 AND tenant_id=7', undef, 'x' x 12000);
        # Each source row fits SQLite's limit, but the combined JSON would not.
        # A post-aggregation check would fail inside SQLite (500). The selected
        # preaggregation guard returns its bounded marker and a 422 instead.
        require DBD::SQLite::Constants;
        my $old = $dbh->sqlite_limit(DBD::SQLite::Constants::SQLITE_LIMIT_LENGTH(), 18000);
        $r = $call->($query);
        is $r->[0], 422, 'oversized JSON aggregation is skipped before SQLite materializes it';
        $dbh->sqlite_limit(DBD::SQLite::Constants::SQLITE_LIMIT_LENGTH(), $old);
    }
    # Ordinary v1 remains independently selected by the absence of the header.
    $r = $host->request($engine, {method => 'POST', path => '/nd/query', content_type => 'application/json',
        body => {format => 'selecto.remote-query', format_version => 1,
            domain => {fingerprint => $domain->fingerprint}, query => {select => ['id',['children.id']]}}});
    is $r->{status}, 501, 'ordinary v1 still refuses nested intent';
    # Exercise every promised scalar kind at both levels through real adapters.
    my $typed = $json->decode($json->encode($d));
    for my $role ('source', 'children') {
        my $rel = $role eq 'source' ? $typed->{source} : $typed->{schemas}{children};
        my $table = $rel->{source_table};
        for my $spec (['serial','integer','BIGINT'], ['enabled','boolean','BOOLEAN'], ['due','date','DATE'], ['note','string','TEXT']) {
            my ($name,$type,$sql) = @$spec;
            $dbh->do("ALTER TABLE $table ADD COLUMN $name $sql");
            push @{$rel->{fields}}, $name;
            $rel->{columns}{$name} = {type => $type, nullable => $name eq 'note' ? JSON::PP::true : JSON::PP::false,
                ($name eq 'serial' ? (encoding => 'decimal-string') : ())};
        }
        $dbh->do("UPDATE $table SET serial=?,enabled=?,due=?,note=NULL", undef, '9007199254740993', 1, '2026-11-14');
    }
    my $typed_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($typed, strict => 1),
        adapter => $adapter, scope => {tenant => 7});
    my $typed_host = Selecto::API::NestedDetail->new(base_path => '/typed', id => 'typed', publication => 'typed:1', collection => 'children');
    my $f = $typed_host->features($typed_engine);
    my $q = {select => ['id','serial','enabled','due','note',['children.id','children.serial','children.enabled','children.due','children.note']],
        filters => [{field => 'id',op => 'eq',value => '1'}, {field => 'enabled',op => 'eq',value => JSON::PP::true}]};
    $r = $typed_host->request($typed_engine, {method => 'POST', path => '/typed/query', content_type => 'application/json',
        raw_body => $json->encode({format => 'selecto.remote-query', format_version => 1,
            domain => {fingerprint => $f->{domain}{fingerprint}}, query => $q}),
        headers => {'Selecto-Nested-Detail-Context' => header($typed_host->context($f))}});
    is $r->{status}, 200, 'all scalar kinds execute on both levels';
    is_deeply $json->decode($r->{body})->{data}{rows},
        [[1,'9007199254740993',JSON::PP::true,'2026-11-14',undef,
            [[11,'9007199254740993',JSON::PP::true,'2026-11-14',undef], [12,'9007199254740993',JSON::PP::true,'2026-11-14',undef]]]],
        'int64 strings, booleans, dates and nullable values retain their codecs';
    my $bad_decimal = eval { Selecto::API::NestedDetail::_output_scalar('1.0000001', {type => 'decimal', nullable => 0}); 1 };
    ok !$bad_decimal, 'decimal precision is refused instead of rounded';
    $dbh->disconnect;
}
subtest 'SQLite complete typed nested contract' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    exercise('sqlite', DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, sqlite_unicode => 1}));
};
subtest 'PostgreSQL complete typed nested contract' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL not configured' unless $url;
    my $u = Mojo::URL->new($url);
    my $db = $u->path->to_string; $db =~ s{^/}{};
    exercise('postgresql', DBI->connect('dbi:Pg:dbname=' . $db . ';host=' . $u->host . ';port=' . $u->port,
        $u->username, $u->password, {RaiseError => 1, PrintError => 0, pg_enable_utf8 => 1}));
};
done_testing;
