package Selecto::Write::Capabilities;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use bytes ();
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed refaddr reftype);
use Selecto::Error ();
use Selecto::Limits ();
use Selecto::Write::Policy ();

my $LIMITS = Selecto::Limits->new;
my %OPERATION = map { $_ => 1 } qw(insert update delete upsert);
my %BOOLEAN = map { $_ => 1 } qw(JSON::PP::Boolean JSON::XS::Boolean Types::Serialiser::Boolean);
my %RECORD = map { $_ => 1 } qw(Selecto::Write::Command Selecto::Write::Batch Selecto::Write::Graph
    Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement Selecto::Limits
    Selecto::Domain Selecto::Domain::Association Selecto::DataRules Selecto::Pattern
    Math::BigRat Math::BigInt Math::BigInt::Calc);

sub protocol_version { 1 }
sub _fail { Selecto::Error->throw($_[0], $_[1], $_[2] // {}) }
sub _name { defined($_[0]) && !defined(reftype($_[0])) && $_[0] =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/ }

# Admit complete input before reading fields or calling any native accessor.
# Native prepared graphs contain bounded compiled domain/limit records; their
# larger native-state ceiling does not enlarge portable capability reports.
#
# The walk's counters live in dynamically scoped variables for the length of
# one admission rather than in a state record read by name at every node: a
# write walks its command before governance and again after it. A refusal
# unwinds through local, which also keeps a nested admission (a tied container
# that admits something itself) apart from the one that is under way.
#
# A write is walked before governance and again after it, and the governed
# command carries records that were admitted already: the submitted predicate,
# and the engine's limits record on every write. Expressions and limit
# records are immutable once built, so a native record of exactly one of
# those classes that a walk admitted keeps what that walk charged for it
# (nodes below it, bytes, levels below it), keyed by the record itself, and a
# later walk charges that instead of walking it again. A record whose charge
# would break a limit is walked as before, so a refusal is the walk's own.
my $DEPTH_MAX = $LIMITS->get('max_expression_depth');
my %IMMUTABLE = map { $_ => 1 } qw(Selecto::Expression Selecto::Limits);
fieldhash my %MEASURED;
our ($NODES, $BYTES, $NODES_LIMIT, $BYTES_LIMIT, $NATIVE, $CODE, %ACTIVE);
sub _admit {
    my ($value, $native, $code) = @_;
    local ($NODES, $BYTES, $NATIVE, $CODE) = (0, 0, $native, $code);
    local $NODES_LIMIT = $LIMITS->get($native ? 'max_response_nodes' : 'max_expression_nodes');
    local $BYTES_LIMIT = $LIMITS->get($native ? 'max_response_bytes' : 'max_state_bytes');
    local %ACTIVE;
    _walk($value, 0);
}
# Returns the levels below $value that the walk visited.
sub _walk {
    my ($value, $depth) = @_;
    _fail($CODE, 'write preflight input exceeds its resource limit')
        if ++$NODES > $NODES_LIMIT || $depth > $DEPTH_MAX;
    my $type = reftype($value);
    unless (defined $type) {
        return 0 unless defined $value;
        use bytes;
        _fail($CODE, 'write preflight input exceeds its byte limit') if ($BYTES += length($value)) > $BYTES_LIMIT;
        return 0;
    }
    my $class = blessed($value) // '';
    if ($BOOLEAN{$class} && $type eq 'SCALAR') {
        _fail($CODE, 'write preflight contains an invalid Boolean')
            if !defined($$value) || defined(reftype($$value)) || "$$value" !~ /\A[01]\z/;
        return 0;
    }
    _fail($CODE, 'write preflight contains unsupported executable or object input')
        if length($class) && (!$NATIVE || !$RECORD{$class});
    _fail($CODE, 'write preflight requires plain containers or native records')
        unless $type eq 'HASH' || $type eq 'ARRAY';
    my $address = refaddr($value);
    _fail($CODE, 'write preflight contains a cycle') if $ACTIVE{$address};
    # Only native admission reaches this with a class, so only it records.
    my $immutable = $IMMUTABLE{$class};
    if ($immutable && (my $measured = $MEASURED{$value})) {
        if ($NODES + $measured->[0] <= $NODES_LIMIT && $BYTES + $measured->[1] <= $BYTES_LIMIT
            && $depth + $measured->[2] <= $DEPTH_MAX) {
            $NODES += $measured->[0];
            $BYTES += $measured->[1];
            return $measured->[2];
        }
    }
    my ($nodes_before, $bytes_before) = ($NODES, $BYTES);
    # The marks are discarded when a refusal unwinds, so they need no scope
    # guard. Scalar leaves are counted here, with the same checks in the same
    # order as a call each would make.
    $ACTIVE{$address} = 1;
    my $count = $type eq 'HASH' ? scalar(keys %$value) : scalar(@$value);
    _fail($CODE, 'write preflight input exceeds its node limit')
        if $NODES + $count > $NODES_LIMIT;
    my $deeper = $depth + 1;
    my $too_deep = $deeper > $DEPTH_MAX;
    my $height = 0;
    use bytes;
    if ($type eq 'HASH') {
        for my $key (keys %$value) {
            _fail($CODE, 'write preflight input exceeds its byte limit')
                if ($BYTES += length($key)) > $BYTES_LIMIT;
            # A copy, as an argument list made before: measuring a number's
            # length must not give the caller's scalar a string value.
            my $item = $value->{$key};
            if (defined reftype($item)) {
                my $below = _walk($item, $deeper) + 1;
                $height = $below if $below > $height;
                next;
            }
            _fail($CODE, 'write preflight input exceeds its resource limit')
                if ++$NODES > $NODES_LIMIT || $too_deep;
            $height ||= 1;
            next unless defined $item;
            _fail($CODE, 'write preflight input exceeds its byte limit')
                if ($BYTES += length($item)) > $BYTES_LIMIT;
        }
    } else {
        for my $i (0 .. $#$value) {
            my $item = $value->[$i];
            if (defined reftype($item)) {
                my $below = _walk($item, $deeper) + 1;
                $height = $below if $below > $height;
                next;
            }
            _fail($CODE, 'write preflight input exceeds its resource limit')
                if ++$NODES > $NODES_LIMIT || $too_deep;
            $height ||= 1;
            next unless defined $item;
            _fail($CODE, 'write preflight input exceeds its byte limit')
                if ($BYTES += length($item)) > $BYTES_LIMIT;
        }
    }
    delete $ACTIVE{$address};
    $MEASURED{$value} = [$NODES - $nodes_before, $BYTES - $bytes_before, $height] if $immutable;
    return $height;
}
sub _boolean {
    my ($value) = @_;
    my $type = reftype($value);
    return $$value ? 1 : 0 if defined($type) && $type eq 'SCALAR' && $BOOLEAN{blessed($value) // ''};
    return undef if defined($type) || !defined($value);
    return undef unless B::svref_2object(\$value)->FLAGS & B::SVf_IOK();
    return $value == 0 ? 0 : $value == 1 ? 1 : undef;
}
sub validate {
    my ($class, $capabilities) = @_;
    _admit($capabilities, 0, 'invalid_write_capabilities');
    _fail('invalid_write_capabilities', 'write adapter capabilities must be an object') unless ref($capabilities) eq 'HASH';
    _fail('invalid_write_capabilities', 'write adapter did not report a protocol version', {expected => 1})
        unless exists $capabilities->{protocol_version};
    my $version = $capabilities->{protocol_version};
    _fail('write_protocol_mismatch', 'write adapter uses an incompatible protocol version',
        {expected => 1, actual => $version})
        unless defined($version) && !defined(reftype($version))
            && B::svref_2object(\$version)->FLAGS & B::SVf_IOK() && $version == 1;
    for my $key (keys %$capabilities) {
        next if $key eq 'protocol_version';
        _fail('invalid_write_capabilities', 'write capability names must be identifiers') unless _name($key);
        my $value = $capabilities->{$key};
        if ($key eq 'returning' && ref($value) eq 'HASH') {
            _fail('invalid_write_capabilities', 'returning capabilities require explicit operation Booleans')
                if grep { !$OPERATION{$_} || !defined(_boolean($value->{$_})) } keys %$value;
        } elsif ($key eq 'returning' && ref($value) eq 'ARRAY') {
            _fail('invalid_write_capabilities', 'returning capabilities require operation names')
                if grep { !_name($_) || !$OPERATION{$_} } @$value;
        } elsif ($key eq 'generated_keys' && !defined(reftype($value)) && defined($value) && $value eq 'returning') {
            next;
        } else {
            _fail('invalid_write_capabilities', 'write capabilities require explicit Booleans') unless defined(_boolean($value));
        }
    }
    return 1;
}
sub _supported {
    my ($capabilities, $capability) = @_;
    if (ref($capability) eq 'ARRAY') {
        my $value = $capabilities->{returning}; my $operation = $capability->[1];
        return _boolean($value->{$operation}) // 0 if ref($value) eq 'HASH';
        return scalar(grep { $_ eq $operation } @$value) ? 1 : 0 if ref($value) eq 'ARRAY';
        return _boolean($value) // 0;
    }
    my $value = $capabilities->{$capability};
    return 1 if $capability eq 'generated_keys' && defined($value) && !defined(reftype($value)) && $value eq 'returning';
    return _boolean($value) // 0;
}
sub _requirement {
    my ($value) = @_;
    return if _name($value);
    return if ref($value) eq 'ARRAY' && @$value == 2 && defined($value->[0]) && !defined(reftype($value->[0]))
        && $value->[0] eq 'returning' && _name($value->[1]) && $OPERATION{$value->[1]};
    _fail('invalid_write', 'write requirement must be a capability name or returning operation');
}
sub supported {
    my ($class, $capabilities, $capability) = @_;
    $class->validate($capabilities); _admit($capability, 0, 'invalid_write'); _requirement($capability);
    return _supported($capabilities, $capability);
}
sub _command {
    my ($command) = @_;
    _fail('invalid_write', 'write requirements need a native command') unless (blessed($command) // '') eq 'Selecto::Write::Command';
    my $operation = $command->{operation}; my $metadata = $command->{metadata};
    _fail('invalid_write', 'write command has an invalid operation or metadata')
        unless _name($operation) && $OPERATION{$operation} && ref($metadata) eq 'HASH' && ref($command->{assignments}) eq 'HASH';
    _fail('invalid_write', 'write cardinality requires a finite nonnegative integer')
        if defined($command->{expected_count}) && (defined(reftype($command->{expected_count}))
            || "$command->{expected_count}" !~ /\A\d{1,9}\z/);
    # Invalid cardinality is structural intent, so reject it before capability
    # discovery can issue a native feature/version query.
    if (exists $metadata->{expected_cardinality}) {
        my ($minimum, $maximum) = @{Selecto::Write::Policy->cardinality_bounds($metadata->{expected_cardinality})};
        my $expected = $command->{expected_count};
        _fail('invalid_expected_cardinality', 'legacy count conflicts with declared write cardinality')
            if defined($expected) && (ref($expected) || "$expected" !~ /\A\d{1,9}\z/
                || $expected < $minimum || defined($maximum) && $expected > $maximum);
    }
    my @required = ($operation);
    my $extra = $metadata->{required_capabilities} // [];
    _fail('invalid_write', 'required capabilities must be an array') unless ref($extra) eq 'ARRAY';
    for my $capability (@$extra) { _requirement($capability); push @required, $capability }
    my $returning = $metadata->{returning} // [];
    _fail('invalid_write', 'returning must be an array of field names')
        unless ref($returning) eq 'ARRAY' && !grep { !defined($_) || defined(reftype($_)) || $_ !~ /\S/ } @$returning;
    push @required, ['returning', $operation] if @$returning;
    my $constraints = $metadata->{native_constraints} // [];
    _fail('invalid_write', 'native constraints must be an array') unless ref($constraints) eq 'ARRAY';
    push @required, 'native_constraint_mapping' if @$constraints;
    # No native document-write representation/compiler exists at this boundary.
    _fail('invalid_write', 'native document mutations are not supported by this write protocol') if exists $metadata->{document};
    push @required, 'mutation_expressions' if grep { (blessed($_) // '') eq 'Selecto::Write::Expression' } values %{$command->{assignments}};
    return @required;
}
sub requirements {
    my ($class, $write) = @_;
    _admit($write, 1, 'invalid_write');
    my $kind = blessed($write) // ''; my @required;
    if ($kind eq 'Selecto::Write::Command') { @required = _command($write) }
    elsif ($kind eq 'Selecto::Write::Batch') {
        _fail('invalid_write', 'batch commands must be a nonempty array') unless ref($write->{commands}) eq 'ARRAY' && @{$write->{commands}};
        @required = ('transactions', 'atomic_batch', map { _command($_) } @{$write->{commands}});
    } elsif ($kind eq 'Selecto::Write::Graph') {
        _fail('invalid_write_graph', 'graph nodes must be a nonempty array') unless ref($write->{nodes}) eq 'ARRAY' && @{$write->{nodes}};
        @required = ('transactions', 'write_graph');
        my $generated = 0; my %earlier;
        for my $node (@{$write->{nodes}}) {
            _fail('invalid_write_graph', 'graph node requires a command and bindings')
                unless ref($node) eq 'HASH' && ref($node->{bindings}) eq 'ARRAY';
            push @required, _command($node->{command});
            _fail('invalid_write_graph', 'graph node identity must be distinct')
                unless defined($node->{id}) && !defined(reftype($node->{id})) && $node->{id} =~ /\S/
                    && !exists $earlier{$node->{id}};
            for my $binding (@{$node->{bindings}}) {
                _fail('invalid_write_graph', 'graph binding requires an earlier source and stored field identifiers')
                    unless ref($binding) eq 'HASH' && defined($binding->{from}) && !defined(reftype($binding->{from}))
                        && exists($earlier{$binding->{from}}) && _name($binding->{field}) && _name($binding->{key});
                push @required, ['returning', $earlier{$binding->{from}}{operation}];
                $generated = 1;
            }
            $earlier{$node->{id}} = $node->{command};
        }
        push @required, 'generated_keys' if $generated;
        my $sets = $write->{owned_sets} // [];
        _fail('invalid_write_graph', 'owned sets must be an array') unless ref($sets) eq 'ARRAY';
        push @required, 'owned_set_sync', 'delete' if @$sets;
    } else { _fail('invalid_write', 'write requirements need a native command, batch or graph') }
    my %seen;
    return [grep { !$seen{ref($_) eq 'ARRAY' ? join(':', @$_) : $_}++ } @required];
}
sub require {
    my ($class, $capabilities, $write) = @_;
    $class->validate($capabilities);
    return _require($capabilities, $class->requirements($write));
}
sub _require {
    my ($capabilities, $required) = @_;
    my @missing = grep { !_supported($capabilities, $_) } @$required;
    _fail('write_capability_missing', 'configured adapter cannot preserve requested write semantics',
        {required => $required, missing => \@missing}) if @missing;
    return 1;
}
sub preflight {
    my ($class, $adapter, $write) = @_;
    # One admission walk per preflight: the requirements computed here are
    # the ones checked against the adapter's report below.
    my $required = $class->requirements($write);
    # A dialect may refuse a structured operation whose physical semantics it
    # cannot supply. This preserves specific fail-closed intent diagnostics;
    # the hook never grants a missing protocol/capability or dispatches SQL.
    if ($adapter->can('_validate_write_intent')) {
        my ($ok, $error);
        { local $@; $ok = eval { $adapter->_validate_write_intent($write); 1 }; $error = $@ unless $ok }
        if (!$ok) {
            die $error if (blessed($error) // '') eq 'Selecto::Error';
            _fail('invalid_write_capabilities', 'write adapter intent validation failed');
        }
    }
    my ($capabilities, $failed);
    { local $@; my $ok = eval { $capabilities = $adapter->write_capabilities; 1 }; $failed = !$ok }
    _fail('invalid_write_capabilities', 'write adapter capability discovery failed') if $failed;
    $class->validate($capabilities);
    return _require($capabilities, $required);
}
1;

=head1 DESCRIPTION

Versioned, bounded write capability preflight for native commands, batches and
graphs. C<validate>, C<requirements>, C<require> and C<supported> return a true
value (or a requirement array) and throw typed C<Selecto::Error> refusals. A
capability report must contain numeric C<protocol_version =E<gt> 1> and explicit
native 0/1 or JSON Boolean flags. C<returning> may instead list supported
operations or map operations to explicit flags. C<generated_keys =E<gt>
'returning'> is the recognized generated-value mode, alongside Boolean flags.

Command metadata carries C<returning>, C<required_capabilities> and
C<native_constraints>; nonempty constraints require native constraint mapping.
Actual mutation-expression assignments require C<mutation_expressions>.
Generated graph dependencies require generated keys and their source command's
RETURNING operation. Native document mutation compilation is unavailable and
is refused. Capability support establishes semantics, never authorization.

Admission traverses complete input without overload, accessor, serialization or
tie hooks, rejects cycles and applies fixed node/byte/depth ceilings. Prepared
native records use the existing larger native response-state ceiling; portable
adapter reports retain the smaller metadata ceiling. Pure governance and
adapter-neutral compilation do not call this dispatch boundary automatically.
C<preflight($adapter,$write)> admits the native write before invoking the
trusted adapter's report callback and converts callback failures to a safe
typed capability error; it does not dispatch the mutation.

=cut
