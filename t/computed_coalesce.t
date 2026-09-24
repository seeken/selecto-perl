use 5.034;
use strict;
use warnings;

use Test::More;
use Storable qw(dclone);
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

my $contract = {
    schema_version => 1, name => 'Quotes',
    source => {
        source_table => 'quote', primary_key => 'id',
        fields => [qw(id cust_id cust_name customer_display_name)],
        columns => {
            id => {type => 'integer'}, cust_id => {type => 'integer'},
            cust_name => {type => 'string'},
            customer_display_name => {
                type => 'string',
                computed => {kind => 'coalesce_fields',
                    fields => ['customer.co_name', 'cust_name']},
            },
        },
        associations => {
            customer => {queryable => 'client', owner_key => 'cust_id', related_key => 'id'},
        },
    },
    schemas => {
        client => {
            source_table => 'client_profile', primary_key => 'id',
            fields => [qw(id co_name)],
            columns => {id => {type => 'integer'}, co_name => {type => 'string'}},
            associations => {},
        },
    },
    joins => {customer => {type => 'left'}},
};

my $domain = Selecto::Domain->parse($contract, strict => 1);
my $engine = Selecto::Engine->new(
    domain => $domain,
    adapter => Selecto::PostgreSQL->new(dbh => bless({}, 'Test::ComputedCoalesceDBH')),
);
my $statement = $engine->compile($engine->query
    ->select('id', 'customer_display_name')
    ->where(Selecto::Expression->starts_with_ci('customer_display_name', 'aC%')));
like $statement->sql, qr/SELECT.*COALESCE\("j_customer"\."co_name", "s0"\."cust_name"\)/s,
    'display reads the joined customer name before the quote fallback';
like $statement->sql, qr/LEFT JOIN "client_profile" AS "j_customer"/s,
    'computed field requests the governed customer join';
like $statement->sql,
    qr/LOWER\(COALESCE\("j_customer"\."co_name", "s0"\."cust_name"\)\) LIKE LOWER\(\$1\)/,
    'filter applies to the same effective customer name';
is_deeply $statement->params, ['aC!%%'], 'case-insensitive prefix remains bound and escaped';

my $many = dclone($contract);
$many->{source}{associations}{customer}{cardinality} = 'many';
my $ok = eval { Selecto::Domain->parse($many, strict => 1); 1 };
ok !$ok, 'many-valued joins cannot masquerade as a scalar coalesced field';

my $wrong_type = dclone($contract);
$wrong_type->{source}{columns}{customer_display_name}{type} = 'integer';
$ok = eval { Selecto::Domain->parse($wrong_type, strict => 1); 1 };
ok !$ok, 'coalesced fields must share the declared type';

done_testing;
