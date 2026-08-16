package Selecto;

use 5.034;
use strict;
use warnings;

our $VERSION = '0.1.0_01';

use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Query ();
use Selecto::Write ();

1;

__END__

=head1 NAME

Selecto - governed domain, query, and portable write contracts for Perl

=head1 SYNOPSIS

  use Selecto;

  my $domain = Selecto::Domain->parse($json, strict => 1);
  my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
  my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);

  my $query = $engine->query
      ->select('id', 'customer.company_name')
      ->where(Selecto::Expression->gte('total', '100.00'))
      ->order_by('id')
      ->limit(50);

  my $result = $engine->all($query);

=head1 DESCRIPTION

Selecto is a native, framework-neutral Perl implementation of Selecto's strict
domain, immutable query, PostgreSQL compilation/execution, and portable write
boundaries. It does not delegate Selecto semantics to an ORM or web framework.

=cut

