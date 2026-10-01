package Selecto::Write;

use 5.034;
use strict;
use warnings;
use Selecto::Write::Expression ();

1;

package Selecto::Write::Command;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

my %OPERATIONS = map { $_ => 1 } qw(insert update upsert delete);

sub new {
    my ($class, %args) = @_;
    my $operation = defined($args{operation}) ? "$args{operation}" : '';
    Selecto::Error->throw('invalid_write', "unsupported operation $operation") unless $OPERATIONS{$operation};
    Selecto::Error->throw('invalid_write', 'relation must be a non-empty string')
        unless defined($args{relation}) && !ref($args{relation}) && "$args{relation}" ne '';
    my $assignments = $args{assignments} // {};
    my $metadata = $args{metadata} // {};
    Selecto::Error->throw('invalid_write', 'assignments must be an object') unless ref($assignments) eq 'HASH';
    Selecto::Error->throw('invalid_write', 'metadata must be an object') unless ref($metadata) eq 'HASH';
    return bless {
        operation => $operation,
        relation => "$args{relation}",
        assignments => { map { ("$_", _clone($assignments->{$_})) } keys %$assignments },
        predicate => $args{predicate},
        scope_predicate => $args{scope_predicate},
        query_enforcement => $args{query_enforcement},
        expected_count => exists($args{expected_count}) ? $args{expected_count} : 1,
        metadata => { map { ("$_", _clone($metadata->{$_})) } keys %$metadata },
    }, $class;
}

sub operation      { return $_[0]->{operation}; }
sub relation       { return $_[0]->{relation}; }
sub assignments    { return { map { ($_ => _clone($_[0]->{assignments}{$_})) } keys %{$_[0]->{assignments}} }; }
sub predicate      { return $_[0]->{predicate}; }
sub scope_predicate { return $_[0]->{scope_predicate}; }
sub query_enforcement { return $_[0]->{query_enforcement}; }
sub expected_count { return $_[0]->{expected_count}; }
sub metadata       { return { map { ($_ => _clone($_[0]->{metadata}{$_})) } keys %{$_[0]->{metadata}} }; }

sub with_query_enforcement {
    my ($self, $evidence) = @_;
    return ref($self)->new(
        operation => $self->operation,
        relation => $self->relation,
        assignments => $self->assignments,
        predicate => $self->predicate,
        scope_predicate => $self->scope_predicate,
        query_enforcement => $evidence,
        expected_count => $self->expected_count,
        metadata => $self->metadata,
    );
}

sub with_assignments {
    my ($self, $assignments) = @_;
    return ref($self)->new(
        operation => $self->operation,
        relation => $self->relation,
        assignments => $assignments,
        predicate => $self->predicate,
        scope_predicate => $self->scope_predicate,
        query_enforcement => $self->query_enforcement,
        expected_count => $self->expected_count,
        metadata => $self->metadata,
    );
}

sub with_scope_predicate {
    my ($self, $scope_predicate) = @_;
    return ref($self)->new(
        operation => $self->operation,
        relation => $self->relation,
        assignments => $self->assignments,
        predicate => $self->predicate,
        scope_predicate => $scope_predicate,
        query_enforcement => $self->query_enforcement,
        expected_count => $self->expected_count,
        metadata => $self->metadata,
    );
}

sub with_metadata {
    my ($self, $metadata) = @_;
    Selecto::Error->throw('invalid_write', 'metadata must be an object')
        unless ref($metadata) eq 'HASH';
    return ref($self)->new(
        operation => $self->operation,
        relation => $self->relation,
        assignments => $self->assignments,
        predicate => $self->predicate,
        scope_predicate => $self->scope_predicate,
        query_enforcement => $self->query_enforcement,
        expected_count => $self->expected_count,
        metadata => $metadata,
    );
}

sub _clone {
    my ($value) = @_;
    return [map { _clone($_) } @$value] if ref($value) eq 'ARRAY';
    return { map { ($_ => _clone($value->{$_})) } keys %$value } if ref($value) eq 'HASH';
    return $value;
}

package Selecto::Write::Batch;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

sub new {
    my ($class, @commands) = @_;
    @commands = @{$commands[0]} if @commands == 1 && ref($commands[0]) eq 'ARRAY';
    Selecto::Error->throw('invalid_write', 'batch must contain commands') unless @commands;
    Selecto::Error->throw('invalid_write', 'batch contains a non-command')
        if grep { !blessed($_) || !$_->isa('Selecto::Write::Command') } @commands;
    return bless { commands => [@commands] }, $class;
}

