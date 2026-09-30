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

__END__

=head1 NAME

Selecto::Adapter::Registry - name-to-class registry for database adapters

=head1 SYNOPSIS

  use Selecto::Adapter::Registry;

  my $registry = Selecto::Adapter::Registry->default;
  $registry->register(futuredb => 'MyApp::Selecto::FutureDB', contract_version => 1);

  my $names   = $registry->names;                       # ['duckdb', ..., 'sqlite']
  my $adapter = $registry->build(futuredb => (dbh => $dbh));

=head1 DESCRIPTION

Applications choose an adapter by a stable lowercase name instead of
constructing a dialect class. The default registry, used by
L<Selecto/adapter>, contains C<duckdb>, C<mariadb>, C<mssql>, C<mysql>,
C<postgresql> and C<sqlite>. Adapter classes are loaded lazily by L</build>,
so the core never loads a driver you do not use.

=head1 METHODS

=head2 default

The process-wide registry used by L<Selecto/adapter>.

=head2 new

A new, empty registry.

=head2 register

  $registry->register($name, $class, contract_version => 1);

Names must match C</\A[a-z][a-z0-9_]*\z/> and be unique
(C<duplicate_adapter>). The contract version must equal
C<$Selecto::Adapter::CONTRACT_VERSION> (C<adapter_contract_mismatch>).
Returns the registry.

=head2 register_default

  Selecto::Adapter::Registry->register_default($name, $class, %options);

Registers in the default registry.

=head2 names

The sorted registered names.

=head2 build

  my $adapter = $registry->build($name, %args);

Loads the class (it must be loadable with C<require>), checks its contract
version and constructs it with C<%args>. Throws C<unknown_adapter>,
C<invalid_adapter> or C<adapter_contract_mismatch>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Adapter>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
