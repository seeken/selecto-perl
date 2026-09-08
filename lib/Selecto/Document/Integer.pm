package Selecto::Document::Integer;
use 5.034;
use strict;
use warnings;
use Math::BigInt;
use Selecto::Error ();
use overload '""' => sub { ${$_[0]} }, fallback => 1;

sub new {
    my ($class, $value) = @_;
    Selecto::Error->throw('invalid_predicate_value', 'Exact signed 64-bit decimal string required')
        unless defined($value) && !ref($value) && "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/;
    my $integer = Math::BigInt->new("$value");
    Selecto::Error->throw('invalid_predicate_value', 'Integer exceeds signed 64-bit range')
        if $integer < Math::BigInt->new('-9223372036854775808') || $integer > Math::BigInt->new('9223372036854775807');
    my $canonical = $integer->bstr;
    my $self = bless \$canonical, $class;
    Internals::SvREADONLY($canonical, 1);
    return $self;
}
sub value { ${$_[0]} }
1;