sub commands { return [@{$_[0]->{commands}}]; }

package Selecto::Write::Graph;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    my $nodes = $args{nodes};
    Selecto::Error->throw('invalid_write_graph', 'graph nodes must be a non-empty array')
        unless ref($nodes) eq 'ARRAY' && @$nodes;

    my (%seen, %required_returning, %required_returning_seen);
    my @normalized;
    for my $index (0 .. $#$nodes) {
        my $node_spec = $nodes->[$index];
        Selecto::Error->throw('invalid_write_graph', 'graph node must be an object')
            unless ref($node_spec) eq 'HASH';
        my $id = defined($node_spec->{id}) ? "$node_spec->{id}" : '';
        Selecto::Error->throw('invalid_write_graph', 'graph node id must be unique and non-empty')
            unless $id ne '' && !$seen{$id}++;
        Selecto::Error->throw('invalid_write_graph', "graph node $id must contain a write command")
            unless blessed($node_spec->{command}) && $node_spec->{command}->isa('Selecto::Write::Command');
        my $bindings = $node_spec->{bindings} // [];
        Selecto::Error->throw('invalid_write_graph', "graph node $id bindings must be an array")
            unless ref($bindings) eq 'ARRAY';
        Selecto::Error->throw('invalid_write_graph', 'graph root must not contain bindings')
            if $index == 0 && @$bindings;
        Selecto::Error->throw('invalid_write_graph', "graph child $id must bind to an earlier node")
            if $index > 0 && !@$bindings;
        my $assignments = $node_spec->{command}->assignments;
        my %bound_fields;
        my @normalized_bindings = map {
            my $binding_spec = $_;
            Selecto::Error->throw('invalid_write_graph', "graph node $id binding must be an object")
                unless ref($binding_spec) eq 'HASH';
            my $field = defined($binding_spec->{field}) ? "$binding_spec->{field}" : '';
            my $from = defined($binding_spec->{from}) ? "$binding_spec->{from}" : '';
            my $key = defined($binding_spec->{key}) ? "$binding_spec->{key}" : '';
            Selecto::Error->throw('invalid_write_graph', "graph node $id binding requires field, from, and key")
                unless $field ne '' && $from ne '' && $key ne '';
            Selecto::Error->throw('invalid_write_graph', "graph node $id binding field and key must be identifiers")
                unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
                    && $key =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
            Selecto::Error->throw('invalid_write_graph', "graph node $id binding source $from must be an earlier node")
                unless exists($seen{$from}) && $from ne $id;
            Selecto::Error->throw('invalid_write_graph', "graph node $id binds field $field more than once")
                if $bound_fields{$field}++;
            Selecto::Error->throw('invalid_write_graph', "graph node $id binding would overwrite assignment $field")
                if exists $assignments->{$field};
            my $scope_field = defined($binding_spec->{scope_field}) ? "$binding_spec->{scope_field}" : undef;
            Selecto::Error->throw('invalid_write_graph', "graph node $id binding scope_field must equal field")
                if defined($scope_field) && $scope_field ne $field;
            if (!$required_returning_seen{$from}{$key}++) {
                push @{$required_returning{$from}}, $key;
            }
            { field => $field, from => $from, key => $key, (defined($scope_field) ? (scope_field => $scope_field) : ()) };
        } @$bindings;
        push @normalized, {
            id => $id,
            command => $node_spec->{command},
            bindings => \@normalized_bindings,
        };
    }

    # Every downstream binding key must be materialized by its source write.
    # Add those internal RETURNING fields without mutating the caller's command
    # or discarding explicitly requested result fields.
    for my $node (@normalized) {
        my $required = $required_returning{$node->{id}} // [];
        next unless @$required;
        my $metadata = $node->{command}->metadata;
        my $returning = $metadata->{returning} // [];
        Selecto::Error->throw('invalid_write', 'returning must be an array of field names')
            unless ref($returning) eq 'ARRAY' && !grep { !defined($_) || ref($_) } @$returning;
        my %returned = map { ("$_" => 1) } @$returning;
        $metadata->{returning} = [
            map { "$_" } @$returning,
            map { $returned{"$_"}++ ? () : "$_" } @$required,
        ];
        $node->{command} = $node->{command}->with_metadata($metadata);
    }
    return bless { nodes => \@normalized }, $class;
}

sub nodes {
    return [map {{
        %{$_},
        bindings => [map {{%$_}} @{$_->{bindings}}],
    }} @{$_[0]->{nodes}}];
}

