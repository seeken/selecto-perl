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

# Canonical values formatted in SQL must be exactly the values the Perl
# decode makes from the driver's text: same definedness, same string, same
# Perl number/string/UTF-8 flags and the same JSON, for a wide corpus of
# NUMERIC, REAL, DOUBLE PRECISION, TIMESTAMP and TIMESTAMPTZ values under
# several DateStyle, TimeZone and extra_float_digits settings, and in the same
# row order. Driver values (the default) must be exactly what DBD::Pg returns.

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
    'infinity', '-infinity', undef);
my @timestamptz = ('2024-01-01 00:00:00+00', '2024-06-01 12:34:56.789+05:30', '2024-06-01 12:34:56+00',
    '1930-06-01 12:00:00+00', '1850-01-01 00:00:00+00', '1880-01-01 00:00:00+00',
    '2024-03-10 07:00:00.5+00', '2024-11-03 06:30:00+00', '0044-03-15 12:00:00+00 BC',
    '2000-01-01 00:00:00.000001+00', 'infinity', '-infinity', undef);
my @date = ('2024-01-01', '0044-03-15 BC', 'infinity', undef);
my @groups = ('alpha', 'beta', 'gamma', undef);

my $rows = 64;
my $insert = $dbh->prepare("INSERT INTO $table VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12)");
for my $id (1 .. $rows) {
    my $pick = sub { my ($list, $step) = @_; return $list->[($id * $step) % @$list]; };
    $insert->execute($id, $pick->(\@groups, 1), $pick->(\@numeric, 1), $pick->(\@numeric4, 3),
        $pick->(\@numeric0, 2), $pick->(\@float4, 5), $pick->(\@float8, 1), $pick->(\@timestamp, 7),
        $pick->(\@timestamptz, 5), $pick->(\@date, 3), ($id % 3 == 0 ? undef : $id % 2 ? 1 : 0),
        ($id % 5 == 0 ? undef : $id * 1_000_000_007 - 31_000_000_000));
}

my %types = (id => 'integer', grp => 'string', n => 'decimal', n4 => 'decimal', n0 => 'decimal',
    f4 => 'decimal', f8 => 'decimal', ts => 'naive_datetime', tstz => 'utc_datetime', d => 'date',
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
# The corpus is small; format every result in SQL, whatever its size.
$Selecto::PostgreSQL::CANONICAL_SQL_MIN_ROWS = 0;
sub engine_for {
    my ($handle, %attributes) = @_;
    return Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter(postgresql => (dbh => $handle, %attributes)));
}
my $sql_engine = engine_for($dbh, canonical_values => 1);
my $perl_engine = engine_for($dbh, canonical_values => 1, canonical_sql => 0);
my $raw_engine = engine_for($dbh);

my @columns = qw(id grp n n4 n0 f4 f8 ts tstz d b i8);
my %queries = (
    all_columns => $sql_engine->query->select(@columns)->order_by('id'),
    numeric_order => $sql_engine->query->select('n', 'id', 'f8')->order_by('n', 'desc')->order_by('id'),
    float_order_page => $sql_engine->query->select('f8', 'f4', 'id')->order_by('f8')->order_by('id')->limit(20)->offset(3),
    timestamp_order => $sql_engine->query->select('tstz', 'ts', 'id')->order_by('tstz', 'desc')->order_by('ts')->order_by('id'),
    aliases => $sql_engine->query->select($x->field('n')->as('id'), $x->field('id')->as('n'), $x->field('ts')->as('label'))
        ->order_by('n')->order_by('id'),
    grouped => $sql_engine->query->select('grp', $x->sum('n')->as('sum_n'), $x->avg('i8')->as('avg_i8'),
        $x->max('tstz')->as('max_tstz'), $x->min('ts')->as('min_ts'), $x->sum('f8')->as('sum_f8'),
        $x->avg('n4')->as('avg_n4'), $x->max('f4')->as('max_f4'))
        ->where($x->not_null('n'))->group_by('grp')->order_by($x->sum('n'), 'desc')->order_by('grp'),
    window => $sql_engine->query->select('id', 'n4',
        $x->window('sum', ['n4'], order_by => [['id', 'asc']])->as('running'),
        $x->window('max', ['ts'], partition_by => ['grp'])->as('latest'))->order_by('id'),
    timezone => $sql_engine->query->select('id', 'tstz', 'ts')->use_timezone('America/New_York')->order_by('tstz')->order_by('id'),
    rollup => $sql_engine->query->select('grp', $x->sum('n4')->as('total'))->group_by_rollup('grp'),
    empty => $sql_engine->query->select('n', 'tstz')->where($x->eq('id', -1)),
);

