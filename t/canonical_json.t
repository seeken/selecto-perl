use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(dualvar);
use Selecto::CanonicalJSON ();

# Selecto::CanonicalJSON (Cpanel::JSON::XS) writes the bytes JSON::PP wrote, so fingerprints
# and canonical bodies are unchanged; that includes whole numbers Perl holds as floats, which
# Cpanel alone writes as 3.0.

my $text = JSON::PP->new->canonical(1)->allow_nonref(1);
my $bytes = JSON::PP->new->canonical(1)->allow_nonref(1)->utf8(1);

my $stringified = 42; my $s1 = "$stringified";
my $numified = '12'; { no warnings; my $n = $numified + 0; }
my $float_math = '3'; { my $n = $float_math * 1.5; }
my $whole_float = 6 / 2;
my $whole_float_stringified = 6 / 2; my $s2 = "$whole_float_stringified";
my $negative_zero = -0.0;
my $utf8 = "caf\x{e9}"; utf8::upgrade($utf8);
my $latin1 = "caf\x{e9}"; utf8::downgrade($latin1);
my @scalars = (
    '', 'a', $utf8, $latin1, "\x{20ac}", "\x{1F600}", qq{q " \\}, "\x00\x1f\t\n\x7f",
    0, 1, -1, 42, 18446744073709551615, -9223372036854775807, 1.5, -2.25, 0.1 + 0.2, 1e15, 1e20, 1e-7,
    3.0, -7.0, $whole_float, $whole_float_stringified, $float_math, 2.5 * 2, sqrt(16), 100 * 1.1, 1e15 / 1,
    $negative_zero, -1 / 9**9**9, $stringified, $numified, dualvar(5, 'five'), dualvar(7, '7'),
    '3.0', '1.0}', '1.0,', '-0.0', '007', undef, JSON::PP::true, JSON::PP::false,
    ($] >= 5.036 ? (!!1, !!0) : ()),
);
my @values = (
    @scalars,
    \@scalars,
    {map { ("k$_" => $scalars[$_]) } 0 .. $#scalars},
    {rows => [map { {id => $_, price => $_ / 4, total => $_ * 1.0} } 1 .. 20]},
    [[], {}, [[]], {a => {}}, [undef]],
    {"caf\x{e9}" => 3.0, "\x{20ac}" => [1.0, 'x', {y => 2.0}], '' => -0.0},
);

my $index = 0;
for my $value (@values) {
    $index++;
    is(Selecto::CanonicalJSON->encode($value), $text->encode($value), "value $index: text matches JSON::PP");
    is(Selecto::CanonicalJSON->encode_utf8($value), $bytes->encode($value), "value $index: bytes match JSON::PP");
}

# Whole floats are rewritten only in the copy that is encoded.
my $tree = {a => [3.0, 'x'], b => 6 / 2};
my $before = $text->encode($tree);
Selecto::CanonicalJSON->encode($tree);
is($text->encode($tree), $before, 'the value encoded is not changed');
is(ref($tree->{a}), 'ARRAY', 'and keeps its structure');

done_testing;
