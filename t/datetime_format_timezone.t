use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::BoundedQuery ();
use Selecto::CannedPage ();
use Selecto::Domain ();
use Selecto::DuckDB ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Query ();

my $E = 'Selecto::Expression';

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { $_ => {type => $columns{$_}} } keys %columns},
        associations => {}};
}
my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Shipments',
    source => {
        %{relation('shipments', id => 'integer', picked_up => 'utc_datetime',
            delivered => 'date')},
        associations => {inspections => {queryable => 'inspections', owner_key => 'id',
            related_key => 'shipment_id', cardinality => 'many'}},
    },
    schemas => {inspections => relation('inspections', id => 'integer',
        shipment_id => 'integer', inspected => 'utc_datetime')},
    joins => {},
});
my $pg = Selecto::Engine->new(domain => $domain,
    adapter => Selecto::PostgreSQL->new(dbh => bless({}, 'Test::NoDBH')));
my $duckdb = Selecto::Engine->new(domain => $domain,
    adapter => Selecto::DuckDB->new(dbh => bless({}, 'Test::NoDBH')));

my $local = $E->datetime_format('picked_up', 'us_datetime', timezone => 'America/New_York');
my $statement = $pg->compile($pg->query->select('id', $local->as('pickup'))
    ->where($E->gte('picked_up', '2026-09-21T04:00:00Z')));
like $statement->sql, qr/TO_CHAR\(\("s0"\."picked_up" AT TIME ZONE \$\d+\), 'MM\/DD\/YYYY FMHH12:MI AM'\)/,
    'us_datetime shows the instant in the requested zone';
is scalar(() = $statement->sql =~ /AT TIME ZONE/g), 1,
    'the filter still compares the stored instant';
ok grep({ $_ eq 'America/New_York' } @{$statement->params}), 'the zone is bound, not interpolated';
like $pg->compile($pg->query->select($E->datetime_format('delivered', 'us_date')->as('day')))->sql,
    qr/TO_CHAR\("s0"\."delivered", 'MM\/DD\/YYYY'\)/, 'us_date formats a date';
like $duckdb->compile($duckdb->query->select($local->as('pickup')))->sql,
    qr/STRFTIME\(.+'%m\/%d\/%Y %-I:%M %p'\)/s, 'DuckDB has the same display format';

ok !eval { $E->datetime_format('picked_up', 'day', timezone => 'Mars/Olympus'); 1 },
    'an unknown zone is refused';
ok !eval { $E->datetime_format('picked_up', 'day', zone => 'UTC'); 1 },
    'an unknown option is refused';
is_deeply $E->datetime_format('picked_up', 'day')->arguments->[2], undef,
    'without a zone the expression is unchanged';

sub page {
    my (@selections) = @_;
    return Selecto::CannedPage->new(
        id => 'shipments', domain => $domain,
        dataset => {query => Selecto::Query->new, entity_key => ['id']},
        views => [{id => 'list', kind => 'detail',
            query => Selecto::Query->new->select('id', @selections)}],
        controls => [],
    );
}
my $page = page($local->as('pickup'), $E->related_collection('inspections', [
    {key => 'inspected', expression => $E->datetime_format('inspections.inspected',
        'us_datetime', timezone => 'America/New_York')},
])->as('inspections'));
my $planned = $page->plan({})->{query};
ok grep({ $_->kind eq 'field' && $_->arguments->[0] eq 'picked_up' } @{$planned->groups}),
    'a formatted date is grouped by its field';
like $pg->compile($planned)->sql, qr/'inspected', TO_CHAR\(/,
    'a nested child date is formatted inside the collection';
my $ordered = Selecto::CannedPage->new(
    id => 'ordered', domain => $domain,
    dataset => {query => Selecto::Query->new, entity_key => ['id']},
    views => [{id => 'list', kind => 'detail', query => Selecto::Query->new
        ->select('id', $local->as('pickup'))->order_by('delivered', 'desc')}],
    controls => [],
);
ok grep({ $_->kind eq 'field' && $_->arguments->[0] eq 'delivered' }
        @{$ordered->plan({})->{query}->groups}),
    'an ordering field is still grouped beside a formatted date';
ok !eval { page($local); 1 }, 'a formatted detail selection needs an alias';
# Bounded preparation only compiles; stand in for a live connection's support.
no warnings qw(redefine once);
local *Selecto::PostgreSQL::bounded_stream_supported = sub { 1 };
local *Selecto::PostgreSQL::query_budget_supported = sub { 1 };
use warnings qw(redefine once);
my $bounded_sql = Selecto::BoundedQuery->prepare($pg, $planned)->{statement}->sql;
like $bounded_sql, qr/'inspected', TO_CHAR\(.+ LIMIT \d+/s,
    'a bounded collection may format a child date and keeps its cap';
ok !eval { Selecto::BoundedQuery->prepare($pg, $pg->query->select('id',
    $E->related_collection('inspections', [{key => 'nested', expression =>
        $E->related_collection('inspections', ['inspected'])}])->as('inspections'))); 1 },
    'a bounded collection still refuses a nested collection as a child';
ok !eval { page($E->related_collection('inspections', [
    {key => 'when', expression => $E->datetime_format('inspections.inspected', 'us_date')},
])->as('inspections')); 1 }, 'a nested formatted field keeps its own name';

done_testing;
