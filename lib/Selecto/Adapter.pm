package Selecto::Adapter;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Error ();

our $CONTRACT_VERSION = 1;
our @REQUIRED_METHODS = qw(
    name dialect compile execute_query preview_write execute_write execute_batch
);

has 'dbh';

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    Selecto::Error->throw('invalid_adapter', 'database adapter requires a DBI-compatible handle')
        unless blessed($self->dbh);
    return $self->assert_contract;
}

sub contract_version ($self_or_class) { return $CONTRACT_VERSION; }
sub required_methods ($self) { return [@REQUIRED_METHODS]; }

sub assert_contract ($self) {
    my $class = ref($self);
    for my $method (@REQUIRED_METHODS) {
        my $implementation = $class->can($method);
        my $abstract = __PACKAGE__->can($method);
        Selecto::Error->throw('invalid_adapter', "$class must implement adapter method $method")
            unless $implementation && $implementation != $abstract;
    }
    return $self;
}

sub feature_inventory ($self) { return []; }
sub write_capabilities ($self) { return {}; }
sub supports ($self, $feature) { return 0; }
sub capability ($self, $feature) { return { supported => $self->supports($feature) ? 1 : 0 }; }

sub normalize_execution_result ($self, $result) {
    return {
        status => 'ok',
        columns => [map { "$_" } @{$result->{columns} // []}],
        rows => [map { [@$_] } @{$result->{rows} // []}],
    };
}

sub normalize_error ($self, $error) {
    return $error if blessed($error) && $error->isa('Selecto::Error');
    my $cause = blessed($error) ? ref($error) : 'database_error';
    return Selecto::Error->new(
        code => 'query_error',
        message => 'Execution failed',
        details => { cause => $cause },
    );
}

sub name ($self) { Selecto::Error->throw('invalid_adapter', 'adapter must implement name'); }
sub dialect ($self) { Selecto::Error->throw('invalid_adapter', 'adapter must implement dialect'); }
sub compile ($self, @args) { Selecto::Error->throw('invalid_adapter', 'adapter must implement compile'); }
sub execute_query ($self, @args) { Selecto::Error->throw('invalid_adapter', 'adapter must implement execute_query'); }
sub preview_write ($self, @args) { Selecto::Error->throw('invalid_adapter', 'adapter must implement preview_write'); }
sub execute_write ($self, @args) { Selecto::Error->throw('invalid_adapter', 'adapter must implement execute_write'); }
sub execute_batch ($self, @args) { Selecto::Error->throw('invalid_adapter', 'adapter must implement execute_batch'); }
sub execute_graph ($self, @args) { Selecto::Error->throw('write_capability_missing', 'adapter does not support write graphs'); }

1;
