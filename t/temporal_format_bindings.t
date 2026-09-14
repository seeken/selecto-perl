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

my @zones = ('UTC', 'America/New_York', 'Asia/Kathmandu', 'Australia/Lord_Howe', 'Etc/GMT+5');
my @formats = map { $_->{id} } @{Selecto::DateFormat->choices};
my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0',
    domain_fingerprint => 'sha256:synthetic-temporal-bindings', name => 'Temporal bindings',
    required_selected => ['id'],
    source => {source_table => 'selecto_temporal_bindings', primary_key => 'id',
        fields => [qw(id naive day instant epoch active)], columns => {
            id => {type => 'integer'}, naive => {type => 'naive_datetime'},
            day => {type => 'date'}, instant => {type => 'utc_datetime'},
            epoch => {type => 'epoch_datetime'}, active => {type => 'boolean', internal => JSON::PP::true}},
        associations => {}}, schemas => {}, joins => {},
})->with_required_predicate(Selecto::Expression->eq('active', JSON::PP::true));

sub selection {
    my ($field) = @_;
    return map {
        my $source = $field eq 'epoch' ? Selecto::Expression->epoch_datetime($field) : $field;
        Selecto::Expression->datetime_format($source, $_)->as($_)
    } @formats;
}

subtest 'numbered placeholder occurrence accounting' => sub {
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter(duckdb => (dbh => TestSelecto::DBH->new)));
    for my $field (qw(naive day instant epoch)) {
        for my $zone (@zones) {
            my $statement = $engine->compile($engine->query->select(selection($field))->use_timezone($zone));
            my %markers = map { $_ => 1 } $statement->sql =~ /\$(\d+)/g;
            is_deeply [sort {$a <=> $b} keys %markers], [1 .. scalar @{$statement->params}],
                "$field in $zone has exactly one value per numbered parameter";
            unlike $statement->sql, qr/\?/, 'no anonymous markers are mixed with numbered parameters';
            unlike $statement->sql, qr/\Q$zone\E/, "$field in $zone does not interpolate caller zones"
                unless $zone eq 'UTC'; # The compiler also owns literal UTC normalization.
        }
    }
};

subtest 'all temporal formats execute equivalently on PostgreSQL and DuckDB' => sub {
    my $database = $ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all => 'disposable API PostgreSQL database is not configured' unless defined $database && length $database;
    plan skip_all => 'both DBI drivers are required' unless eval {require DBI; require DBD::Pg; require DBD::DuckDB; 1};
    my @handles = (
        DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1}),
        DBI->connect('dbi:DuckDB:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1}),
    );
    my @engines;
    for my $index (0..1) {
        my $dbh = $handles[$index];
        $dbh->do(q{SET TIME ZONE 'Pacific/Honolulu'});
        $dbh->do('CREATE TEMP TABLE selecto_temporal_bindings (id INTEGER, naive TIMESTAMP, day DATE, instant TIMESTAMPTZ, epoch DECIMAL(24,6), active BOOLEAN)');
        $dbh->do(q{INSERT INTO selecto_temporal_bindings(id,naive,epoch,active) VALUES
            (1,'1969-12-31 23:59:59.999999',-0.000001,true),
            (2,'2024-03-10 02:30:00.000001',1710055800,true),
            (3,'2024-11-03 01:30:00.100001',1730611800,true),
            (4,'2024-02-29 12:34:56.001001',1709208000,true),
            (5,NULL,NULL,true),(6,'2024-01-01 00:00:00',1704067200,false)});
        $dbh->do('UPDATE selecto_temporal_bindings SET day=CAST(naive AS DATE), instant=TO_TIMESTAMP(epoch)');
        push @engines, Selecto::Engine->new(domain => $domain,
            adapter => Selecto->adapter(($index ? 'duckdb' : 'postgresql') => (dbh => $dbh)));
    }
    my $handler = Selecto::API::EngineHandler->new;
    for my $index (0..1) {
        my $engine = $engines[$index];
        for my $case (
            ['UTC', '1969-12-31T00:00:00.000Z', -86400, '+00:00'],
            ['America/New_York', '1969-12-31T00:00:00.000-05:00', -68400, '-05:00'],
            ['Asia/Kathmandu', '1969-12-31T00:00:00.000+05:30', -106200, '+05:30'],
        ) {
            my ($zone, @expected) = @$case;
            my $request = {select => [map {{field => 'day', format => $_, alias => $_}}
                qw(rfc3339_millis epoch_seconds timezone_offset)],
                timezone => $zone, filters => [{field => 'id', op => 'eq', value => 1}]};
            for my $session ('Pacific/Honolulu', 'UTC') {
                $handles[$index]->do("SET TIME ZONE '$session'"); # Authored fixture values only.
                my $result = $handler->query($engine, $request);
                is_deeply $result->{rows}, [[1, @expected]],
                    "adapter $index DATE midnight in $zone is independent of session $session";
            }
        }
        $handles[$index]->do(q{SET TIME ZONE 'Pacific/Honolulu'});
    }
    for my $field (qw(naive day instant epoch)) {
        for my $zone (@zones) {
            my $request = {select => [map {{field => $field, format => $_, alias => $_}} @formats],
                timezone => $zone, order_by => [{field => 'id'}],
                filters => [{field => 'id', op => 'gte', value => 1}]};
            my @observations = map { $handler->query($_, $request) } @engines;
            is_deeply $observations[1]{columns}, $observations[0]{columns}, "$field in $zone preserves formatted aliases";
            is_deeply $observations[1]{rows}, $observations[0]{rows}, "$field in $zone matches live PostgreSQL for all 20 formats";
            is scalar @{$observations[1]{rows}}, 5, "$field in $zone retains required scope and NULL row";
        }
    }
    $_->disconnect for @handles;
};
done_testing;