package Selecto::Write::Graph::Result;

use 5.034;
use strict;
use warnings;

sub new { my ($class, %args) = @_; return bless { %args }, $class; }
sub nodes { return { %{$_[0]->{nodes} // {}} }; }
sub root  { return $_[0]->{root}; }

package Selecto::Write::Result;

use 5.034;
use strict;
use warnings;

sub new { my ($class, %args) = @_; return bless { %args }, $class; }
sub operation { return $_[0]->{operation}; }
sub affected_rows { return $_[0]->{affected_rows}; }
sub values { return { %{$_[0]->{values} // {}} }; }
sub to_hash {
    my ($self) = @_;
    my $value = { operation => $self->{operation}, affected_rows => $self->{affected_rows} };
    $value->{values} = $self->values if keys %{$self->{values} // {}};
    return $value;
}

1;

__END__

=head1 NAME

Selecto::Write - portable write commands, batches, graphs and results

=head1 SYNOPSIS

  use Selecto;

  # Usually built and checked by the engine:
  my $command = $engine->write_command(
      operation   => 'update',
      assignments => {
          quantity   => Selecto::Write::Expression->decrement('quantity', 1),
          updated_at => Selecto::Write::Expression->current_timestamp,
      },
      filter => ['eq', 'id', 42],
  );
  my $result = $engine->execute_write($command);
  print $result->affected_rows;

  # Or constructed directly:
  my $insert = Selecto::Write::Command->new(
      operation   => 'insert',
      relation    => 'orders',          # must be the engine domain's table
      assignments => {order_no => 'PO-41'},
      metadata    => {returning => ['id']},
  );

  my $results = $engine->execute_batch(Selecto::Write::Batch->new($insert, $command));

=head1 DESCRIPTION

Writes in Selecto are data. A L</Selecto::Write::Command> says what to
change; the L<Selecto::Engine> checks it against the domain's C<writes>
contract, applies trusted tenant scope, and passes it to the adapter with a
single-use L<Selecto::Write::Authorization>. SQL adapters refuse to execute
a command, batch or graph that did not come through an engine
(C<ungoverned_write>).

Every write, batch and graph runs in a transaction. When a command's
affected-row count differs from C<expected_count> the transaction rolls back
and C<cardinality_mismatch> is thrown with the expected count in its details
(never the matched count).

Loading C<Selecto::Write> loads all the packages below and
L<Selecto::Write::Expression>.

=head1 Selecto::Write::Command

=head2 new

  my $command = Selecto::Write::Command->new(
      operation      => 'update',       # insert, update, upsert or delete
      relation       => 'orders',       # the domain's table
      assignments    => {status => 'closed'},
      predicate      => Selecto::Expression->eq('id', 42),
      expected_count => 1,              # default 1; pass undef to skip the check
      metadata       => {returning => ['id', 'status']},
  );

Assignment values are plain scalars or L<Selecto::Write::Expression>
objects. The C<predicate> is a L<Selecto::Expression> over root fields only;
association paths and computed fields fail with C<unknown_field>.

C<metadata> keys:

=over 4

=item C<returning>

Root fields to return; they appear in C<values> of the result. Requires the
adapter's C<returning> write capability.

=item C<conflict_target>, C<upsert_update_fields>

Required for upserts: the unique key columns, and the fields to update when
the row exists.

=back

The engine's rules for each operation:

=over 4

=item *

Only root fields granted in C<writes.fields> (C<insertable>,
C<updatable>) can be assigned (C<write_field_not_writable>).

=item *

C<required> fields must be present on inserts and upserts; all omissions are
reported together as C<missing_required_write_fields>.

=item *

An C<expected_count> above one needs C<bulk> on the operation.

=item *

Date assignments must be C<YYYY-MM-DD> or C<undef>.

=item *

Operations the contract does not enable fail with
C<write_operation_not_enabled>.

=back

=head2 Accessors and copies

C<operation>, C<relation>, C<assignments>, C<predicate>,
C<scope_predicate>, C<query_enforcement>, C<expected_count>, C<metadata>.
C<with_assignments>, C<with_metadata>, C<with_scope_predicate> and
C<with_query_enforcement> return modified copies. Commands are never changed
in place.

=head1 Selecto::Write::Batch

  my $batch = Selecto::Write::Batch->new(@commands);   # or \@commands
  my $results = $engine->execute_batch($batch);        # array of results

Runs several commands atomically: if any fails or misses its expected count,
all are rolled back. C<commands> returns the list.

=head1 WRITE GRAPHS

  my $graph = Selecto::Write::Graph->new(nodes => [
      {id => 'order', command => $insert_order},
      {id => 'line',  command => $insert_line,
       bindings => [{field => 'order_id', from => 'order', key => 'id'}]},
  ]);
  my $result = $engine->execute_graph($graph);
  my $order_id = $result->root->values->{id};
  my $line_id  = $result->nodes->{line}->values->{id};

A C<Selecto::Write::Graph> is an ordered list of nodes executed in one
transaction. The first node is the root and has no bindings; every later
node binds at least one field to a value returned by an earlier node.
Construction rejects missing, forward or duplicate bindings and bindings that
would overwrite an authored assignment, and adds the keys later nodes need to
their source node's C<returning>.

The engine checks each child against a writable relationship declared by its
parent's domain:

  writes => {
      relationships => {
          lines => {
              writable => 1, table => 'order_lines',
              parent_key => 'id', child_key => 'order_id',
              allowed_ops => [qw(insert update delete)],
              domain => {...},   # the child's canonical domain; required when strict
          },
      },
  }

Children stay under the parent row they bind to. Update and delete children
receive the parent key as a C<WHERE> condition, never as an assignment; an
upsert child's C<conflict_target> must include the parent key. Graph
execution requires the adapter's C<write_graph> capability (PostgreSQL,
DuckDB, and SQLite 3.35 or newer).

C<Selecto::Write::Graph::Result> has C<root> and C<nodes> (a hash of node id
to L</Selecto::Write::Result>).

=head1 Selecto::Write::Result

C<operation>, C<affected_rows>, C<values> (a hash of the C<returning>
fields), and C<to_hash>, which returns
C<< {operation => ..., affected_rows => ..., values => {...}} >> for JSON
responses.

=head1 TENANT SCOPE

Declare C<< writes.scope.tenant => {field => ..., satisfied_by => ['trusted_context']} >>
and construct the engine with C<< scope => {tenant => $tenant} >>. The
tenant is then added to every update and delete predicate and assigned on
every insert, and commands naming another tenant fail. The full rules are in
L<Selecto::Engine/TENANT SCOPE>.

=head1 REQUIRED PREDICATES

A domain's required predicate (L<Selecto::Domain/with_required_predicate>)
guards every governed write: commands, batch members, the root node of a
graph (children are already confined to their parent row), actions at
preview and execute, and L<Selecto::API::EngineHandler> writes. The engine
adds it to the command's C<scope_predicate> once (a command already carrying
it, or one whose query enforcement does, is not guarded twice) after
C<writes.scope.tenant>, so both boundaries hold.

=over 4

=item *

Updates and deletes match only rows inside the predicate, so a row outside
it is never changed and C<expected_count> counts only rows inside it.

=item *

Inserted rows must satisfy the predicate before the transaction opens
(C<query_rule_violation>; C<query_rule_not_evaluable> when an inserted value
it reads is missing).

=item *

Upserts are refused with C<query_enforcement_unsupported_operation> ("upsert
is not supported on a domain with a required predicate"), because a conflict
can resolve to a row outside the predicate.

=item *

A predicate that reads an association field has no portable write form:
every write on the domain fails with C<query_rule_unsupported_field>
("association fields are not portable write guards"), with C<relation>,
C<fields> and C<associations> in the details.

=back

This deliberately goes beyond the shared protocol's earlier rule that
required predicates are read scopes. A domain without a required predicate
is unaffected.

=head1 QUERY-GUARDED WRITES

L<Selecto::Engine/enforce_query> attaches the predicate of the query that
selected a row to the write that changes it, so a row that stopped matching
between read and write is not changed. The adapter combines the command
predicate, trusted scope and captured predicate in one statement; SQL
three-valued logic is preserved and domain drift fails closed.

=head1 TRANSACTIONS

Adapters open and commit their own transactions on an idle handle. Inside a
transaction the host already holds open, a managed write runs in a
savepoint: it commits or rolls back with the host's transaction and a
failure undoes only the write. A host can instead construct the adapter
with C<< transaction_mode => 'external' >> and an C<< AutoCommit => 0 >> DBI
handle; the adapter then never begins, commits, rolls back or creates
savepoints, and the host must commit on success and roll back on every
exception. See L<Selecto::SQL/transaction_mode>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Engine>, L<Selecto::Write::Expression>,
L<Selecto::Domain/writes>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
