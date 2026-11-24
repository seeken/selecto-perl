use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto::CoDomain ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

{
    package CoDomainTest::DBH;
    sub ping { 1 }
}

{
    package CoDomainTest::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;

    our $LAST_STATEMENT;

    sub execute_query ($self, $statement) {
        $LAST_STATEMENT = $statement;
        my %values = (
            id => 501,
            party_name => 'North Yard Supplies',
            site_code => 'NORTH',
            city => 'Arc',
            region => 'CO',
            'party_state.label' => 'Active',
        );
        return {
            columns => $statement->columns,
            rows => [[map { $values{$_} } @{$statement->columns}]],
        };
    }
}

my $parties = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Parties',
    source => {
        source_table => 'parties', primary_key => 'id',
        fields => [qw(id party_name site_code city region state_code account_id)],
        columns => {
            id => {type => 'integer', label => 'Party ID'},
            party_name => {type => 'string', label => 'Company'},
            site_code => {type => 'string', label => 'Key'},
            city => {type => 'string', label => 'City'},
            region => {type => 'string', label => 'Region'},
            state_code => {type => 'string'},
            account_id => {type => 'integer'},
        },
        associations => {
            party_state => {
                queryable => 'party_state', owner_key => 'state_code', related_key => 'id',
            },
        },
    },
    schemas => {
        party_state => {
            source_table => 'party_states', primary_key => 'id',
            fields => [qw(id label)],
            columns => {
                id => {type => 'string'},
                label => {type => 'string', label => 'Status'},
            },
            associations => {},
        },
    },
    joins => {party_state => {type => 'left'}},
    query_library => {
        segments => {
            carriers => {filters => [['eq', 'state_code', 'active']]},
        },
        projections => {
            carrier_lookup => {fields => [qw(
                id party_name site_code city region party_state.label
            )]},
        },
        orderings => {
            company_name => {order_by => [['party_name', 'asc'], ['id', 'asc']]},
        },
        views => {
            carrier_lookup => {
                segments => ['carriers'], projection => 'carrier_lookup',
                ordering => 'company_name',
            },
        },
    },
}, strict => 1);

my $orders = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Orders',
    source => {
        source_table => 'orders', primary_key => 'id', fields => ['id'],
        columns => {id => {type => 'integer'}}, associations => {},
    },
    schemas => {}, joins => {},
    co_domains => {
        carriers => {
            domain => 'parties', view => 'carrier_lookup',
            search => {
                fields => [qw(id party_name site_code city region)],
                mode => 'prefix', rank => 1,
            },
            result => {
                value_field => 'id', label_field => 'party_name',
                description_fields => [qw(id site_code city region party_state.label)],
            },
        },
    },
}, strict => 1);

is_deeply [sort keys %{$orders->co_domains}], ['carriers'],
    'strict domains retain portable co-domain definitions';
is_deeply(
    Selecto::Domain->parse($orders->as_contract, strict => 1)->co_domains,
    $orders->co_domains,
    'co-domain definitions survive portable contract projection',
);

my $engine = Selecto::Engine->new(
    domain => $parties->with_required_predicate(
        Selecto::Expression->in('account_id', [1001, 1002]),
    ),
    adapter => CoDomainTest::Adapter->new(dbh => bless({}, 'CoDomainTest::DBH')),
);
my $lookup = Selecto::CoDomain->lookup(
    source_domain => $orders,
    co_domain => 'carriers',
    engine => $engine,
    query => 'north arc',
    limit => 12,
    predicate => Selecto::Expression->in('id', [501, 777]),
);
is_deeply $lookup->{results}, [{
    value => '501', label => 'North Yard Supplies',
    description => "Party ID 501 \x{b7} Key NORTH \x{b7} City Arc \x{b7} Region CO \x{b7} Status Active",
}], 'co-domain lookup maps the target projection into portable lookup results';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql,
    qr/TO_TSQUERY\('simple', \$\d+\)/,
    'prefix lookup uses the governed PostgreSQL text-search expression';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql,
    qr/TS_RANK.*DESC.*"s0"\."party_name" ASC/s,
    'search rank precedes the co-domain named ordering';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql,
    qr/"s0"\."account_id" IN .*"s0"\."id" IN/s,
    'target tenant scope and selection-derived scope are both enforced';
