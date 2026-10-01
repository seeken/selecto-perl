package Selecto::Adapter;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Error ();

our $CONTRACT_VERSION = 1;

# Write execution: Selecto::Engine calls execute_write, execute_batch, and
# execute_graph with a second argument, a Selecto::Write::Authorization for the
# exact governed object. Adapters that execute writes must pass both to
# Selecto::Write::Authorization->require_for before running anything, so a raw
# command cannot skip domain governance. preview_write compiles only.
our @REQUIRED_METHODS = qw(
    name dialect compile execute_query preview_write execute_write execute_batch
);

has 'dbh';

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    Selecto::Error->throw('invalid_adapter', 'database adapter requires a DBI-compatible handle')
        if $self->requires_dbh && !blessed($self->dbh);
    return $self->assert_contract;
}

sub requires_dbh ($self_or_class) { return 1; }

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

__END__

=head1 NAME

Selecto::Adapter - the database adapter contract

=head1 SYNOPSIS

  # Using an adapter
  my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
  $adapter->name;                     # 'postgresql'
  $adapter->supports('rollup');       # 1
  $adapter->write_capabilities;       # {insert => 1, upsert => 1, returning => 1, ...}

  # Writing one: most SQL databases should subclass Selecto::SQL.
  package MyApp::Selecto::FutureDB;
  use Mojo::Base 'Selecto::SQL';
  use Selecto::Adapter::Registry ();

  sub name        { 'futuredb' }
  sub dialect     { __PACKAGE__ }
  sub placeholder { '?' }
  sub supports    { my ($self, $feature) = @_; $feature eq 'transactions' }

  Selecto::Adapter::Registry->default->register(
      futuredb => __PACKAGE__, contract_version => 1);

  1;

  # In the application:
  use MyApp::Selecto::FutureDB;
  my $adapter = Selecto->adapter(futuredb => (dbh => $dbh));

=head1 DESCRIPTION

An adapter turns a domain and a query into a L<Selecto::Statement>, executes
statements and governed writes over a DBI handle, and reports which features
it supports. Dialect SQL and result normalization live entirely inside the
adapter. L<Selecto::Engine> accepts any object that inherits
C<Selecto::Adapter> and implements the required methods.

The bundled adapters inherit L<Selecto::SQL>, which implements compilation,
execution, streaming and transactions for SQL databases; a new SQL adapter
usually only needs its identity, placeholder style, identifier quoting,
capability list and value decoding.

Adapters are registered by a stable lowercase name in a
L<Selecto::Adapter::Registry>. An independently distributed adapter can
register itself when its module is loaded, as in the synopsis.

=head1 THE CONTRACT

C<$Selecto::Adapter::CONTRACT_VERSION> is currently 1. An adapter must
implement:

=over 4

=item C<name>

The stable lowercase registry name.

=item C<dialect>

An identifier for the SQL dialect, usually the class name.

=item C<compile($domain, $query)>

Returns a L<Selecto::Statement>. The root relation always comes from the
domain; queries never name a table.

=item C<execute_query($statement)>

Returns C<< {columns => [...], rows => [[...], ...]} >>. It must never let
the statement change data: the bundled SQL adapters refuse
(C<invalid_query>) anything but one C<SELECT> or C<WITH> statement and run every query in a transaction or savepoint
they always roll back (see L<Selecto::SQL/"The query path">).

=item C<preview_write($command)>

Returns C<< {sql => ..., params => [...]} >> without executing.

=item C<execute_write($command, $authorization)>, C<execute_batch($batch, $authorization)>

Execute governed writes. Implementations must pass both arguments to
C<< Selecto::Write::Authorization->require_for >> before running anything,
so that a command that did not come through an engine is refused.

=back

Optional: C<execute_graph> (defaults to C<write_capability_missing>),
C<stream_query($statement, %options)> returning a L<Selecto::Stream>, and
C<projection_sum_statement>.

=head1 METHODS

=head2 new

  my $adapter = MyAdapter->new(dbh => $dbh, %attributes);

Requires a blessed C<dbh> unless the class overrides C<requires_dbh> to
return false (document-database adapters may accept an injected native
client instead). Calls C<assert_contract>.

=head2 dbh

The DBI handle.

=head2 supports

  $adapter->supports($feature);

True when the adapter can compile a feature. Feature names include
C<transactions>, C<stream>, C<cte>, C<recursive_cte>, C<window_functions>,
C<set_operations>, C<rollup>, C<lateral_join>, C<json_rowset>,
C<array_rowset>, C<array_predicates>, C<json_contains>, C<text_search>,
C<value_expressions>, C<json_text>, C<row_locks>, C<returning> and
C<projection_sum>. The base class supports nothing.

=head2 capability

Returns C<< {supported => 0|1} >> for a feature.

=head2 write_capabilities

A hash of write features such as C<insert>, C<update>, C<upsert>,
C<delete>, C<transactions>, C<atomic_batch>, C<mutation_expressions>,
C<returning> and C<write_graph>.

=head2 feature_inventory

The list of feature names the adapter family knows about (whether or not
supported).

=head2 normalize_error

Converts any exception into a L<Selecto::Error>. The default wraps
non-Selecto errors as C<query_error> with the message "Execution failed" and
only the error class in its details, so driver messages (which may contain
connection details) are not exposed.

=head2 normalize_execution_result

Normalizes an execution result into C<< {status => 'ok', columns, rows} >>.

=head2 contract_version, required_methods, assert_contract, requires_dbh

Contract introspection. C<assert_contract> throws C<invalid_adapter> when a
required method is missing.

=head1 DOCUMENT DATABASES

Document databases use L<Selecto::Document::Engine> with an approved
L<Selecto::Document::ShapeRelease> rather than L<Selecto::Engine>. Their
adapters still inherit C<Selecto::Adapter> but are distributed separately.

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>, L<Selecto::Adapter::Registry>,
L<Selecto::Statement>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
