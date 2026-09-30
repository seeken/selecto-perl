package Selecto::Document::Engine;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Hash::Util qw(lock_hash);
use Selecto::Document::Plan ();
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_shape_release', 'document engine requires a shape release')
        unless blessed($args{release}) && $args{release}->isa('Selecto::Document::ShapeRelease');
    Selecto::Error->throw('invalid_adapter', 'document engine requires a Selecto adapter')
        unless blessed($args{adapter}) && $args{adapter}->isa('Selecto::Adapter');
    Selecto::Error->throw('tenant_required', 'document engine requires trusted tenant scope')
        unless defined($args{tenant}) && !ref($args{tenant}) && length("$args{tenant}");
    my $self = bless { release => $args{release}, adapter => $args{adapter}, tenant => "$args{tenant}" }, $class;
    lock_hash(%$self);
    return $self;
}

sub plan {
    my ($self, %args) = @_;
    return Selecto::Document::Plan->new(%args, release => $self->{release}, tenant => $self->{tenant});
}

sub compile {
    my ($self, $plan) = @_;
    Selecto::Error->throw('invalid_document_plan', 'Native plan required')
        unless blessed($plan) && $plan->isa('Selecto::Document::Plan');
    $plan->validate_scope($self->{release}, $self->{tenant});
    return $self->{adapter}->compile($self->{release}, $plan);
}
sub all { my ($self, $plan) = @_; return $self->{adapter}->execute_query($self->compile($plan)); }

1;

__END__

=head1 NAME

Selecto::Document::Engine - engine for approved document-database access patterns

=head1 DESCRIPTION

The document-database counterpart of L<Selecto::Engine>. It compiles a
L<Selecto::Document::Plan> through an adapter supplied by a separate
distribution (for example a MongoDB adapter).

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Document::Plan>, L<Selecto::Document::ShapeRelease>, L<Selecto::Adapter>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
