package Selecto::Error;

use 5.034;
use strict;
use warnings;
use overload '""' => 'as_string', fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless {
        code    => "$args{code}",
        message => "$args{message}",
        details => $args{details} && ref($args{details}) eq 'HASH' ? { %{$args{details}} } : {},
    }, $class;
}

sub throw {
    my ($class, $code, $message, $details) = @_;
    die $class->new(code => $code, message => $message, details => $details // {});
}

sub code    { return $_[0]->{code}; }
sub message { return $_[0]->{message}; }
sub details { return { %{$_[0]->{details}} }; }

sub to_hash {
    my ($self) = @_;
    return {
        type    => $self->{code},
        message => $self->{message},
        details => { %{$self->{details}} },
    };
}

sub as_string { return $_[0]->{message}; }

1;

