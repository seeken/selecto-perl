use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
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

subtest 'export scalars keep NUMERIC scale, give JSON booleans and decode JSON' => sub {
    my $plain = bless {}, 'Selecto::PostgreSQL';
    my $export = bless {_selecto_export_scalars => 1}, 'Selecto::PostgreSQL';
    # Without the option nothing changes: decimals lose trailing zeros,
    # booleans are 1/0 and JSON stays text (pinned values).
    is_deeply([map { $plain->_decode($_, 'numeric') } '533.10', '7152.00', '0.0000', '-0.50', '42', '-0.000'],
        ['533.1', '7152', '0', '-0.5', '42', '0'], 'normal results still normalize decimals');
    is_deeply([map { $plain->_decode($_, 'bool') } 't', 'f'], [1, 0], 'normal booleans are 1 and 0');
    is($plain->_decode('{"a": [1, 2]}', 'jsonb'), '{"a": [1, 2]}', 'normal JSON stays text');

    is_deeply([map { $export->_decode($_, 'numeric') } '533.10', '7152.00', '0.0000', '-0.50', '42', '-0.0001', 'NaN'],
        ['533.10', '7152.00', '0.0000', '-0.50', '42', '-0.0001', 'NaN'], 'export decimals keep the database text');
    ok(JSON::PP::is_bool($export->_decode('t', 'bool')) && $export->_decode('t', 'bool'), 'true');
    ok(JSON::PP::is_bool($export->_decode('f', 'bool')) && !$export->_decode('f', 'bool'), 'false');
    is_deeply($export->_decode(qq({"b": "\x{6771}\x{4eac}", "a": [1, 2]}), 'jsonb'), {a => [1, 2], b => "\x{6771}\x{4eac}"}, 'jsonb decoded');
    is_deeply($export->_decode('[true, null]', 'json'), [JSON::PP::true, undef], 'json decoded');
    for my $type (grep { !/\A(?:numeric|bool|json|jsonb)\z/ } @types) {
        for my $value (@{$samples{$type}}) {
            is(flavour($export->_decode($value, $type)), flavour($plain->_decode($value, $type)),
                "export leaves $type " . (defined $value ? "'$value'" : 'undef') . ' as before');
        }
    }

    my @export_types = qw(numeric bool jsonb json int4 timestamp date float8 text);
    my @raw = (
        ['533.10', 't', '{"k": 1}', '[]', '7', '2025-05-31 00:00:00', '2025-05-31', '1.50', 'x'],
        ['-0.0001', 'f', 'null', '{"a": {"b": null}}', undef, '2024-02-29 13:45:07', undef, undef, undef],
        [undef, undef, undef, undef, '-4', undef, '1999-12-31', '-0', ''],
    );
    my @per_cell = map { my $row = $_; [map { $export->_decode($row->[$_], $export_types[$_]) } 0 .. $#export_types] } @raw;
    my @decoded = map { [@$_] } @raw;
    $export->_decode_rows(\@decoded, \@export_types);
    is(JSON::PP->new->canonical->allow_nonref->encode(\@decoded),
        JSON::PP->new->canonical->allow_nonref->encode(\@per_cell), 'column-wise export decode matches per-cell');
    is(JSON::PP->new->canonical->encode($decoded[0]),
        '[533.10,true,{"k":1},[],7,"2025-05-31T00:00:00","2025-05-31","1.5","x"]' =~ s/533\.10/"533.10"/r,
        'export row values');
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
