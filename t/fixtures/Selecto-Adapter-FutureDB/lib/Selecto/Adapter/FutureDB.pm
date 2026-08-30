package Selecto::Adapter::FutureDB;

use 5.034;
use Mojo::Base 'Selecto::Adapter', -signatures;
use Selecto::Adapter::Registry ();
use Selecto::Statement ();

our $VERSION = '0.001';

sub name ($self) { return 'futuredb'; }
sub dialect ($self) { return __PACKAGE__; }
sub compile ($self, @args) {
    return Selecto::Statement->new(sql => 'SELECT 1', adapter_name => $self->name);
}
sub execute_query ($self, @args) { return {columns => [], rows => []}; }
sub preview_write ($self, @args) { return {}; }
sub execute_write ($self, @args) { return {}; }
sub execute_batch ($self, @args) { return []; }

Selecto::Adapter::Registry->register_default(
    futuredb => __PACKAGE__,
    contract_version => __PACKAGE__->contract_version,
);

1;
