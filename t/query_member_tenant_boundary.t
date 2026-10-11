use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Query ();

# Lesson 39: a query member reads its own relation, so the root's trusted
# tenant boundary never reaches it through a join. Every member over a
# tenant-scoped relation (declared CTE, recursive CTE, subquery and lateral
# members, and the same sources built inline with with_cte,
# with_recursive_cte, subquery_join and lateral_join) must carry that
# boundary, whether it is the engine tenant or only the root's required
# predicate, or be refused with missing_tenant_scope. Before, inline sources
# and members under a root without a tenant field of its own read every
# tenant's rows: a tenant 7 read summed tenant 8's orders.

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

my $E = 'Selecto::Expression';

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

my %members = (
    ctes => {
        order_totals => {source => 'order',
            query => {select => ['customer_id', {as => 'spent', aggregate => 'sum', field => 'total'}], group_by => ['customer_id']},
            join => {owner_key => 'id', related_key => 'customer_id', type => 'left'}},
        order_tree => {kind => 'recursive', source => 'order',
            base => {select => [qw(id customer_id total parent_id)], filter => ['is_null', 'parent_id']},
            step => {select => [qw(id customer_id total parent_id)]},
            step_join => {owner_key => 'parent_id', related_key => 'id'},
            join => {owner_key => 'id', related_key => 'customer_id', type => 'inner'}},
    },
    subqueries => {order_sub => {source => 'order',
        query => {select => ['customer_id', {as => 'spent', aggregate => 'sum', field => 'total'}], group_by => ['customer_id']},
        on => [{left => 'id', right => 'customer_id'}], type => 'left'}},
    laterals => {order_sum => {source => 'order',
        query => {select => [{as => 'spent', aggregate => 'sum', field => 'total'}]},
        correlations => {customer_id => 'id'}, join_type => 'left'}},
);

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "query members carry the root tenant boundary on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l39_${_}_$suffix") } qw(customers orders regions);
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, name text, tenant_id integer)");
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, customer_id integer, region_id integer, total integer, tenant_id integer, parent_id integer)");
        $dbh->do("CREATE TABLE $t{regions} (id integer primary key, name text)");
        $dbh->do("INSERT INTO $t{customers} VALUES (1, 'Seven', 7), (2, 'Eight', 8)");
        # Order 3 is tenant 8's, filed against tenant 7's customer 1.
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 1, 1, 10, 7, NULL), (2, 1, 1, 5, 7, 1), (3, 1, 1, 1000, 8, NULL), (4, 2, 1, 500, 8, 3)");
        $dbh->do("INSERT INTO $t{regions} VALUES (1, 'North')");
        my $adapter = Selecto->adapter(($name eq 'sqlite' ? 'sqlite' : 'postgresql') => (dbh => $dbh));
        my $laterals = $adapter->supports('lateral_join');

        my $orders = {%{relation($t{orders}, id => 'integer', customer_id => 'integer', region_id => 'integer',
            total => 'integer', tenant_id => 'integer', parent_id => 'integer')}, tenant_field => 'tenant_id'};
        my $contract = sub {
            my (%o) = @_;
            my $root = $o{global}
                ? {%{relation($t{regions}, id => 'integer', name => 'string')},
                    associations => {orders => {queryable => 'order', owner_key => 'id', related_key => 'region_id'}}}
                : {%{relation($t{customers}, id => 'integer', name => 'string', tenant_id => 'integer')}, tenant_field => 'tenant_id'};
            return {schema_version => 1, name => 'Root', source => $root, schemas => {order => $orders},
                joins => ($o{global} ? {orders => {type => 'left'}} : {}),
                ($o{members} ? (query_members => \%members) : ()),
                ($o{required} ? (required_filters => $o{required}) : ())};
        };
        my $parse = sub { Selecto::Domain->parse($contract->(@_)) };
        my $orders_domain = Selecto::Domain->parse({schema_version => 1, name => 'Orders', source => $orders, schemas => {}, joins => {}});
        my $rows = sub { my ($engine, $query) = @_; return $engine->all($query)->{rows} };
        my $sum_child = sub { Selecto::Query->new->select('customer_id', $E->sum('total')->as('spent'))->group_by('customer_id') };
        my $inline = {
            cte => sub { $_[0]->with_cte('t', $orders_domain, $sum_child->(),
                join => {owner_key => 'id', related_key => 'customer_id', type => 'left'}) },
            subquery => sub { $_[0]->subquery_join('t', $orders_domain, $sum_child->(), on => [{left => 'id', right => 'customer_id'}]) },
            lateral => sub { $_[0]->lateral_join('t', $orders_domain, Selecto::Query->new->select($E->sum('total')->as('spent')),
                correlations => {customer_id => 'id'}) },
        };
        my @kinds = ('cte', 'subquery', ($laterals ? 'lateral' : ()));
        my %declared = (cte => 'order_totals', subquery => 'order_sub', lateral => 'order_sum');
        my $tree = sub {
            my ($query) = @_;
            my $step = Selecto::Query->new->select(qw(id customer_id total parent_id));
            return $query->with_recursive_cte('t', $orders_domain, $step->where($E->is_null('parent_id')), $step,
                join => {owner_key => 'id', related_key => 'customer_id', type => 'inner'},
                recursive_join => {owner_key => 'parent_id', related_key => 'id', type => 'inner'}, max_depth => 5);
        };

        my %roots = (
            'engine tenant' => sub { Selecto::Engine->new(domain => $parse->(@_), adapter => $adapter, scope => {tenant => 7}) },
            'required_filters only' => sub { Selecto::Engine->new(domain => $parse->(@_, required => [['tenant_id', 7]]), adapter => $adapter) },
            'required predicate only' => sub {
                Selecto::Engine->new(domain => $parse->(@_)->with_required_predicate($E->eq('tenant_id', 7)), adapter => $adapter) },
        );
        for my $boundary (sort keys %roots) {
            my $engine = $roots{$boundary}->(members => 1);
            for my $kind (@kinds) {
                my $member = $declared{$kind};
                is_deeply($rows->($engine, $engine->query->with_member($member)->select('id', "$member.spent")->order_by('id')),
                    [[1, 15]], "$boundary: declared $kind member sums only tenant 7's orders");
                is_deeply($rows->($engine, $inline->{$kind}->($engine->query)->select('id', 't.spent')->order_by('id')),
                    [[1, 15]], "$boundary: inline $kind sums only tenant 7's orders");
            }
            is_deeply($rows->($engine, $engine->query->with_member('order_tree')->select('order_tree.total')->order_by('order_tree.total')),
                [[5], [10]], "$boundary: declared recursive member walks only tenant 7's orders");
            is_deeply($rows->($engine, $tree->($engine->query)->select('t.total')->order_by('t.total')),
                [[5], [10]], "$boundary: inline recursive CTE walks only tenant 7's orders");
            is_deeply($rows->($engine, $engine->query->select('id')->union($engine->query->select('id'))->order_by('id')),
                [[1]], "$boundary: set operands keep the root boundary");
        }

        # A child configured by an engine holding the same trusted tenant is
        # already bounded and still composes (no duplicated condition).
        my $scoped = Selecto::Engine->new(domain => $parse->(), adapter => $adapter, scope => {tenant => 7});
        my $owner = Selecto::Engine->new(domain => $orders_domain, adapter => $adapter, scope => {tenant => 7});
        my $owned = $owner->query->select('customer_id', $E->sum('total')->as('spent'))->group_by('customer_id');
        my $composed = $scoped->query->with_cte('t', $orders_domain, $owned,
            join => {owner_key => 'id', related_key => 'customer_id', type => 'left'})->select('id', 't.spent');
        is_deeply($rows->($scoped, $composed), [[1, 15]], 'a same-tenant configured child still composes');
        is(scalar(() = $scoped->compile($composed)->sql =~ /"tenant_id" = /g), 2,
            'the child and the root each bind the tenant once');

        # A root relation without a tenant field of its own: the trusted
        # engine tenant still bounds every tenant-scoped member.
        my $global = Selecto::Engine->new(domain => $parse->(global => 1, members => 1), adapter => $adapter, scope => {tenant => 7});
        my $by_region = sub {
            Selecto::Query->new->select('region_id', $E->sum('total')->as('spent'))->group_by('region_id') };
        is_deeply($rows->($global, $global->query->with_cte('t', $orders_domain, $by_region->(),
            join => {owner_key => 'id', related_key => 'region_id', type => 'left'})->select('id', 't.spent')),
            [[1, 15]], 'global root under an engine tenant: inline CTE sums only tenant 7');
        is_deeply($rows->($global, $global->query->subquery_join('t', $orders_domain, $by_region->(),
            on => [{left => 'id', right => 'region_id'}])->select('id', 't.spent')),
            [[1, 15]], 'global root under an engine tenant: inline subquery sums only tenant 7');
        is_deeply($rows->($global, $global->query->with_member('order_tree')->select('order_tree.total')->order_by('order_tree.total')),
            [[5], [10]], 'global root under an engine tenant: declared member walks only tenant 7');
        is_deeply($rows->($global, $global->query->retarget('orders')->select($E->sum('total')->as('spent'))),
            [[15]], 'global root under an engine tenant: a retargeted read sums only tenant 7');

        # A scoped root whose boundary cannot be carried fails closed.
        is(code_of(sub { Selecto::Engine->new(domain => $parse->(members => 1, required => [['name', 'Seven']]), adapter => $adapter) }),
            'missing_tenant_scope', 'declared members under a root predicate without a tenant condition are refused');
        for my $case (
            ['a root predicate without a tenant condition', $parse->(required => [['name', 'Seven']])],
            ['a global root bounded by a predicate', $parse->(global => 1, required => [['id', 1]])],
        ) {
            my ($label, $domain) = @$case;
            my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
            for my $kind (@kinds) {
                my $query = $inline->{$kind}->($engine->query)->select('id', 't.spent');
                is(code_of(sub { $engine->all($query) }), 'missing_tenant_scope', "$label: inline $kind is refused");
            }
            is(code_of(sub { $engine->all($tree->($engine->query)->select('t.total')) }), 'missing_tenant_scope',
                "$label: inline recursive CTE is refused");
        }

        # A root with no boundary at all keeps reading every tenant.
        my $open = Selecto::Engine->new(domain => $parse->(global => 1), adapter => $adapter);
        is_deeply($rows->($open, $open->query->with_cte('t', $orders_domain, $by_region->(),
            join => {owner_key => 'id', related_key => 'region_id', type => 'left'})->select('id', 't.spent')),
            [[1, 1515]], 'an unscoped root is unchanged');

        $dbh->do("DROP TABLE $t{$_}") for qw(orders customers regions);
    };
}

done_testing;
