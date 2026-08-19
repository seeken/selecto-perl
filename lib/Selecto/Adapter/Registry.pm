package Selecto::Adapter::Registry;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Error ();

has adapters => sub { return {}; };

our $DEFAULT;

sub default ($class) {
    return $DEFAULT if $DEFAULT;
    $DEFAULT = $class->new;
    $DEFAULT->register(duckdb => 'Selecto::DuckDB');
    $DEFAULT->register(mariadb => 'Selecto::MariaDB');
    $DEFAULT->register(mssql => 'Selecto::MSSQL');
    $DEFAULT->register(mysql => 'Selecto::MySQL');
    $DEFAULT->register(postgresql => 'Selecto::PostgreSQL');
    $DEFAULT->register(sqlite => 'Selecto::SQLite');
    return $DEFAULT;
}

sub register ($self, $name, $class) {
    Selecto::Error->throw('invalid_adapter', 'adapter name must use lowercase letters, numbers, and underscores')
        unless defined($name) && $name =~ /\A[a-z][a-z0-9_]*\z/;
    Selecto::Error->throw('invalid_adapter', 'adapter class must be a Perl package name')
        unless defined($class) && $class =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;
    $self->adapters->{$name} = $class;
    return $self;
}

sub names ($self) { return [sort keys %{$self->adapters}]; }

sub build ($self, $name, %args) {
    my $class = $self->adapters->{$name // ''};
    Selecto::Error->throw('unknown_adapter', "database adapter is not registered: " . ($name // '')) unless $class;
    my $file = $class =~ s{::}{/}gr . '.pm';
    my $loaded = eval { require $file; 1 };
    Selecto::Error->throw('invalid_adapter', "could not load database adapter $name") unless $loaded;
    my $adapter = $class->new(%args);
    Selecto::Error->throw('invalid_adapter', "$class must inherit Selecto::Adapter")
        unless blessed($adapter) && $adapter->isa('Selecto::Adapter');
    return $adapter;
}

1;
