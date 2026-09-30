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

__END__

=head1 NAME

Selecto::Error - structured exceptions with stable codes

=head1 SYNOPSIS

  use Scalar::Util qw(blessed);

  my $ok = eval { $engine->execute_write($command); 1 };
  if (!$ok) {
      my $error = $@;
      die $error unless blessed($error) && $error->isa('Selecto::Error');
      if ($error->code eq 'cardinality_mismatch') { ... }
      warn $error->message;           # also what "$error" stringifies to
      my $details = $error->details;  # e.g. {expected => 1}
      my $json    = $error->to_hash;  # {type => ..., message => ..., details => {...}}
  }

  Selecto::Error->throw('my_code', 'Something failed', {field => 'name'});

=head1 DESCRIPTION

Every failure raised by Selecto is a C<Selecto::Error>. Match on C<code>:
codes are stable and shared with the other Selecto implementations, while
messages are meant for people and may change. Messages and details never
contain connection strings, credentials or raw driver errors; a database
failure is reported as C<query_error> (or, on PostgreSQL, a
C<database_*_violation> code for constraint failures) with only the error
class in its details.

The object stringifies to its message.

=head1 METHODS

=head2 new

  my $error = Selecto::Error->new(code => $code, message => $message, details => \%details);

=head2 throw

  Selecto::Error->throw($code, $message, \%details);

Constructs an error and C<die>s with it.

=head2 code, message, details

Accessors. C<details> returns a shallow copy.

=head2 to_hash

Returns C<< {type => $code, message => $message, details => {...}} >>, the
shape used in canonical API error responses.

=head2 as_string

Returns the message.

=head1 SEE ALSO

L<Selecto>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
