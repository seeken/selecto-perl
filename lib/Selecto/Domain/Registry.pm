package Selecto::Domain::Registry;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);
use Storable qw(dclone);
use Selecto::Domain ();
use Selecto::Domain::Ref ();
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    my @unknown = grep { $_ ne 'name' } keys %args;
    Selecto::Error->throw(
        'invalid_domain_registry',
        'unknown domain registry options',
        {options => [sort @unknown]},
    ) if @unknown;
    my $name = $args{name} // $class;
    Selecto::Error->throw('invalid_domain_registry', 'domain registry name must be a non-empty string')
        if CORE::ref($name) || "$name" !~ /\S/;
    return bless {name => "$name", providers => {}}, $class;
}

sub define {
    my ($class, %args) = @_;
    my $callback = delete $args{domains};
    Selecto::Error->throw('invalid_domain_registry', 'domain registry DSL requires a domains callback')
        unless CORE::ref($callback) eq 'CODE';
    my $registry = $class->new(%args);
    $callback->($registry);
    return $registry;
}

sub name { return $_[0]->{name}; }

sub register {
    my ($self, $id, $domain, %options) = @_;
    $id = _domain_id($id);
    my @unknown = grep { $_ ne 'metadata' } keys %options;
    Selecto::Error->throw(
        'invalid_domain_registry',
        'unknown domain registration options',
        {domain_id => $id, options => [sort @unknown]},
    ) if @unknown;
    Selecto::Error->throw('duplicate_domain', 'domain id is already registered', {domain_id => $id})
        if exists $self->{providers}{$id};
    if (CORE::ref($domain) eq 'CODE') {
        Selecto::Error->throw(
            'invalid_domain_registry',
            'provider registrations do not accept static metadata; return an ok result instead',
        ) if keys %options;
        $self->{providers}{$id} = $domain;
        return $self;
    }
    my $resolved = _coerce_domain($domain, $id);
    my $metadata = $options{metadata} // {};
    Selecto::Error->throw('invalid_domain_registry', 'domain metadata must be an object')
        unless CORE::ref($metadata) eq 'HASH';
    my $result = __PACKAGE__->ok($resolved, $metadata);
    $self->{providers}{$id} = sub { return $result; };
    return $self;
}

sub register_provider {
    my ($self, $id, $provider) = @_;
    return $self->register($id, $provider);
}

sub ids {
    my ($self) = @_;
    return [sort keys %{$self->{providers}}];
}

sub ref {
    my ($self, $id) = @_;
    $id = _domain_id($id);
    return Selecto::Domain::Ref->new(
        id => $id,
        registry => $self,
        registry_name => $self->{name},
        metadata => {},
    );
}

sub resolve {
    my ($self, $id, $context) = @_;
    $id = _domain_id($id);
    $context //= {};
    Selecto::Error->throw(
        'invalid_registry_context',
        'domain registry context must be an object',
        {domain_id => $id, registry => $self->{name}},
    ) unless CORE::ref($context) eq 'HASH';
    my $provider = $self->{providers}{$id};
    Selecto::Error->throw(
        'domain_not_found',
        'registered Selecto domain was not found',
        {domain_id => $id, registry => $self->{name}},
    ) unless $provider;

    my ($result, $ok);
    {
        local $@;
        $ok = eval { $result = $provider->($id, dclone($context)); 1 };
    }
    Selecto::Error->throw(
        'domain_registry_failed',
        'registered Selecto domain could not be resolved',
        {domain_id => $id, registry => $self->{name}},
    ) unless $ok;
    Selecto::Error->throw(
        'invalid_registry_result',
        'domain registry providers must return an explicit result',
        {domain_id => $id, registry => $self->{name}},
    ) unless blessed($result) && $result->isa('Selecto::Domain::Registry::Result');
    Selecto::Error->throw(
        'invalid_registry_result',
        'domain registry providers returned an invalid result status',
        {domain_id => $id, registry => $self->{name}},
    ) unless $result->status eq 'ok' || $result->status eq 'error';

    if ($result->status eq 'error') {
        my $reason = $result->reason;
        my $code = $reason eq 'not_found' ? 'domain_not_found'
            : $reason eq 'forbidden' ? 'domain_forbidden'
            : 'domain_registry_failed';
        my $message = $reason eq 'not_found' ? 'registered Selecto domain was not found'
            : $reason eq 'forbidden' ? 'registered Selecto domain is not available'
            : 'registered Selecto domain could not be resolved';
        Selecto::Error->throw($code, $message, {
            domain_id => $id,
            registry => $self->{name},
        });
    }

    my $domain = _coerce_domain($result->domain, $id);
    my $metadata = $result->metadata;
    my $contract = $domain->as_contract;
    my $version = delete($metadata->{version}) // $contract->{domain_version};
    my $fingerprint = delete($metadata->{fingerprint})
        // $contract->{domain_fingerprint}
        // $domain->fingerprint;
    my $ref = Selecto::Domain::Ref->new(
        id => $id,
        registry => $self,
        registry_name => $self->{name},
        version => $version,
        fingerprint => $fingerprint,
        metadata => $metadata,
    );
    return wantarray ? ($domain, $ref) : $domain;
}

sub resolve_ref {
    my ($self, $ref, $context) = @_;
    Selecto::Error->throw('invalid_domain_ref', 'expected a Selecto domain reference')
        unless blessed($ref) && $ref->isa('Selecto::Domain::Ref');
    Selecto::Error->throw(
        'domain_registry_mismatch',
        'domain reference belongs to a different registry',
        {expected => $self->{name}, actual => $ref->registry_name},
    ) unless blessed($ref->registry) && refaddr($ref->registry) == refaddr($self);
    return $self->resolve($ref->id, $context);
}

