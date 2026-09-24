use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Domain::DSL ();
use Selecto::Domain::Overlay ();
use Selecto::Domain::Registry ();

# Every supported way of obtaining a domain keeps its canonical writes
# contract, so the engine governs registry, overlay, and derived domains
# exactly as it governs a parsed one.

sub code_of {
    my ($code) = @_;
    return eval { $code->(); 'ok' } // do {
        my $error = $@;
        blessed($error) && $error->isa('Selecto::Error') ? $error->code : die $error;
    };
}

my $contract = {
    schema_version => 1, name => 'Orders',
    source => {
        source_table => 'orders', primary_key => 'id',
        fields => [qw(id site_id title)],
        columns => {id => {type => 'integer'}, site_id => {type => 'integer'}, title => {type => 'string'}},
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => {update => {enabled => JSON::PP::true}},
        fields => {title => {updatable => JSON::PP::true}},
        scope => {tenant => {field => 'site_id'}},
    },
};
my $adapter = Selecto->adapter(postgresql => (dbh => bless {}, 'Offline::Handle'));
my $update = Selecto::Write::Command->new(
    operation => 'update', relation => 'orders', assignments => {title => 'x'},
    predicate => Selecto::Expression->eq('id', 1),
);
my $governed = sub {
    my ($domain) = @_;
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7});
    return $engine->preview_write($update)->{sql};
};

my $parsed = Selecto::Domain->parse($contract);
like($governed->($parsed), qr/"site_id" = \$\d/, 'a parsed domain enforces its write contract');

my $registry = Selecto::Domain::Registry->new(name => 'test');
$registry->register(orders => $contract);
my $resolved = $registry->resolve('orders');
is_deeply($resolved->writes, $parsed->writes, 'a registry keeps the writes section');
is_deeply($resolved->write_tenant_scope, $parsed->write_tenant_scope, 'a registry keeps the tenant scope');
like($governed->($resolved), qr/"site_id" = \$\d/, 'a registry domain enforces its write contract');

my $without_scope = {%$contract, writes => {%{$contract->{writes}}}};
delete $without_scope->{writes}{scope};
my $composed = Selecto::Domain::Overlay->compose(
    Selecto::Domain->parse($without_scope),
    Selecto::Domain::DSL->define(sub { $_[0]->write_tenant_scope({field => 'site_id'}) }),
);
is($composed->write_tenant_scope->{field}, 'site_id', 'an overlay can add the tenant scope');
like($governed->($composed), qr/"site_id" = \$\d/, 'an overlay-composed domain enforces it');
is_deeply($composed->writes->{fields}, $parsed->writes->{fields}, 'an overlay keeps existing write grants');

my $derived = $parsed->with_required_predicate(Selecto::Expression->eq('site_id', 7));
is_deeply($derived->write_tenant_scope, $parsed->write_tenant_scope, 'derived domains keep the tenant scope');
like($governed->($derived), qr/"site_id" = \$\d/, 'derived domains enforce the write contract');

my $legacy = Selecto::Domain->new(name => 'Orders', table => 'orders',
    fields => {id => 'integer', site_id => 'integer', title => 'string'});
my $legacy_registry = Selecto::Domain::Registry->new(name => 'legacy');
$legacy_registry->register(orders => $legacy);
is(code_of(sub { $governed->($legacy_registry->resolve('orders')) }), 'write_policy_missing',
    'a registered domain without a canonical contract has no write policy and is denied');

done_testing;
