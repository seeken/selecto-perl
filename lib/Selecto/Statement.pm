package Selecto::Statement;

use Mojo::Base -base, -signatures;

sub new ($class, %args) {
    return $class->SUPER::new(
        sql => "$args{sql}",
        params => [@{$args{params} // []}],
        columns => [@{$args{columns} // []}],
        adapter_name => defined($args{adapter_name}) ? "$args{adapter_name}" : 'unknown',
    );
}

sub sql ($self) { return $self->{sql}; }
sub params ($self) { return [@{$self->{params}}]; }
sub columns ($self) { return [@{$self->{columns}}]; }
sub adapter_name ($self) { return $self->{adapter_name}; }
sub to_hash ($self) {
    return {
        sql => $self->{sql},
        params => [@{$self->{params}}],
        aliases => [@{$self->{columns}}],
    };
}

1;

__END__

=head1 NAME

Selecto::Statement - compiled SQL with its bound parameters

=head1 SYNOPSIS

  my $statement = $engine->compile($query);

  $statement->sql;           # 'SELECT "s0"."id" FROM "items" AS "s0" WHERE "s0"."price" > ?'
  $statement->params;        # [10]
  $statement->columns;       # ['id']
  $statement->adapter_name;  # 'sqlite'

=head1 DESCRIPTION

The adapter-neutral result of compiling a query. Application values are
never part of the SQL text; they are carried separately in C<params> in
placeholder order. Adapters return statements from C<compile> and accept
them in C<execute_query> and C<stream_query>.

=head1 METHODS

=head2 new

  my $statement = Selecto::Statement->new(
      sql => $sql, params => \@params, columns => \@columns, adapter_name => 'mydb',
  );

For adapter authors. A statement built this way carries no authority:
C<execute_query> and C<stream_query> run it only if it is exactly one
statement starting with C<SELECT> or C<WITH>, and always under a guard that discards any change it makes (see
L<Selecto::SQL/"The query path">). Writes go through L<Selecto::Engine>.

=head2 sql, params, columns, adapter_name

Accessors; C<params> and C<columns> return copies.

=head2 to_hash

Returns C<< {sql => ..., params => [...], aliases => [...]} >>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Adapter>, L<Selecto::Engine/compile>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
