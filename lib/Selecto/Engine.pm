package Selecto::Engine;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Error ();
use Selecto::Query ();
use Selecto::QueryEnforcement ();
use Selecto::QueryLibrary ();

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_domain', 'engine requires a domain')
        unless blessed($args{domain}) && $args{domain}->isa('Selecto::Domain');
    Selecto::Error->throw('invalid_adapter', 'engine requires a Selecto database adapter')
        unless blessed($args{adapter}) && $args{adapter}->isa('Selecto::Adapter');
    $args{adapter}->assert_contract;
    return bless { domain => $args{domain}, adapter => $args{adapter} }, $class;
}

sub domain  { return $_[0]->{domain}; }
sub adapter { return $_[0]->{adapter}; }
sub query   { return Selecto::Query->new; }
sub compile { my ($self, $query) = @_; return $self->{adapter}->compile($self->{domain}, $query); }
sub all     { my ($self, $query) = @_; return $self->{adapter}->execute_query($self->compile($query)); }
sub execute_write { my ($self, $command) = @_; return $self->{adapter}->execute_write($command); }
sub execute_batch { my ($self, $batch) = @_; return $self->{adapter}->execute_batch($batch); }
sub execute_graph { my ($self, $graph) = @_; return $self->{adapter}->execute_graph($graph); }
sub query_library { my ($self) = @_; return Selecto::QueryLibrary->library($self->domain); }
sub apply_segment {
    my ($self, $query, $id, $params) = @_;
    return Selecto::QueryLibrary->apply_segment($self->domain, $query, $id, $params // {});
}
sub apply_projection {
    my ($self, $query, $ids) = @_;
    return Selecto::QueryLibrary->apply_projection($self->domain, $query, $ids);
}
sub apply_ordering {
    my ($self, $query, $id) = @_;
    return Selecto::QueryLibrary->apply_ordering($self->domain, $query, $id);
}
sub apply_view {
    my ($self, $query, $id, $params) = @_;
    return Selecto::QueryLibrary->apply_view($self->domain, $query, $id, $params // {});
}

sub enforce_query {
    my ($self, $command, $query) = @_;
    return $self->enforce_query_evidence(
        $command,
        Selecto::QueryEnforcement->capture($self->domain, $query),
    );
}

sub enforce_query_evidence {
    my ($self, $command, $evidence) = @_;
    Selecto::Error->throw('query_enforcement_unsupported_operation', 'query-enforced upsert is not supported')
        if $command->operation eq 'upsert';
    Selecto::QueryEnforcement::validate_source($self->domain, $command->relation, $evidence);
    my $tenant_field = $self->domain->tenant_field;
    Selecto::Error->throw('missing_tenant_scope', 'trusted tenant scope is required')
        if defined($tenant_field) && !_contains_field($command->scope_predicate, $tenant_field);
    return $command->with_query_enforcement($evidence);
}

sub _contains_field {
    my ($expression, $field) = @_;
    return 0 unless blessed($expression) && $expression->isa('Selecto::Expression');
    return $expression->arguments->[0] eq $field if $expression->kind eq 'field';
    for my $argument (@{$expression->arguments}) {
        my @values = ref($argument) eq 'ARRAY' ? @$argument : ($argument);
        return 1 if grep { _contains_field($_, $field) } @values;
    }
    return 0;
}

1;
