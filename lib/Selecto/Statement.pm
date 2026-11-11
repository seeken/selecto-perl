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
# The relations the statement names, as its SQL spells them (dialect-quoted,
# schema-prefixed when the SQL is), recorded by the adapter's compile; undef
# for a statement a host built by hand.
sub relations ($self) {
    return ref($self->{_selecto_relations}) eq 'ARRAY' ? [@{$self->{_selecto_relations}}] : undef;
}
# A statement wrapped around this one: other SQL, the same relations, declared schemas
# and row lock, so what was generated stays generated, and what was hand-built stays
# that. Companions that wrap a compiled statement use this, not new.
sub derive ($self, %args) {
    my $derived = (ref $self)->new(sql => $args{sql} // $self->{sql}, params => $args{params} // $self->{params},
        columns => $args{columns} // $self->{columns}, adapter_name => $args{adapter_name} // $self->{adapter_name});
    for my $key (qw(_selecto_relations _selecto_row_lock _selecto_recursion_depth)) {
        $derived->{$key} = ref($self->{$key}) eq 'ARRAY' ? [@{$self->{$key}}] : $self->{$key} if exists $self->{$key};
    }
    return $derived;
}

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

B<The SQL text is for looking at, not for running.> On PostgreSQL the adapter
writes operators and functions to their schemas, pins the session and checks
its state only when it executes a statement, so C<< $dbh->prepare($statement->sql) >>
resolves every operator through the session: a role with CREATE on a schema on
the search path can plant one, and a tenant's predicate is then theirs. Run a
statement with C<execute_query> or C<stream_query> (or
L<Selecto::Engine/all>, L<Selecto::Engine/stream>), including inside a
read-only transaction of your own.

=head1 METHODS

=head2 new

  my $statement = Selecto::Statement->new(
      sql => $sql, params => \@params, columns => \@columns, adapter_name => 'mydb',
  );

For adapter authors.

=head2 relations

The relations the statement names, as an array reference of the names its
SQL spells (dialect-quoted, schema-prefixed where the SQL is), recorded by
C<compile>: the root, joined and bridge relations, member, retarget and
co-domain sources, collection and C<association_exists> subqueries. Undef
for a statement built by hand. Statements an adapter derives from a
compiled one (bounded wrappers, scalar columns, canonical formatting) keep
the list.

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
