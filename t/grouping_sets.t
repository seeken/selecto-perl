use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;

# CUBE and GROUPING SETS against real databases: SQLite and DuckDB in memory,
# and PostgreSQL when SELECTO_PERL_TEST_POSTGRES_URL names a disposable one.
my $x = 'Selecto::Expression';
my $table = 'selecto_grouping_sets_' . $$;

my %connect = (
    sqlite => sub {
        return undef unless eval { require DBD::SQLite; 1 };
        return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    },
    duckdb => sub {
        return undef unless eval { require DBD::DuckDB; 1 };
        return DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
    postgresql => sub {
        my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
        return undef unless defined($url) && eval { require DBD::Pg; require Selecto::Certification; 1 };
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        return DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
);
my @cleanup;
END { eval { $_->[0]->do("DROP TABLE IF EXISTS $_->[1]") } for @cleanup }

sub code_of {
    my ($run) = @_;
    return eval { $run->(); 1 } ? 'ok' : ref($@) && $@->can('code') ? $@->code : die $@;
}

# Rows as "state|region|count|sum|marker" strings, sorted, so backends that
# return numbers in different forms compare equal.
sub rows_of {
    my ($engine, $query) = @_;
    my $result = $engine->all($query);
    return [sort map {
        my @row = @$_;
        join '|', map { defined($_) ? (/\A-?\d+(?:\.\d+)?\z/ ? 0 + $_ : $_) : 'NULL' } @row;
    } @{$result->{rows}}];
}

my @detail  = ('done|east|2|12|0', 'open|east|1|10|0', 'open|west|1|20|0');
my @by_state  = ('done|NULL|2|12|1', 'open|NULL|2|30|1');
my @by_region = ('NULL|east|3|22|2', 'NULL|west|1|20|2');
my @total   = ('NULL|NULL|4|42|3');

my $ran = 0;
for my $backend (qw(sqlite duckdb postgresql)) {
    my $dbh = $connect{$backend}->() or next;
    $ran++;
    subtest $backend => sub {
        $dbh->do("CREATE TABLE $table(id INTEGER PRIMARY KEY, state VARCHAR(10), region VARCHAR(10), total INTEGER)");
        push @cleanup, [$dbh, $table];
        $dbh->do("INSERT INTO $table VALUES (1,'open','east',10),(2,'open','west',20),(3,'done','east',5),(4,'done','east',7)");
        my $adapter = Selecto->adapter($backend => (dbh => $dbh));
        my $engine = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->new(
            name => 'Orders', table => $table,
            fields => {id => 'integer', state => 'string', region => 'string', total => 'integer'}));
        my @columns = ('state', 'region', $x->count->as('n'), $x->sum('total')->as('sum_total'),
            $x->grouping('state', 'region')->as('marker'));
        my $base = $engine->query->select(@columns);

        ok($adapter->supports('cube'), 'declares cube');
        ok($adapter->supports('grouping_sets'), 'declares grouping_sets');

        my $cube = $base->group_by_cube('state', 'region');
        is($cube->grouping_mode, 'cube', 'cube mode');
        is_deeply($cube->grouping_set_positions, [[0, 1], [0], [1], []], 'a cube is every subset');
        is_deeply(rows_of($engine, $cube), [sort @detail, @by_state, @by_region, @total], 'cube rows and markers');
        is(scalar @{$engine->compile($cube)->params}, 0, 'no bound values for markers or NULL dimensions');

        my $sets = $base->group_by_grouping_sets(['state'], ['region'], []);
        is($sets->grouping_mode, 'grouping_sets', 'grouping_sets mode');
        is_deeply($sets->grouping_sets, [[0], [1], []], 'declared sets are kept as dimension positions');
        is_deeply(rows_of($engine, $sets), [sort @by_state, @by_region, @total], 'grouping sets rows and markers');

        is_deeply(rows_of($engine, $base->group_by_grouping_sets(['state', 'region'], ['state'], [])),
            rows_of($engine, $base->group_by_rollup('state', 'region')),
            'prefix grouping sets equal the rollup');
        my $plain = $engine->query->select('state', 'region', $x->count->as('n'));
        is_deeply(rows_of($engine, $plain->group_by_grouping_sets(['state', 'region'])),
            rows_of($engine, $plain->group_by('state', 'region')),
            'one full grouping set equals a plain group by');

        my $filtered = $cube->where($x->eq('region', 'east'));
        is_deeply(rows_of($engine, $filtered),
            [sort 'done|east|2|12|0', 'open|east|1|10|0', 'done|NULL|2|12|1', 'open|NULL|1|10|1',
                'NULL|east|3|22|2', 'NULL|NULL|3|22|3'],
            'a filter applies to every grouping set');

        my $ordered = $engine->all($sets->order_by($x->count, 'desc')->order_by($x->grouping('state', 'region')));
        is_deeply([map { 0 + $_->[2] } @{$ordered->{rows}}], [4, 3, 2, 2, 1], 'ordering by selected columns');
        is(scalar @{$engine->all($sets->order_by($x->count, 'desc')->order_by($x->grouping('state', 'region'))->limit(2))->{rows}}, 2, 'limit');

        is(code_of(sub { $engine->compile($sets->order_by('id')) }), 'invalid_query', 'ordering by an unselected field is refused');
        is($cube->grouping_mode, 'cube', 'compilation leaves the query unchanged');
        # Adapters that build the sets from UNION ALL branches check the
        # projection themselves; the others leave that to the database.
        is(code_of(sub { $engine->compile($engine->query->select('id')->group_by_cube('state')) }), 'invalid_query',
            'a free field is refused in a cube') if $backend eq 'sqlite';
    };
}

subtest 'query construction' => sub {
    my $query = Selecto::Query->new;
    is(code_of(sub { $query->group_by_cube() }), 'invalid_query', 'cube needs a dimension');
    is(code_of(sub { $query->group_by_cube(map { "d$_" } 1 .. 9) }), 'invalid_query', 'cube is bounded to 8 dimensions');
    is(scalar @{$query->group_by_cube(map { "d$_" } 1 .. 8)->grouping_set_positions}, 256, '8 dimensions are 256 sets');
    is(code_of(sub { $query->group_by_grouping_sets() }), 'invalid_query', 'grouping sets need a set');
    is(code_of(sub { $query->group_by_grouping_sets('state') }), 'invalid_query', 'a set is an array');
    is(code_of(sub { $query->group_by_grouping_sets(['state', 'state']) }), 'invalid_query', 'a dimension twice in a set');
    is(code_of(sub { $query->group_by_grouping_sets(['a', 'b'], ['b', 'a']) }), 'invalid_query', 'the same set twice');
    is(code_of(sub { $query->group_by_grouping_sets([]) }), 'invalid_query', 'the grand total alone has no dimension');
    is(code_of(sub { $query->group_by_grouping_sets(map { ["d$_"] } 1 .. 65) }), 'invalid_query', 'at most 64 sets');
    is(code_of(sub { Selecto::Query->new(grouping_mode => 'cube', grouping_sets => [[0]], groups => [$x->field('a')]) }),
        'invalid_query', 'stored sets belong to the grouping_sets mode only');
    is(code_of(sub { Selecto::Query->new(grouping_mode => 'grouping_sets', grouping_sets => [[1]], groups => [$x->field('a')]) }),
        'invalid_query', 'a stored position must exist');
    my $sets = $query->group_by_grouping_sets(['a', 'b'], ['b'], []);
    is_deeply($sets->group_by('a')->grouping_sets, undef, 'a later group_by replaces the sets');
    is($sets->group_by_rollup('a')->grouping_mode, 'rollup', 'and a later rollup the mode');
    is_deeply($sets->limit(5)->grouping_sets, [[0, 1], [1], []], 'other builders keep them');
};

subtest 'an adapter without the capability refuses' => sub {
    plan skip_all => 'DBD::MariaDB is not installed' unless eval { require Selecto::MySQL; 1 };
    my $adapter = eval { Selecto->adapter(mysql => (dbh => undef)) } or plan skip_all => 'no MySQL adapter without a handle';
    ok(!$adapter->supports('cube'), 'MySQL does not declare cube');
    ok(!$adapter->supports('grouping_sets'), 'MySQL does not declare grouping_sets');
};

plan skip_all => 'no database driver is available' unless $ran;
done_testing;
