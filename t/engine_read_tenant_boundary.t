use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::BoundedQuery ();
use Selecto::CannedPage ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Limits ();
use Selecto::Query ();

# Lesson 43: a trusted engine tenant limits every read, not only the public
# route. Every direct Engine read path (all, compile, stream, projection
# sums, export scalars, bounded results, canned pages, retargets, related
# collections, query members, inline sources, laterals, lateral lookups,
# query library segments and engine copies) binds the root of a tenant_field
# domain to the engine tenant, intersected with any required predicate:
# one agreeing or wider (tenant_id IN (7, 8)) returns only tenant 7's rows,
# and one that disagrees (tenant_id = 8, by required_filters, a required
# predicate or require_tenant_filter) is refused with tenant_mismatch.

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

my $x = 'Selecto::Expression';

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
sub column { [sort { $a <=> $b } map { $_->[0] } @{$_[0]}] }

sub contract {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Orders',
        source => {%{relation($t->{orders}, id => 'integer', tenant_id => 'integer', total => 'integer', customer_id => 'integer')},
            tenant_field => 'tenant_id', associations => {
                customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id'},
                ($o{lookup} ? (lookup => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id',
                    join_strategy => 'lateral_lookup'}) : ()),
                lines => {queryable => 'line', owner_key => 'id', related_key => 'order_id', cardinality => 'many'},
            }},
        schemas => {
            customer => {%{relation($t->{customers}, id => 'integer', tenant_id => 'integer', name => 'string')}, tenant_field => 'tenant_id'},
            line => {%{relation($t->{lines}, id => 'integer', order_id => 'integer', tenant_id => 'integer', qty => 'integer')},
                tenant_field => 'tenant_id'},
        },
        joins => {customer => {type => 'left'}, lines => {type => 'left'}, ($o{lookup} ? (lookup => {type => 'left'}) : ())},
        query_members => {ctes => {line_qty => {source => 'line', query => {select => ['order_id', 'qty']},
            join => {owner_key => 'id', related_key => 'order_id'}}}},
        query_library => {segments => {tenant8 => {filters => [['eq', 'tenant_id', 8]]}}},
        ($o{required} ? (required_filters => $o{required}) : ())};
}

