package Selecto::Tenant::Context;

use 5.034;
use strict;
use warnings;
no overloading;
use JSON::PP ();
use Cpanel::JSON::XS ();
use Selecto::Domain::QueryContract ();
use Selecto::Identifier ();
use Selecto::Error ();

sub boolean {
    my ($class, $given, $label) = @_;
    my $copy = Selecto::Domain::QueryContract->copy_declaration({value => $given});
    my $value = $copy->{value};
    return $$value ? 1 : 0 if ref($value) eq 'JSON::PP::Boolean';
    _fail('invalid_tenant_context', "$label must be boolean")
        unless defined($value) && !ref($value) && "$value" =~ /\A[01]\z/;
    return $value ? 1 : 0;
}
sub normalize {
    my ($class, $given) = @_;
    return {} unless defined $given;
    $given = {tenant_id => $given} unless ref($given);
    my $value = Selecto::Domain::QueryContract->copy_declaration($given);
    my %known = map { $_ => 1 } qw(tenant_id id tenant_field prefix required require_tenant required_filters);
    _fail('invalid_tenant_context', 'tenant context contains unsupported fields') if grep { !$known{$_} } keys %$value;
    my %context = (tenant_field => Selecto::Identifier::checked($value->{tenant_field} // 'tenant_id'));
    for my $key (qw(tenant_id id)) {
        next unless defined $value->{$key};
        _fail('invalid_tenant_context', 'tenant id must be a nonblank scalar')
            unless !ref($value->{$key}) && "$value->{$key}" =~ /\S/;
    }
    _fail('tenant_context_mismatch', 'tenant context id aliases conflict')
        if defined($value->{tenant_id}) && defined($value->{id}) && "$value->{tenant_id}" ne "$value->{id}";
    $context{tenant_id} = $value->{tenant_id} // $value->{id} if defined($value->{tenant_id}) || defined($value->{id});
    $context{prefix} = Selecto::Identifier::checked($value->{prefix}) if defined $value->{prefix};
    my @requirements = map { $class->boolean($value->{$_}, "tenant context $_") }
        grep { defined $value->{$_} } qw(required require_tenant);
    _fail('tenant_context_mismatch', 'tenant context requirement aliases conflict')
        if @requirements == 2 && $requirements[0] != $requirements[1];
    $context{required} = $requirements[0] if @requirements;
    my $filters = $value->{required_filters} // [];
    _fail('invalid_tenant_context', 'tenant required filters must be an array') unless ref($filters) eq 'ARRAY';
    $context{required_filters} = [map { $class->filter(@$_) } map {
        _fail('invalid_tenant_context', 'tenant required filter must contain field and scalar value') unless ref($_) eq 'ARRAY' && @$_ == 2;
        $_;
    } @$filters];
    return \%context;
}
sub filter {
    my ($class, $field, $value) = @_;
    my $copy = Selecto::Domain::QueryContract->copy_declaration({field => $field, value => $value});
    $field = Selecto::Identifier::checked($copy->{field});
    $value = $copy->{value};
    _fail('invalid_tenant_context', 'tenant required filter value must be a defined scalar')
        unless defined($value) && (!ref($value) || ref($value) eq 'JSON::PP::Boolean');
    return [$field, $value];
}
sub unique_filters {
    my ($class, $filters) = @_;
    my $copy = Selecto::Domain::QueryContract->copy_declaration({filters => $filters})->{filters};
    my %seen;
    return [grep { !$seen{Cpanel::JSON::XS->new->canonical->encode($_)}++ } @$copy];
}
sub report {
    my ($class, $required, $context, $filters) = @_;
    my $field = $context->{tenant_field} // 'tenant_id';
    my %values;
    for my $filter (@$filters) {
        next unless ref($filter) eq 'ARRAY' && @$filter == 2 && defined($filter->[0]) && !ref($filter->[0]) && $filter->[0] eq $field
            && defined($filter->[1]) && !ref($filter->[1]);
        $values{Cpanel::JSON::XS->new->encode($filter->[1])} = $filter->[1];
    }
    my @values = map { $values{$_} } sort keys %values;
    my $reason;
    if (!@values) {
        $reason = 'tenant_scope_missing' if defined($context->{tenant_id}) || ($required || $context->{required}) && !defined($context->{prefix});
    } elsif (@values > 1) { $reason = 'tenant_scope_ambiguous'; }
    elsif (defined($context->{tenant_id}) && Cpanel::JSON::XS->new->encode($values[0]) ne Cpanel::JSON::XS->new->encode($context->{tenant_id})) { $reason = 'tenant_scope_mismatch'; }
    my $valid = $reason ? 0 : 1;
    return {valid => bless(\$valid, 'JSON::PP::Boolean'),
        ($reason ? (error => {code => $reason, tenant_field => $field}) : ())};
}
sub _fail { Selecto::Error->throw($_[0], $_[1]); }

1;

=head1 NAME

Selecto::Tenant::Context - internal bounded plain read-context handling

=head1 DESCRIPTION

Shared by the public engine read-scope lifecycle. Complete plain metadata
admission precedes normalization/copying; no callbacks, unknown blessed values,
ties or cyclic structures are accepted. Scope evidence comes only from trusted
required filters, not optional predicates. This helper grants no write scope
or native catalog authority. See L<Selecto::Engine/with_tenant, apply_tenant_scope, validate_tenant_scope>.

=cut
