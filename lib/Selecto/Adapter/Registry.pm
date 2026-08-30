package Selecto::Adapter::Registry;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Adapter ();
use Selecto::Error ();

has adapters => sub { return {}; };
has contract_versions => sub { return {}; };

our $DEFAULT;

sub default ($class) {
    return $DEFAULT if $DEFAULT;
    $DEFAULT = $class->new;
    my $version = $Selecto::Adapter::CONTRACT_VERSION;
    $DEFAULT->register(duckdb => 'Selecto::DuckDB', contract_version => $version);
    $DEFAULT->register(mariadb => 'Selecto::MariaDB', contract_version => $version);
    $DEFAULT->register(mssql => 'Selecto::MSSQL', contract_version => $version);
    $DEFAULT->register(mysql => 'Selecto::MySQL', contract_version => $version);
    $DEFAULT->register(postgresql => 'Selecto::PostgreSQL', contract_version => $version);
    $DEFAULT->register(sqlite => 'Selecto::SQLite', contract_version => $version);
    return $DEFAULT;
}

sub register_default ($class, $name, $adapter_class, %options) {
    return $class->default->register($name, $adapter_class, %options);
}

sub register ($self, $name, $class, %options) {
    Selecto::Error->throw('invalid_adapter', 'adapter name must use lowercase letters, numbers, and underscores')
        unless defined($name) && $name =~ /\A[a-z][a-z0-9_]*\z/;
    Selecto::Error->throw('invalid_adapter', 'adapter class must be a Perl package name')
        unless defined($class) && $class =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;
    Selecto::Error->throw('invalid_adapter', 'unknown adapter registration options')
        if grep { $_ ne 'contract_version' } keys %options;
    Selecto::Error->throw('duplicate_adapter', "database adapter is already registered: $name")
        if exists $self->adapters->{$name};
    my $version = $options{contract_version} // $Selecto::Adapter::CONTRACT_VERSION;
    Selecto::Error->throw(
        'adapter_contract_mismatch',
        "database adapter $name uses contract version $version; expected $Selecto::Adapter::CONTRACT_VERSION",
    ) unless defined($version) && "$version" =~ /\A\d+\z/
        && int($version) == $Selecto::Adapter::CONTRACT_VERSION;
    $self->adapters->{$name} = $class;
    $self->contract_versions->{$name} = int($version);
    return $self;
}

sub names ($self) { return [sort keys %{$self->adapters}]; }

sub build ($self, $name, %args) {
    my $class = $self->adapters->{$name // ''};
    Selecto::Error->throw('unknown_adapter', "database adapter is not registered: " . ($name // '')) unless $class;
    my $file = $class =~ s{::}{/}gr . '.pm';
    my $loaded = eval { require $file; 1 };
    Selecto::Error->throw('invalid_adapter', "could not load database adapter $name") unless $loaded;
    my $declared = eval { $class->contract_version };
    Selecto::Error->throw(
        'adapter_contract_mismatch',
        "database adapter $name does not implement contract version " . $self->contract_versions->{$name},
    ) unless defined($declared) && "$declared" =~ /\A\d+\z/
        && int($declared) == $self->contract_versions->{$name};
    my $adapter = $class->new(%args);
    Selecto::Error->throw('invalid_adapter', "$class must inherit Selecto::Adapter")
        unless blessed($adapter) && $adapter->isa('Selecto::Adapter');
    return $adapter;
}

1;
