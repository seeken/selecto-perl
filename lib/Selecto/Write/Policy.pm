package Selecto::Write::Policy;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed reftype);
use JSON::PP ();
use Selecto::Error ();
use Selecto::Domain::QueryContract ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();

sub _fail {
    my ($code, $message, %details) = @_;
    Selecto::Error->throw($code, $message, {code => $code, %details});
}
sub _plain {
    return Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value};
}
sub _true {
    my ($value) = @_;
    return $$value == 1 if (reftype($value) // '') eq 'SCALAR' && JSON::PP::is_bool($value);
    return defined($value) && !defined(reftype($value)) && $value eq '1';
}
sub normalize_cardinality {
    my ($class, $raw) = @_;
    my $value = _plain($raw);
    return 'many' if defined($value) && !ref($value) && $value eq 'many';
    if (ref($value) eq 'ARRAY') {
        my ($kind, @counts) = @$value;
        if (defined($kind) && !ref($kind)) {
            my $arity = $kind eq 'between' ? 2 : $kind =~ /\A(?:exactly|at_most|at_least)\z/ ? 1 : 0;
            if ($arity && @counts == $arity
                && !grep { !defined($_) || ref($_) || !/\A\d{1,9}\z/ } @counts) {
                @counts = map { 0 + $_ } @counts;
                return [$kind, @counts] if ($kind ne 'exactly' || $counts[0] > 0)
                    && ($kind ne 'between' || $counts[1] >= $counts[0]);
            }
        }
    }
    _fail('invalid_expected_cardinality', 'invalid expected write cardinality');
}
sub cardinality_bounds {
    my ($class, $value) = @_;
    $value = $class->normalize_cardinality($value);
    return [0, undef] if !ref($value);
    return [$value->[1], $value->[1]] if $value->[0] eq 'exactly';
    return [0, $value->[1]] if $value->[0] eq 'at_most';
    return [$value->[1], undef] if $value->[0] eq 'at_least';
    return [$value->[1], $value->[2]];
}
sub resolve_cardinality {
    my ($class, $spec, $requested) = @_;
    my $input = _plain({spec => $spec, requested => $requested});
    ($spec, $requested) = @{$input}{qw(spec requested)};
    _fail('invalid_write_policy', 'write operation policy must be an object') unless ref($spec) eq 'HASH';
    my $ceiling = exists($spec->{expected_cardinality}) ? $spec->{expected_cardinality}
        : defined($requested) && _true($spec->{bulk}) ? 'many' : ['exactly', 1];
    $ceiling = $class->normalize_cardinality($ceiling);
    return $ceiling unless defined $requested;
    $requested = $class->normalize_cardinality($requested);
    my ($want, $allow) = ($class->cardinality_bounds($requested), $class->cardinality_bounds($ceiling));
    _fail('expected_cardinality_policy_violation', 'caller cardinality cannot weaken domain policy',
        domain_expected_cardinality => $ceiling, requested_expected_cardinality => $requested)
        unless $want->[0] >= $allow->[0]
            && (!defined($allow->[1]) || defined($want->[1]) && $want->[1] <= $allow->[1]);
    return $requested;
}
sub normalize_returning {
    my ($class, $raw) = @_;
    my $value = _plain($raw);
    return 'none' unless defined $value;
    return $$value ? 'all' : 'none' if JSON::PP::is_bool($value);
    if (!ref($value)) {
        return 'none' if $value =~ /\A(?:0|minimal|count|none)\z/;
        return 'all' if $value =~ /\A(?:1|all|record|records)\z/;
    }
    return $value if ref($value) eq 'ARRAY' && !grep { !defined($_) || ref($_) || !/\A[A-Za-z_][A-Za-z0-9_]*\z/ } @$value;
    _fail('invalid_returning_policy', 'invalid write returning policy');
}
sub resolve_returning {
    my ($class, $spec, $requested, $fields) = @_;
    my $input = _plain({spec => $spec, requested => $requested, fields => $fields});
    ($spec, $requested, $fields) = @{$input}{qw(spec requested fields)};
    _fail('invalid_write_policy', 'write operation policy and field registry must be objects')
        unless ref($spec) eq 'HASH' && ref($fields) eq 'HASH';
    my $ceiling = $class->normalize_returning($spec->{returning});
    $ceiling = 'all' if ref($requested) eq 'ARRAY' && !exists($spec->{returning});
    my $value = defined($requested) ? $class->normalize_returning($requested) : $ceiling;
    my $subset = !ref($value) && $value eq 'none' || !ref($ceiling) && $ceiling eq 'all';
    if (ref($value) eq 'ARRAY' && ref($ceiling) eq 'ARRAY') {
        my %allowed = map { $_ => 1 } @$ceiling;
        $subset = !grep { !$allowed{$_} } @$value;
    }
    _fail('returning_policy_violation', 'caller returning policy exceeds domain policy',
        domain_returning => $ceiling, requested_returning => $value) unless $subset;
    my @returned = !ref($value) ? $value eq 'all' ? sort keys %$fields : () : @$value;
    my %seen;
    for my $field (@returned) {
        _fail('duplicate_returning_identifier', 'returning identifiers must be distinct', field => $field) if $seen{$field}++;
        _fail('undeclared_write_identifier', 'returning field must be declared on the write source',
            field => $field, identifier_kind => 'returning') unless exists $fields->{$field};
    }
    return \@returned;
}
sub _has_write_once_guard {
    my ($predicate, $field) = @_;
    return 0 unless blessed($predicate) && ref($predicate) eq 'Selecto::Expression';
    if ($predicate->kind eq 'and') {
        return scalar(grep { _has_write_once_guard($_, $field) } @{$predicate->arguments->[0]});
    }
    return 0 unless $predicate->kind eq 'is_null';
    my $operand = $predicate->arguments->[0];
    return blessed($operand) && ref($operand) eq 'Selecto::Expression'
        && $operand->kind eq 'field' && $operand->arguments->[0] eq $field;
}
sub _missing {
    my ($assignments, $field) = @_;
    return 1 unless exists $assignments->{$field};
    my $value = $assignments->{$field};
    if (blessed($value) && ref($value) eq 'Selecto::Write::Expression') {
        return 1 unless $value->kind eq 'literal';
        $value = $value->arguments->[0];
    }
    return !defined($value) || !ref($value) && $value !~ /\S/;
}

# Native governance calls this after authoritative tenant scoping and before
# authorization. Policy copies must be retained by the caller, because
# write-once guards and normalized result/cardinality metadata are executable.
sub apply {
    my ($class, $command, $raw_writes, $fields, %options) = @_;
    my $writes = _plain($raw_writes // {});
    _fail('invalid_domain', 'writes must be an object') unless ref($writes) eq 'HASH';
    my $operation = $command->operation;
    my $spec = ref($writes->{operations}) eq 'HASH' ? $writes->{operations}{$operation} : undef;
    return $command unless ref($spec) eq 'HASH'; # Existing governance diagnoses missing grants.
    my $metadata = $command->metadata;
    if (exists($spec->{expected_cardinality}) || exists($metadata->{expected_cardinality})) {
        my $requested = $metadata->{expected_cardinality};
        my $legacy_count = $command->expected_count;
        _fail('invalid_write', 'legacy write count must be a finite nonnegative integer')
            if defined($legacy_count) && (ref($legacy_count) || $legacy_count !~ /\A\d{1,9}\z/);
        if (exists($metadata->{expected_cardinality}) && defined($command->expected_count)) {
            my ($minimum, $maximum) = @{$class->cardinality_bounds($requested)};
            _fail('invalid_expected_cardinality', 'legacy exact count conflicts with declared write cardinality')
                if ref($legacy_count) || $legacy_count !~ /\A\d{1,9}\z/
                    || $legacy_count < $minimum || defined($maximum) && $legacy_count > $maximum;
            # The old exact count is an additional caller constraint, not a
            # default that governance may discard when a range is also given.
            $requested = $legacy_count == 0 ? ['between', 0, 0] : ['exactly', 0 + $legacy_count];
        }
        $requested = $legacy_count == 0 ? ['between', 0, 0] : ['exactly', $legacy_count]
            if !defined($requested) && defined($legacy_count);
        $requested //= 'many';
        my $resolved = $class->resolve_cardinality($spec, $requested);
        $metadata->{expected_cardinality} = $resolved;
        $command = $command->_with(expected_count => defined($legacy_count) ? $legacy_count
            : ref($resolved) && $resolved->[0] eq 'exactly' ? $resolved->[1] : undef);
    }
    if (exists $spec->{returning}) {
        my $requested = $metadata->{returning};
        $requested = 'none' if !defined($requested) || ref($requested) eq 'ARRAY' && !@$requested;
        $metadata->{returning} = $class->resolve_returning($spec, $requested, $fields);
    }
    my $assignments = $command->assignments;
    my $field_specs = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : {};
    if ($operation eq 'upsert') {
        my $updates = _plain($metadata->{upsert_update_fields} // []);
        _fail('invalid_write', 'upsert update fields must be an array of field identifiers')
            unless ref($updates) eq 'ARRAY' && !grep { !defined($_) || ref($_) || !/\A[A-Za-z_][A-Za-z0-9_]*\z/ } @$updates;
        for my $field (@$updates) {
            my $field_spec = $field_specs->{$field};
            next unless ref($field_spec) eq 'HASH';
            my ($reason) = grep { _true($field_spec->{$_}) } qw(immutable write_once server_managed);
            _fail('write_field_not_writable', 'upsert conflict branch cannot rewrite a protected field',
                field => $field, reason => $reason) if defined $reason;
        }
    }
    if ($operation eq 'insert' || $operation eq 'upsert') {
        my @missing = sort grep {
            my $field_spec = $field_specs->{$_};
            my $required = ref($field_spec) eq 'HASH' && (_true($field_spec->{required})
                || ref($field_spec->{required_on}) eq 'ARRAY' && grep { $_ eq 'insert' } @{$field_spec->{required_on}});
            $required && _missing($assignments, $_);
        } keys %$field_specs;
        _fail('missing_required_write_fields', 'required write fields are missing', fields => \@missing) if @missing;
    }
    if ($operation ne 'delete') {
        for my $field (sort keys %$assignments) {
            my $field_spec = $field_specs->{$field};
            next unless ref($field_spec) eq 'HASH';
            next if grep { $field eq $_ } _trusted_fields($options{trusted_field});
            _fail('write_field_not_writable', 'server-managed fields cannot be assigned', field => $field, reason => 'server_managed')
                if _true($field_spec->{server_managed});
            if ($operation eq 'update' && _true($field_spec->{immutable})) {
                _fail('write_field_not_writable', 'immutable fields cannot be updated', field => $field, reason => 'immutable');
            }
            if ($operation eq 'update' && _true($field_spec->{write_once})
                && !_has_write_once_guard($command->predicate, $field)) {
                $command = $command->_with(predicate => Selecto::QueryEnforcement::combine(
                    $command->predicate, Selecto::Expression->is_null($field)));
            }
        }
    }
    if (_true($spec->{require_filter}) && ($operation eq 'update' || $operation eq 'delete')) {
        _fail('missing_predicate', 'write operation requires a governed filter')
            unless defined($command->predicate) || defined($command->scope_predicate) || defined($command->query_enforcement);
    }
    return $command->with_metadata($metadata);
}

# The fields the engine assigns from trusted scope: one name or a list.
sub _trusted_fields {
    my ($trusted) = @_;
    return grep { defined } (ref($trusted) eq 'ARRAY' ? @$trusted : ($trusted));
}

1;

__END__

=head1 NAME

Selecto::Write::Policy - domain bounds for native write intent

=head1 DESCRIPTION

Resolves returning fields and cardinality as subsets of explicit domain policy.
Native governance applies required insert fields, immutable/server-managed
assignments and atomic write-once predicates before dispatch. The adapter must
enforce resolved cardinality in the transaction. Metadata alone grants no writes.

=cut
