use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::DateFormat ();

my $domain = Selecto::Domain->new(
    name => 'Synthetic grouped bindings', table => 'selecto_grouped_bindings',
    fields => {id=>'integer', instant=>'utc_datetime', epoch=>'epoch_datetime',
        naive=>'naive_datetime', day=>'date', active=>'boolean'},
)->with_required_predicate(Selecto::Expression->eq('active', JSON::PP::true));
my $zone = 'America/New_York';
my $instant = Selecto::Expression->field('instant');
my $hour = Selecto::Expression->datetime_format($instant, 'hour');

{
    package AnonymousTemporalAdapter;
    use Mojo::Base 'Selecto::PostgreSQL';
    sub placeholder { return '?'; }
    sub _reuses_parameter_identity { return 0; }
}

subtest 'anonymous adapter retains every occurrence' => sub {
    my $engine = Selecto::Engine->new(domain=>$domain,
        adapter=>AnonymousTemporalAdapter->new(dbh=>TestSelecto::DBH->new));
    my $query = $engine->query->select($instant->as('value'), Selecto::Expression->count->as('n'))
        ->where(Selecto::Expression->gt('id', 0))->group_by($instant)
        ->order_by($instant)->use_timezone($zone);
    my $statement = $engine->compile($query);
    is_deeply $statement->params, [$zone, JSON::PP::true, 0, $zone, $zone],
        'SELECT, WHERE, GROUP BY and ORDER BY keep textual bind order';
    my $count = () = $statement->sql =~ /\?/g;
    is $count, scalar @{$statement->params}, 'cached SQL never loses anonymous bind values';
    my $rollup = $engine->compile($engine->query->select($instant->as('value'),
        Selecto::Expression->grouping($instant)->as('g'))
        ->group_by_rollup($instant)->use_timezone($zone));
    is_deeply $rollup->params, [$zone, $zone, JSON::PP::true, $zone],
        'GROUPING metadata also retains anonymous occurrences';
};

for my $name (qw(postgresql duckdb)) {
    subtest "$name grouped expression identities" => sub {
        my $engine = Selecto::Engine->new(domain=>$domain,
            adapter=>Selecto->adapter($name=>(dbh=>TestSelecto::DBH->new)));
        my $statement = $engine->compile($engine->query->select($instant->as('value'),
            Selecto::Expression->count->as('n'))->group_by($instant)->order_by($instant)->use_timezone($zone));
        is_deeply $statement->params, [$zone, JSON::PP::true], 'zone binds once for selection, grouping and sorting';
        my $occurrences = () = $statement->sql =~ /AT TIME ZONE \$1/g;
        is $occurrences, 3, 'all three clauses refer to the same parameter identity';
        unlike $statement->sql, qr/\Q$zone\E/, 'zone is never interpolated';
        my $nested = $engine->compile($engine->query->select($hour->as('hour'),
            Selecto::Expression->count->as('n'))->group_by($instant)->order_by($instant)->use_timezone($zone));
        is_deeply $nested->params, [$zone, JSON::PP::true], 'selected formatter reuses its governed grouped child';
        my $metadata_first = $engine->compile($engine->query->select(
            Selecto::Expression->grouping($hour)->as('g'), $hour->as('hour'),
            Selecto::Expression->count->as('n'))->group_by_rollup($hour)->order_by($hour)->use_timezone($zone));
        is_deeply $metadata_first->params, [$zone, JSON::PP::true], 'GROUPING can precede its selected dimension';
        my $ungrouped = $engine->compile($engine->query->select($instant->as('value'))->use_timezone('UTC'));
        is_deeply $ungrouped->params, ['UTC', JSON::PP::true], 'group cache cannot leak across compilations';
        is $engine->adapter->_renumber_placeholders(q{SELECT '$1''$2', "part$3", $1, $2}, 4),
            q{SELECT '$1''$2', "part$3", $5, $6},
            'nested-query numbering leaves quoted SQL contents untouched';
    };
}

