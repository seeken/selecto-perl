use 5.034;
use strict;
use warnings;
use B ();
use Test::More;
use DBI ();
use JSON::PP ();
use Mojo::JSON ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::PostgreSQL ();

# Canonical values are decoded in Perl by default (canonical_sql => 0); the
# opt-in canonical_sql => 1 formats some of them in SQL. Both paths run here.
# Canonical values formatted in SQL must be exactly the values the Perl
# decode makes from the driver's text: same definedness, same string, same
# Perl number/string/UTF-8 flags and the same JSON, for a wide corpus of
# NUMERIC, REAL, DOUBLE PRECISION, DATE, TIMESTAMP and TIMESTAMPTZ values
# under several DateStyle, TimeZone and extra_float_digits settings, and in
# the same row order. The one accepted difference: a column formatted in SQL
# is the ISO form whatever the DateStyle, so under a non-ISO DateStyle it
# equals the Perl decode under ISO (same TimeZone). Driver values (the
# default) must be exactly what DBD::Pg returns.

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
sub connect_db {
    return DBI->connect($dsn, $username, $password, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1,
    });
}
my $dbh = connect_db();
my $version = $dbh->{pg_server_version};
my $table = 'selecto_perl_test_canonical';
$dbh->do("DROP TABLE IF EXISTS $table");
$dbh->do("CREATE TABLE $table (id integer primary key, grp text, n numeric, n4 numeric(12,4),
    n0 numeric(10,0), f4 real, f8 double precision, ts timestamp, tstz timestamptz, d date,
    b boolean, i8 bigint)");

my @numeric = ('0', '-0', '0.000', '1', '-1', '1.500', '10.500', '9.5', '100', '1000.000', '0.0001',
    '-0.0001000', '123456789012345678901234567890.123456789000', '0.00000000000000000001',
    '-98765432109876543210.5000', '5.0', '50', '-50.10', '1e30', '2.5e-5', 'NaN',
    ($version >= 140000 ? ('Infinity', '-Infinity') : ()), undef);
my @numeric4 = ('1', '1.5', '-0.5', '0', '12345678.1234', '-0.0001', '7.1000', undef);
my @numeric0 = ('42', '0', '-7', '9999999999', undef);
my @float8 = ('0', '-0', '1.5', '100', '1e20', '1e-7', '1.0e-10', '0.1', '123456.789', '1e15', '1e16',
    '1e17', '-2.5', '0.30000000000000004', '2.2250738585072014e-308', '4.9e-324',
    '1.7976931348623157e308', '-1.5e-300', '10', '9.5', 'NaN', 'Infinity', '-Infinity', undef);
my @float4 = ('0', '-0', '0.1', '1.5', '3.4028235e38', '1.4e-45', '1e10', '100', '-7.25', '16777217',
    'NaN', 'Infinity', '-Infinity', undef);
my @timestamp = ('2024-01-01 00:00:00', '2024-01-01 10:20:30.5', '2024-01-01 10:20:30.123456',
    '2024-02-29 23:59:59.999999', '1900-01-01 00:00:00.000001', '0044-03-15 12:00:00 BC',
    '4713-01-01 00:00:00 BC', '294276-12-31 23:59:59.999999', '1999-12-31 23:59:59.1',
    '0001-01-01 00:00:00', '0001-12-31 23:59:59.5 BC', '9999-12-31 23:59:59', '10000-01-01 00:00:00.25',
    'infinity', '-infinity', undef);
my @timestamptz = ('2024-01-01 00:00:00+00', '2024-06-01 12:34:56.789+05:30', '2024-06-01 12:34:56+00',
    '1930-06-01 12:00:00+00', '1850-01-01 00:00:00+00', '1880-01-01 00:00:00+00',
    '2024-03-10 07:00:00.5+00', '2024-11-03 06:30:00+00', '0044-03-15 12:00:00+00 BC',
    '2000-01-01 00:00:00.000001+00', '1971-06-01 10:00:00.25+00', '1972-01-07 00:44:29+00',
    '1972-01-07 00:44:30+00', '1972-01-08 00:00:00+00', '1937-06-30 12:00:00+00', '1969-12-31 23:59:59.999+00',
    '0001-01-01 00:30:00+00', '0001-01-01 23:00:00+00', '0001-12-31 22:00:00+00 BC',
    '10000-01-01 00:00:00+00', 'infinity', '-infinity', undef);
