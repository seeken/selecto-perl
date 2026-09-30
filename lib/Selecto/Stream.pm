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
    my (@row, $available, $decoded);
    my $ok = eval {
        @row = $self->{sth}->fetchrow_array;
        $available = @row ? 1 : 0;
        $decoded = [map {
            $self->{decode}->($row[$_], $self->{types}[$_])
        } 0 .. $#row] if $available;
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
    return $decoded;
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

__END__

=head1 NAME

Selecto::Stream - row-at-a-time query results

=head1 SYNOPSIS

  my $stream = $engine->stream($query, fetch_size => 500);
  my $columns = $stream->columns;
  while (my $row = $stream->next) {
      consume($row);             # an array reference, decoded like Engine::all rows
  }
  $stream->close;                # safe to call more than once

=head1 DESCRIPTION

Returned by L<Selecto::Engine/stream>. The stream fetches and decodes one
row per call, so Selecto itself never accumulates the result. How much the
DBI driver or server buffers is up to the driver; C<fetch_size> is passed as
a C<RowCacheSize> hint and defaults to 500.

The stream closes itself when the rows are exhausted, when a fetch or decode
fails (the error is normalized to a L<Selecto::Error> and thrown), and when
it goes out of scope. Close it explicitly when you stop early.

=head1 METHODS

=head2 next

Returns the next row as an array reference, or C<undef> when there are no
more rows.

=head2 columns

The result column names.

=head2 close, closed

Finishes the statement handle; C<closed> reports whether that has happened.

=head2 new

Called by adapters with C<sth>, C<columns>, C<types>, C<decode> and
C<normalize_error>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Engine>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
