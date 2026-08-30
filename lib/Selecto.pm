package Selecto;

use 5.034;
use strict;
use warnings;

our $VERSION = '0.2.0_01';

use Selecto::Adapter ();
use Selecto::Adapter::Registry ();
use Selecto::Action ();
use Selecto::API ();
use Selecto::Domain ();
use Selecto::Domain::DSL ();
use Selecto::Domain::Overlay ();
use Selecto::Domain::Ref ();
use Selecto::Domain::Registry ();
use Selecto::Engine ();
use Selecto::Error ();
use Selecto::Expression ();
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

  use Selecto;

  my $domain = Selecto::Domain->parse($json, strict => 1);
  my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
  my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

  my $query = $engine->query
      ->select('id', 'customer.company_name')
      ->where(Selecto::Expression->gte('total', '100.00'))
      ->order_by('id')
      ->limit(50);

  my $result = $engine->all($query);

=head1 DESCRIPTION

Selecto is a native, HTTP-neutral Perl implementation of Selecto's strict
domain, immutable query, database-adapter, and portable write boundaries.
Mojolicious supplies the lightweight object foundation and adapter registry;
it does not own query semantics or database execution.

=cut
