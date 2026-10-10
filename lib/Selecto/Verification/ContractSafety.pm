package Selecto::Verification::ContractSafety;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain::ContractVerification ();
use Selecto::Error ();

# An independent exhaustive model: each dimension is built from its boolean,
# then checked against the result produced by the public compatibility API.
sub verify {
    my ($class, %options) = @_;
    Selecto::Error->throw('invalid_argument', 'unknown contract safety option')
        if grep { $_ ne 'verifier' } keys %options;
    my $verifier = $options{verifier} // sub { Selecto::Domain::ContractVerification->verify(@_) };
    Selecto::Error->throw('invalid_argument', 'verifier must be a callback') unless ref($verifier) eq 'CODE';
    my $provider = {
        name => 'billing', domain_version => '1.0.0', domain_fingerprint => 'sha256:provider',
        source => {fields => [qw(id status tenant_id)]},
        filters => {status_picker => {field => 'status'}},
        published_views => {invoice_summary_v1 => {
            version => '1.0.0', fingerprint => 'sha256:surface',
            columns => {invoice_id => {type => 'integer'}, status => {type => 'string'}, balance_due => {type => 'decimal'}},
            filters => ['status_picker'], required_filters => ['tenant_id'],
        }},
    };
    my @dimensions = qw(field_valid filter_valid scope_satisfied version_valid fingerprint_valid);
    my @codes = qw(missing_field missing_filter unsatisfied_required_filter incompatible_contract_version provider_fingerprint_changed);
    my @counterexamples;
    for my $mask (0 .. 31) {
        my @valid = map { ($mask >> $_) & 1 } 0 .. 4;
        my %state = map { $dimensions[$_] => $valid[$_] ? JSON::PP::true : JSON::PP::false } 0 .. 4;
        my $consumer = {name => 'registration', domain_dependencies => [{
            provider => 'billing', contract => 'invoice_summary_v1',
            accepts => $valid[3] ? '~> 1.0' : '~> 2.0',
            expected_fingerprint => $valid[4] ? 'sha256:surface' : 'sha256:old',
            uses => {fields => [$valid[0] ? 'invoice_id' : 'missing_field'],
                filters => [$valid[1] ? 'status_picker' : 'missing_filter'], query_members => []},
            satisfies => $valid[2] ? ['tenant_id'] : [],
        }]};
        my $result = eval { $verifier->(dclone($provider), $consumer) };
        my $failed = $@;
        my $well_formed = !$failed && ref($result) eq 'HASH' && exists($result->{compatible})
            && JSON::PP::is_bool($result->{compatible}) && ref($result->{errors}) eq 'ARRAY'
            && !grep { ref($_) ne 'HASH' || !defined($_->{code}) || ref($_->{code}) } @{$result->{errors}};
        my $expected = $mask == 31;
        if (!$well_formed || !!$result->{compatible} != !!$expected) {
            push @counterexamples, {state => {%state}, invariant => 'compatibility_result_is_complete',
                expected_compatible => $expected ? JSON::PP::true : JSON::PP::false};
        }
        my %actual = $well_formed ? (map { $_->{code} => 1 } @{$result->{errors}}) : ();
        my @missing = map { $codes[$_] } grep { !$valid[$_] && !$actual{$codes[$_]} } 0 .. 4;
        if (!$well_formed || @missing) {
            push @counterexamples, {state => {%state}, invariant => 'incompatible_dimensions_have_specific_diagnostics',
                missing_diagnostic_codes => \@missing};
        }
    }
    return {proof_level => 'bounded_exhaustive', model => 'selecto.domain_contract_compatibility.v1',
        state_count => 32, check_count => 64, invariant_count => 2, counterexamples => \@counterexamples};
}

1;
