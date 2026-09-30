package Selecto::Write::Expression;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

my %KINDS = map { $_ => 1 } qw(
    literal field current_timestamp default
    add subtract multiply divide coalesce
);

sub new {
    my ($class, $kind, @arguments) = @_;
    $kind = defined($kind) && !ref($kind) ? "$kind" : '';
    Selecto::Error->throw('invalid_write', 'unknown mutation expression kind')
        unless $KINDS{$kind};
    if ($kind eq 'literal') {
        Selecto::Error->throw('invalid_write', 'mutation literal requires one value')
            unless @arguments == 1;
    } elsif ($kind eq 'field') {
        Selecto::Error->throw('invalid_write', 'mutation field requires one root identifier')
            unless @arguments == 1 && defined($arguments[0]) && !ref($arguments[0])
                && "$arguments[0]" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        $arguments[0] = "$arguments[0]";
    } elsif ($kind eq 'current_timestamp' || $kind eq 'default') {
        Selecto::Error->throw('invalid_write', "mutation $kind takes no operands")
            if @arguments;
    } elsif ($kind eq 'coalesce') {
        Selecto::Error->throw('invalid_write', 'mutation coalesce requires at least two expression operands')
            unless @arguments == 1 && ref($arguments[0]) eq 'ARRAY'
                && @{$arguments[0]} >= 2
                && !grep { !blessed($_) || !$_->isa(__PACKAGE__) } @{$arguments[0]};
    } else {
        Selecto::Error->throw('invalid_write', "mutation $kind requires two expression operands")
            unless @arguments == 2
                && !grep { !blessed($_) || !$_->isa(__PACKAGE__) } @arguments;
    }
    return bless {kind => $kind, arguments => [map { _clone($_) } @arguments]}, $class;
}

sub literal { my ($class, $value) = @_; return $class->new('literal', $value); }
sub field {
    my ($class, $name) = @_;
    return $class->new('field', $name);
}
sub current_timestamp { my ($class) = @_; return $class->new('current_timestamp'); }
sub default { my ($class) = @_; return $class->new('default'); }
sub add { my ($class, $left, $right) = @_; return $class->_binary('add', $left, $right); }
sub subtract { my ($class, $left, $right) = @_; return $class->_binary('subtract', $left, $right); }
sub multiply { my ($class, $left, $right) = @_; return $class->_binary('multiply', $left, $right); }
sub divide { my ($class, $left, $right) = @_; return $class->_binary('divide', $left, $right); }
sub increment {
    my ($class, $field, $amount) = @_;
    $amount //= 1;
    return $class->add($class->field($field), $class->literal($amount));
}
sub decrement {
    my ($class, $field, $amount) = @_;
    $amount //= 1;
    return $class->subtract($class->field($field), $class->literal($amount));
}
sub coalesce {
    my ($class, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    Selecto::Error->throw('invalid_write', 'mutation coalesce requires at least two operands')
        unless @values >= 2;
    return $class->new('coalesce', [map { $class->_operand($_) } @values]);
}

sub _binary {
    my ($class, $kind, $left, $right) = @_;
    return $class->new($kind, $class->_operand($left), $class->_operand($right));
}

sub _operand {
    my ($class, $value) = @_;
    return $value if blessed($value) && $value->isa(__PACKAGE__);
    return $class->literal($value);
}

sub kind { return $_[0]->{kind}; }
sub arguments { return [map { _clone($_) } @{$_[0]->{arguments}}]; }

sub referenced_fields {
    my ($self) = @_;
    my %fields;
    _collect_fields($self, \%fields);
    return [sort keys %fields];
}

sub _collect_fields {
    my ($value, $fields) = @_;
    if (blessed($value) && $value->isa(__PACKAGE__)) {
        $fields->{$value->{arguments}[0]} = 1 if $value->{kind} eq 'field';
        _collect_fields($_, $fields) for @{$value->{arguments}};
    } elsif (ref($value) eq 'ARRAY') {
        _collect_fields($_, $fields) for @$value;
    }
}

sub _clone {
    my ($value) = @_;
    return bless {
        kind => $value->{kind},
        arguments => [map { _clone($_) } @{$value->{arguments}}],
    }, ref($value) if blessed($value) && $value->isa(__PACKAGE__);
    return [map { _clone($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _clone($value->{$_}) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}

1;

__END__

=head1 NAME

Selecto::Write::Expression - adapter-independent assignment expressions

=head1 SYNOPSIS

  use Selecto::Write::Expression;

  my $command = $engine->write_command(
      operation   => 'update',
      assignments => {
          quantity   => Selecto::Write::Expression->decrement('quantity', 1),
          price      => Selecto::Write::Expression->multiply(
                            Selecto::Write::Expression->field('price'), '1.05'),
          nickname   => Selecto::Write::Expression->coalesce(
                            Selecto::Write::Expression->field('nickname'), 'none'),
          updated_at => Selecto::Write::Expression->current_timestamp,
      },
      filter => ['eq', 'id', 42],
  );

=head1 DESCRIPTION

A closed AST for computed assignments in L<Selecto::Write::Command>s. Each
adapter compiles it to its own SQL, literals stay bound parameters, and field
references are validated against the governing domain.

Operands that are not already expressions are treated as literals.

=head1 CONSTRUCTORS

=over 4

=item C<literal($value)>

=item C<field($name)>

A root field of the row being updated. Field references are only valid in
updates, because an inserted row does not exist yet.

=item C<add($left, $right)>, C<subtract>, C<multiply>, C<divide>

=item C<increment($field, $amount)>, C<decrement($field, $amount)>

Shortcuts for C<< add(field($field), literal($amount)) >> and the
subtraction equivalent; C<$amount> defaults to 1.

=item C<coalesce(@operands)>

The first non-null operand; at least two are required.

=item C<current_timestamp>

=item C<default>

The column's database default. Dialects that cannot express an individual
C<DEFAULT> assignment (SQLite) fail with C<invalid_write>.

=back

=head1 METHODS

C<kind>, C<arguments> and C<referenced_fields> (the sorted field names the
expression reads).

=head1 ERRORS

Malformed expressions throw C<invalid_write>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Write>, L<Selecto::Engine>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
