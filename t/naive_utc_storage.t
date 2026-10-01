use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::DateFormat ();
use Selecto::DateShortcut ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();

# Two utc_datetime columns holding the same instants: "naive" is a
# time-zone-less timestamp of UTC wall time (a Rails datetime), "aware" is a
# timestamptz. Declaring storage naive_utc must make them indistinguishable.
sub storage_domain {
    my (%options) = @_;
    my %naive = (type => 'utc_datetime');
    $naive{storage} = 'naive_utc' unless $options{without_hint};
    return Selecto::Domain->parse({
        schema_version => 1, domain_version => '1.0.0',
        domain_fingerprint => 'sha256:synthetic-naive-utc', name => 'Naive UTC storage',
        required_selected => ['id'],
        source => {source_table => 'selecto_naive_utc_fixture', primary_key => 'id',
            fields => [qw(id naive aware naive_instant)], columns => {
                id => {type => 'integer'}, naive => \%naive, aware => {type => 'utc_datetime'},
                naive_instant => {type => 'utc_datetime', computed => {kind => 'expression',
                    expression => ['cast', ['field', 'naive'], 'utc_datetime']}},
            },
            associations => {event => {queryable => 'events', owner_key => 'id', related_key => 'id'}}},
        schemas => {events => {source_table => 'selecto_naive_utc_fixture', primary_key => 'id',
            fields => [qw(id naive)], columns => {id => {type => 'integer'}, naive => {%naive}}}},
        joins => {event => {type => 'left'}},
    });
}

sub domain_error {
    my ($column) = @_;
    my $ok = eval {
        Selecto::Domain->parse({
            schema_version => 1, domain_version => '1.0.0', name => 'Invalid storage',
            source => {source_table => 'items', primary_key => 'id', fields => [qw(id at)],
                columns => {id => {type => 'integer'}, at => $column}},
            schemas => {}, joins => {},
        });
        1;
    };
    return $ok ? undef : $@;
}

subtest 'storage validation' => sub {
    my $domain = storage_domain();
    is $domain->field_storage('naive'), 'naive_utc', 'root storage is reported';
    is $domain->field_storage('event.naive'), 'naive_utc', 'association storage is reported';
    is $domain->field_storage('aware'), undef, 'default storage is undefined';
    is $domain->field_metadata('naive')->{storage}, 'naive_utc', 'storage is column metadata';
    for my $case (
        [{type => 'utc_datetime', storage => 'naive'}, qr/storage must be naive_utc/],
        [{type => 'utc_datetime', storage => 'NAIVE_UTC'}, qr/storage must be naive_utc/],
        [{type => 'utc_datetime', storage => undef}, qr/storage must be naive_utc/],
        [{type => 'utc_datetime', storage => ['naive_utc']}, qr/storage must be naive_utc/],
        [{type => 'naive_datetime', storage => 'naive_utc'}, qr/not a utc_datetime column/],
        [{type => 'string', storage => 'naive_utc'}, qr/not a utc_datetime column/],
        [{type => 'utc_datetime', storage => 'naive_utc',
            computed => {kind => 'expression', expression => ['field', 'id']}}, qr/is computed/],
    ) {
        my $error = domain_error($case->[0]);
        ok blessed($error) && $error->code eq 'invalid_domain', 'invalid storage is invalid_domain';
        like blessed($error) ? $error->message : "$error", $case->[1], 'message names the problem';
    }
    my $schema_error = eval {
        Selecto::Domain->parse({
            schema_version => 1, domain_version => '1.0.0', name => 'Invalid schema storage',
            source => {source_table => 'items', primary_key => 'id', fields => ['id'],
                columns => {id => {type => 'integer'}}},
            schemas => {other => {source_table => 'other', primary_key => 'id', fields => ['id'],
                columns => {id => {type => 'integer', storage => 'naive_utc'}}}},
            joins => {},
        });
        1;
    } ? undef : $@;
    like $schema_error->message, qr/schemas\.other column id declares storage/,
        'unreferenced schemas are validated too';
};

