package Selecto;

use 5.034;
use strict;
use warnings;

our $VERSION = '0.2.0';

use Selecto::Adapter ();
use Selecto::Adapter::Registry ();
use Selecto::Action ();
use Selecto::API ();
use Selecto::API::ResultFormatter ();
use Selecto::CoDomain ();
use Selecto::DataRules ();
use Selecto::Domain ();
use Selecto::Domain::DSL ();
use Selecto::Domain::Overlay ();
use Selecto::Domain::Ref ();
use Selecto::Domain::Registry ();
use Selecto::Document::Engine ();
use Selecto::Document::Integer ();
use Selecto::Document::Missing ();
use Selecto::Document::Plan ();
use Selecto::Document::ShapeRelease ();
use Selecto::Engine ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::FieldPolicy ();
use Selecto::Files ();
use Selecto::Query ();
use Selecto::QueryEnforcement ();
use Selecto::QueryLibrary ();
use Selecto::SQL ();
use Selecto::Statement ();
use Selecto::Stream ();
use Selecto::Write ();
use Selecto::Write::Expression ();

sub adapter {
    my ($class, $name, %args) = @_;
    return Selecto::Adapter::Registry->default->build($name, %args);
}

sub available_adapters { return Selecto::Adapter::Registry->default->names; }

sub domain_registry {
    my ($class, %args) = @_;
    return Selecto::Domain::Registry->new(%args);
}

sub engine_registered {
    my ($class, %args) = @_;
    return Selecto::Engine->from_registry(%args);
}

1;

__END__

=head1 NAME

Selecto - governed domain, query, and portable write contracts for Perl

=head1 SYNOPSIS

  use DBI;
  use Selecto;

  my $dbh = DBI->connect($dsn, $user, $password,
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});

  my $domain = Selecto::Domain->parse($json_or_hashref);
  my $engine = Selecto::Engine->new(
      domain  => $domain,
      adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
      scope   => {tenant => $session->tenant_id},   # when the domain is scoped
  );

  my $result = $engine->all(
      $engine->query
          ->select('id', 'customer.company_name', 'total')
          ->where(Selecto::Expression->gte('total', '100.00'))
          ->order_by('id')
          ->limit(50)
  );
  # {columns => ['id', 'customer.company_name', 'total'], rows => [[...], ...]}

  my $written = $engine->execute_write($engine->write_command(
      operation   => 'update',
      assignments => {status => 'closed'},
      filter      => ['eq', 'id', 17],
  ));

=head1 DESCRIPTION

Selecto is a governed data-access layer. A I<domain> describes one root
table, its columns, its relationships and the writes it allows. An I<engine>
pairs a domain with a database I<adapter>, builds immutable I<queries> whose
field paths are resolved against the domain, and executes portable I<writes>
only when the domain grants them. Values are always bound parameters; there
is no raw-SQL escape hatch, and any feature an adapter cannot express fails
with a L<Selecto::Error> instead of falling back to something weaker.

The core is HTTP-neutral. It uses DBI as its database boundary and
L<Mojolicious> only for its small object system; it has no routes, templates
or ORM. L<Selecto::API> and L<Selecto::API::EngineHandler> implement the
canonical Selecto HTTP contract as plain functions that any web framework can
call, and the separate Selecto::Components distribution provides a
Mojolicious user interface.

This is alpha software. Its contracts track the cross-language Selecto
protocol; interfaces may still change between minor versions.

=head2 A short tour

=over 4

=item 1.

Write a domain (L<Selecto::Domain>). The canonical form is a hash or JSON
document with a C<source> relation, optional C<schemas> for related tables,
and optional C<writes>, C<actions> and C<query_library> sections.

=item 2.

Pick an adapter with L</adapter> and wrap it and the domain in a
L<Selecto::Engine>. Give the engine the tenant from your authenticated
session when the domain is multi-tenant.

=item 3.

Build queries with L<Selecto::Query> and L<Selecto::Expression>, run them with
C<< $engine->all >> or stream them with C<< $engine->stream >>.

=item 4.

Write through C<< $engine->write_command >> and C<< $engine->execute_write >>
(L<Selecto::Write>), or run declared actions with C<< $engine->plan_action >>
and C<< $engine->execute_action >> (L<Selecto::Action>).

=item 5.

Expose the domain over HTTP with L<Selecto::API> and
L<Selecto::API::EngineHandler>, if you need to.

=back

The F<README.md> in the distribution contains a complete, runnable walk
through these steps using an in-memory SQLite database.

=head1 CLASS METHODS

Loading C<Selecto> loads the core modules (domains, queries, expressions,
the engine, writes, actions, errors, L<Selecto::API>, L<Selecto::CoDomain>,
L<Selecto::FieldPolicy> and L<Selecto::Files>). Load
L<Selecto::API::EngineHandler>, L<Selecto::CannedPage> and
L<Selecto::Importer> explicitly when you use them. Concrete adapters are
loaded lazily by L</adapter>.

=head2 adapter

  my $adapter = Selecto->adapter($name, %args);
  my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));

