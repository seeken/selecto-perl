use 5.034;
use strict;
use warnings;
use B ();
use Test::More;
use Selecto::PostgreSQL ();

# PostgreSQL::_decode_rows skips work it can prove is a no-op: integers made
# of ASCII digits bypass the regex, and timestamps holding neither '+' nor 'Z'
# bypass the suffix substitution. Over wide generated results every decoded
# cell must be exactly what the previous column-wise implementation (kept
# verbatim below) and the per-cell _decode give it: same definedness, same
# string, same number/string flags (which JSON encoding exposes) and same
# UTF-8 flag.

# _decode_rows as it was before the fast paths.
sub previous_decode_rows {
    my ($rows, $types) = @_;
    for my $i (0 .. $#$types) {
        my $type = $types->[$i] // '';
        if ($type eq 'bool') {
            for my $row (@$rows) {
                my $value = $row->[$i];
                $row->[$i] = ($value eq 't' || "$value" eq '1') ? 1 : 0 if defined $value;
            }
        } elsif ($type eq 'int2' || $type eq 'int4' || $type eq 'int8') {
            for my $row (@$rows) {
                my $value = $row->[$i];
                $row->[$i] = int($value) if defined($value) && "$value" =~ /\A-?\d+\z/;
            }
        } elsif ($type eq 'numeric' || $type eq 'float4' || $type eq 'float8') {
            for my $row (@$rows) {
                next unless defined(my $value = $row->[$i]);
                my $normalized = "$value";
                $normalized =~ s/(\.\d*?)0+\z/$1/;
                $normalized =~ s/\.\z//;
                $row->[$i] = $normalized eq '-0' ? '0' : $normalized;
            }
        } elsif ($type eq 'timestamp' || $type eq 'timestamptz') {
            for my $row (@$rows) {
                next unless defined(my $value = $row->[$i]);
                my $normalized = "$value";
                $normalized =~ tr/ /T/;
                $normalized =~ s/(?:\.0+)?(?:\+00(?::00)?|Z)\z//;
                $row->[$i] = $normalized;
            }
        }
    }
    return;
}

package Local::Digits {
    use overload '""' => sub { $_[0]{text} }, '0+' => sub { $_[0]{number} }, fallback => 1;
    sub new { my ($class, $text, $number) = @_; return bless {text => $text, number => $number}, $class }
}

my $FLAGS = B::SVf_IOK() | B::SVf_NOK() | B::SVf_POK() | B::SVf_ROK() | B::SVf_UTF8();

sub shape {
    my ($value) = @_;
    return 'undef' unless defined $value;
    my $flags = B::svref_2object(\$value)->FLAGS & $FLAGS;
    no warnings 'numeric';
    return ref($value) ? sprintf('%d:%s', $flags, overload::StrVal($value)) : sprintf('%d:%s', $flags, "$value");
}

sub flavour {
    my ($value) = @_;
    return 'undef' unless defined $value;
    my $copy = $value;
    my $number = (B::svref_2object(\$value)->FLAGS & (B::SVf_IOK() | B::SVf_NOK())) ? 'num' : 'str';
    return "$number:$copy";
}

sub utf8_text { my ($text) = @_; utf8::upgrade($text); return $text }

# Integers as DBD::Pg returns them (pure IVs) and as text drivers, test
# doubles or hosts could hand them over.
my @integer_pool = (
    0, 1, -1, 7, 42, -42, 2147483647, -2147483648, 9223372036854775807, -9223372036854775807 - 1,
    '0', '7', '-7', '00012', '-0', '-00', '12', ' 3', "4\n", '3 ', '+5', '1.5', '1e3', '1_000',
    'abc', '', '-', '--1', "\x{0663}", "1\x{0663}", "\x{FF11}\x{FF12}", utf8_text('123'), utf8_text('-9'),
    7.0, 1.5, -0.0, 1e20, 3.25,
    Local::Digits->new('15', 15), Local::Digits->new('x', 0), [1],
);
my @bool_pool = (0, 1, 't', 'f', '1', '0', '', 'true', utf8_text('t'), 1.0, 2);
my @numeric_pool = (
    '813.71', '982.60', '12.50', '12.500000', '-0.000', '0.000', '-0', '100', '100.0', '10.010',
    '1e5', '.50', '-12.30', 'NaN', 'Infinity', '', '5.', utf8_text('34104.15'), utf8_text('1.10'),
    3.25, 7, -0.0, 1e21,
);
my @timestamp_pool = (
    '2025-05-11 16:27:34', '2025-05-11 16:27:30', '2025-03-01 10:00:00.000000', '2025-03-01 10:00:00.120',
    '2025-03-01 10:00:00+00', '2025-03-01 10:00:00.0+00:00', '2025-03-01 10:00:00.000+00',
    '2025-03-01T10:00:00Z', '2025-03-01 10:00:00.00Z', '2025-03-01 10:00:00-05', '2025-03-01 10:00:00+05:30',
    '2025-03-01 10:00:00+00:00:00', '2025-03-01 10:00:00+00+00', 'Z', '+00', '.0+00', '', 'ZZ',
    '2025-03-01 10:00:00Z ', 'x+y', utf8_text('2025-05-11 16:27:34'), utf8_text('2025-05-11 16:27:34+00'),
    "2025-05-11 16:27:34 \x{1F600}", 20250511,
);
my @text_pool = ('hello', "Ren\x{e9}e \x{6771}\x{4eac}", '', '0', 12, '{"a": [1, 2]}');

