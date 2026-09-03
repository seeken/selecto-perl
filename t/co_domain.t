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
            co_name => 'Acme Transport',
            cl_key => 'ACME',
            city => 'Detroit',
            state => 'MI',
            descr => 'Active',
        );
        return {
            columns => $statement->columns,
            rows => [[map { $values{$_} } @{$statement->columns}]],
        };
    }
}

my $clients = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Clients',
    source => {
        source_table => 'client_profile', primary_key => 'id',
        fields => [qw(id co_name cl_key city state status parent_id)],
        columns => {
            id => {type => 'integer', label => 'Client ID'},
            co_name => {type => 'string', label => 'Company'},
            cl_key => {type => 'string', label => 'Key'},
            city => {type => 'string', label => 'City'},
            state => {type => 'string', label => 'State'},
            status => {type => 'string'},
            parent_id => {type => 'integer'},
        },
        associations => {
            client_status => {
                queryable => 'client_status', owner_key => 'status', related_key => 'id',
            },
        },
    },
    schemas => {
        client_status => {
            source_table => 'ref_client_status', primary_key => 'id',
            fields => [qw(id descr)],
            columns => {
                id => {type => 'string'},
                descr => {type => 'string', label => 'Status'},
            },
            associations => {},
        },
    },
    joins => {client_status => {type => 'left'}},
    query_library => {
        segments => {
            carriers => {filters => [['eq', 'status', 'A']]},
        },
        projections => {
            carrier_lookup => {fields => [qw(
                id co_name cl_key city state client_status.descr
            )]},
        },
        orderings => {
            company_name => {order_by => [['co_name', 'asc'], ['id', 'asc']]},
        },
        views => {
            carrier_lookup => {
                segments => ['carriers'], projection => 'carrier_lookup',
                ordering => 'company_name',
            },
        },
    },
}, strict => 1);

my $loads = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Loads',
    source => {
        source_table => 'load', primary_key => 'id', fields => ['id'],
        columns => {id => {type => 'integer'}}, associations => {},
    },
    schemas => {}, joins => {},
    co_domains => {
        carriers => {
            domain => 'client', view => 'carrier_lookup',
            search => {
                fields => [qw(id co_name cl_key city state)],
                mode => 'prefix', rank => 1,
            },
            result => {
                value_field => 'id', label_field => 'co_name',
                description_fields => [qw(id cl_key city state client_status.descr)],
            },
        },
    },
}, strict => 1);

is_deeply [sort keys %{$loads->co_domains}], ['carriers'],
    'strict domains retain portable co-domain definitions';
is_deeply(
    Selecto::Domain->parse($loads->as_contract, strict => 1)->co_domains,
    $loads->co_domains,
    'co-domain definitions survive portable contract projection',
);

my $engine = Selecto::Engine->new(
    domain => $clients->with_required_predicate(
        Selecto::Expression->in('parent_id', [9, 11]),
    ),
    adapter => CoDomainTest::Adapter->new(dbh => bless({}, 'CoDomainTest::DBH')),
);
my $lookup = Selecto::CoDomain->lookup(
    source_domain => $loads,
    co_domain => 'carriers',
    engine => $engine,
    query => 'acme det',
    limit => 12,
    predicate => Selecto::Expression->in('id', [501, 777]),
);
is_deeply $lookup->{results}, [{
    value => '501', label => 'Acme Transport',
    description => "Client ID 501 \x{b7} Key ACME \x{b7} City Detroit \x{b7} State MI \x{b7} Status Active",
}], 'co-domain lookup maps the target projection into portable lookup results';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql,
    qr/TO_TSQUERY\('simple', \$\d+\)/,
    'prefix lookup uses the governed PostgreSQL text-search expression';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql,
    qr/TS_RANK.*DESC.*"s0"\."co_name" ASC/s,
    'search rank precedes the co-domain named ordering';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql,
    qr/"s0"\."parent_id" IN .*"s0"\."id" IN/s,
    'target tenant scope and selection-derived scope are both enforced';
is_deeply $CoDomainTest::Adapter::LAST_STATEMENT->params,
    [9, 11, 'A', 501, 777, 'acme:* & det:*', 'acme:* & det:*'],
    'all co-domain values remain bound parameters';
like $CoDomainTest::Adapter::LAST_STATEMENT->sql, qr/LIMIT 12\z/,
    'caller-controlled result bounds remain governed';

my $error;
eval {
    Selecto::CoDomain->lookup(
        source_domain => $loads, co_domain => 'unknown', engine => $engine,
        query => 'acme',
    );
};
$error = $@;
ok blessed($error) && $error->isa('Selecto::Error'),
    'an unknown co-domain fails with a typed error';
is $error->code, 'unknown_co_domain', 'unknown co-domain identifiers fail closed';

my $broken_contract = $loads->as_contract;
$broken_contract->{co_domains}{carriers}{result}{label_field} = 'secret_field';
my $broken = Selecto::Domain->parse($broken_contract, strict => 1);
eval {
    Selecto::CoDomain->lookup(
        source_domain => $broken, co_domain => 'carriers', engine => $engine,
        query => 'acme',
    );
};
$error = $@;
is $error->code, 'unknown_field',
    'target fields outside the governed co-domain fail before execution';

my $invalid_contract = $loads->as_contract;
$invalid_contract->{co_domains}{carriers}{search}{raw_sql} = '1=1';
eval { Selecto::Domain->parse($invalid_contract, strict => 1) };
$error = $@;
is $error->code, 'unknown_domain_key',
    'unknown co-domain search keys fail closed during strict parsing';

my $ambiguous_contract = $loads->as_contract;
$ambiguous_contract->{co_domains}{carriers}{projection} = 'carrier_lookup';
eval { Selecto::Domain->parse($ambiguous_contract, strict => 1) };
$error = $@;
is $error->code, 'invalid_domain',
    'co-domain query-library composition cannot be ambiguous';

done_testing;
