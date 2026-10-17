package Selecto::CanonicalJSON;

# Canonical JSON (sorted keys, no ASCII escaping) for what Selecto publishes or hashes:
# domain and predicate fingerprints and Canonical JSON v1 API bodies. Encoded by
# Cpanel::JSON::XS, byte for byte as JSON::PP encoded it before, which t/canonical_json.t
# checks. The one difference: Cpanel writes a number with a whole value that Perl holds as
# a float (6/2, 2.5*2, "3" after float arithmetic, -0.0) as 3.0 or -0.0 where JSON::PP wrote
# 3 and 0. Such numbers are rare, so an encoding that shows one is redone from a copy that
# has them as integers.

use 5.034;
use strict;
use warnings;
no warnings 'recursion';
use Cpanel::JSON::XS 4.38 ();

my $TEXT = Cpanel::JSON::XS->new->canonical(1)->allow_nonref(1);
my $BYTES = Cpanel::JSON::XS->new->canonical(1)->allow_nonref(1)->utf8(1);
my $SCALAR = Cpanel::JSON::XS->new->allow_nonref(1);

# Canonical JSON text (characters).
sub encode {
    my ($class, $value) = @_;
    return _encode($TEXT, $value);
}

# Canonical JSON as UTF-8 bytes.
sub encode_utf8 {
    my ($class, $value) = @_;
    return _encode($BYTES, $value);
}

sub _encode {
    my ($json, $value) = @_;
    my $text = $json->encode($value);
    # A number written N.0; the same text inside a string only costs the copy.
    return $text unless $text =~ /\.0(?:[,\]}]|\z)/;
    return $json->encode(_whole_floats_as_integers($value));
}

sub _whole_floats_as_integers {
    my ($value) = @_;
    my $type = ref($value);
    return [map { _whole_floats_as_integers($_) } @$value] if $type eq 'ARRAY';
    return {map { ($_ => _whole_floats_as_integers($value->{$_})) } keys %$value} if $type eq 'HASH';
    return $value if $type || !defined($value);
    return $value unless $SCALAR->encode($value) =~ /\A(-?[0-9]+)\.0\z/;
    return $1 eq '-0' ? 0 : 0 + $1;
}

1;
