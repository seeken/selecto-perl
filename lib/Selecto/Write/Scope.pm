package Selecto::Write::Scope;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();

# Canonical write scope: writes.scope.tenant.
#
#   writes => {scope => {tenant => {
#       required => 1,                      # optional; only true is accepted
#       field => 'site_id',                 # defaults to source.tenant_field
#       satisfied_by => ['trusted_context'],
#   }}}
#
# The declaration is enforced data. When a domain declares it, every governed
# mutation of that domain requires a trusted tenant supplied by the host
# (Selecto::Engine->new(scope => {tenant => ...})), never by the caller:
#
# - update and delete gain `field = trusted` in their scope predicate;
# - insert and upsert are assigned the trusted tenant;
# - any caller-authored tenant comparison or assignment must name the same
#   tenant, or the write fails with tenant_mismatch;
# - upsert must resolve conflicts on a target that includes the tenant field,
#   so the conflict row always belongs to the trusted tenant.
#
# The Elixir implementation also honors prefix, filter, and payload sources.
# Perl accepts those names in a contract but satisfies scope from the trusted
# context only; a domain that omits trusted_context cannot be written here.

my %SCOPE_KEYS = map { $_ => 1 } qw(tenant);
my %TENANT_KEYS = map { $_ => 1 } qw(required field tenant_field satisfied_by sources);
my %SOURCES = map { $_ => 1 } qw(trusted_context prefix filter payload);
my @DEFAULT_SOURCES = qw(trusted_context prefix);
my $IDENTIFIER = qr/\A[A-Za-z_][A-Za-z0-9_]*\z/;

# Returns the normalized tenant scope {field, satisfied_by} or undef.
# $fields is a hash of declared root fields when known.
sub parse_tenant {
    my ($class, $writes, %args) = @_;
    return undef unless ref($writes) eq 'HASH' && defined($writes->{scope});
    my $scope = $writes->{scope};
    _invalid('writes.scope must be an object') unless ref($scope) eq 'HASH';
    my @unknown = sort grep { !$SCOPE_KEYS{$_} } keys %$scope;
    _invalid('writes.scope contains unsupported keys', {keys => \@unknown}) if @unknown;
    my $tenant = $scope->{tenant};
    return undef unless defined $tenant;
    _invalid('writes.scope.tenant must be an object') unless ref($tenant) eq 'HASH';
    @unknown = sort grep { !$TENANT_KEYS{$_} } keys %$tenant;
    _invalid('writes.scope.tenant contains unsupported keys', {keys => \@unknown}) if @unknown;

    if (exists $tenant->{required}) {
        my $required = $tenant->{required};
        _invalid('writes.scope.tenant.required must be true; a domain without tenant scope omits writes.scope.tenant')
            unless defined($required) && (JSON::PP::is_bool($required) ? $required : !ref($required) && "$required" eq '1');
    }

    my $field = $tenant->{field} // $tenant->{tenant_field} // $args{tenant_field};
    _invalid('writes.scope.tenant.field must name a root field')
        unless defined($field) && !ref($field) && "$field" =~ $IDENTIFIER;
    $field = "$field";
    _invalid('writes.scope.tenant.field must name a root field', {field => $field})
        if ref($args{fields}) eq 'HASH' && !exists($args{fields}{$field});

    my $sources = $tenant->{satisfied_by} // $tenant->{sources} // [@DEFAULT_SOURCES];
    _invalid('writes.scope.tenant.satisfied_by must be a non-empty list')
        unless ref($sources) eq 'ARRAY' && @$sources;
    my (%seen, @normalized);
    for my $source (@$sources) {
        _invalid('writes.scope.tenant.satisfied_by contains an unknown source',
            {source => defined($source) && !ref($source) ? "$source" : undef})
            unless defined($source) && !ref($source) && $SOURCES{"$source"};
        push @normalized, "$source" unless $seen{"$source"}++;
    }
    return {field => $field, satisfied_by => \@normalized};
}

# Validate a trusted tenant value supplied by the host.
sub trusted_tenant {
    my ($class, $value) = @_;
    return undef unless defined $value;
    Selecto::Error->throw('invalid_tenant_scope', 'trusted tenant must be a non-empty scalar')
        if ref($value) || "$value" eq '';
    return $value;
}

