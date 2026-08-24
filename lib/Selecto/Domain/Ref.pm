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

=head1 DESCRIPTION

References carry a registry-owned id and version/fingerprint metadata without
embedding the authored domain contract. C<to_hash> returns a data-only
projection suitable for diagnostics or transport.

=cut