my @date = ('2024-01-01', '0044-03-15 BC', '0001-01-01', '0001-12-31 BC', '10000-02-29', '1999-12-31',
    'infinity', '-infinity', undef);
my @groups = ('alpha', 'beta', 'gamma', undef);

my $rows = 64;
my $insert = $dbh->prepare("INSERT INTO $table VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12)");
for my $id (1 .. $rows) {
    my $pick = sub { my ($list, $step) = @_; return $list->[($id * $step) % @$list]; };
    $insert->execute($id, $pick->(\@groups, 1), $pick->(\@numeric, 1), $pick->(\@numeric4, 3),
        $pick->(\@numeric0, 2), $pick->(\@float4, 5), $pick->(\@float8, 1), $pick->(\@timestamp, 7),
        $pick->(\@timestamptz, 5), $pick->(\@date, 4), ($id % 3 == 0 ? undef : $id % 2 ? 1 : 0),
        ($id % 5 == 0 ? undef : $id * 1_000_000_007 - 31_000_000_000));
}

# real and double precision are declared float (not a portable type): only
# decimal fields are formatted in SQL; see the declared-type subtest.
my %types = (id => 'integer', grp => 'string', n => 'decimal', n4 => 'decimal', n0 => 'decimal',
    f4 => 'float', f8 => 'float', ts => 'naive_datetime', tstz => 'utc_datetime', d => 'date',
    b => 'boolean', i8 => 'integer');
my $domain = TestSelecto::writable_domain(name => 'Canonical', table => $table, fields => \%types);