sub ok {
    my ($class, $domain, $metadata) = @_;
    $metadata //= {};
    Selecto::Error->throw('invalid_domain_registry', 'domain metadata must be an object')
        unless CORE::ref($metadata) eq 'HASH';
    return Selecto::Domain::Registry::Result->new(
        status => 'ok', domain => $domain, metadata => $metadata,
    );
}

sub error {
    my ($class, $reason) = @_;
    $reason = defined($reason) && !CORE::ref($reason) ? "$reason" : 'registry_failed';
    $reason = 'registry_failed' unless $reason eq 'not_found' || $reason eq 'forbidden';
    return Selecto::Domain::Registry::Result->new(status => 'error', reason => $reason);
}

sub not_found { return shift->error('not_found'); }
sub forbidden { return shift->error('forbidden'); }

sub _coerce_domain {
    my ($value, $id) = @_;
    my $domain;
    my $ok = eval {
        $domain = blessed($value) && $value->isa('Selecto::Domain')
            ? $value
            : Selecto::Domain->parse($value, strict => 1);
        my $contract = $domain->contract;
        if (defined $contract) {
            require Selecto::Domain::Overlay;
            Selecto::Domain::Overlay->validate_contract_shapes($contract);
        }
        1;
    };
    if (!$ok) {
        my $reason = blessed($@) && $@->isa('Selecto::Error') ? $@->code : 'invalid_domain';
        Selecto::Error->throw(
            'invalid_registered_domain',
            'registered Selecto domain failed validation',
            {domain_id => $id, reason => $reason},
        );
    }
    return $domain;
}

sub _domain_id {
    my ($id) = @_;
    Selecto::Error->throw('invalid_domain_id', 'domain id must be a non-empty string')
        if !defined($id) || CORE::ref($id) || "$id" !~ /\S/;
    return "$id";
}

package Selecto::Domain::Registry::Result;

use 5.034;
use strict;
use warnings;
use Storable qw(dclone);

sub new {
    my ($class, %args) = @_;
    return bless {
        status => $args{status},
        domain => $args{domain},
        metadata => dclone($args{metadata} // {}),
        reason => $args{reason},
    }, $class;
}

sub status   { return $_[0]->{status}; }
sub domain   { return $_[0]->{domain}; }
sub metadata { return dclone($_[0]->{metadata}); }
sub reason   { return $_[0]->{reason}; }

1;

__END__

=head1 NAME

Selecto::Domain::Registry - trusted, fail-closed named domain resolution

=head1 SYNOPSIS

  use Selecto;

  my $registry = Selecto->domain_registry(name => 'MyApp::Domains')
      ->register(orders => $orders_domain)
      ->register_provider(tenant_orders => sub {
          my ($id, $context) = @_;
          return Selecto::Domain::Registry->forbidden
              unless $context->{can_read_orders};
          return Selecto::Domain::Registry->ok(
              tenant_orders_domain($context->{tenant_id}),
              {version => '2026-08', tenant_id => $context->{tenant_id}},
          );
      });

  my ($domain, $ref) = $registry->resolve(
      tenant_orders => {can_read_orders => 1, tenant_id => 42});

  my $engine = Selecto->engine_registered(
      domain  => $ref,
      context => {can_read_orders => 1, tenant_id => 42},
      adapter => $adapter,
  );
  $engine->domain_ref->to_hash;   # {id, registry, version, fingerprint, metadata}

=head1 DESCRIPTION

A registry keeps the mapping from domain names to domains on the server, so
clients can refer to a domain by name without ever supplying one. Static
registrations are validated immediately. Dynamic providers are called with
the id and a copy of a trusted context hash and must return an explicit
C<ok>, C<not_found> or C<forbidden> result.

Everything else fails closed: bare return values (C<invalid_registry_result>),
invalid contracts (C<invalid_registered_domain>), provider exceptions
(C<domain_registry_failed>, without the exception text), unknown ids
(C<domain_not_found>), and references from another registry
(C<domain_registry_mismatch>). A forbidden result throws
C<domain_forbidden>.

Resolution also returns a L<Selecto::Domain::Ref>: opaque provenance (id,
registry name, version, fingerprint, metadata) that engines keep as
C<domain_ref>.

=head1 METHODS

=head2 new

  my $registry = Selecto::Domain::Registry->new(name => 'MyApp::Domains');

=head2 define

  my $registry = Selecto::Domain::Registry->define(
      name => 'MyApp::Domains', domains => sub { my ($r) = @_; $r->register(...) });

=head2 register

  $registry->register($id, $domain_or_contract, metadata => \%metadata);
  $registry->register($id, sub { ... });   # a provider

Registers a L<Selecto::Domain>, a canonical contract hash, or a provider
callback. Duplicate ids throw C<duplicate_domain>. Returns the registry.

=head2 register_provider

Same as L</register> with a callback.

=head2 resolve

  my ($domain, $ref) = $registry->resolve($id, \%context);
  my $domain = $registry->resolve($id, \%context);

The version comes from the result metadata's C<version> or the contract's
C<domain_version>; the fingerprint from metadata C<fingerprint>, the
contract's C<domain_fingerprint> or the computed fingerprint.

=head2 resolve_ref

  my $domain = $registry->resolve_ref($ref, \%context);

Resolves a reference issued by this registry again. Providers are called
again, so pass the same trusted context.

=head2 ref

  my $ref = $registry->ref($id);

A bare reference to a registered id, without resolving it.

=head2 ids, name

The registered ids (sorted) and the registry name.

=head2 ok, not_found, forbidden, error

  return Selecto::Domain::Registry->ok($domain, \%metadata);
  return Selecto::Domain::Registry->not_found;

Result constructors for providers.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain::Ref>, L<Selecto::Engine/from_registry>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
