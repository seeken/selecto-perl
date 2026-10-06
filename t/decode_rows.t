use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::MSSQL ();
use Selecto::PostgreSQL ();
use Selecto::SQL ();

# Column-wise PostgreSQL decoding must give every cell exactly what the
# per-cell _decode gives it, including Perl's string/number flavour (which
# JSON encoding exposes), for every type _decode treats specially and some
# it passes through.
my %samples = (
    bool => ['t', 'f', '1', '0', 1, 0, '', undef],
    int2 => ['0', '-1', '32767', 7, '00012', '1.5', 'abc', '', undef],
    int4 => ['2147483647', '-2147483648', '-0', ' 3', "4\n", undef],
    int8 => ['9223372036854775807', '-9223372036854775808', '123', undef],
    numeric => ['12.50', '12.500000', '-0.000', '0.000', '-0', '100', '100.0', '10.010',
        '1e5', '.50', '-12.30', 'NaN', '', 3.25, 7, undef],
    float4 => ['1.50', '-0', '3', 'Infinity', undef],
    float8 => ['0.10000', '-1.0', '2.25e-05', undef],
    timestamp => ['2025-03-01 10:00:00', '2025-03-01 10:00:00.000000', '2025-03-01 10:00:00.120',
        '2025-03-01 10:00:00.120000', '2025-03-01 10:00:00+00', '2025-03-01 10:00:00.0+00:00',
        '2025-03-01T10:00:00Z', '2025-03-01 10:00:00-05', '', undef],
    timestamptz => ['2025-03-01 10:00:00+00', '2025-03-01 10:00:00.000000+00', '2025-03-01 10:00:00.5+00',
        '2025-03-01 10:00:00+05:30', undef],
    date => ['2025-03-01', undef],
    text => ['hello', 'Renée 東京', '', '0', undef],
    jsonb => ['{"a": [1, 2]}', undef],
    '' => ['as is', 1, undef],
);

sub flavour {
    my ($value) = @_;
    return 'undef' unless defined $value;
    no warnings 'numeric';
    my $copy = $value;
    my $number = (B::svref_2object(\$value)->FLAGS & (B::SVf_IOK() | B::SVf_NOK())) ? 'num' : 'str';
    return "$number:$copy";
}
use B ();

my $adapter = bless {}, 'Selecto::PostgreSQL';
my @types = sort keys %samples;
my $height = 0;
for (values %samples) { $height = @$_ if @$_ > $height }

# One row per sample index; a column per type, padded with the column's first sample.
my @rows = map {
    my $index = $_;
    [map { my $column = $samples{$_}; $index < @$column ? $column->[$index] : $column->[0] } @types]
} 0 .. $height - 1;

my @expected = map {
    my $row = $_;
    [map { $adapter->_decode($row->[$_], $types[$_]) } 0 .. $#types]
} @rows;

my @actual = map { [@$_] } @rows;
$adapter->_decode_rows(\@actual, \@types);

for my $r (0 .. $#rows) {
    for my $c (0 .. $#types) {
        is(flavour($actual[$r][$c]), flavour($expected[$r][$c]),
            "row $r $types[$c] " . (defined $rows[$r][$c] ? "'$rows[$r][$c]'" : 'undef'));
    }
}

subtest 'missing or short type lists leave values untouched, as _decode does' => sub {
    my @rows = (['12.50', 't', '2025-03-01 10:00:00']);
    $adapter->_decode_rows(\@rows, []);
    is_deeply(\@rows, [['12.50', 't', '2025-03-01 10:00:00']], 'no types');
    $adapter->_decode_rows(\@rows, ['numeric']);
    is_deeply(\@rows, [['12.5', 't', '2025-03-01 10:00:00']], 'only typed columns decode');
};

subtest 'empty results' => sub {
    my @rows;
    $adapter->_decode_rows(\@rows, ['int4']);
    is_deeply(\@rows, [], 'nothing to decode');
};

subtest 'a subclass that redefines _decode keeps the per-cell path' => sub {
    package Local::CustomPostgreSQL {
        use parent -norequire, 'Selecto::PostgreSQL';
        sub _decode { return defined $_[1] ? "<$_[1]>" : undef }
    }
    my $custom = bless {}, 'Local::CustomPostgreSQL';
    my @rows = (['12.50', undef]);
    $custom->_decode_rows(\@rows, ['numeric', 'text']);
    is_deeply(\@rows, [['<12.50>', undef]], 'subclass _decode applied per cell');
};

subtest 'the base adapter decodes nothing; adapters with their own _decode decode per cell' => sub {
    my $base = bless {}, 'Selecto::SQL';
    my @rows = (['12.50', 't']);
    $base->_decode_rows(\@rows, ['numeric', 'bool']);
    is_deeply(\@rows, [['12.50', 't']], 'identity');

    my $mssql = bless {}, 'Selecto::MSSQL';
    my @types = (4, 2);    # SQL_INTEGER, SQL_NUMERIC
    my @raw = (['42', '12.500']);
    my @per_cell = map { my $row = $_; [map { $mssql->_decode($row->[$_], $types[$_]) } 0 .. 1] } @raw;
    my @decoded = map { [@$_] } @raw;
    $mssql->_decode_rows(\@decoded, \@types);
    is_deeply(\@decoded, \@per_cell, 'same as per-cell _decode');
};

done_testing;
