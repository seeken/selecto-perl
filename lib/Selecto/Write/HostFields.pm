package Selecto::Write::HostFields;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Selecto::CanonicalJSON ();
use Selecto::Error ();
use Selecto::Write::Scope ();
use Selecto::Write::Expression ();

# Generated assignments are authority, not command metadata. Copies retain
# that authority only while every generated value is unchanged.
fieldhash my %GENERATED;
sub _json { Selecto::CanonicalJSON->encode($_[0]) }
sub _same {
    my ($a, $b) = @_;
    return ref($a) eq 'Selecto::Write::Expression' && $a->kind eq 'current_timestamp'
        if ref($b) eq 'Selecto::Write::Expression' && $b->kind eq 'current_timestamp';
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
    my ($class, $command, $writes, $context, %options) = @_;
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
        next if ($mode eq 'created_by' || $mode eq 'created_at') && $command->operation ne 'insert';
        if ($mode eq 'created_at' || $mode eq 'modified_at') {
            next if $command->operation eq 'delete' || $options{defer_timestamps};
            my $value = Selecto::Write::Expression->current_timestamp;
            $command = $command->with_assignments({%{$command->assignments}, $field => $value});
            $generated{$field} = $value;
            next;
        }
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

__END__

=head1 NAME

Selecto::Write::HostFields - trusted write bindings and database clocks

=head1 DESCRIPTION

Internal shared lifecycle for C<writes.host_bound_fields>. C<owner> pins trusted
ownership; C<created_by> and C<modified_by> fill trusted actor context.
C<created_at> fills inserts and C<modified_at> fills inserts and updates with
L<Selecto::Write::Expression/current_timestamp>. Clock modes declare no C<source>
and use database time in the mutation statement, including bulk updates.
Database timezone, transaction and column precision rules apply.

All modes refuse caller assignments as C<host_bound_field> and upserts as
C<host_bound_upsert_unsupported>. Private in-process provenance survives only
unchanged generated assignments and matching operation, relation and context;
serialized metadata cannot grant this authority. The portable compiler defers
clock expressions until its plain literal admission has completed. Literal
validators on database expressions remain C<required_data_rule_pending>.

See L<Selecto::Domain/writes> and F<docs/saved-views-governance.md>.

=cut
