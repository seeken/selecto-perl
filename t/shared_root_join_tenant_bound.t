use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Engine ();
use Selecto::Expression ();

# Lesson 42: under a trusted engine tenant, a read from a shared root (one
# that declares no tenant_field) binds every joined or through relation that
# declares tenant_field to the engine tenant, in the join condition so a left
# join keeps the shared row without another tenant's. Before, the boundary
# applied only to domains that themselves declare tenant_field, so a products
# root under tenant 7 returned tenant 8's orders.total through Engine reads
# and the public query route (200).

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

sub relation {
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}

sub contract {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Products', domain_version => '1',
        domain_fingerprint => 'sha256:shared-root-join-tenant-bound',
        source => {%{relation($t->{products}, id => 'integer', name => 'string')}, associations => {
            orders => {queryable => 'order', owner_key => 'id', related_key => 'product_id', cardinality => 'many',
                ($o{lateral} ? (join_strategy => 'lateral_lookup') : ())},
            tags => {queryable => 'tag', owner_key => 'id', related_key => 'id', cardinality => 'many',
                through => {table => $t->{product_tags}, owner_key => 'product_id', related_key => 'tag_id'}},
        }},
        schemas => {
            order => {%{relation($t->{orders}, id => 'integer', product_id => 'integer', tenant_id => 'integer', total => 'integer')},
                tenant_field => 'tenant_id'},
            tag => {%{relation($t->{tags}, id => 'integer', tenant_id => 'integer', label => 'string')}, tenant_field => 'tenant_id'},
        },
        joins => {orders => {type => 'left'}, tags => {type => 'left'}}};
}

my $handler = Selecto::API::EngineHandler->new;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "shared-root joins are bound to the engine tenant on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l42_${_}_$suffix") } qw(products orders product_tags tags);
        $dbh->do("CREATE TABLE $t{products} (id integer primary key, name text)");
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, product_id integer, tenant_id integer, total integer)");
        $dbh->do("CREATE TABLE $t{product_tags} (id integer primary key, product_id integer, tag_id integer)");
        $dbh->do("CREATE TABLE $t{tags} (id integer primary key, tenant_id integer, label text)");
        # Product 2 has only a tenant 8 order and tag.
        $dbh->do("INSERT INTO $t{products} VALUES (1, 'Widget'), (2, 'Gadget')");
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 1, 7, 10), (2, 1, 8, 999), (3, 2, 8, 555)");
        $dbh->do("INSERT INTO $t{product_tags} VALUES (1, 1, 1), (2, 1, 2), (3, 2, 2)");
        $dbh->do("INSERT INTO $t{tags} VALUES (1, 7, 'tag-7'), (2, 8, 'tag-8 secret')");
        my $adapter = Selecto->adapter(($name eq 'sqlite' ? 'sqlite' : 'postgresql') => (dbh => $dbh));

        for my $variant (['left join'], ($name eq 'postgresql' ? (['lateral lookup', lateral => 1]) : ())) {
            my ($label, @options) = @$variant;
            my $domain = Selecto::Domain->parse(contract(\%t, @options));
            my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7});
            is_deeply($engine->all($engine->query->select('id', 'orders.total')->order_by('id'))->{rows},
                [[1, 10], [2, undef]], "$label: only tenant 7's orders join, and the shared rows stay");
            is_deeply($engine->all($engine->query->select('id', 'tags.label')->order_by('id'))->{rows},
                [[1, 'tag-7'], [2, undef]], "$label: a through join returns only tenant 7's tags");
            is_deeply($engine->all($engine->query->select('id')->where(Selecto::Expression->eq('orders.total', 999)))->{rows},
                [], "$label: another tenant's order is not a filter oracle");
            is_deeply([sort { $a->[0] <=> $b->[0] } @{$handler->query($engine, {select => ['id', 'orders.total']})->{rows}}],
                [[1, 10], [2, undef]], "$label: the public query handler returns only tenant 7's orders");
            my $api = Selecto::API->new(domain => $domain, base_path => '/api');
            my $response = $api->request({method => 'POST', path => '/api/query', body => {select => ['id', 'orders.total', 'tags.label']}},
                {query => sub { ['ok', $handler->query($engine, $_[0])] }});
            is($response->{status}, 200, "$label: the API route answers");
            unlike($response->{body}, qr/999|555|tag-8/, "$label: the API route never returns tenant 8's rows");

            my $open = Selecto::Engine->new(domain => $domain, adapter => $adapter);
            is(scalar @{$open->all($open->query->select('id', 'orders.total'))->{rows}}, 3,
                "$label: an engine without a tenant is unchanged");
        }

        $dbh->do("DROP TABLE $t{$_}") for qw(products orders product_tags tags);
    };
}

done_testing;
