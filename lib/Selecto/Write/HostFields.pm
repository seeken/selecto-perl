package Selecto::Write::HostFields;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Selecto::CanonicalJSON ();
use Selecto::Error ();
use Selecto::Write::Scope ();

# Generated assignments are authority, not command metadata. Copies retain
# that authority only while every generated value is unchanged.
fieldhash my %GENERATED;
sub _json { Selecto::CanonicalJSON->encode($_[0]) }
sub _same {
    my ($a, $b) = @_;
    $a = $a->arguments->[0] if ref($a) eq 'Selecto::Write::Expression' && $a->kind eq 'literal';
    return !ref($a) && defined($a) && "$a" eq "$b";
}
sub inherit {
    my ($class, $old, $new) = @_;
    my $proof = $GENERATED{$old} or return $new;
    my $values = $new->assignments;
    return $new if $new->operation ne $proof->{operation} || $new->relation ne $proof->{relation};
    return $new if grep { !exists($values->{$_}) || !_same($values->{$_}, $proof->{values}{$_}) }
        keys %{$proof->{values}};
    $GENERATED{$new} = $proof;
    return $new;
}
sub apply {
    my ($class, $command, $writes, $context) = @_;
    my $fields = $writes->{host_bound_fields} // {};
    return $command unless keys %$fields;
    Selecto::Error->throw('host_bound_upsert_unsupported', 'host-bound fields require insert, update or delete')
        if $command->operation eq 'upsert';
    my $identity = _json([$fields, $context]);
    my $proof = $GENERATED{$command};
    my $values = $command->assignments;
    for my $field (sort keys %$fields) {
        Selecto::Error->throw('host_bound_field', 'a host-bound field cannot be assigned by a command', {field => $field})
            if exists($values->{$field}) && !($proof && $proof->{identity} eq $identity
                && exists($proof->{values}{$field}) && _same($values->{$field}, $proof->{values}{$field}));
    }
    my %generated;
    for my $field (sort keys %$fields) {
        my $spec = $fields->{$field};
        my $mode = $spec->{mode};
        next if $mode eq 'created_by' && $command->operation ne 'insert';
        my $key = $spec->{source}[1];
        my $value = $context->{$key};
        Selecto::Error->throw('missing_host_context', 'a host-bound field requires trusted scalar context',
            {field => $field, context_key => $key}) unless defined($value) && !ref($value) && length("$value");
        if ($mode eq 'owner') {
            # Use precisely the tenant assignment and pinning implementation.
            $command = Selecto::Write::Scope->apply($command,
                {field => $field, satisfied_by => ['trusted_context']}, $value);
        } elsif ($command->operation ne 'delete') {
            $command = $command->with_assignments({%{$command->assignments}, $field => $value});
        }
        $generated{$field} = $value if exists $command->assignments->{$field};
    }
    $GENERATED{$command} = {identity => $identity, values => \%generated, operation => $command->operation, relation => $command->relation};
    return $command;
}

1;
