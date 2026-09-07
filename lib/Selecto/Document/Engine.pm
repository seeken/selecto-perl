package Selecto::Document::Engine;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
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
    return bless { release => $args{release}, adapter => $args{adapter}, tenant => "$args{tenant}" }, $class;
}

sub plan {
    my ($self, %args) = @_;
    return Selecto::Document::Plan->new(%args, release => $self->{release}, tenant => $self->{tenant});
}

sub compile { my ($self, $plan) = @_; return $self->{adapter}->compile($self->{release}, $plan); }
sub all { my ($self, $plan) = @_; return $self->{adapter}->execute_query($self->compile($plan)); }

1;