my $FLAGS = B::SVf_IOK() | B::SVf_NOK() | B::SVf_POK() | B::SVf_ROK() | B::SVf_UTF8();
sub shape {
    my ($value) = @_;
    return 'undef' unless defined $value;
    return sprintf('%s/%x', $value, B::svref_2object(\$value)->FLAGS & $FLAGS);
}
my $json = JSON::PP->new->canonical->allow_nonref;
sub same_rows {
    my ($got, $expected, $label) = @_;
    my @mismatch;
    for my $r (0 .. ($#$expected > $#$got ? $#$expected : $#$got)) {
        for my $c (0 .. $#{$expected->[$r] // []}) {
            my ($g, $e) = ($got->[$r][$c], $expected->[$r][$c]);
            push @mismatch, "row $r col $c: " . shape($g) . ' vs ' . shape($e)
                unless shape($g) eq shape($e);
        }
    }
    ok(!@mismatch && @$got == @$expected, $label) or diag join("\n", @mismatch[0 .. ($#mismatch > 9 ? 9 : $#mismatch)]);
    is(Mojo::JSON::encode_json($got), Mojo::JSON::encode_json($expected), "$label (Mojo::JSON)");
    is($json->encode($got), $json->encode($expected), "$label (JSON::PP)");
}


my $x = 'Selecto::Expression';
sub engine_for {
    my ($handle, %attributes) = @_;
    return Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter(postgresql => (dbh => $handle, %attributes)));
}
my $sql_engine = engine_for($dbh, canonical_values => 1, canonical_sql => 1);
my $perl_engine = engine_for($dbh, canonical_values => 1);   # the default: decoded in Perl
my $raw_engine = engine_for($dbh);
my $raw_sql_engine = engine_for($dbh, canonical_sql => 1);
my $FORMATTED = qr/pg_catalog\.(?:to_char|trim_scale)\(/;

my @columns = qw(id grp n n4 n0 f4 f8 ts tstz d b i8);
my %queries = (
    all_columns => $sql_engine->query->select(@columns)->order_by('id'),
    numeric_order => $sql_engine->query->select('n', 'id', 'f8')->order_by('n', 'desc')->order_by('id'),
    float_order_page => $sql_engine->query->select('f8', 'f4', 'id')->order_by('f8')->order_by('id')->limit(20)->offset(3),
    timestamp_order => $sql_engine->query->select('tstz', 'ts', 'd', 'id')->order_by('tstz', 'desc')->order_by('ts')
        ->order_by('d')->order_by('id'),
    aliases => $sql_engine->query->select($x->field('n')->as('id'), $x->field('id')->as('n'), $x->field('ts')->as('label'),
        $x->field('d')->as('day'))->order_by('n')->order_by('id'),
    grouped => $sql_engine->query->select('grp', $x->sum('n')->as('sum_n'), $x->avg('i8')->as('avg_i8'),
        $x->max('tstz')->as('max_tstz'), $x->min('ts')->as('min_ts'), $x->sum('f8')->as('sum_f8'),
        $x->avg('n4')->as('avg_n4'), $x->max('f4')->as('max_f4'))
        ->where($x->not_null('n'))->group_by('grp')->order_by($x->sum('n'), 'desc')->order_by('grp'),
    grouped_fields => $sql_engine->query->select('d', 'n0', $x->count('id')->as('count'))
        ->group_by('d', 'n0')->order_by('d')->order_by('n0'),
    window => $sql_engine->query->select('id', 'n4', 'tstz',
        $x->window('sum', ['n4'], order_by => [['id', 'asc']])->as('running'),
        $x->window('max', ['ts'], partition_by => ['grp'])->as('latest'))->order_by('id'),
    timezone => $sql_engine->query->select('id', 'tstz', 'ts', 'd')->use_timezone('America/New_York')
        ->order_by('tstz')->order_by('id'),
    rollup => $sql_engine->query->select('grp', $x->sum('n4')->as('total'))->group_by_rollup('grp'),
    rollup_fields => $sql_engine->query->select('d', $x->count('id')->as('count'))->group_by_rollup('d'),
    ordered_rollup => $sql_engine->query->select('grp', $x->sum('n4')->as('total'))->group_by_rollup('grp')
        ->order_by('grp'),
    empty => $sql_engine->query->select('n', 'tstz')->where($x->eq('id', -1)),
);
my %unformatted = map { $_ => 1 } qw(float_order_page grouped rollup ordered_rollup);

my @settings = (
    ['UTC', 'ISO, MDY', 1],
    ['America/New_York', 'ISO, MDY', 1],
    ['Asia/Kolkata', 'ISO, DMY', 0],
    ['Europe/Amsterdam', 'ISO, YMD', 3],
    ['America/Chicago', 'ISO, MDY', 1],
    ['Africa/Monrovia', 'ISO, MDY', 1],
    ['Europe/London', 'SQL, DMY', -15],
    ['Australia/Lord_Howe', 'Postgres, MDY', 2],
    ['Etc/GMT+0', 'German, DMY', 1],
    ['UTC', 'SQL, MDY', 0],
    ['Pacific/Chatham', 'Postgres, DMY', -2],
    ['Africa/Monrovia', 'German, DMY', 1],
);

sub session {
    my ($handle, $zone, $style, $digits) = @_;
    $handle->do('SET TimeZone = ' . $handle->quote($zone));
    $handle->do('SET DateStyle = ' . $handle->quote($style));
    $handle->do("SET extra_float_digits = $digits");
}

for my $setting (@settings) {
    my ($zone, $style, $digits) = @$setting;
    my ($order) = $style =~ /, (\w+)\z/;
    my $iso = $style =~ /\AISO/ ? 1 : 0;
    subtest "TimeZone $zone, DateStyle $style, extra_float_digits $digits" => sub {
        for my $name (sort keys %queries) {
            my $query = $queries{$name};
            my $statement = $sql_engine->compile($query);
            my %formatted = map { $_ => 1 } $sql_engine->adapter->_canonical_columns($statement);
            # Formatted columns are ISO whatever the DateStyle: the Perl decode
            # under ISO. Columns decoded in Perl follow the session DateStyle.
            session($dbh, $zone, "ISO, $order", $digits);
            my $iso_rows = $perl_engine->all($query)->{rows};
            session($dbh, $zone, $style, $digits);
            my $same_rows = $perl_engine->all($query)->{rows};
            my $expected = [map {
                my $r = $_;
                [map { $formatted{$_} ? $iso_rows->[$r][$_] : $same_rows->[$r][$_] } 0 .. $#{$same_rows->[$r]}]
            } 0 .. $#$same_rows];
            my $got = $sql_engine->all($query)->{rows};
            my $ran_formatted = $dbh->{Statement} =~ $FORMATTED ? 1 : 0;
            is($ran_formatted, $unformatted{$name} ? 0 : 1,
                "$name " . ($unformatted{$name} ? 'decoded in Perl' : 'ran formatted SQL'));
            same_rows($got, $expected, "$name: SQL canonical values equal the Perl decode"
                . ($iso ? '' : ' (ISO in the formatted columns)'));
            my $driver = $dbh->selectall_arrayref($statement->sql, undef, @{$statement->params});
            same_rows($raw_engine->all($query)->{rows}, $driver, "$name: default rows are the driver values");
            next unless $iso;
            my $decoded = $dbh->selectall_arrayref($statement->sql, undef, @{$statement->params});
            my $sth = $dbh->prepare($statement->sql);
            $sth->execute(@{$statement->params});
            my @types = @{$sth->{pg_type}};
            $sth->finish;
            $perl_engine->adapter->_decode_rows($decoded, \@types);
            same_rows($got, $decoded, "$name: equal to _decode_rows over the driver values");
        }
        $dbh->do('RESET TimeZone');
        $dbh->do('RESET DateStyle');
        $dbh->do('RESET extra_float_digits');
    };
}

subtest 'no time zone offset has seconds after the fast-path cutoff' => sub {
    # The timestamptz fast path uses TO_CHAR's OF, which has no seconds; it
    # starts after Africa/Monrovia's -00:44:30 ended on 1972-01-07.
    my ($zones) = $dbh->selectrow_array(q{
        SELECT string_agg(DISTINCT z.name, ', ')
        FROM pg_catalog.pg_timezone_names z,
             pg_catalog.generate_series(TIMESTAMPTZ '1972-01-08 00:00:00+00', TIMESTAMPTZ '2040-01-01 00:00:00+00',
                 INTERVAL '29 days') AS g
        WHERE CAST(EXTRACT(EPOCH FROM (g AT TIME ZONE z.name) - (g AT TIME ZONE 'UTC')) AS INTEGER) % 60 <> 0});
    is($zones, undef, 'none in the tz database');
};

subtest 'the formatted SQL sorts and groups the underlying values' => sub {
    my $query = $sql_engine->query->select('n', 'id')->where($x->in('id', [map { $_ } 1 .. $rows]))
        ->order_by('n')->order_by('id');
    my $got = [map { $_->[0] } @{$sql_engine->all($query)->{rows}}];
    like($dbh->{Statement}, $FORMATTED, 'formatted');
    unlike($dbh->{Statement}, qr/ORDER BY (?:\d|"n")/, 'ordered by the expression, never by position or name');
    my $perl = [map { $_->[0] } @{$perl_engine->all($query)->{rows}}];
    is_deeply($got, $perl, 'same order as the unformatted statement');
    my @defined = grep { defined && $_ =~ /\A-?\d/ } @$got;
    isnt(join(',', sort @defined), join(',', @defined), 'which is not the order of the text');
    $dbh->do(q{SET DateStyle = 'SQL, DMY'});
    my $days = $sql_engine->query->select('d', $x->count('id')->as('count'))->group_by('d')->order_by('d');
    my $grouped = $sql_engine->all($days)->{rows};
    like($dbh->{Statement}, qr/GROUP BY "s0"\."d" ORDER BY "s0"\."d"/, 'grouped and ordered by the column');
    $dbh->do('RESET DateStyle');
    my @dates = map { $_->[0] } @$grouped;
    is_deeply(\@dates, [map { $_->[0] } @{$perl_engine->all($days)->{rows}}], 'dates in date order');
    my @finite = grep { defined && !/infinity|BC/ } @dates;
    isnt(join(',', @finite), join(',', sort @finite), 'which is not the order of the text');
};

subtest 'every result is formatted, whatever its size' => sub {
    my $few = $sql_engine->query->select('id', 'n', 'ts')->where($x->lte('id', 3))->order_by('id');
    same_rows($sql_engine->all($few)->{rows}, $perl_engine->all($few)->{rows}, 'three rows');
    $sql_engine->all($few);
    like($dbh->{Statement}, $FORMATTED, 'formatted on the first run');
};

subtest 'streams' => sub {
    my $query = $queries{all_columns};
    my $collect = sub { my ($stream) = @_; my @out; while (my $row = $stream->next) { push @out, $row } return \@out; };
    my $expected = $perl_engine->all($query)->{rows};
    same_rows($collect->($raw_engine->stream($query)), $raw_engine->all($query)->{rows}, 'a stream holds driver values by default');
    same_rows($collect->($raw_engine->stream($query, bounded => 1, fetch_size => 7)),
        $raw_engine->all($query)->{rows}, 'a bounded stream holds driver values by default');
    same_rows($collect->($raw_engine->stream($query, canonical_values => 1)), $expected,
        'canonical_values => 1 streams canonical values, decoded in Perl by default');
    unlike($dbh->{Statement}, $FORMATTED, 'from the unformatted statement');
    same_rows($collect->($raw_engine->stream($query, bounded => 1, fetch_size => 7, canonical_values => 1)),
        $expected, 'and so does a bounded stream');
    require Selecto::BoundedQuery;
    same_rows(Selecto::BoundedQuery->all($raw_engine, $query, max_rows => 1000, max_cell_bytes => 1000,
        canonical_values => 1)->{rows}, $expected, 'and BoundedQuery');
    # Under a non-ISO DateStyle the Perl decode shows the session style, as it
    # always has; only SQL formatting gives ISO dates.
    $dbh->do(q{SET DateStyle = 'German, DMY'});
    my $german = $perl_engine->all($query)->{rows};
    ok((grep { defined($_->[9]) && $_->[9] =~ /\A\d\d\.\d\d\.\d{4}/ } @$german),
        'the default canonical dates follow a German DateStyle');
    same_rows($collect->($raw_engine->stream($query, canonical_values => 1)), $german,
        'a canonical stream decoded in Perl follows the session DateStyle');
    same_rows($collect->($raw_sql_engine->stream($query, canonical_values => 1)), $expected,
        'with canonical_sql => 1 canonical_values => 1 streams canonical values, formatted in SQL');
    same_rows($collect->($raw_sql_engine->stream($query, bounded => 1, fetch_size => 7, canonical_values => 1)),
        $expected, 'and so does a bounded stream');
    my $bounded = Selecto::BoundedQuery->all($raw_sql_engine, $query, max_rows => 1000, max_cell_bytes => 1000,
        canonical_values => 1);
    same_rows($bounded->{rows}, $expected, 'and BoundedQuery');
    $dbh->do('RESET DateStyle');
};

subtest 'statement cache' => sub {
    my $cached = connect_db();
    my $engine = engine_for($cached, canonical_values => 1, statement_cache => 1, canonical_sql => 1);
    my $perl = engine_for($cached, canonical_values => 1, statement_cache => 1);
    for my $name (qw(all_columns grouped timezone)) {
        my $expected = $perl_engine->all($queries{$name})->{rows};
        same_rows($engine->all($queries{$name})->{rows}, $expected, "$name, run $_ (SQL)") for 1 .. 3;
        same_rows($perl->all($queries{$name})->{rows}, $expected, "$name, run $_ (Perl)") for 1 .. 3;
    }
    $cached->disconnect;
};

subtest 'declared types' => sub {
    my $handle = connect_db();
    $handle->do(q{SET TimeZone = 'America/Chicago'});
    my $other = 'selecto_perl_test_canonical_declared';
    $handle->do("DROP TABLE IF EXISTS $other");
    $handle->do("DROP DOMAIN IF EXISTS selecto_perl_test_amount");
    $handle->do("CREATE DOMAIN selecto_perl_test_amount AS numeric(10,2)");
    $handle->do("CREATE TABLE $other (id integer primary key, money selecto_perl_test_amount, naive timestamp,
        naive_utc timestamp, aware timestamptz, day date, text_day varchar(20), text_amount text,
        f8 double precision, i4 integer)");
    $handle->do(q{INSERT INTO } . $other . q{ VALUES
        (1, 1.50, '2024-01-01 10:00:00.5', '2024-01-01 10:00:00', '2024-06-01 12:00:00+00', '2024-02-29',
            '2024-01-01', '1.50', 0.5, 7),
        (2, 3, '0044-03-15 12:00:00 BC', '1850-01-01 00:00:00', '1850-01-01 00:00:00+00', '0044-03-15 BC',
            'not a day', 'x', 1e20, -2),
        (3, NULL, NULL, 'infinity', 'infinity', NULL, NULL, NULL, NULL, NULL)});
    my $make = sub {
        my (%attributes) = @_;
        return Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $handle, canonical_values => 1,
            canonical_sql => 1, %attributes)), domain => TestSelecto::writable_domain(name => 'Declared', table => $other,
            fields => {id => 'integer', money => 'decimal', naive => 'utc_datetime', naive_utc => 'utc_datetime',
                aware => 'naive_datetime', day => 'utc_datetime', text_day => 'date', text_amount => 'decimal',
                f8 => 'decimal', i4 => 'decimal'}));
    };
    my ($engine, $perl) = ($make->(), $make->(canonical_sql => 0));
    my $query = $engine->query->select(qw(id money naive naive_utc aware day text_day text_amount))->order_by('id');
    my $got = $engine->all($query)->{rows};
    like($handle->{Statement}, $FORMATTED, 'formatted in SQL');
    same_rows($got, $perl->all($query)->{rows}, 'the column type picks the formatter: a domain over NUMERIC, '
        . 'timestamps declared as the other kind or as a date, and text declared date or decimal');
    my $zoned = $query->use_timezone('Asia/Kolkata');
    same_rows($engine->all($zoned)->{rows}, $perl->all($zoned)->{rows}, 'under a query timezone');
    my $mismatched = $engine->query->select('id', 'f8', 'i4')->order_by('id');
    is_deeply($engine->all($mismatched)->{rows}, [[1, '0.5', '7'], [2, '1e+20', '-2'], [3, undef, undef]],
        'float and integer columns declared decimal come out as their PostgreSQL text');
    is_deeply($perl->all($mismatched)->{rows}, [[1, '0.5', 7], [2, '1e+20', -2], [3, undef, undef]],
        'where the Perl decode gives integers as numbers');

    $handle->do("DROP TABLE $other");
    my $error = eval { $engine->all($query); 1 } ? undef : $@;
    my $perl_error = eval { $perl->all($query); 1 } ? undef : $@;
    ok($error && $perl_error, 'a missing table fails both ways');
    is($error->code, $perl_error->code, 'with the same code');
    is_deeply($error->details, $perl_error->details, 'and the same details, SQLSTATE included');
    is($error->details->{sqlstate}, '42P01', 'undefined_table');
    $handle->do("DROP DOMAIN selecto_perl_test_amount");
    $handle->disconnect;
};

subtest 'formatting is opt-in and version-gated' => sub {
    my $query = $queries{numeric_order};
    $perl_engine->all($query);
    unlike($dbh->{Statement}, $FORMATTED, 'by default canonical values are decoded in Perl');
    is($perl_engine->adapter->canonical_sql, 0, 'canonical_sql is 0 by default');
    is_deeply([$perl_engine->adapter->_canonical_columns($perl_engine->compile($queries{all_columns}))], [],
        'and nothing is formatted');
    $raw_sql_engine->all($query, canonical_values => 1);
    like($dbh->{Statement}, $FORMATTED, 'canonical_sql => 1 formats in SQL');
    $raw_sql_engine->all($query);
    unlike($dbh->{Statement}, $FORMATTED, 'only when canonical values are asked for');
    my $statement = $sql_engine->compile($queries{all_columns});
    is_deeply([$sql_engine->adapter->_canonical_columns($statement)], [2, 3, 4, 7, 8, 9],
        'numeric, timestamp, timestamptz and date columns are formatted');
    no warnings 'redefine';
    local *Selecto::PostgreSQL::_canonical_server_version = sub { 120000 };
    is_deeply([$sql_engine->adapter->_canonical_columns($statement)], [7, 8, 9], 'numeric is not before PostgreSQL 13');
    my $sql = $sql_engine->adapter->_canonical_statement($statement)->sql;
    unlike($sql, qr/trim_scale/, 'no trim_scale');
    same_rows($sql_engine->all($queries{all_columns})->{rows}, $perl_engine->all($queries{all_columns})->{rows},
        'numeric decoded in Perl');
};

$dbh->do("DROP TABLE IF EXISTS $table");
done_testing;