sub run_live {
    my ($name, $dbh) = @_;
    $dbh->{HandleError} = sub { diag $_[0]; return 0; }; # Synthetic session only.
    $dbh->do(q{SET TIME ZONE 'Pacific/Honolulu'});
    $dbh->do('CREATE TEMP TABLE selecto_grouped_bindings (id INTEGER, instant TIMESTAMPTZ, epoch DECIMAL(24,6), naive TIMESTAMP, day DATE, active BOOLEAN)');
    $dbh->do(q{INSERT INTO selecto_grouped_bindings(id,epoch,active) VALUES
        (1,-0.000001,true),(2,1710055800,true),(3,1730611800,true),
        (4,1730615400,true),(5,NULL,true),(6,1710055800,false)});
    $dbh->do(q{UPDATE selecto_grouped_bindings SET instant=TO_TIMESTAMP(epoch),
        naive=TO_TIMESTAMP(epoch) AT TIME ZONE 'UTC', day=CAST(TO_TIMESTAMP(epoch) AT TIME ZONE 'UTC' AS DATE)});
    my $engine = Selecto::Engine->new(domain=>$domain, adapter=>Selecto->adapter($name=>(dbh=>$dbh)));
    for my $field ($instant, Selecto::Expression->field('epoch'), Selecto::Expression->epoch_datetime('epoch')) {
        my $base = $engine->query->select($field->as('value'), Selecto::Expression->count->as('n'))
            ->group_by($field)->order_by($field)->use_timezone($zone);
        my $rows = $engine->all($base)->{rows};
        is_deeply [map {$_->[1]} @$rows], [1,1,2,1], 'ordered groups merge fold instants and preserve NULL and host scope';
        is_deeply $engine->all($engine->query->select(Selecto::Expression->count->as('n'))
            ->group_by($field)->order_by($field)->use_timezone($zone))->{rows},
            [[1],[1],[2],[1]], 'an unselected grouping key can still sort the results';
        is_deeply $engine->all($base->limit(2)->offset(1))->{rows}, [@$rows[1,2]],
            'pagination occurs after ordered grouping';
    }
    my $nested = $engine->all($engine->query->select($hour->as('hour'), Selecto::Expression->count->as('n'))
        ->group_by($instant)->order_by($instant)->use_timezone($zone));
    is_deeply [map {$_->[1]} @{$nested->{rows}}], [1,1,2,1], 'selected formatter over a grouped local instant executes';
    my $rollup = $engine->all($engine->query->select(Selecto::Expression->grouping($hour)->as('g'),
        $hour->as('hour'), Selecto::Expression->count->as('n'))
        ->group_by_rollup($hour)->order_by($hour)->use_timezone($zone));
    is scalar(@{$rollup->{rows}}), 5, 'metadata-first rollup includes the four groups and total';
    is_deeply [map {$_->[2]} grep {$_->[0] == 1} @{$rollup->{rows}}], [5], 'rollup total preserves host scope';
    my $left = $engine->query->select(Selecto::Expression->count->as('n'))
        ->where(Selecto::Expression->lte('id',2))->group_by($hour)->use_timezone($zone);
    my $right = $engine->query->select(Selecto::Expression->count->as('n'))
        ->where(Selecto::Expression->gte('id',3))->group_by($hour)->use_timezone($zone);
    is_deeply $engine->all($left->union_all($right)->order_by('n'))->{rows}, [[1],[1],[1],[2]],
        'compound grouped queries shift numbered identities without merging operand scope';
    my $cte_source = $engine->query->select('id',$hour->as('hour'))
        ->where(Selecto::Expression->lte('id',4))->group_by('id',$instant)->use_timezone('UTC');
    my $cte_query = $engine->query->with_cte('grouped_times',$domain,$cte_source,
        columns=>[qw(id hour)],join=>{owner_key=>'id',related_key=>'id',type=>'inner'})
        ->select($hour->as('hour'),Selecto::Expression->count->as('n'))
        ->group_by($hour)->order_by($hour)->use_timezone($zone);
    is_deeply [map {$_->[1]} @{$engine->all($cte_query)->{rows}}], [2,1,1],
        'CTE UTC groups and outer local groups use independent expression contexts';
    my $yes = Selecto::Expression->eq('active', JSON::PP::true);
    my $no = Selecto::Expression->eq('active', JSON::PP::false);
    is_deeply $engine->all($engine->query->select($yes->as('yes'),$no->as('no'),
        Selecto::Expression->count->as('n'))->group_by($yes,$no))->{rows}, [[1,0,5]],
        'true and false literals have distinct grouped-expression identities';
    my %observations;
    for my $source (qw(instant epoch naive day)) {
        for my $format (@{Selecto::DateFormat->choices}) {
            my $field = $source eq 'epoch' ? Selecto::Expression->epoch_datetime($source) : $source;
            my $expression = Selecto::Expression->datetime_format($field, $format->{id});
            for my $selected_zone (undef, 'UTC', $zone, 'Asia/Kathmandu', 'Australia/Lord_Howe', 'Etc/GMT+5') {
                my $query = $engine->query->select($expression->as('value'), Selecto::Expression->count->as('n'))
                    ->group_by($expression)->order_by($expression);
                $query = $query->use_timezone($selected_zone) if defined $selected_zone;
                my $result = $engine->all($query);
                my $key = join '/', $source, $format->{id}, $selected_zone // 'omitted';
                my $total = 0;
                $total += $_->[1] for @{$result->{rows}};
                is $total, 5, "$key ordered formatting groups preserve every scoped row";
                $observations{$key} = $result->{rows};
            }
        }
    }
    return \%observations;
}

my %observations;
subtest 'PostgreSQL live grouped parameter identities' => sub {
    my $database = $ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all => 'disposable API PostgreSQL database is not configured' unless defined($database) && length($database);
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };
    my $dbh = DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $observations{postgresql} = run_live('postgresql',$dbh);
    $dbh->disconnect;
};
subtest 'DuckDB live grouped parameter identities' => sub {
    plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBI; require DBD::DuckDB; 1 };
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $observations{duckdb} = run_live('duckdb',$dbh);
    $dbh->disconnect;
};
subtest 'ordered formatted groups match across native drivers' => sub {
    plan skip_all => 'both live drivers are required' unless keys(%observations) == 2;
    for my $key (sort keys %{$observations{postgresql}}) {
        is_deeply $observations{duckdb}{$key}, $observations{postgresql}{$key}, $key;
    }
};
done_testing;
