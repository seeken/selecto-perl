use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::DateFormat ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();

sub temporal_domain {
    return Selecto::Domain->parse({
        schema_version => 1, domain_version => '1.0.0',
        domain_fingerprint => 'sha256:synthetic-epoch-timezone', name => 'Synthetic instants',
        required_selected => ['id'],
        source => {source_table => 'selecto_epoch_timezone_fixture', primary_key => 'id',
            fields => [qw(id instant epoch active)], columns => {
                id => {type => 'integer'}, instant => {type => 'utc_datetime'},
                epoch => {type => 'epoch_datetime'}, active => {type => 'boolean', internal => JSON::PP::true}},
            associations => {}}, schemas => {}, joins => {},
    })->with_required_predicate(Selecto::Expression->eq('active', JSON::PP::true));
}

for my $name (qw(postgresql duckdb)) {
    subtest "$name compiled storage-to-instant boundary" => sub {
        my $engine = Selecto::Engine->new(domain => temporal_domain(),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
        my $raw = $engine->compile($engine->query->select('epoch')->use_timezone('America/New_York'));
        like $raw->sql, qr/TO_TIMESTAMP\("s0"\."epoch"\) AT TIME ZONE /,
            'raw numeric storage becomes an instant before timezone conversion';
        unlike $raw->sql, qr/America\/New_York/, 'zone remains a bound value';
        is $raw->params->[0], 'America/New_York', 'zone parameter retained';
        my $explicit = Selecto::Expression->epoch_datetime('epoch');
        my $converted = $engine->compile($engine->query->select($explicit->as('local_time'))->use_timezone('America/New_York'));
        unlike $converted->sql, qr/TO_TIMESTAMP\(TO_TIMESTAMP\(/, 'explicit temporal expression is not converted twice';
        like $converted->sql, qr/TO_TIMESTAMP\("s0"\."epoch"\) AT TIME ZONE /,
            'explicit temporal expression retains timezone rendering';
        my $numeric = $engine->compile($engine->query->select('epoch'));
        unlike $numeric->sql, qr/TO_TIMESTAMP|AT TIME ZONE/, 'without a zone raw storage selection remains numeric';
    };
}

sub live_cases {
    my ($name, $dbh) = @_;
    $dbh->do(q{SET TIME ZONE 'Pacific/Honolulu'});
    $dbh->do('CREATE TEMP TABLE selecto_epoch_timezone_fixture (id BIGINT, instant TIMESTAMPTZ, epoch DECIMAL(24,6), active BOOLEAN)');
    $dbh->do(q{INSERT INTO selecto_epoch_timezone_fixture(id,epoch,active) VALUES
        (1,-0.000001,true),(2,1710055800,true),(3,1730611800,true),
        (4,1730615400,true),(5,NULL,true),(6,1710055800,false)});
    $dbh->do('UPDATE selecto_epoch_timezone_fixture SET instant=TO_TIMESTAMP(epoch)');
    my $engine = Selecto::Engine->new(domain => temporal_domain(), adapter => Selecto->adapter($name => (dbh => $dbh)));
    my $handler = Selecto::API::EngineHandler->new;
    my $request = {select => ['instant','epoch'], order_by => [{field => 'id'}], timezone => 'America/New_York'};
    my @expected = ('1969-12-31T18:59:59.999999','2024-03-10T03:30:00',
        '2024-11-03T01:30:00','2024-11-03T01:30:00',undef);
    my $result = $handler->query($engine, $request);
    is_deeply $result->{columns}, [qw(id instant epoch)], 'required identity and both temporal names remain stable';
    is_deeply $result->{rows}, [map {[$_+1,$expected[$_],$expected[$_]]} 0..$#expected],
        'raw epoch selection matches stored instants across negative microseconds, DST gap/fold and NULL';
    my $filtered = $handler->query($engine, {%$request, filters => [{field => 'epoch', op => 'between',
        value => '2024-11-03T01:00:00', end => '2024-11-03T02:00:00'}]});
    is_deeply [map {$_->[0]} @{$filtered->{rows}}], [3,4], 'epoch filters use local calendar values and preserve both fold instants';
    my $objects = $handler->query($engine, {%$request, row_format => 'objects', select => [
        {field => 'epoch', alias => 'local_epoch'}, {field => 'instant', alias => 'local_instant'}]});
    is_deeply $objects->{rows}, [map {{id=>$_+1,local_epoch=>$expected[$_],local_instant=>$expected[$_]}} 0..$#expected],
        'aliased object rows retain timezone results and hidden scope';
    my $no_zone = $handler->query($engine, {select => ['epoch'], order_by => [{field => 'id'}]});
    is_deeply $no_zone->{rows}, [[1,'-0.000001'],[2,'1710055800'],[3,'1730611800'],[4,'1730615400'],[5,undef]],
        'omitting timezone preserves exact numeric epoch storage strings';
    for my $zone ('UTC', 'America/New_York', 'Asia/Kathmandu', 'Australia/Lord_Howe') {
        for my $format (@{Selecto::DateFormat->choices}) {
            my $formatted = $handler->query($engine, {select => [
                {field => 'instant', format => $format->{id}, alias => 'instant_format'},
                {field => 'epoch', format => $format->{id}, alias => 'epoch_format'}],
                timezone => $zone, order_by => [{field => 'id'}]});
            is_deeply [map {$_->[2]} @{$formatted->{rows}}], [map {$_->[1]} @{$formatted->{rows}}],
                "$format->{id} in $zone preserves equivalent stored instants";
        }
    }
    is_deeply $handler->query($engine, {%$request, limit => 0})->{rows}, [], 'zero page stays empty';
}

subtest 'PostgreSQL live epoch timezone' => sub {
    my $database = $ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all => 'disposable API PostgreSQL database is not configured' unless defined $database && length $database;
    plan skip_all => 'DBD::Pg is not installed' unless eval {require DBI; require DBD::Pg; 1};
    my $dbh = DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    live_cases('postgresql',$dbh);
    $dbh->disconnect;
};
subtest 'DuckDB live epoch timezone' => sub {
    plan skip_all => 'DBD::DuckDB is not installed' unless eval {require DBI; require DBD::DuckDB; 1};
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    live_cases('duckdb',$dbh);
    $dbh->disconnect;
};
done_testing;