my $naive = '"s0"."naive"';
my $aware = '"s0"."aware"';
my $naive_instant = qq{($naive AT TIME ZONE 'UTC')};

sub compile_pair {
    my ($engine, $build) = @_;
    my $naive_compiled = $engine->compile($build->('naive'));
    my $aware_compiled = $engine->compile($build->('aware'));
    return ($naive_compiled, $aware_compiled);
}

for my $name (qw(postgresql duckdb)) {
    subtest "$name compiles naive_utc as an instant" => sub {
        my $engine = Selecto::Engine->new(domain => storage_domain(),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
        my $plain = $engine->compile($engine->query->select('naive')->where(
            Selecto::Expression->gte('naive', '2024-01-01')));
        unlike $plain->sql, qr/AT TIME ZONE/, 'without a zone the stored value is read and compared as is';

        my @cases = (
            ['field under a zone', sub { $engine->query->select($_[0])->use_timezone('Asia/Kolkata') }],
            ['filter under a zone', sub { $engine->query->select('id')->where(
                Selecto::Expression->gte($_[0], '2024-01-01'))->use_timezone('Asia/Kolkata') }],
            ['calendar format', sub { $engine->query->select(
                Selecto::Expression->datetime_format($_[0], 'day')->as('d'))->use_timezone('America/Denver') }],
            ($name eq 'postgresql' ? (['year bucket', sub { $engine->query->select(Selecto::Expression->bucket($_[0],
                {kind => 'year_increment', increment => 1})->as('b'))->use_timezone('America/Denver') }],
            ['elapsed days', sub { $engine->query->select(Selecto::Expression->count_bucket($_[0], 0, undef, q{elapsed_days})->as('n'))->use_timezone('America/Denver') }]) : ()),
            ['date shortcut', sub { $engine->query->select('id')->where(
                Selecto::DateShortcut->expression($_[0], 'this_year'))->use_timezone('America/Denver') }],
            map {
                my $format = $_;
                (["$format with a zone", sub { $engine->query->select(
                    Selecto::Expression->datetime_format($_[0], $format)->as('f'))->use_timezone('America/Denver') }],
                 ["$format without a zone", sub { $engine->query->select(
                    Selecto::Expression->datetime_format($_[0], $format)->as('f')) }]);
            } qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds timezone_offset),
        );
        for my $case (@cases) {
            my ($label, $build) = @$case;
            my ($naive_compiled, $aware_compiled) = compile_pair($engine, $build);
            (my $expected = $aware_compiled->sql) =~ s/\Q$aware\E/$naive_instant/g;
            is $naive_compiled->sql, $expected, "$label reads the naive column as an instant";
            is_deeply $naive_compiled->params, $aware_compiled->params, "$label binds the same values";
        }
        my $cast = $engine->compile($engine->query->select('naive_instant'));
        like $cast->sql, qr/CAST\(\Q$naive_instant\E AS TIMESTAMPTZ\)/,
            'casting to utc_datetime reads the naive column as an instant';
        my $joined = $engine->compile($engine->query->select('event.naive')->use_timezone('Asia/Kolkata'));
        like $joined->sql, qr/\(\("j_event"\."naive" AT TIME ZONE 'UTC'\) AT TIME ZONE /,
            'association columns honour their storage';

        my $legacy = Selecto::Engine->new(domain => storage_domain(without_hint => 1),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
        for my $case (@cases) {
            my ($label, $build) = @$case;
            my $naive_compiled = $legacy->compile($build->('naive'));
            my $aware_compiled = $legacy->compile($build->('aware'));
            (my $expected = $aware_compiled->sql) =~ s/\Q$aware\E/$naive/g;
            is $naive_compiled->sql, $expected, "$label is unchanged without the hint";
        }
    };
}

for my $name (qw(sqlite mysql mariadb mssql)) {
    subtest "$name accepts the hint and compiles as before" => sub {
        my $hinted = Selecto::Engine->new(domain => storage_domain(),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
        my $legacy = Selecto::Engine->new(domain => storage_domain(without_hint => 1),
            adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)));
        my $query = sub {
            $_[0]->query->select('naive', 'event.naive')
                ->where(Selecto::Expression->between('naive', '2024-01-01', '2024-12-31'))
                ->order_by('naive');
        };
        is $hinted->compile($query->($hinted))->sql, $legacy->compile($query->($legacy))->sql,
            'SQL is identical with and without the hint';
        my $zoned = eval { $hinted->compile($hinted->query->select('naive')->use_timezone('Asia/Kolkata')); 1 };
        my $error = $@;
        ok !$zoned && blessed($error) && $error->code eq 'unsupported_feature',
            'query timezones remain unsupported';
    };
}

# Live verification: both columns hold the same instants, across Denver's DST
# gap and fold and a Kolkata year boundary.
my @INSTANTS = (
    '2024-03-10 08:30:00', '2024-03-10 09:30:00', '2024-11-03 07:30:00',
    '2024-11-03 08:30:00', '2024-12-31 20:00:00.123456', '1969-12-31 23:59:59.5', undef,
);

sub live_cases {
    my ($name, $dbh) = @_;
    my $domain = storage_domain();
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
    my $handler = Selecto::API::EngineHandler->new;
    for my $zone ('America/Denver', 'Asia/Kolkata', 'UTC') {
        my $raw = $handler->query($engine, {select => [qw(naive aware)], timezone => $zone,
            order_by => [{field => 'id'}]});
        is_deeply [map { $_->[1] } @{$raw->{rows}}], [map { $_->[2] } @{$raw->{rows}}],
            "local wall time in $zone matches";
        for my $format (@{Selecto::DateFormat->choices}) {
            my $result = $handler->query($engine, {timezone => $zone, order_by => [{field => 'id'}],
                select => [{field => 'naive', format => $format->{id}, alias => 'n'},
                    {field => 'aware', format => $format->{id}, alias => 'a'}]});
            is_deeply [map { $_->[1] } @{$result->{rows}}], [map { $_->[2] } @{$result->{rows}}],
                "$format->{id} in $zone matches";
        }
        for my $bucket (
            {kind => 'year_increment', increment => 1},
            {kind => 'date_relative_ranges', ranges => [{minimum => 0, maximum => 400, label => 'recent'}]},
            {kind => 'elapsed_days_ranges', ranges => [{minimum => 0, maximum => 400, label => 'recent'}]},
        ) {
            my $rows = $engine->all($engine->query->select('id',
                Selecto::Expression->bucket('naive', $bucket)->as('n'),
                Selecto::Expression->bucket('aware', $bucket)->as('a'))
                ->order_by('id')->use_timezone($zone))->{rows};
            is_deeply [map { $_->[1] } @$rows], [map { $_->[2] } @$rows], "$bucket->{kind} in $zone matches";
        }
        my $counts = $engine->all($engine->query->select(
            Selecto::Expression->count_bucket(q{naive}, 0, undef, q{elapsed_days})->as('n'),
            Selecto::Expression->count_bucket(q{aware}, 0, undef, q{elapsed_days})->as('a'))
            ->use_timezone($zone))->{rows};
        is $counts->[0][0], $counts->[0][1], "elapsed-day counts in $zone match";
        for my $filter (
            [between => '2024-03-10T01:00:00', '2024-03-10T04:00:00'],
            [between => '2024-11-03T01:00:00', '2024-11-03T02:00:00'],
            [gte => '2025-01-01T00:00:00'],
        ) {
            my ($op, $value, $end) = @$filter;
            my @ids = map {
                my $field = $_;
                [map { $_->[0] } @{$handler->query($engine, {select => ['id'], timezone => $zone,
                    order_by => [{field => 'id'}], filters => [{field => $field, op => $op,
                    value => $value, (defined($end) ? (end => $end) : ())}]})->{rows}}];
            } qw(naive aware);
            is_deeply $ids[0], $ids[1], "$op $value filter in $zone matches";
        }
        for my $shortcut (qw(this_year last_year ytd_all_years)) {
            my @ids = map {
                my $field = $_;
                [map { $_->[0] } @{$engine->all($engine->query->select('id')
                    ->where(Selecto::DateShortcut->expression($field, $shortcut))
                    ->order_by('id')->use_timezone($zone))->{rows}}];
            } qw(naive aware);
            is_deeply $ids[0], $ids[1], "$shortcut shortcut in $zone matches";
        }
    }
    for my $format (qw(iso8601 rfc3339_millis epoch_seconds epoch_milliseconds timezone_offset)) {
        my $result = $handler->query($engine, {order_by => [{field => 'id'}],
            select => [{field => 'naive', format => $format, alias => 'n'},
                {field => 'aware', format => $format, alias => 'a'}]});
        is_deeply [map { $_->[1] } @{$result->{rows}}], [map { $_->[2] } @{$result->{rows}}],
            "$format without a zone matches";
    }
    my $denver = $handler->query($engine, {timezone => 'America/Denver', order_by => [{field => 'id'}],
        select => [{field => 'naive', format => 'rfc3339_millis', alias => 'n'}]});
    is_deeply [map { $_->[1] } @{$denver->{rows}}], [
        '2024-03-10T01:30:00.000-07:00', '2024-03-10T03:30:00.000-06:00',
        '2024-11-03T01:30:00.000-06:00', '2024-11-03T01:30:00.000-07:00',
        '2024-12-31T13:00:00.123-07:00', '1969-12-31T16:59:59.500-07:00', undef,
    ], 'naive UTC renders the expected Denver instants across the DST gap and fold';
    my $kolkata = $handler->query($engine, {timezone => 'Asia/Kolkata', order_by => [{field => 'id'}],
        select => [{field => 'naive', format => 'epoch_seconds', alias => 'n'},
            {field => 'naive', format => 'year', alias => 'y'}]});
    is_deeply [map { [$_->[1], $_->[2]] } @{$kolkata->{rows}}], [
        [1710059400, '2024'], [1710063000, '2024'], [1730619000, '2024'], [1730622600, '2024'],
        [1735675200, '2025'], [-1, '1970'], [undef, undef],
    ], 'naive UTC epochs and Kolkata years are correct';
}

sub populate {
    my ($dbh, $naive_type, $aware_type) = @_;
    $dbh->do("CREATE TEMP TABLE selecto_naive_utc_fixture (id INTEGER, naive $naive_type, aware $aware_type)");
    my $id = 0;
    for my $instant (@INSTANTS) {
        $id++;
        if (defined $instant) {
            $dbh->do("INSERT INTO selecto_naive_utc_fixture VALUES ($id, CAST('$instant' AS $naive_type), " .
                "CAST('$instant+00' AS $aware_type))");
        } else {
            $dbh->do("INSERT INTO selecto_naive_utc_fixture VALUES ($id, NULL, NULL)");
        }
    }
}

subtest 'PostgreSQL live naive_utc storage' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && length $url;
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };
    my ($user, $password, $host, $port, $database) = $url =~
        m{\Apostgres(?:ql)?://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/]*)(?::(\d+))?/([^?]+)}
        or plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not a postgres:// URL';
    my $dbh = DBI->connect("dbi:Pg:dbname=$database" . (length($host) ? ";host=$host" : '') .
        (defined($port) ? ";port=$port" : ''), $user, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    # A session zone far from UTC proves results do not depend on it.
    $dbh->do(q{SET TIME ZONE 'Pacific/Honolulu'});
    populate($dbh, 'TIMESTAMP', 'TIMESTAMPTZ');
    live_cases('postgresql', $dbh);
    $dbh->disconnect;
};

subtest 'DuckDB live naive_utc storage' => sub {
    plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBI; require DBD::DuckDB; 1 };
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do(q{SET TimeZone = 'Pacific/Honolulu'});
    populate($dbh, 'TIMESTAMP', 'TIMESTAMPTZ');
    live_cases('duckdb', $dbh);
    $dbh->disconnect;
};

done_testing;