is_deeply $CoDomainTest::Adapter::LAST_STATEMENT->params,
    [1001, 1002, 'active', 501, 777, 'north:* & arc:*', 'north:* & arc:*'],
    'all co-domain values remain bound parameters';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql, qr/LIMIT 12\z/,
    'caller-controlled result bounds remain governed';

my $error;
eval {
    Selecto::CoDomain->lookup(
        source_domain => $orders, co_domain => 'unknown', engine => $engine,
        query => 'north',
    );
};
$error = $@;
ok blessed($error) && $error->isa('Selecto::Error'),
    'an unknown co-domain fails with a typed error';
is $error->code, 'unknown_co_domain', 'unknown co-domain identifiers fail closed';

my $broken_contract = $orders->as_contract;
$broken_contract->{co_domains}{carriers}{result}{label_field} = 'secret_field';
my $broken = Selecto::Domain->parse($broken_contract, strict => 1);
eval {
    Selecto::CoDomain->lookup(
        source_domain => $broken, co_domain => 'carriers', engine => $engine,
        query => 'north',
    );
};
$error = $@;
is $error->code, 'unknown_field',
    'target fields outside the governed co-domain fail before execution';

my $invalid_contract = $orders->as_contract;
$invalid_contract->{co_domains}{carriers}{search}{raw_sql} = '1=1';
eval { Selecto::Domain->parse($invalid_contract, strict => 1) };
$error = $@;
is $error->code, 'unknown_domain_key',
    'unknown co-domain search keys fail closed during strict parsing';

my $blank_configuration = $orders->as_contract;
$blank_configuration->{co_domains}{carriers}{search}{configuration} = '   ';
eval { Selecto::Domain->parse($blank_configuration, strict => 1) };
$error = $@;
is $error->code, 'invalid_domain',
    'blank co-domain search configurations fail closed during strict parsing';

my $ambiguous_contract = $orders->as_contract;
$ambiguous_contract->{co_domains}{carriers}{projection} = 'carrier_lookup';
eval { Selecto::Domain->parse($ambiguous_contract, strict => 1) };
$error = $@;
is $error->code, 'invalid_domain',
    'co-domain query-library composition cannot be ambiguous';

# A tenant_field co-domain with no tenant boundary is refused. A host lookup
# predicate or a trusted engine tenant is a boundary.
{
    my $contract = $parties->as_contract;
    $contract->{source}{tenant_field} = 'account_id';
    my $tenanted = Selecto::Domain->parse($contract, strict => 1);
    my $adapter = CoDomainTest::Adapter->new(dbh => bless({}, 'CoDomainTest::DBH'));
    my $lookup_code = sub {
        my ($engine, @extra) = @_;
        return eval {
            Selecto::CoDomain->lookup(source_domain => $orders, co_domain => 'carriers',
                engine => $engine, query => 'north', limit => 5, @extra);
            1;
        } ? 'ok' : blessed($@) ? $@->code : "died: $@";
    };
    is $lookup_code->(Selecto::Engine->new(domain => $tenanted, adapter => $adapter)),
        'missing_tenant_scope', 'an unscoped tenant_field co-domain lookup is refused';
    is $lookup_code->(Selecto::Engine->new(domain => $tenanted, adapter => $adapter),
        predicate => Selecto::Expression->eq('account_id', 1001)),
        'ok', 'a host lookup predicate on the tenant field is a tenant boundary';
    is $lookup_code->(Selecto::Engine->new(domain => $tenanted, adapter => $adapter),
        predicate => Selecto::Expression->in('id', [501, 777])),
        'missing_tenant_scope', 'a host lookup predicate on another field is not a tenant boundary';
    is $lookup_code->(Selecto::Engine->new(domain => $tenanted, adapter => $adapter, scope => {tenant => 1001})),
        'ok', 'a trusted engine tenant is a tenant boundary';
    like $CoDomainTest::Adapter::LAST_STATEMENT->sql, qr/account_id/,
        'the trusted tenant reaches the lookup SQL';
}

done_testing;
