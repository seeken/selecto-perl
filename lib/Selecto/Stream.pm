package Selecto::Stream;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_stream', 'stream requires a DBI statement handle')
        unless blessed($args{sth});
    Selecto::Error->throw('invalid_stream', 'stream columns and types must be arrays')
        unless ref($args{columns}) eq 'ARRAY' && ref($args{types}) eq 'ARRAY';
    Selecto::Error->throw('invalid_stream', 'stream decoder and error normalizer must be callbacks')
        unless ref($args{decode}) eq 'CODE' && ref($args{normalize_error}) eq 'CODE';
    return bless {
        sth => $args{sth},
        columns => [@{$args{columns}}],
        types => [@{$args{types}}],
        decode => $args{decode},
        normalize_error => $args{normalize_error},
        closed => 0,
    }, $class;
}

sub next {
    my ($self) = @_;
    return undef if $self->{closed};
    my (@row, $available);
    my $ok = eval {
        @row = $self->{sth}->fetchrow_array;
        $available = @row ? 1 : 0;
        1;
    };
    if (!$ok) {
        my $error = $@;
        $self->close;
        die $self->{normalize_error}->($error);
    }
    if (!$available) {
        $self->close;
        return undef;
    }
    return [map {
        $self->{decode}->($row[$_], $self->{types}[$_])
    } 0 .. $#row];
}

sub columns { return [@{$_[0]->{columns}}]; }
sub closed  { return $_[0]->{closed} ? 1 : 0; }

sub close {
    my ($self) = @_;
    return $self if $self->{closed};
    $self->{closed} = 1;
    eval { $self->{sth}->finish if $self->{sth}->can('finish') };
    return $self;
}

sub DESTROY { $_[0]->close if ref($_[0]); }

1;
