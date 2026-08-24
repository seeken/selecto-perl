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
