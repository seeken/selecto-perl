package Selecto::Engine;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Error ();
use Selecto::Query ();

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_domain', 'engine requires a domain')
        unless blessed($args{domain}) && $args{domain}->isa('Selecto::Domain');
    Selecto::Error->throw('invalid_adapter', 'engine requires a Selecto database adapter')
        unless blessed($args{adapter}) && $args{adapter}->isa('Selecto::Adapter');
    $args{adapter}->assert_contract;
    return bless { domain => $args{domain}, adapter => $args{adapter} }, $class;
}

sub domain  { return $_[0]->{domain}; }
sub adapter { return $_[0]->{adapter}; }
sub query   { return Selecto::Query->new; }
sub compile { my ($self, $query) = @_; return $self->{adapter}->compile($self->{domain}, $query); }
sub all     { my ($self, $query) = @_; return $self->{adapter}->execute_query($self->compile($query)); }
sub execute_write { my ($self, $command) = @_; return $self->{adapter}->execute_write($command); }
sub execute_batch { my ($self, $batch) = @_; return $self->{adapter}->execute_batch($batch); }

1;