my %pools = (
    int2 => \@integer_pool, int4 => \@integer_pool, int8 => \@integer_pool,
    bool => \@bool_pool,
    numeric => \@numeric_pool, float4 => \@numeric_pool, float8 => \@numeric_pool,
    timestamp => \@timestamp_pool, timestamptz => \@timestamp_pool,
    date => ['2025-03-01'], text => \@text_pool, jsonb => \@text_pool, '' => \@text_pool,
);

# A wide result: every type several times over, plus a missing type.
my @types = ((sort keys %pools) x 3, undef);

# Deterministic generator, so a failure names a reproducible cell.
my $seed = 20261006;
sub next_index { my ($size) = @_; $seed = ($seed * 1103515245 + 12345) % 2147483648; return $seed % $size }

my $height = 3_000;
my @source = map {
    my $r = $_;
    [map {
        my $pool = $pools{$types[$_] // ''};
        # Every pool member appears in every column, then the rest is random;
        # about one cell in eight is NULL.
        $r < @$pool ? $pool->[$r] : next_index(8) == 0 ? undef : $pool->[next_index(scalar @$pool)]
    } 0 .. $#types]
} 0 .. $height - 1;

# Each implementation decodes its own copy of the same source cells.
my @previous = map { [@$_] } @source;
my @current = map { [@$_] } @source;
previous_decode_rows(\@previous, \@types);
my $adapter = bless {}, 'Selecto::PostgreSQL';
$adapter->_decode_rows(\@current, \@types);

my ($cells, @mismatches) = (0);
for my $r (0 .. $#source) {
    for my $c (0 .. $#types) {
        $cells++;
        my ($got, $want) = (shape($current[$r][$c]), shape($previous[$r][$c]));
        my $per_cell = flavour($adapter->_decode($source[$r][$c], $types[$c]));
        push @mismatches, "row $r column $c (" . ($types[$c] // 'undef') . "): got $got, previous $want"
            if $got ne $want;
        push @mismatches, "row $r column $c (" . ($types[$c] // 'undef') . "): flavour " . flavour($current[$r][$c])
            . ", _decode $per_cell"
            if flavour($current[$r][$c]) ne $per_cell;
    }
}
is(scalar @mismatches, 0, "$cells generated cells decode exactly as before and as _decode")
    or diag(join("\n", @mismatches[0 .. ($#mismatches < 20 ? $#mismatches : 19)]));

subtest 'the fast paths are taken where they apply and change nothing' => sub {
    my @rows = ([42, '00012', '2025-05-11 16:27:34', '2025-05-11 16:27:34.000+00']);
    $adapter->_decode_rows(\@rows, [qw(int4 int4 timestamp timestamptz)]);
    is(shape($rows[0][0]), shape(42), 'IV stays an IV');
    is(shape($rows[0][1]), shape(12), 'digit string becomes a number');
    is($rows[0][2], '2025-05-11T16:27:34', 'timestamp without time zone');
    is($rows[0][3], '2025-05-11T16:27:34', 'UTC suffix and zero fraction still stripped');
};

subtest 'a live PostgreSQL result decodes exactly as before' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && $url ne '';
    plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url, 'postgresql');
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
    my $live = Selecto::PostgreSQL->new(dbh => $dbh);
    my $sth = $dbh->prepare(<<'SQL');
SELECT n::int2, (n * 1000)::int4, (n::int8 * 3000000000) - 6000000000, n % 3 = 0,
       (n / 7.0)::numeric(12, 4), (n * 1.5)::float8, (n / 4.0)::float4,
       NULLIF(timestamp '2025-01-01 00:00:00' + n * interval '1001 milliseconds', timestamp '2025-01-01 00:00:05.005'),
       timestamptz '2025-01-01 00:00:00+00' + n * interval '30 seconds',
       date '2025-01-01' + n, 'Ren' || chr(233) || 'e ' || n, jsonb_build_object('n', n)
FROM generate_series(-50, 1949) AS n
SQL
    $sth->execute;
    my @types = $live->_column_types($sth);
    my $rows = $sth->fetchall_arrayref;
    $dbh->disconnect;
    my @previous = map { [@$_] } @$rows;
    previous_decode_rows(\@previous, \@types);
    $live->_decode_rows($rows, \@types);
    my $mismatch = 0;
    for my $r (0 .. $#$rows) {
        for my $c (0 .. $#types) {
            $mismatch++ if shape($rows->[$r][$c]) ne shape($previous[$r][$c]);
        }
    }
    is($mismatch, 0, scalar(@$rows) . ' live rows of ' . join(',', @types) . ' decode as before');
};

done_testing;
