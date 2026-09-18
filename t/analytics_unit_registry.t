use 5.034;
use strict;
use warnings;

use Test::More;
use Scalar::Util qw(blessed);
use Selecto::Analytics::UnitRegistry ();
use Selecto::Analytics::TransformRegistry ();
use Selecto::Domain ();

my $registry = 'Selecto::Analytics::UnitRegistry';

is_deeply(
    $registry->normalize_unit({kind => 'Currency', code => 'usd'}),
    {kind => 'currency', code => 'USD'},
    'currency units are normalized',
);
is_deeply(
    $registry->normalize_unit({kind => 'percentage'}),
    {kind => 'percentage', scale => 'fraction'},
    'percentage units receive an explicit storage scale',
);
is_deeply(
    $registry->column_unit({type => 'decimal'}),
    {kind => 'scalar'},
    'unannotated numeric columns infer a scalar unit',
);
is $registry->column_unit({type => 'string'}), undef,
    'non-numeric columns do not infer a quantitative unit';

is_deeply(
    $registry->aggregate_unit({kind => 'currency', code => 'USD'}, 'sum'),
    {kind => 'currency', code => 'USD'},
    'sum preserves its source unit',
);
is_deeply(
    $registry->aggregate_unit({kind => 'currency', code => 'USD'}, 'count_distinct'),
    {kind => 'count'},
    'count aggregates produce a count unit',
);
ok $registry->compatible(
    {kind => 'currency', code => 'USD'}, {kind => 'currency', code => 'usd'},
), 'normalized matching units are axis-compatible';
ok !$registry->compatible(
    {kind => 'currency', code => 'USD'}, {kind => 'currency', code => 'CAD'},
), 'different currency units are not silently compatible';

my $transforms = 'Selecto::Analytics::TransformRegistry';
ok $transforms->allows(
    'moving_average', {kind => 'currency', code => 'USD'}, 'flow',
), 'moving averages are derived from quantitative unit metadata';
ok $transforms->allows(
    'cumulative', {kind => 'distance', code => 'mile'}, 'flow',
), 'flow behavior enables cumulative transforms';
ok !$transforms->allows(
    'cumulative', {kind => 'currency', code => 'USD'}, 'stock',
), 'stock behavior prevents misleading cumulative transforms';
ok !$transforms->allows(
    'percentage_point_change', {kind => 'currency', code => 'USD'}, 'flow',
), 'percentage-point change is restricted by unit kind';
is_deeply $transforms->result_unit(
    'percent_change', {kind => 'currency', code => 'USD'}, 'flow',
), {kind => 'percentage', scale => 'whole'},
    'percent change derives a percentage result unit';
is_deeply $transforms->result_unit(
    'moving_average', {kind => 'currency', code => 'USD'}, 'flow',
), {kind => 'currency', code => 'USD'},
    'moving averages preserve their input unit';
my %currency_transforms = map { $_->{id} => $_ }
    @{$transforms->catalog({kind => 'currency', code => 'USD'}, 'flow')};
ok $currency_transforms{moving_average}{requires_ordered_axis},
    'transform discovery tells consumers when an ordered axis is required';
is_deeply $currency_transforms{moving_average}{parameters}{window},
    {type => 'integer', minimum => 2, maximum => 365},
    'transform discovery publishes bounded typed parameters';

my $domain = Selecto::Domain->parse({
    schema_version => 1,
    name => 'Unit-bearing orders',
    source => {
        source_table => 'orders', primary_key => 'id',
        fields => [qw(id amount ratio customer_id)],
        columns => {
            id => {type => 'integer'},
            amount => {
                type => 'decimal',
                unit => {kind => 'Currency', code => 'usd'},
                behavior => 'FLOW',
            },
            ratio => {type => 'decimal', unit => {kind => 'percentage'}},
            customer_id => {type => 'integer'},
        },
        associations => {
            customer => {
                queryable => 'customers', owner_key => 'customer_id', related_key => 'id',
            },
        },
    },
    schemas => {
        customers => {
            source_table => 'customers', primary_key => 'id', fields => [qw(id credit_limit)],
            columns => {
                id => {type => 'integer'},
                credit_limit => {
                    type => 'decimal', unit => {kind => 'currency', code => 'USD'},
                    behavior => 'stock',
                },
            },
            associations => {},
        },
    },
    joins => {customer => {type => 'left'}},
}, strict => 1);

is_deeply $domain->field_unit('amount'), {kind => 'currency', code => 'USD'},
    'root field units are normalized into the canonical contract';
is $domain->field_behavior('amount'), 'flow',
    'root field analytical behavior is normalized';
is_deeply $domain->field_unit('ratio'), {kind => 'percentage', scale => 'fraction'},
    'percentage scale defaults survive domain parsing';
is_deeply $domain->field_unit('customer.credit_limit'),
    {kind => 'currency', code => 'USD'},
    'associated field units resolve through canonical metadata';
is $domain->field_behavior('customer.credit_limit'), 'stock',
    'associated field behavior resolves through canonical metadata';

for my $case (
    [{kind => 'temperature'}, qr/kind is not available/],
    [{kind => 'currency', code => 'US'}, qr/three letters/],
    [{kind => 'percentage', scale => 'points'}, qr/fraction or whole/],
    [{kind => 'count', code => 'items'}, qr/code is not valid/],
) {
    my ($unit, $message) = @$case;
    my $error;
    eval { $registry->normalize_unit($unit) };
    $error = $@;
    ok blessed($error) && $error->isa('Selecto::Error'),
        'invalid unit metadata raises a governed error';
    like $error->message, $message, 'invalid unit metadata explains the problem';
}

my $invalid_domain = $domain->contract;
$invalid_domain->{source}{columns}{amount}{unit} = {kind => 'currency', code => 'USD'};
$invalid_domain->{source}{columns}{amount}{type} = 'string';
my $error;
eval { Selecto::Domain->parse($invalid_domain, strict => 1) };
$error = $@;
ok blessed($error) && $error->isa('Selecto::Error'),
    'units on non-numeric columns are rejected';
like $error->message, qr/only for numeric columns/,
    'non-numeric unit errors identify the contract problem';

done_testing;
