package Selecto::Domain::Ref;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_domain_ref', 'domain reference id must be a non-empty string')
        if !defined($args{id}) || ref($args{id}) || "$args{id}" !~ /\S/;
    Selecto::Error->throw('invalid_domain_ref', 'domain reference requires a registry object')
        unless blessed($args{registry}) && $args{registry}->can('resolve');
    Selecto::Error->throw('invalid_domain_ref', 'domain reference registry name must be a non-empty string')
        if !defined($args{registry_name}) || ref($args{registry_name})
            || "$args{registry_name}" !~ /\S/;
    Selecto::Error->throw('invalid_domain_ref', 'domain reference metadata must be an object')
        unless ref($args{metadata} // {}) eq 'HASH';
    return bless {
        id => "$args{id}",
        registry => $args{registry},
        registry_name => "$args{registry_name}",
        version => $args{version},
        fingerprint => $args{fingerprint},
        metadata => dclone($args{metadata} // {}),
    }, $class;
}

sub id            { return $_[0]->{id}; }
sub registry      { return $_[0]->{registry}; }
sub registry_name { return $_[0]->{registry_name}; }
sub version       { return $_[0]->{version}; }
sub fingerprint   { return $_[0]->{fingerprint}; }
sub metadata      { return dclone($_[0]->{metadata}); }

sub to_hash {
    my ($self) = @_;
    return {
        id => $self->{id},
        registry => $self->{registry_name},
        version => $self->{version},
        fingerprint => $self->{fingerprint},
        metadata => dclone($self->{metadata}),
    };
}

1;

__END__

=head1 NAME

Selecto::Domain::Ref - opaque provenance for a registered Selecto domain

=head1 SYNOPSIS

  my ($domain, $ref) = $registry->resolve(orders => \%context);
  $ref->id;            # 'orders'
  $ref->version;       # from provider metadata or domain_version
  $ref->fingerprint;
  my $data = $ref->to_hash;

=head1 DESCRIPTION

A reference names a domain inside a L<Selecto::Domain::Registry> and
records where it came from, without embedding the domain contract. Engines
built with L<Selecto::Engine/from_registry> keep it as C<domain_ref>, so
downstream code can inspect provenance without accepting a caller-supplied
domain.

=head1 METHODS

C<id>, C<registry> (the registry object), C<registry_name>, C<version>,
C<fingerprint> and C<metadata> (a copy).

=head2 to_hash

Returns C<< {id, registry, version, fingerprint, metadata} >>, a data-only
projection suitable for diagnostics or transport. It cannot be turned back
into a domain without the registry.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain::Registry>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