my $handler = Selecto::API::EngineHandler->new;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "every Engine read honours the engine tenant on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l43_${_}_$suffix") } qw(orders customers lines);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, total integer, customer_id integer)");
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, name text)");
        $dbh->do("CREATE TABLE $t{lines} (id integer primary key, order_id integer, tenant_id integer, qty integer)");
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 10, 1), (2, 8, 999, 2), (3, 7, 20, 1)");
        $dbh->do("INSERT INTO $t{customers} VALUES (1, 7, 'c7'), (2, 8, 'c8 secret')");
        # Line 3 hangs off tenant 7's order 1 but belongs to tenant 8.
        $dbh->do("INSERT INTO $t{lines} VALUES (1, 1, 7, 5), (2, 2, 8, 500), (3, 1, 8, 600)");
        my $pg = $name eq 'postgresql';
        my $lines_domain = Selecto::Domain->parse({schema_version => 1, name => 'Lines',
            source => {%{relation($t{lines}, id => 'integer', order_id => 'integer', tenant_id => 'integer', qty => 'integer')},
                tenant_field => 'tenant_id'}, schemas => {}, joins => {}});

        # Each read path returns the root ids (or values) it saw.
        my %paths = (
            'all' => sub { column($_[0]->all($_[0]->query->select('id'))->{rows}) },
            'compile' => sub { column($adapter->execute_query($_[0]->compile($_[0]->query->select('id')))->{rows}) },
            'stream' => sub {
                my $stream = $_[0]->stream($_[0]->query->select('id'));
                my @rows; while (my $row = $stream->next) { push @rows, $row } column(\@rows) },
            'bounded all' => sub { column(Selecto::BoundedQuery->all($_[0], $_[0]->query->select('id')->order_by('id'), max_rows => 100)->{rows}) },
            'canned page' => sub {
                my ($e) = @_;
                my $page = Selecto::CannedPage->new(id => 'orders', domain => $e->domain,
                    dataset => {query => $e->query, entity_key => ['id']},
                    views => [{id => 'list', kind => 'detail', query => $e->query->select('id', 'total')}], controls => []);
                column($page->run($e, {})->{rows}) },
            'public query handler' => sub { column($handler->query($_[0], {select => ['id']})->{rows}) },
            'joined field' => sub { [sort map { $_->[0] // 'null' } @{$_[0]->all($_[0]->query->select('customer.name'))->{rows}}] },
            'filter on joined field' => sub { column($_[0]->all($_[0]->query->select('id')->where($x->eq('customer.name', 'c8 secret')))->{rows}) },
            'retarget to a joined relation' => sub { column($_[0]->all($_[0]->query->retarget('lines')->select('id'))->{rows}) },
            'retarget (exists)' => sub { column($_[0]->all($_[0]->query->retarget('customer', strategy => 'exists')->select('id'))->{rows}) },
            'related collection' => sub {
                my $rows = $_[0]->all($_[0]->query->select('id', $x->related_collection('lines', ['id'])->as('l')))->{rows};
                [sort { $a <=> $b } map { my $c = $_->[1]; $c = JSON::PP::decode_json($c) unless ref $c; map { $_->{id} } @$c } @$rows] },
            'query member' => sub { [sort { $a <=> $b } map { $_->[1] // () }
                @{$_[0]->all($_[0]->query->with_member('line_qty')->select('id', 'line_qty.qty'))->{rows}}] },
            'inline subquery' => sub { [sort { $a <=> $b } map { $_->[1] // () } @{$_[0]->all($_[0]->query->subquery_join('sq', $lines_domain,
                Selecto::Query->new->select('order_id', 'qty'), on => [{left => 'id', right => 'order_id'}])->select('id', 'sq.qty'))->{rows}}] },
            'query library segment' => sub { column($_[0]->all($_[0]->apply_segment($_[0]->query->select('id'), 'tenant8'))->{rows}) },
            'with_limits copy' => sub { my $e = $_[0]->with_limits(Selecto::Limits->new); column($e->all($e->query->select('id'))->{rows}) },
            ($adapter->supports('projection_sum') ? ('projection sum' => sub { [$_[0]->projection_sum($_[0]->query->select('total'), 'total')] }) : ()),
            ($adapter->supports('export_scalars') ? ('export scalars' => sub { column($_[0]->all($_[0]->query->select('id'), export_scalars => 1)->{rows}) }) : ()),
            ($adapter->supports('lateral_join') ? ('lateral join' => sub { [sort { $a <=> $b } map { $_->[1] // () } @{$_[0]->all($_[0]->query->lateral_join('lj', $lines_domain,
                Selecto::Query->new->select('qty'), correlations => {order_id => 'id'})->select('id', 'lj.qty'))->{rows}}] }) : ()),
            ($pg ? ('lateral lookup' => sub { [sort map { $_->[0] // 'null' } @{$_[0]->all($_[0]->query->select('lookup.name'))->{rows}}] }) : ()),
        );
        my %expected = (
            'all' => [1, 3], 'compile' => [1, 3], 'stream' => [1, 3], 'bounded all' => [1, 3], 'canned page' => [1, 3],
            'public query handler' => [1, 3], 'joined field' => ['c7', 'c7'], 'filter on joined field' => [],
            'retarget to a joined relation' => [1], 'retarget (exists)' => [1], 'related collection' => [1],
            'query member' => [5], 'inline subquery' => [5], 'query library segment' => [], 'with_limits copy' => [1, 3],
            'projection sum' => [30], 'export scalars' => [1, 3], 'lateral join' => [5], 'lateral lookup' => ['c7', 'c7'],
        );
        my $engine = sub {
            my (%o) = @_;
            my $domain = Selecto::Domain->parse(contract(\%t, lookup => $pg, %o));
            $domain = $domain->with_required_predicate($o{predicate}) if $o{predicate};
            my $e = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7});
            $e = $e->require_tenant_filter(@{$o{filter}}) if $o{filter};
            return $e;
        };

        my %agree = (
            'no required predicate' => [],
            'required_filters tenant_id = 7' => [required => [['tenant_id', 7]]],
            'required_filters tenant_id IN (7, 8)' => [required => [['tenant_id', ['in', [7, 8]]]]],
            'required predicate tenant_id = 7' => [predicate => $x->eq('tenant_id', 7)],
            'required predicate tenant_id IN (7, 8)' => [predicate => $x->in('tenant_id', [7, 8])],
            'require_tenant_filter tenant_id = 7' => [filter => ['tenant_id', 7]],
        );
        for my $variant (sort keys %agree) {
            my $e = $engine->(@{$agree{$variant}});
            for my $path (sort keys %paths) {
                my $got;
                my $code = code_of(sub { $got = $paths{$path}->($e) });
                # A require_tenant_filter policy admits only engine-bound
                # source queries; an ad hoc inline source is refused.
                if ($variant =~ /require_tenant_filter/ && $path =~ /\A(?:inline subquery|lateral join)\z/) {
                    is($code, 'mixed_tenant_scopes', "$variant: an ad hoc $path is refused");
                    next;
                }
                is($code, 'ok', "$variant: $path reads") or next;
                is_deeply($got, $expected{$path}, "$variant: $path returns only tenant 7's rows");
            }
        }
        my %disagree = (
            'required_filters tenant_id = 8' => [required => [['tenant_id', 8]]],
            'required predicate tenant_id = 8' => [predicate => $x->eq('tenant_id', 8)],
            'require_tenant_filter tenant_id = 8' => [filter => ['tenant_id', 8]],
        );
        for my $variant (sort keys %disagree) {
            my $e = eval { $engine->(@{$disagree{$variant}}) };
            if (!$e) {
                is(blessed($@) && $@->code, 'tenant_mismatch', "$variant: refused when the engine is configured");
                next;
            }
            is(code_of(sub { $paths{$_}->($e) }), 'tenant_mismatch', "$variant: $_ is refused") for sort keys %paths;
        }

        my $open = Selecto::Engine->new(domain => Selecto::Domain->parse(contract(\%t, lookup => $pg)), adapter => $adapter);
        is_deeply($paths{all}->($open), [1, 2, 3], 'an engine without a tenant still reads every tenant');

        $dbh->do("DROP TABLE $t{$_}") for qw(orders customers lines);
    };
}

done_testing;
