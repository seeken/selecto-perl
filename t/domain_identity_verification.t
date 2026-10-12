use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();

# Engines re-verify their domain's identity (refusing a domain modified after
# configuration) only when asked: verify_domain_identity => 1, or
# $Selecto::Engine::VERIFY_DOMAIN_IDENTITY. When they do, one outermost call verifies
# once, however many engine methods it reaches.

my $engine_for = sub {
    my (%options) = @_;
    return Selecto::Engine->new(domain => TestSelecto::orders_domain(),
        adapter => Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new), %options);
};
my $compile = sub {
    my ($engine) = @_;
    return $engine->compile($engine->query->select('id', 'total')->where(Selecto::Expression->eq('total', 10)));
};
my $error_code = sub {
    my ($code) = @_;
    return eval { $code->(); 1 } ? '' : (ref($@) && $@->can('code') ? $@->code : "$@");
};
# How many whole-domain digests a piece of work computes.
my $digests = sub {
    my ($code) = @_;
    my $count = 0;
    no warnings 'redefine';
    my $original = \&Selecto::ConfiguredDomain::digest;
    local *Selecto::ConfiguredDomain::digest = sub { $count++; goto &$original };
    $code->();
    return $count;
};

# Default: no re-verification, and no digests once configured.
{
    my $engine = $engine_for->();
    is $digests->(sub { $compile->($engine) for 1 .. 3 }), 0, 'by default, using an engine computes no domain digests';
    $engine->{domain}{name} .= ' (changed)';
    is $error_code->(sub { $compile->($engine) }), '', 'and a domain changed after configuration is not refused';
    my $identity = $engine->_read_policy_identity;
    like $identity, qr/\A[0-9a-f]{64}\z/, 'the read policy identity is still a digest';
    is $digests->(sub { is $engine->_read_policy_identity, $identity, 'and stays the same' }), 0,
        'computed once, then kept';
}

# Opted in per engine: a domain changed between calls is refused.
{
    my $engine = $engine_for->(verify_domain_identity => 1);
    is $error_code->(sub { $compile->($engine) }), '', 'a verifying engine compiles';
    my $query = $engine->query->select('id', 'total')->where(Selecto::Expression->eq('total', 10));
    # One verification digests the domain and its read domain: two digests, not one per
    # engine method compile reaches.
    is $digests->(sub { $engine->compile($query) }), 2,
        'one compile verifies once, however many engine methods it reaches';
    is $digests->(sub { $engine->compile($query) for 1 .. 3 }), 6, 'and each call verifies again';
    $engine->{domain}{name} .= ' (changed)';
    is $error_code->(sub { $compile->($engine) }), 'domain_modified_after_configuration',
        'a domain changed between calls is refused';
}

# Opted in for every engine.
{
    local $Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;
    my $engine = $engine_for->();
    $engine->{domain}{name} .= ' (changed)';
    is $error_code->(sub { $compile->($engine) }), 'domain_modified_after_configuration',
        '$Selecto::Engine::VERIFY_DOMAIN_IDENTITY turns it on for all engines';
    my $quiet = $engine_for->(verify_domain_identity => 0);
    $quiet->{domain}{name} .= ' (changed)';
    is $error_code->(sub { $compile->($quiet) }), '', 'an engine can still opt out';
}

# Only a genuinely configured engine, either way.
{
    my $engine = $engine_for->();
    my $forged = bless {%$engine}, 'Selecto::Engine';
    is $error_code->(sub { $forged->domain }), 'domain_modified_after_configuration',
        'an engine that was not configured is refused';
}

done_testing;
