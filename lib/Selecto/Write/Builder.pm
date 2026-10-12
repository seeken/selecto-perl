package Selecto::Write::Builder;

use 5.034;
use strict;
use warnings;
no overloading;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed reftype);
use Selecto::Error ();
use Selecto::Domain::QueryContract ();
use Selecto::Write::Operation ();

fieldhash my %STATE;
sub _fail { Selecto::Error->throw('invalid_write_builder', $_[0]) }
sub _copy { Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value} }
sub _state {
    my ($self) = @_;
    _fail('an original native write builder is required')
        unless (blessed($self) // '') eq __PACKAGE__
            && (reftype($self) // '') eq 'SCALAR' && exists $STATE{$self};
    my $s = $STATE{$self};
    $s->{engine}->assert_domain_identity;
    _fail('write builder has already been consumed') if $s->{consumed};
    if ($s->{row}) { require Selecto::Write::Editable; Selecto::Write::Editable->assert_live($s->{row}) }
    return $s;
}
sub _from_editable {
    my ($class, $engine, $row, $edge) = @_;
    _fail('editable builder binding is native-only') unless caller eq 'Selecto::Write::Editable';
    my $self = $class->new($engine);
    $STATE{$self}{row} = $row;
    $STATE{$self}{edge} = $edge if defined $edge;
    return $self;
}
sub new {
    my ($class, $engine, @extra) = @_;
    _fail('constructor requires exactly one configured native engine')
        unless $class eq __PACKAGE__ && !@extra
            && (blessed($engine) // '') eq 'Selecto::Engine';
    $engine->assert_domain_identity;
    my $token = 0;
    my $self = bless \$token, __PACKAGE__;
    $STATE{$self} = {engine => $engine, inputs => {}, assignments => {}, filters => []};
    return $self;
}
sub _mode {
    my ($s, $mode) = @_;
    _fail("method requires $mode mode") unless ($s->{mode} // '') eq $mode;
}
sub _select {
    my ($self, $type, @args) = @_;
    _fail('operation selection takes no values; use assignments') if @args;
    my $s = _state($self);
    _fail('row-bound writes require update; related writes require insert')
        if $s->{row} && $type ne (defined($s->{edge}) ? 'insert' : 'update');
    _fail('operation cannot be changed on this draft')
        if defined($s->{mode}) && ($s->{mode} ne 'scalar' || $s->{type} ne $type);
    @{$s}{qw(mode type)} = ('scalar', $type);
    return $self;
}
sub insert { my $self = shift; $self->_select('insert', @_) }
sub update { my $self = shift; $self->_select('update', @_) }
sub upsert { my $self = shift; $self->_select('upsert', @_) }
sub delete { my $self = shift; $self->_select('delete', @_) }
sub action {
    my ($self, @args) = @_;
    my $s = _state($self);
    _fail('row-bound action convenience is not supported yet; use an explicit action target') if $s->{row};
    my $name = _copy($args[0]);
    _fail('action requires one nonblank name')
        unless @args == 1 && defined($name) && !ref($name) && $name =~ /\S/;
    _fail('action cannot replace a selected operation or action')
        if defined($s->{mode}) && ($s->{mode} ne 'action' || $s->{action} ne $name);
    _fail('action is not declared by the domain') unless exists $s->{engine}->domain->actions->{$name};
    @{$s}{qw(mode action)} = ('action', $name);
    return $self;
}
sub _pairs {
    my (@args) = @_;
    return _copy($args[0]) if @args == 1 && ref($args[0]) eq 'HASH';
    _fail('values must be a hashref or even field/value pairs') if @args % 2;
    my $pairs = _copy([@args]);
    my %values;
    while (@$pairs) {
        my ($key, $value) = splice @$pairs, 0, 2;
        _fail('field and input names must be nonblank scalars')
            unless defined($key) && !ref($key) && $key =~ /\S/;
        _fail('duplicate field or input name') if exists $values{$key};
        $values{$key} = $value;
    }
    return \%values;
}
sub assignments {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'scalar');
    _fail('delete does not accept assignments') if $s->{type} eq 'delete';
    my $values = _pairs(@args);
    if ($s->{row} && !defined($s->{edge})) {
        my $identity = Selecto::Write::Editable->identity_filter($s->{row});
        _fail('row-bound update cannot change primary identity') if exists $values->{$identity->[0]};
    }
    $s->{assignments} = $values;
    return $self;
}
sub inputs {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'action');
    my $values = _pairs(@args);
    $s->{inputs} = $values;
    return $self;
}
sub target {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'action');
    _fail('target requires one native target') unless @args == 1;
    my $target = _copy($args[0]);
    $s->{target} = $target;
    return $self;
}
sub with_tenant {
    my ($self, @args) = @_;
    my $s = _state($self);
    _fail('with_tenant requires one non-null tenant identity') unless @args == 1 && defined($args[0]);
    my $tenant = _copy($args[0]);
    _fail('tenant identity must be a nonblank scalar') if ref($tenant) || $tenant !~ /\S/;
    my $next = $s->{engine}->with_write_context({tenant_id => $tenant});
    $s->{engine} = $next;
    return $self;
}
sub filter {
    my ($self, @args) = @_;
    _fail('filter requires one predicate') unless @args == 1;
    if ((blessed($args[0]) // '') eq 'Selecto::Expression') {
        my $s = _state($self); _mode($s, 'scalar');
        _fail('related inserts cannot add filters') if defined $s->{edge};
        require Selecto::Write::QueryEnforcement;
        my $evidence = Selecto::Write::QueryEnforcement->capture($s->{engine}->query->where($args[0]));
        my %fields = map { $_ => 1 } keys %{$s->{engine}->domain->fields};
        my $predicate = Selecto::Write::QueryEnforcement::_filters($evidence->{filters}, \%fields);
        $s->{predicates} = [@{$s->{predicates} // []}, $predicate];
        return $self;
    }
    return $self->filters([@args]);
}
sub filters {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'scalar');
    _fail('related inserts cannot add filters') if defined $s->{edge};
    _fail('filters requires one array') unless @args == 1;
    my $filters = _copy($args[0]);
    _fail('filters must be an array of native portable predicates') unless ref($filters) eq 'ARRAY';
    # Validate with the same parser compilation uses, without authorizing a write.
    require Selecto::Write::PortableCommand;
    my %fields = map { $_ => 1 } keys %{$s->{engine}->domain->fields};
    Selecto::Write::PortableCommand->_filters($filters, \%fields);
    $s->{filters} = [@{$s->{filters}}, @$filters];
    return $self;
}
sub _fields {
    my (@args) = @_;
    my $fields = _copy(@args == 1 && ref($args[0]) eq 'ARRAY' ? $args[0] : \@args);
    my %seen;
    _fail('fields must be unique scalar identifiers') if grep {
        !defined($_) || ref($_) || !/\A[A-Za-z_][A-Za-z0-9_]*\z/ || $seen{$_}++
    } @$fields;
    return $fields;
}
sub _projection {
    my ($self, $mode, @args) = @_;
    my $s = _state($self); _mode($s, 'scalar');
    _fail('related inserts cannot override result mode') if defined $s->{edge} && $mode ne 'returning';
    _fail('returning and return_for_update are mutually exclusive')
        if defined($s->{result_mode}) && $s->{result_mode} ne $mode;
    my $fields = _fields(@args);
    @{$s}{qw(result_mode returning)} = ($mode, $fields);
    return $self;
}
sub returning { my $self = shift; $self->_projection('returning', @_) }
sub return_for_update { my $self = shift; $self->_projection('editable', @_) }
sub expected_cardinality {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'scalar');
    _fail('related inserts have exact cardinality one') if defined $s->{edge};
    _fail('expected_cardinality requires one value') unless @args == 1;
    my $value = _copy($args[0]);
    require Selecto::Write::Policy;
    Selecto::Write::Policy->resolve_cardinality(
        $s->{engine}->domain->writes->{operations}{$s->{type}}, $value);
    $s->{expected_cardinality} = $value;
    return $self;
}
sub conflict_target {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'scalar');
    _fail('conflict_target requires upsert') unless $s->{type} eq 'upsert';
    $s->{conflict_target} = _fields(@args);
    return $self;
}
sub upsert_update_fields {
    my ($self, @args) = @_;
    my $s = _state($self); _mode($s, 'scalar');
    _fail('upsert_update_fields requires upsert') unless $s->{type} eq 'upsert';
    $s->{upsert_update_fields} = _fields(@args);
    return $self;
}
sub _command {
    my ($s) = @_;
    my $engine = $s->{engine};
    if (defined $s->{edge}) {
        return Selecto::Write::Editable->bound_command($s->{row}, $s->{edge}, $s->{type},
            $s->{assignments}, {returning => $s->{returning} // []});
    }
    my $op = Selecto::Write::Operation->new($engine->domain->as_contract)
        ->operation($s->{type}, $s->{assignments})->filters($s->{filters})
        ->expected_cardinality($s->{expected_cardinality} // ['exactly', 1]);
    $op = $op->filter(Selecto::Write::Editable->identity_filter($s->{row})) if $s->{row};
    $op = $op->enforce_query($engine->query->where(Selecto::Expression->all(@{$s->{predicates}})))
        if @{$s->{predicates} // []};
    for my $key (qw(returning conflict_target upsert_update_fields)) {
        $op = $op->$key($s->{$key}) if exists $s->{$key};
    }
    my $compiled = $op->compile(context => $engine->write_context,
        storage_backend => $engine->adapter->name);
    return $compiled->{command};
}
sub _dispatch {
    my ($self, $phase, @options) = @_;
    my $s = _state($self);
    _fail('select an operation or action before dispatch') unless defined $s->{mode};
    $s->{consumed} = 1 if $phase eq 'execute';
    if ($s->{mode} eq 'action') {
        _fail('action options must be key/value pairs') if @options % 2;
        my %options = @options;
        _fail('unknown action dispatch option') if grep { $_ ne 'resolver' && $_ ne 'context' } keys %options;
        _fail('resolver must be explicit host code')
            if exists($options{resolver}) && ref($options{resolver}) ne 'CODE';
        $options{context} = _copy($options{context}) if exists $options{context};
        my $plan = $s->{engine}->plan_action({action => $s->{action}, inputs => $s->{inputs},
            (exists($s->{target}) ? (target => $s->{target}) : ())});
        my $method = $phase . '_action';
        return $s->{engine}->$method($plan, %options);
    }
    _fail('scalar dispatch takes no options') if @options;
    if ($s->{row}) {
        my ($result, $error);
        my $ok = eval {
            my $command = _command($s);
            if (defined $s->{edge}) {
                if ($phase eq 'preview') {
                    require Selecto::Action::Graph;
                    $result = $s->{engine}->_rules_transaction(sub { Selecto::Action::Graph->preview($s->{engine}, $command) });
                } else {
                    $result = $s->{engine}->execute_graph($command)->nodes->{child};
                }
            } else {
                my $method = $phase . '_write';
                $result = ($s->{result_mode} // '') eq 'editable'
                    ? Selecto::Write::Editable->dispatch($s->{engine}, $command, $phase)
                    : $s->{engine}->$method($command);
            }
            1;
        };
        if (!$ok) {
            $error = $@;
            Selecto::Write::Session->poison($s->{engine}, $error) if $phase eq 'execute';
            die $error;
        }
        return $result;
    }
    my $command = _command($s);
    if (($s->{result_mode} // '') eq 'editable') {
        require Selecto::Write::Editable;
        return Selecto::Write::Editable->dispatch($s->{engine}, $command, $phase);
    }
    my $method = $phase . '_write';
    return $s->{engine}->$method($command);
}
sub preview { my $self = shift; $self->_dispatch('preview', @_) }
sub execute { my $self = shift; $self->_dispatch('execute', @_) }

1;

__END__

=head1 NAME

Selecto::Write::Builder - native fluent governed writes and domain actions

=head1 SYNOPSIS

  my $w = Selecto::Write->new($engine)->insert->with_tenant(8);
  $w->assignments(name => 'Test');
  $w->returning(qw(id name));
  my $preview = $w->preview; # {sql, params}
  my $result = $w->execute;

  my $action = Selecto::Write->new($engine)->action('archive');
  $action->target(42)->inputs(reason => 'completed');
  my $done = $action->execute(resolver => $policy, context => $actor_context);

=head1 DESCRIPTION

Construct through C<Selecto::Write-E<gt>new($engine)>. Setters mutate one local
draft and return it. Assignments/inputs replace their complete sets and accept
hashrefs or even named pairs. Duplicate pairs refuse. Filters add with AND;
native root expressions and portable comparison tuples are supported.
C<with_tenant> binds trusted host context on a private engine copy and supplies
omitted tenant assignments through existing governance. A bound tenant cannot
be changed. Transport inputs never grant trusted context.

Execution freezes and consumes the draft for one attempt, including failures.
Preview does not consume it or grant execution authority. Actions use native
planning and fresh per-phase capability resolution, preserve their native
envelope, and cannot override operation, assignments, or returning policy.
Existing immutable L<Selecto::Write::Operation> remains available separately.

C<return_for_update> instead of C<returning> requires one returned row and an
explicitly granted primary key inside C<$engine-E<gt>transaction(sub {...})>.
PostgreSQL supports opaque row handles, exact-key follow-up updates and declared
owned one-to-many inserts. Other adapters refuse this capability. Handles expire
at callback exit or a changed native connection/transaction. Read-side
C<select_for_update> is available on a configured root query with an exact key
filter, public root fields and the same transaction lifetime.

See F<docs/fluent-writes.md> for complete domain configuration, SQL previews,
native action calls, capability limits and error handling.

=cut
