use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Selecto;
use TestSelecto;

sub domain_contract {
    my ($name) = @_;
    return {
        schema_version => 1,
        domain_version => '1.2.0',
        domain_fingerprint => 'sha256:orders-authored',
        name => $name // 'Orders',
        source => {
            source_table => 'orders',
            primary_key => 'id',
            fields => ['id'],
            columns => {id => {type => 'integer'}},
            associations => {},
        },
        schemas => {},
        joins => {},
    };
}

sub thrown_by {
    my ($callback) = @_;
    my $error;
    eval { $callback->(); 1 } or $error = $@;
    return $error;
}

my $registry = Selecto->domain_registry(name => 'Example::Domains')
    ->register(orders => domain_contract(), metadata => {source => 'static'})
    ->register_provider(secure_orders => sub {
        my ($id, $context) = @_;
        return Selecto::Domain::Registry->forbidden unless $context->{allowed};
        return Selecto::Domain::Registry->ok(
            domain_contract('Secure Orders'),
            {version => '2.0.0', source => 'provider'},
        );
    });

is_deeply($registry->ids, [qw(orders secure_orders)], 'registry ids are stable and discoverable');
my ($orders, $orders_ref) = $registry->resolve('orders');
isa_ok($orders, 'Selecto::Domain', 'static registration resolves a validated domain');
isa_ok($orders_ref, 'Selecto::Domain::Ref', 'resolution returns opaque provenance');
is($orders_ref->id, 'orders', 'reference carries the opaque id');
is($orders_ref->registry_name, 'Example::Domains', 'reference identifies its registry');
is($orders_ref->version, '1.2.0', 'reference derives the authored domain version');
is($orders_ref->fingerprint, 'sha256:orders-authored',
    'reference derives the authored fingerprint');
is_deeply($orders_ref->metadata, {source => 'static'}, 'reference retains provider metadata');

my ($secure, $secure_ref) = $registry->resolve('secure_orders', {allowed => 1});
is($secure->name, 'Secure Orders', 'provider can resolve from trusted context');
is($secure_ref->version, '2.0.0', 'provider metadata can supply provenance version');
is_deeply($secure_ref->metadata, {source => 'provider'},
    'reserved provenance fields are removed from reference metadata');

my $opaque = $registry->ref('orders');
my ($from_ref, $resolved_ref) = $registry->resolve_ref($opaque);
is($from_ref->name, 'Orders', 'opaque references can be resolved by their owning registry');
is($resolved_ref->fingerprint, 'sha256:orders-authored', 'resolved ref receives full provenance');
is_deeply(
    $resolved_ref->to_hash,
    {
        id => 'orders',
        registry => 'Example::Domains',
        version => '1.2.0',
        fingerprint => 'sha256:orders-authored',
        metadata => {source => 'static'},
    },
    'references expose a data-only portable projection',
);

my $adapter = Selecto->adapter(sqlite => (dbh => TestSelecto::DBH->new));
my $registered_engine = Selecto->engine_registered(
    domain => 'orders',
    registry => $registry,
    adapter => $adapter,
);
isa_ok($registered_engine, 'Selecto::Engine', 'registry can configure an engine directly');
is($registered_engine->domain->name, 'Orders', 'registry-backed engine uses the resolved domain');
is($registered_engine->domain_ref->registry_name, 'Example::Domains',
    'registry-backed engine retains domain provenance');
my $ref_engine = Selecto::Engine->from_registry(domain => $opaque, adapter => $adapter);
is($ref_engine->domain_ref->id, 'orders', 'opaque ref supplies its owning registry to the engine');

my $error = thrown_by(sub { $registry->resolve('missing') });
isa_ok($error, 'Selecto::Error', 'unknown domains fail with typed errors');
is($error->code, 'domain_not_found', 'unknown domain fails closed');

$error = thrown_by(sub { $registry->resolve('secure_orders', {allowed => 0}) });
is($error->code, 'domain_forbidden', 'provider denial fails closed');

$error = thrown_by(sub { $registry->resolve('orders', []) });
is($error->code, 'invalid_registry_context', 'registry contexts must be objects');

$error = thrown_by(sub { $registry->register(orders => domain_contract()) });
is($error->code, 'duplicate_domain', 'duplicate ids cannot silently replace authority');

my $bad_results = Selecto::Domain::Registry->new(name => 'Bad::Results')
    ->register_provider(bare => sub { return domain_contract(); })
    ->register_provider(invalid => sub {
        return Selecto::Domain::Registry->ok({name => 'Invalid'});
    })
    ->register_provider(bad_shape => sub {
        my $contract = domain_contract('Bad Shape');
        $contract->{writes} = [];
        return Selecto::Domain::Registry->ok($contract);
    })
    ->register_provider(dies => sub { die "secret provider detail\n"; })
    ->register_provider(bad_status => sub {
        return Selecto::Domain::Registry::Result->new(status => 'maybe');
    });

$error = thrown_by(sub { $bad_results->resolve('bare') });
is($error->code, 'invalid_registry_result', 'bare provider maps are rejected');

$error = thrown_by(sub { $bad_results->resolve('invalid') });
is($error->code, 'invalid_registered_domain', 'provider domains cross strict validation');
is($error->details->{reason}, 'invalid_domain', 'invalid domain cause is typed without raw failure');

$error = thrown_by(sub { $bad_results->resolve('bad_shape') });
is($error->code, 'invalid_registered_domain', 'malformed governance sections are rejected');

$error = thrown_by(sub { $bad_results->resolve('dies') });
is($error->code, 'domain_registry_failed', 'provider exceptions are normalized');
unlike("$error", qr/secret provider detail/, 'provider exception details are not leaked');

$error = thrown_by(sub { $bad_results->resolve('bad_status') });
is($error->code, 'invalid_registry_result', 'provider result status is fail-closed');

my $other = Selecto::Domain::Registry->new(name => 'Other::Domains')
    ->register(orders => domain_contract());
$error = thrown_by(sub { $other->resolve_ref($opaque) });
is($error->code, 'domain_registry_mismatch', 'registry substitution is rejected');

my $defined = Selecto::Domain::Registry->define(
    name => 'Defined::Domains',
    domains => sub {
        $_[0]->register(people => domain_contract('People'));
    },
);
is($defined->resolve('people')->name, 'People', 'registry definition DSL builds named domains');

$error = thrown_by(sub {
    Selecto::Domain::Registry->new(name => 'Options', unexpected => 1);
});
is($error->code, 'invalid_domain_registry', 'unknown registry options fail closed');

done_testing;