# Apply a parsed tenant scope to a command. Returns the governed command.
sub apply {
    my ($class, $command, $scope, $trusted, %args) = @_;
    return $command unless $scope;
    my $field = $scope->{field};
    my $label = {relation => $args{label} // $command->relation, %{$args{details} // {}}};
    Selecto::Error->throw(
        'unsupported_tenant_scope_source',
        'this runtime satisfies tenant scope from trusted context only',
        {%$label, satisfied_by => [@{$scope->{satisfied_by}}]},
    ) unless grep { $_ eq 'trusted_context' } @{$scope->{satisfied_by}};
    Selecto::Error->throw(
        'missing_tenant_scope',
        'tenant-scoped writes require a trusted tenant from the host',
        {%$label, field => $field},
    ) unless defined $trusted;

    for my $expression (grep { defined } $command->predicate, $command->scope_predicate) {
        _check_references($expression, $field, $trusted, $label);
    }

    my $operation = $command->operation;
    my $assignments = $command->assignments;
    if (exists $assignments->{$field}) {
        _mismatch($field, $label) unless _same_tenant($assignments->{$field}, $trusted);
    }
    if ($operation eq 'insert' || $operation eq 'upsert') {
        $assignments->{$field} = $trusted;
    }
    if ($operation eq 'upsert') {
        my $target = $command->metadata->{conflict_target};
        Selecto::Error->throw(
            'tenant_scope_conflict_target',
            'tenant-scoped upsert must resolve conflicts on a target that includes the tenant field',
            {%$label, field => $field},
        ) unless ref($target) eq 'ARRAY' && grep { defined($_) && !ref($_) && "$_" eq $field } @$target;
    }

    my $guard = Selecto::Expression->eq($field, $trusted);
    my $existing = $command->scope_predicate;
    return $command
        ->with_assignments($assignments)
        ->with_scope_predicate(defined($existing) ? Selecto::Expression->all($existing, $guard) : $guard);
}

# A caller may restate the trusted tenant, but may not name another tenant or
# compare the tenant field in any other way.
sub _check_references {
    my ($expression, $field, $trusted, $label) = @_;
    return unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    my $operand = $arguments->[0];
    if (blessed($operand) && $operand->isa('Selecto::Expression')
        && $operand->kind eq 'field' && $operand->arguments->[0] eq $field) {
        if ($kind eq 'eq') {
            my $value = $arguments->[1];
            return if blessed($value) && $value->isa('Selecto::Expression')
                && $value->kind eq 'literal' && _same_tenant($value->arguments->[0], $trusted);
        } elsif ($kind eq 'in') {
            my $values = $arguments->[1];
            return if ref($values) eq 'ARRAY' && @$values
                && !grep { !_same_tenant($_, $trusted) } @$values;
        }
        _mismatch($field, $label);
    }
    for my $argument (@$arguments) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            if ($argument->kind eq 'field') {
                _mismatch($field, $label) if $argument->arguments->[0] eq $field;
                next;
            }
            _check_references($argument, $field, $trusted, $label);
        } elsif (ref($argument) eq 'ARRAY') {
            _check_references($_, $field, $trusted, $label) for @$argument;
        }
    }
}

sub _same_tenant {
    my ($value, $trusted) = @_;
    if (blessed($value) && $value->isa('Selecto::Write::Expression')) {
        return 0 unless $value->kind eq 'literal';
        $value = $value->arguments->[0];
    }
    return defined($value) && !ref($value) && "$value" eq "$trusted";
}

sub _mismatch {
    my ($field, $label) = @_;
    Selecto::Error->throw(
        'tenant_mismatch',
        'tenant value must match the trusted tenant scope',
        {%$label, field => $field},
    );
}

sub _invalid {
    my ($message, $details) = @_;
    Selecto::Error->throw('invalid_domain', $message, $details // {});
}

1;

__END__

=head1 NAME

Selecto::Write::Scope - enforced tenant scope for governed writes

=head1 DESCRIPTION

Parses C<writes.scope.tenant> and applies it, with a trusted tenant supplied
by the host engine, to every governed write command.

=cut
