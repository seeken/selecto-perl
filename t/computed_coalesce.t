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
    schema_version => 1, name => 'Orders',
    source => {
        source_table => 'orders', primary_key => 'id',
        fields => [qw(id billto_party_id billto_name billto_display_name)],
        columns => {
            id => {type => 'integer'}, billto_party_id => {type => 'integer'},
            billto_name => {type => 'string'},
            billto_display_name => {
                type => 'string',
                computed => {kind => 'coalesce_fields',
                    fields => ['billto.party_name', 'billto_name']},
            },
        },
        associations => {
            billto => {queryable => 'parties', owner_key => 'billto_party_id', related_key => 'id'},
        },
    },
    schemas => {
        parties => {
            source_table => 'parties', primary_key => 'id',
            fields => [qw(id party_name)],
            columns => {id => {type => 'integer'}, party_name => {type => 'string'}},
            associations => {},
        },
    },
    joins => {billto => {type => 'left'}},
};

my $domain = Selecto::Domain->parse($contract, strict => 1);
my $engine = Selecto::Engine->new(
    domain => $domain,
    adapter => Selecto::PostgreSQL->new(dbh => bless({}, 'Test::ComputedCoalesceDBH')),
);
my $statement = $engine->compile($engine->query
    ->select('id', 'billto_display_name')
    ->where(Selecto::Expression->starts_with_ci('billto_display_name', 'aC%')));
like $statement->sql, qr/SELECT.*COALESCE\("j_billto"\."party_name", "s0"\."billto_name"\)/s,
    'display reads the joined billto name before the order fallback';
like $statement->sql, qr/LEFT JOIN "parties" AS "j_billto"/s,
    'computed field requests the governed billto join';
like $statement->sql,
    qr/LOWER\(COALESCE\("j_billto"\."party_name", "s0"\."billto_name"\)\) LIKE LOWER\(\$1\)/,
    'filter applies to the same effective billto name';
is_deeply $statement->params, ['aC!%%'], 'case-insensitive prefix remains bound and escaped';

my $many = dclone($contract);
$many->{source}{associations}{billto}{cardinality} = 'many';
my $ok = eval { Selecto::Domain->parse($many, strict => 1); 1 };
ok !$ok, 'many-valued joins cannot masquerade as a scalar coalesced field';

my $wrong_type = dclone($contract);
$wrong_type->{source}{columns}{billto_display_name}{type} = 'integer';
$ok = eval { Selecto::Domain->parse($wrong_type, strict => 1); 1 };
ok !$ok, 'coalesced fields must share the declared type';

done_testing;
