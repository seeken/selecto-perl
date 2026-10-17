use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Engine ();
use Selecto::Expression ();

# Lesson 41: a join between two relations that both declare tenant_field
# pairs their tenant fields even when the association authors scope keys on
# another column (region_id -> region_id), and through associations pair them
# too. Before, the authored pair replaced the tenant pair, so a tenant 7 read
# of `select id, account.name` returned tenant 8's account sharing tenant 7's
# region, through Engine reads and the public query route alike.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub relation {
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}

sub contract {
    my ($t, %o) = @_;
    my $region = $o{no_keys} ? {} : {source_scope_key => 'region_id', target_scope_key => 'region_id'};
    my $bridge_region = $o{no_keys} ? {} : {source_scope_key => 'region_id', through_scope_key => 'region_id', target_scope_key => 'region_id'};
    return {schema_version => 1, name => 'Orders', domain_version => '1', domain_fingerprint => 'sha256:join-tenant-pairing',
        source => {%{relation($t->{orders}, id => 'integer', tenant_id => 'integer', region_id => 'integer', account_id => 'integer')},
            tenant_field => 'tenant_id', associations => {
                account => {queryable => 'account', owner_key => 'account_id', related_key => 'id', %$region,
                    ($o{lateral} ? (join_strategy => 'lateral_lookup') : ())},
                tags => {queryable => 'tag', owner_key => 'id', related_key => 'id', cardinality => 'many',
                    through => {table => $t->{order_tags}, owner_key => 'order_id', related_key => 'tag_id', %$bridge_region}},
            }},
        schemas => {
            account => {%{relation($t->{accounts}, id => 'integer', tenant_id => 'integer', region_id => 'integer', name => 'string')},
                tenant_field => 'tenant_id'},
            tag => {%{relation($t->{tags}, id => 'integer', tenant_id => 'integer', region_id => 'integer', label => 'string')},
                tenant_field => 'tenant_id'},
        },
        joins => {account => {type => 'left'}, tags => {type => 'left'}},
        ($o{required} ? (required_filters => [['tenant_id', 7]]) : ())};
}

my $handler = Selecto::API::EngineHandler->new;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "joins pair tenant fields on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l41_${_}_$suffix") } qw(orders accounts order_tags tags);
        # Account and tag ids repeat per tenant; tenant 8's rows share
        # tenant 7's region 1.
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, region_id integer, account_id integer)");
        $dbh->do("CREATE TABLE $t{accounts} (row_id integer primary key, id integer, tenant_id integer, region_id integer, name text)");
        $dbh->do("CREATE TABLE $t{order_tags} (row_id integer primary key, order_id integer, tag_id integer, region_id integer)");
        $dbh->do("CREATE TABLE $t{tags} (row_id integer primary key, id integer, tenant_id integer, region_id integer, label text)");
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 1, 1), (2, 8, 1, 1)");
        $dbh->do("INSERT INTO $t{accounts} VALUES (1, 1, 7, 1, 'tenant-7 name'), (2, 1, 8, 1, 'tenant-8 secret')");
        $dbh->do("INSERT INTO $t{order_tags} VALUES (1, 1, 5, 1), (2, 2, 5, 1)");
        $dbh->do("INSERT INTO $t{tags} VALUES (1, 5, 7, 1, 'tag-7'), (2, 5, 8, 1, 'tag-8 secret')");
        my $adapter = Selecto->adapter(($name eq 'sqlite' ? 'sqlite' : 'postgresql') => (dbh => $dbh));

        my @variants = (['region scope keys'], ['no scope keys', no_keys => 1],
            ($name eq 'postgresql' ? (['region scope keys, lateral lookup', lateral => 1]) : ()));
        for my $variant (@variants) {
            my ($label, @options) = @$variant;
            for my $boundary (['engine tenant'], ['required predicate only', required => 1]) {
                my ($boundary_label, @root) = @$boundary;
                my $domain = Selecto::Domain->parse(contract(\%t, @options, @root));
                my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter,
                    (@root ? () : (scope => {tenant => 7})));
                my $case = "$label, $boundary_label";
                is_deeply($engine->all($engine->query->select('id', 'account.name')->order_by('id'))->{rows},
                    [[1, 'tenant-7 name']], "$case: a direct join returns only tenant 7's account");
                is_deeply($engine->all($engine->query->select('id', 'tags.label')->order_by('id'))->{rows},
                    [[1, 'tag-7']], "$case: a through join returns only tenant 7's tag");
                is_deeply($engine->all($engine->query->select('id')
                    ->where(Selecto::Expression->eq('account.name', 'tenant-8 secret')))->{rows},
                    [], "$case: another tenant's joined value is not a filter oracle");
                is_deeply($handler->query($engine, {select => ['id', 'account.name']})->{rows},
                    [[1, 'tenant-7 name']], "$case: the public query handler returns only tenant 7's account");
                is_deeply($handler->query($engine, {select => ['id', 'tags.label']})->{rows},
                    [[1, 'tag-7']], "$case: the public query handler returns only tenant 7's tag");
                my $api = Selecto::API->new(domain => $domain, base_path => '/api');
                my $response = $api->request({method => 'POST', path => '/api/query', body => {select => ['id', 'account.name']}},
                    {query => sub { ['ok', $handler->query($engine, $_[0])] }});
                is($response->{status}, 200, "$case: the API route answers");
                unlike($response->{body}, qr/tenant-8/, "$case: the API route never returns tenant 8's account");
            }
        }

        my $unpairable = contract(\%t);
        $unpairable->{schemas}{account}{tenant_field} = 'owner_tenant';
        is(code_of(sub { Selecto::Domain->parse($unpairable) }), 'invalid_domain',
            'a tenant field the target relation does not have is refused');

        $dbh->do("DROP TABLE $t{$_}") for qw(orders accounts order_tags tags);
    };
}

done_testing;