Builds the adapter registered under C<$name> in the default
L<Selecto::Adapter::Registry>, passing C<%args> to its constructor. Every SQL
adapter takes C<dbh> (a connected DBI handle you own) and
C<transaction_mode> (C<managed>, the default, or C<external>) and an optional
C<transaction_handler>; see L<Selecto::SQL>. Throws C<unknown_adapter> for an unregistered name and
C<invalid_adapter> when the module cannot be loaded or no handle is given.

=head2 available_adapters

  my $names = Selecto->available_adapters;   # ['duckdb', 'mariadb', ...]

Returns the sorted adapter names currently registered. This release registers
C<duckdb>, C<mariadb>, C<mssql>, C<mysql>, C<postgresql> and C<sqlite>.

=head2 domain_registry

  my $registry = Selecto->domain_registry(name => 'MyApp::Domains');

Shortcut for C<< Selecto::Domain::Registry->new(%args) >>.

=head2 engine_registered

  my $engine = Selecto->engine_registered(
      domain  => $ref_or_id,
      adapter => $adapter,
      (registry => $registry, context => \%context, scope => \%scope),
  );

Shortcut for C<< Selecto::Engine->from_registry(%args) >>: resolves the
domain through a L<Selecto::Domain::Registry> and keeps the resulting
L<Selecto::Domain::Ref> on the engine as C<domain_ref>.

=head1 MODULES

=head2 Core

=over 4

=item L<Selecto::Domain>

The domain contract: parsing, field resolution, fingerprints, derived
request-scoped domains.

=item L<Selecto::Query>

Immutable query builder: selections, filters, grouping, ordering,
pagination, CTEs, set operations, window functions, row streaming.

=item L<Selecto::Expression>

Field, literal, comparison, text, null, membership, boolean, aggregate,
window, collection and date/time expressions, and the portable filter AST.

=item L<Selecto::ValueExpression>

The closed, typed AST for computed value columns.

=item L<Selecto::Engine>

Binds a domain to an adapter; executes queries, writes and actions under the
domain's governance and the trusted tenant scope.

=item L<Selecto::Write>

Portable write commands, batches, write graphs and results.

=item L<Selecto::Write::Expression>

Adapter-independent assignment expressions (increment, coalesce, current
timestamp, and so on).

=item L<Selecto::Action>, L<Selecto::Action::Plan>, L<Selecto::Action::Grant>

Declared domain actions: planning, capability authorization, input forms and
single-use grants.

=item L<Selecto::Error>

The exception class raised for every Selecto failure.

=back

=head2 Databases

=over 4

=item L<Selecto::Adapter>, L<Selecto::Adapter::Registry>, L<Selecto::SQL>

The adapter contract, the name registry, and the shared SQL implementation
that concrete adapters inherit.

=item L<Selecto::PostgreSQL>, L<Selecto::SQLite>, L<Selecto::MySQL>,
L<Selecto::MariaDB>, L<Selecto::MSSQL>, L<Selecto::DuckDB>

The bundled adapters.

=item L<Selecto::Statement>, L<Selecto::Stream>

Compiled SQL with its bound parameters, and the row-streaming cursor.

=back

=head2 Integration

=over 4

=item L<Selecto::API>, L<Selecto::API::EngineHandler>

HTTP-neutral hosting of the canonical Selecto API, and the governed query and
write handler behind it.

=item L<Selecto::QueryLibrary>

Named segments, projections, orderings and views declared by the domain.

=item L<Selecto::CannedPage>

Faceted search pages with totals, facet counts and drill-down.

=item L<Selecto::CoDomain>

Governed lookups into a different domain.

=item L<Selecto::Domain::DSL>, L<Selecto::Domain::Registry>, L<Selecto::Domain::Ref>

Overlays for customizing shared domains, and server-owned named domain
resolution with provenance.

=item L<Selecto::QueryMember>

Reusable CTE, lateral and array-expansion sources declared in the domain.

=item L<Selecto::FieldPolicy>

Resolves which form fields are hidden, read-only, editable or action-backed.

=item L<Selecto::Importer>

CSV inspection and governed import previews.

=item L<Selecto::Files>

Experimental attachment facade with hidden tenant and storage authority.

=back

Modules not listed here are internal parts of the distribution.

=head1 SECURITY

Selecto is designed to fail closed. The points that matter to integrators:

=over 4

=item *

Build engines per request from trusted context. Pass the tenant from your
session as C<< scope => {tenant => ...} >>, or narrow the domain with
L<Selecto::Domain/with_required_predicate>; never take either from a request
body.

=item *

L<Selecto::API::EngineHandler>, L<Selecto::CannedPage> and
L<Selecto::CoDomain> refuse to run with C<missing_tenant_scope> when a domain
names a tenant field but no tenant boundary is present.
C<< $engine->all >> is deliberately available for trusted cross-tenant host
code.

=item *

Keep the default strict write policy. C<< write_policy => 'permissive' >>
and the adapters' C<execute_*_unsafe> methods are for trusted tooling and
tests.

=item *

Keep credentials in the DBI handle. Database failures surface as
C<query_error> without the driver's message.

=back

=head1 SEE ALSO

L<DBI>, L<Mojolicious>,
L<https://github.com/seeken/selecto-perl>,
L<https://github.com/seeken/selecto-perl-components>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
