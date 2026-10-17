package Selecto::Domain::CapabilityPolicy;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use bytes ();
use Encode qw(encode_utf8);
use JSON::PP ();
use Selecto::Domain::QueryContract ();
use Selecto::Error ();
use Selecto::Limits ();

my $LIMITS = Selecto::Limits->new;
my @MEMBER_GROUPS = qw(ctes values subqueries laterals unnests);
my %FAMILY = (
    filters => 'filter', functions => 'function', published_views => 'published_view',
    detail_actions => 'detail_action', choice_sources => 'choice_source', actions => 'action',
);

sub validate {
    my ($class, $input) = @_;
    # Admit every authored section before interpreting or copying references.
    # Callback markers remain metadata; callbacks and object hooks never run.
    my $contract = Selecto::Domain::QueryContract->copy_declaration($input);
    my $state = {errors => [], nodes => 0, bytes => 0, work => 0};
    my $registry = _object($state, exists($contract->{capabilities}) ? $contract->{capabilities} : {}, ['capabilities']);
    for my $id (sort keys %$registry) {
        _work($state);
        my $path = ['capabilities', $id];
        my $entry = _object($state, $registry->{$id}, $path);
        next unless ref($registry->{$id}) eq 'HASH';
        my $operations = $entry->{operations};
        if (!defined $operations) {
            _error($state, 'capability_missing_operations', [@$path, 'operations']);
        } elsif (ref($operations) ne 'ARRAY') {
            _error($state, 'invalid_capability_operations', [@$path, 'operations']);
        } elsif (!@$operations) {
            _error($state, 'capability_empty_operations', [@$path, 'operations']);
        } else {
            for my $i (0 .. $#$operations) {
                _work($state);
                _error($state, 'invalid_capability_operation', [@$path, 'operations', $i])
                    unless _string($operations->[$i]);
            }
        }
    }
    for my $section (sort keys %FAMILY) {
        next unless exists $contract->{$section};
        _references($state, _object($state, $contract->{$section}, [$section]),
            [$section], $FAMILY{$section}, $registry);
    }
    if (exists $contract->{query_members}) {
        my $members = _object($state, $contract->{query_members}, ['query_members']);
        for my $group (@MEMBER_GROUPS) {
            next unless exists $members->{$group};
            _references($state, _object($state, $members->{$group}, ['query_members', $group]),
                ['query_members', $group], 'query_member', $registry);
        }
    }
    my $valid = @{$state->{errors}} ? 0 : 1;
    return {valid => bless(\$valid, 'JSON::PP::Boolean'), errors => $state->{errors}, warnings => []};
}

sub _references {
    my ($state, $entries, $path, $family, $registry) = @_;
    for my $id (sort keys %$entries) {
        _work($state);
        my $entry = _object($state, $entries->{$id}, [@$path, $id]);
        next unless defined $entry->{capability};
        my $reference = $entry->{capability};
        my $location = [@$path, $id, 'capability'];
        if (!_string($reference)) {
            _error($state, "invalid_${family}_capability", $location);
        } elsif (!exists $registry->{$reference}) {
            _error($state, "${family}_capability_not_found", $location);
        }
    }
}

sub _object {
    my ($state, $value, $path) = @_;
    return $value if ref($value) eq 'HASH';
    _error($state, 'invalid_section_shape', $path);
    return {};
}
sub _string {
    return defined($_[0]) && !ref($_[0]) && (B::svref_2object(\$_[0])->FLAGS & B::SVp_POK());
}
sub _work {
    _limit('capability validation exceeds its work limit')
        if ++$_[0]{work} > $LIMITS->{max_expression_nodes};
}
sub _error {
    my ($state, $code, $path) = @_;
    # A compact long registry id can occur in many errors. Charge every emitted
    # path before allocating another diagnostic rather than limiting input only.
    $state->{nodes} += 4 + @$path;
    _limit('capability validation exceeds its diagnostic node limit')
        if $state->{nodes} > $LIMITS->{max_expression_nodes};
    $state->{bytes} += length('code') + length('path');
    for my $value ($code, @$path) {
        $state->{bytes} += length(utf8::is_utf8($value) ? encode_utf8($value) : $value);
        _limit('capability validation exceeds its diagnostic byte limit')
            if $state->{bytes} > $LIMITS->{max_state_bytes};
    }
    push @{$state->{errors}}, {code => $code, path => [@$path]};
}
sub _limit { Selecto::Error->throw('invalid_capability_policy', $_[0]); }

1;

__END__

=head1 NAME

Selecto::Domain::CapabilityPolicy - bounded portable capability declaration validation

=head1 API

C<Selecto::Domain-E<gt>validate_capability_policy($plain_contract)> validates the
complete plain declaration before checking capability registry operations and
references from filters, functions, the five query-member groups, published
views, detail actions, choice sources and actions. It returns C<valid>, contextual
C<errors> and C<warnings>. Unknown or malformed references accumulate independent
diagnostics. Missing or null optional references do not require a capability.

This metadata API does not execute queries, callbacks, operation implementations
or capability resolvers, and does not make authorization decisions. Field
capability metadata is preserved by the existing public domain projections;
this validator checks the seven declared reference families above. Native
executable domains and non-plain objects must use their existing APIs.

=cut