my @settings = (
    ['UTC', 'ISO, MDY', 1],
    ['America/New_York', 'ISO, MDY', 1],
    ['Asia/Kolkata', 'ISO, DMY', 0],
    ['Europe/Amsterdam', 'ISO, YMD', 3],
    ['Europe/London', 'SQL, DMY', -15],
    ['Australia/Lord_Howe', 'Postgres, MDY', 2],
    ['Etc/GMT+0', 'German, DMY', 1],
    ['UTC', 'SQL, MDY', 0],
    ['Pacific/Chatham', 'Postgres, DMY', -2],
);

for my $setting (@settings) {
    my ($zone, $style, $digits) = @$setting;
    subtest "TimeZone $zone, DateStyle $style, extra_float_digits $digits" => sub {
        $dbh->do('SET TimeZone = ' . $dbh->quote($zone));
        $dbh->do('SET DateStyle = ' . $dbh->quote($style));
        $dbh->do("SET extra_float_digits = $digits");
        for my $name (sort keys %queries) {
            my $query = $queries{$name};
            my $expected = $perl_engine->all($query)->{rows};
            $sql_engine->all($query);  # learns the result types of this SQL text
            my $got = $sql_engine->all($query)->{rows};
            my $formatted = $dbh->{Statement} =~ /pg_catalog\.pg_typeof/ ? 1 : 0;
            ok($formatted, "$name ran formatted SQL") unless $name eq 'empty' || $name eq 'float_order_page';
            same_rows($got, $expected, "$name: SQL canonical values equal the Perl decode");
            my $statement = $raw_engine->compile($query);
            my $driver = $dbh->selectall_arrayref($statement->sql, undef, @{$statement->params});
            same_rows($raw_engine->all($query)->{rows}, $driver, "$name: default rows are the driver values");
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

subtest 'the formatted SQL sorts the underlying values' => sub {
    my $query = $sql_engine->query->select('n', 'id')->where($x->in('id', [map { $_ } 1 .. $rows]))
        ->order_by('n')->order_by('id');
    $sql_engine->all($query);
    my $got = [map { $_->[0] } @{$sql_engine->all($query)->{rows}}];
    my $perl = [map { $_->[0] } @{$perl_engine->all($query)->{rows}}];
    is_deeply($got, $perl, 'same order as the unformatted statement');
    my @defined = grep { defined && $_ =~ /\A-?\d/ } @$got;
    isnt(join(',', sort @defined), join(',', @defined), 'which is not the order of the text');
};

subtest 'streams' => sub {
    my $query = $queries{all_columns};
    my $collect = sub { my ($stream) = @_; my @out; while (my $row = $stream->next) { push @out, $row } return \@out; };
    same_rows($collect->($raw_engine->stream($query)), $raw_engine->all($query)->{rows}, 'a stream holds driver values by default');
    same_rows($collect->($raw_engine->stream($query, canonical_values => 1)), $perl_engine->all($query)->{rows},
        'canonical_values => 1 streams canonical values');
    same_rows($collect->($raw_engine->stream($query, bounded => 1, fetch_size => 7, canonical_values => 1)),
        $perl_engine->all($query)->{rows}, 'and so does a bounded stream');
    same_rows($collect->($raw_engine->stream($query, bounded => 1, fetch_size => 7)),
        $raw_engine->all($query)->{rows}, 'a bounded stream holds driver values by default');
};

subtest 'statement cache' => sub {
    my $cached = connect_db();
    my $engine = engine_for($cached, canonical_values => 1, statement_cache => 1);
    my $query = $queries{grouped};
    my $expected = $perl_engine->all($query)->{rows};
    same_rows($engine->all($query)->{rows}, $expected, "first execution, run $_") for 1 .. 3;
    $cached->disconnect;
};

subtest 'a changed column type is caught and decoded in Perl' => sub {
    my $handle = connect_db();
    $handle->do(q{SET TimeZone = 'UTC'});
    my $drift = 'selecto_perl_test_canonical_drift';
    $handle->do("DROP TABLE IF EXISTS $drift");
    $handle->do("DROP DOMAIN IF EXISTS selecto_perl_test_amount");
    $handle->do("CREATE DOMAIN selecto_perl_test_amount AS numeric(10,2)");
    $handle->do("CREATE TABLE $drift (id integer primary key, amount numeric, at timestamptz, money selecto_perl_test_amount)");
    $handle->do("INSERT INTO $drift VALUES (1, NULL, NULL, 1.50), (2, 2.50, '2024-01-01 00:00:00+00', 3)");
    my $drift_domain = TestSelecto::writable_domain(name => 'Drift', table => $drift,
        fields => {id => 'integer', amount => 'decimal', at => 'utc_datetime', money => 'decimal'});
    my $engine = Selecto::Engine->new(domain => $drift_domain,
        adapter => Selecto->adapter(postgresql => (dbh => $handle, canonical_values => 1)));
    my $perl = Selecto::Engine->new(domain => $drift_domain,
        adapter => Selecto->adapter(postgresql => (dbh => $handle, canonical_values => 1, canonical_sql => 0)));
    my $query = $engine->query->select('id', 'amount', 'at', 'money')->order_by('id');
    $engine->all($query);
    # CASE resolves a domain to its base type, so a domain over NUMERIC is
    # formatted like NUMERIC (trim_scale reads the same value).
    my $formatted = $engine->all($query)->{rows};
    like($handle->{Statement}, qr/pg_typeof/, 'formatted in SQL');
    same_rows($formatted, $perl->all($query)->{rows}, 'a domain over NUMERIC');
    my $sql = $engine->compile($query)->sql;
    my $entry = $handle->{private_selecto_canonical_types}{$sql};
    is_deeply($entry->{blocked}, {}, 'nothing is blocked');

    $handle->do("ALTER TABLE $drift ALTER COLUMN amount TYPE text USING round(amount)::text");
    $handle->do("ALTER TABLE $drift ALTER COLUMN at TYPE date USING at::date");
    same_rows($engine->all($query)->{rows}, $perl->all($query)->{rows},
        'NUMERIC to TEXT and TIMESTAMPTZ to DATE, with NULL first rows, without a parse error');
    is_deeply($entry->{blocked}, {1 => 1, 2 => 1}, 'the changed columns are no longer formatted');
    my $later = $engine->all($query)->{rows};
    like($handle->{Statement}, qr/pg_typeof/, 'the unchanged column still is');
    is_deeply($perl->all($query)->{rows}[1], [2, '3', '2024-01-01', '3'], 'values typed as the new columns');
    same_rows($engine->all($query)->{rows}, $perl->all($query)->{rows}, 'a later run');

    $handle->do("DROP TABLE $drift");
    my $error = eval { $engine->all($query); 1 } ? undef : $@;
    my $perl_error = eval { $perl->all($query); 1 } ? undef : $@;
    ok($error && $perl_error, 'a missing table fails both ways');
    is($error->code, $perl_error->code, 'with the same code');
    is_deeply($error->details, $perl_error->details, 'and the same details, SQLSTATE included');
    is($error->details->{sqlstate}, '42P01', 'undefined_table');
    $handle->do("DROP DOMAIN selecto_perl_test_amount");
    $handle->disconnect;
};

subtest 'small results decode in Perl' => sub {
    local $Selecto::PostgreSQL::CANONICAL_SQL_MIN_ROWS = 65;
    my $query = $sql_engine->query->select('id', 'n')->order_by('id');
    $sql_engine->all($query) for 1 .. 2;
    unlike($dbh->{Statement}, qr/pg_typeof/, 'a result below the threshold is not formatted in SQL');
    local $Selecto::PostgreSQL::CANONICAL_SQL_MIN_ROWS = 64;
    $sql_engine->all($query);
    like($dbh->{Statement}, qr/pg_typeof/, 'one at the threshold is');
    my $few = $query->where($x->lte('id', 3));
    $sql_engine->all($few) for 1 .. 2;
    unlike($dbh->{Statement}, qr/pg_typeof/, 'and a three-row result is not');
};

subtest 'formatting can be turned off and is version-gated' => sub {
    my $query = $queries{numeric_order};
    $perl_engine->all($query);
    $perl_engine->all($query);
    unlike($dbh->{Statement}, qr/pg_typeof/, 'canonical_sql => 0 decodes in Perl');
    my $mock = TestSelecto::DBH->new;
    $mock->{pg_server_version} = 120000;
    my $old = engine_for($mock, canonical_values => 1);
    my $statement = $old->compile($query);
    my $plan = $old->adapter->_projection($statement);
    my $text = $old->adapter->_canonical_sql_text($plan,
        $dbh->{private_selecto_canonical_types}{$statement->sql});
    ok(!defined($text) || $text->{sql} !~ /trim_scale/, 'no trim_scale before PostgreSQL 13');
};

$dbh->do("DROP TABLE IF EXISTS $table");
done_testing;
