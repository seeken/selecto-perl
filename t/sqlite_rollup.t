use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use DBI;
use Selecto;
use Selecto::Limits;
use lib 't/lib';
use TestSelecto;

my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->new(name => 'Orders', table => 'orders', fields => {
    id => 'integer', person_id => 'integer', state => 'string', total => 'decimal',
}, associations => {person => {
    table => 'people', fields => {id => 'integer', name => 'string'},
    owner_key => 'person_id', related_key => 'id', join_type => 'left',
}});
my $adapter = Selecto->adapter(sqlite => dbh => TestSelecto::DBH->new);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

sub error_code {
    my ($run) = @_;
    my $ok = eval { $run->(); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : die $@;
}
sub sorted_rows {
    my ($rows) = @_;
    my $json = JSON::PP->new->canonical;
    return [sort { $json->encode($a) cmp $json->encode($b) } @$rows];
}
sub rollup_query {
    my ($engine, @dimensions) = @_;
    return $engine->query->select(@dimensions, $x->count->as('order_count'),
        $x->grouping(@dimensions)->as('grouping_marker'))->group_by_rollup(@dimensions);
}

subtest 'compiler admission and bounded masks do not require a SQLite driver' => sub {
    ok($adapter->supports('rollup'), 'SQLite declares rollup support');
    my $query = rollup_query($engine, 'state', 'person_id');
    my $statement = $engine->compile($query);
    is(scalar(() = $statement->sql =~ /UNION ALL/g), 2, 'two dimensions emit three branches');
    unlike($statement->sql, qr/\b(?:ROLLUP|GROUPING)\s*\(/, 'SQLite needs no native grouping-set functions');
    is_deeply($statement->columns, [qw(state person_id order_count grouping_marker)], 'public aliases survive');
    is_deeply($statement->params, [], 'compiler-generated NULLs and masks add no bindings');
    is($query->grouping_mode, 'rollup', 'compilation leaves the caller query unchanged');
    is(scalar(@{$query->groups}), 2, 'compilation leaves all caller dimensions intact');
    for my $case (
        [$engine->query->select('id')->group_by_rollup('state'), 'unrelated scalar field'],
        [$engine->query->select($x->grouping('person_id'))->group_by_rollup('state'), 'undeclared marker operand'],
        [$engine->query->select('state')->group_by_rollup('state', $x->field('state')->as('other')), 'duplicate dimension with an alias'],
        [$engine->query->select('state', 'state')->group_by_rollup('state'), 'duplicate result column'],
        [$query->order_by('id'), 'unselected ordering field'],
        [$engine->query->select($x->dimension_display('person.name', 'id'))->group_by_rollup('state'), 'unrelated display key'],
        [$engine->query->select($x->window('row_number'))->group_by_rollup('state'), 'window projection'],
    ) {
        is(error_code(sub { $engine->compile($case->[0]) }), 'invalid_query', "$case->[1] fails before execution");
    }
    is(error_code(sub {$engine->compile($engine->query->select($x->grouping('state')))}),
        'unsupported_feature', 'GROUPING outside a rollup is refused before execution');
    my @fields = map { "d$_" } 0 .. 31;
    my $wide = Selecto::Engine->new(adapter => $adapter,
        domain => Selecto::Domain->new(name => 'Wide', table => 'wide',
            fields => {map { $_ => 'integer' } @fields}));
    my @bounded = @fields[0 .. 30];
    my $bounded = $wide->compile($wide->query->select($x->grouping(@bounded)->as('mask'))
        ->group_by_rollup(@bounded));
    is(scalar(() = $bounded->sql =~ /UNION ALL/g), 31, '31 dimensions remain bounded to 32 branches');
    like($bounded->sql, qr/THEN 2147483647 END/, '31-bit grand-total mask remains exact');
    is(error_code(sub {$wide->compile($wide->query->select($x->count)->group_by_rollup(@fields))}),
        'invalid_query', '32 dimensions are refused');
    is(error_code(sub {$engine->compile($engine->query
        ->select($x->grouping([('state') x 32]))->group_by_rollup('state'))}),
        'invalid_query', 'oversized marker operands are refused');
    my $parameterized = $query->where($x->eq('state', 'open'));
    for my $limit (2, 3) {
        my $bounded_engine = Selecto::Engine->new(domain => $domain, adapter => $adapter,
            limits => Selecto::Limits->new(max_generated_parameters => $limit));
        is(error_code(sub {$bounded_engine->compile($parameterized)}), $limit == 3 ? 'ok' : 'invalid_query',
            "final parameter admission accounts for all three branches at limit $limit");
    }
};

subtest 'public SQLite rollups execute entirely in memory' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('PRAGMA temp_store = MEMORY');
    $dbh->do('CREATE TEMP TABLE memory_proof(id INTEGER)');
    is($dbh->selectrow_array('PRAGMA temp_store'), 2, 'TEMP storage is MEMORY');
    is_deeply([map { $_->[2] } @{$dbh->selectall_arrayref('PRAGMA database_list')}], ['', ''],
        'main and TEMP databases have no file paths');
    my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
    $dbh->do('CREATE TABLE orders(id INTEGER PRIMARY KEY, person_id INTEGER, state TEXT, total NUMERIC)');
    $dbh->do('INSERT INTO orders VALUES(?,?,?,?)', undef, @$_) for
        [101, 1, 'open', 12.50], [102, 1, 'closed', 7.50], [103, 2, 'open', 20.00],
        [104, undef, 'orphan', 5.00], [105, 3, 'open', 20.25];
    $dbh->do('CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT)');
    $dbh->do('INSERT INTO people VALUES(?,?)', undef, @$_) for [1, 'Alice'], [2, 'Bob'], [3, 'Carol'];

    subtest 'exact central RQ001 and RQ002 observations' => sub {
        my $one = $engine->all(rollup_query($engine, 'state'));
        is_deeply($one->{columns}, [qw(state order_count grouping_marker)], 'RQ001 column aliases');
        is_deeply(sorted_rows($one->{rows}), sorted_rows([
            [undef, 5, 1], ['closed', 1, 0], ['open', 3, 0], ['orphan', 1, 0],
        ]), 'RQ001 single-dimension counts and mask match central fixtures');
        my $two = $engine->all(rollup_query($engine, 'state', 'person_id'));
        is_deeply($two->{columns}, [qw(state person_id order_count grouping_marker)], 'RQ002 column aliases');
        is_deeply(sorted_rows($two->{rows}), sorted_rows([
            [undef, undef, 5, 3], ['closed', undef, 1, 1], ['closed', 1, 1, 0],
            ['open', undef, 3, 1], ['open', 1, 1, 0], ['open', 2, 1, 0], ['open', 3, 1, 0],
            ['orphan', undef, 1, 1], ['orphan', undef, 1, 0],
        ]), 'RQ002 preserves the real NULL detail and identically keyed subtotal');
        is($dbh->selectrow_array('PRAGMA query_only'), 0, 'query read guard restores caller state');
    };

    subtest 'ordering, aliases and pagination apply after the union' => sub {
        my $one = rollup_query($engine, 'state')->order_by('state');
        is_deeply($engine->all($one)->{rows}, [
            [undef, 5, 1], ['closed', 1, 0], ['open', 3, 0], ['orphan', 1, 0],
        ], 'single-dimension grand total sorts first');
        my $two = rollup_query($engine, 'state', 'person_id')->order_by('state')->order_by('person_id');
        is_deeply($engine->all($two)->{rows}, [
            [undef, undef, 5, 3], ['closed', undef, 1, 1], ['closed', 1, 1, 0],
            ['open', undef, 3, 1], ['open', 1, 1, 0], ['open', 2, 1, 0], ['open', 3, 1, 0],
            ['orphan', undef, 1, 1], ['orphan', undef, 1, 0],
        ], 'multi-dimension marker breaks real NULL and subtotal ties');
        is_deeply($engine->all($two->limit(2)->offset(7))->{rows},
            [['orphan', undef, 1, 1], ['orphan', undef, 1, 0]], 'pagination is applied once to all branches');
        is_deeply($engine->all($one->offset(2))->{rows}, [['open', 3, 0], ['orphan', 1, 0]],
            'offset without limit keeps SQLite LIMIT -1 behavior');
        my $aliased = $engine->query->select($x->field('state')->as('label'),
            $x->count->as('n'), $x->grouping('state')->as('mask'))->group_by_rollup('state')->order_by('label');
        is_deeply($engine->all($aliased)->{rows}, $engine->all($one)->{rows}, 'selected alias orders positionally');
        my $reordered = $engine->query->select('state', 'person_id', $x->count->as('n'),
            $x->grouping('person_id', 'state')->as('mask'))->group_by_rollup('state', 'person_id');
        my $rows = $engine->all($reordered)->{rows};
        is_deeply(sorted_rows([grep { $_->[3] == 2 } @$rows]), sorted_rows([
            ['closed', undef, 1, 2], ['open', undef, 3, 2], ['orphan', undef, 1, 2],
        ]), 'GROUPING bit order follows its operands');
    };

    subtest 'empty input, measure operands and NULL display keys' => sub {
        my $empty = rollup_query($engine, 'state', 'person_id')->where($x->lt('id', 0));
        is_deeply($engine->all($empty)->{rows}, [[undef, undef, 0, 3]], 'empty input still produces count-zero grand total');
        my $no_measure = $engine->query->select('state', $x->grouping('state')->as('mask'))
            ->group_by_rollup('state')->where($x->lt('id', 0));
        is_deeply($engine->all($no_measure)->{rows}, [[undef, 1]], 'empty input has a grand total without a selected aggregate');
        my $sum = $engine->query->select('state', $x->sum('person_id')->as('total'),
            $x->grouping('state')->as('mask'))->group_by_rollup('state');
        is_deeply(sorted_rows($engine->all($sum)->{rows}), sorted_rows([
            [undef, 7, 1], ['closed', 1, 0], ['open', 6, 0], ['orphan', undef, 0],
        ]), 'aggregate arguments retain their real fields in every branch');
        is_deeply($engine->all($sum->where($x->lt('id', 0)))->{rows}, [[undef, undef, 1]],
            'SUM stays NULL for empty input');
        my $fractional = $engine->query->select('state', $x->sum('total')->as('amount'),
            $x->grouping('state')->as('mask'))->group_by_rollup('state');
        is_deeply(sorted_rows($engine->all($fractional)->{rows}), sorted_rows([
            [undef, 65.25, 1], ['closed', 7.50, 0], ['open', 52.75, 0], ['orphan', 5, 0],
        ]), 'fractional fixture amounts retain SQLite aggregate values');
        my $display = $engine->query->select('person_id', $x->dimension_display('person.name', 'person_id')->as('name'),
            $x->count->as('n'), $x->grouping('person_id')->as('mask'))->group_by_rollup('person_id')->order_by('person_id');
        is_deeply($engine->all($display)->{rows}, [
            [undef, undef, 5, 1], [1, 'Alice', 2, 0], [2, 'Bob', 1, 0], [3, 'Carol', 1, 0], [undef, undef, 1, 0],
        ], 'dimension display aggregates association labels and retains real NULL groups');
    };

    subtest 'required scope and bind occurrences survive each branch' => sub {
        $dbh->do('CREATE TABLE scoped(id INTEGER PRIMARY KEY, tenant INTEGER, state TEXT, person_id INTEGER, total INTEGER, active INTEGER)');
        $dbh->do('INSERT INTO scoped VALUES(?,?,?,?,?,?)', undef, @$_) for
            [1, 7, 'A', 1, 10, 1], [2, 7, 'A', undef, 20, 0], [3, 7, 'B', 2, 13, undef], [4, 8, 'A', 1, 1000, 1];
        my $scoped_domain = Selecto::Domain->new(name => 'Scoped', table => 'scoped', fields => {
            id => 'integer', tenant => 'integer', state => 'string', person_id => 'integer', total => 'integer', active => 'boolean',
        })->with_required_predicate($x->eq('tenant', 7));
        my $scoped = Selecto::Engine->new(domain => $scoped_domain, adapter => $adapter);
        my $literal = q{literal'); SELECT 900; --};
        my $query = $scoped->query->select('state', 'person_id', $x->sum('total')->as('total'),
            $x->grouping('state', 'person_id')->as('mask'), $x->literal($literal)->as('tag'))
            ->group_by_rollup('state', 'person_id')->where($x->gte('total', 10));
        my $statement = $scoped->compile($query);
        is_deeply($statement->params, [map { ($literal, 7, 10) } 1 .. 3], 'selection and both predicates repeat in SQL occurrence order');
        unlike($statement->sql, qr/SELECT 900/, 'caller values remain outside SQL');
        is_deeply(sorted_rows($scoped->all($query)->{rows}), sorted_rows([
            ['A', 1, 10, 0, $literal], ['A', undef, 20, 0, $literal], ['B', 2, 13, 0, $literal],
            ['A', undef, 30, 1, $literal], ['B', undef, 13, 1, $literal], [undef, undef, 43, 3, $literal],
        ]), 'all branches preserve required scope and aggregate only caller-visible rows');
        my $measures = $scoped->query->select('state', $x->count_field('person_id')->as('n'),
            $x->count_distinct('person_id')->as('distinct_n'), $x->true_count('active')->as('true_n'),
            $x->false_count('active')->as('false_n'), $x->count_bucket('total', 10, 20)->as('bucket'),
            $x->grouping('state')->as('mask'))->group_by_rollup('state');
        my ($total) = grep { $_->[-1] == 1 } @{$scoped->all($measures)->{rows}};
        is_deeply($total, [undef, 2, 2, 1, 1, 3, 1], 'inclusive count-bucket and closed aggregates keep their ordinary semantics');
    };

    subtest 'parameterized dimensions and scalar compositions' => sub {
        my $dimension = $x->eq('state', 'open');
        my $query = $engine->query->select($dimension->as('open'), $x->count->as('n'),
            $x->grouping($dimension)->as('mask'))->group_by_rollup($dimension);
        is_deeply($engine->compile($query)->params, ['open', 'open'], 'retained SELECT and GROUP BY bind their own occurrences');
        is_deeply(sorted_rows($engine->all($query)->{rows}), sorted_rows([[0, 2, 0], [1, 3, 0], [undef, 5, 1]]),
            'parameterized dimensions group correctly without leaking into masks');
        my $composed = $engine->query->select($x->eq($x->field('state'), 'open')->as('is_open'),
            $x->is_null($x->count)->as('null_count'), $x->grouping('state')->as('mask'))->group_by_rollup('state');
        is_deeply(sorted_rows($engine->all($composed)->{rows}), sorted_rows([[0, 0, 0], [1, 0, 0], [0, 0, 0], [undef, 0, 1]]),
            'scalar compositions apply dimension dropout outside closed aggregates');
    };
    subtest 'nested query sources and compound operands retain their own contexts' => sub {
        my $cte_source = $engine->query->select('id', 'state')->where($x->eq('state', 'open'));
        my $cte = $engine->query->with_cte('open_orders', $domain, $cte_source,
            columns => [qw(id state)], join => {owner_key => 'id', related_key => 'id', type => 'inner'})
            ->select('state', $x->count->as('n'), $x->grouping('state')->as('mask'))->group_by_rollup('state');
        is_deeply($engine->compile($cte)->params, ['open', 'open'], 'CTE binds repeat before each branch body');
        is_deeply(sorted_rows($engine->all($cte)->{rows}), sorted_rows([['open', 3, 0], [undef, 3, 1]]),
            'branch-local WITH and ordinary child selections remain valid');
        my $extra = $engine->query->select($x->literal('extra')->as('state'), $x->count->as('order_count'),
            $x->literal(0)->as('grouping_marker'))->where($x->eq('state', 'closed'));
        my $compound = rollup_query($engine, 'state')->union_all($extra)->order_by('state');
        is_deeply($engine->all($compound)->{rows}, [
            [undef, 5, 1], ['closed', 1, 0], ['extra', 1, 0], ['open', 3, 0], ['orphan', 1, 0],
        ], 'rollup remains a governed set-operation operand');
        my $three = rollup_query($engine, 'state', 'person_id', 'id');
        my %counts;
        $counts{$_->[-1]}++ for @{$engine->all($three)->{rows}};
        is_deeply(\%counts, {0 => 5, 1 => 5, 3 => 3, 7 => 1}, 'three dimensions yield all four prefix grouping sets');
    };
    $dbh->disconnect;
};

done_testing;
