use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::PostgreSQL ();
use Selecto::Statement;
use lib 't/lib';
use TestPostgreSQL ();

# A host transaction's reads look an extension type's catalog up once: on a
# large catalog the lookup scans pg_type. A statement in a transaction of its
# own looks it up afresh.
unless (($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '' && eval { require DBD::Pg; 1 }) {
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set';
}
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
unless ($preinstalled || eval { $admin->do('CREATE EXTENSION citext'); 1 }) {
    plan skip_all => 'the citext extension is unavailable';
}
my $schema = ($admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'}))[0];
my @clean = ('DROP TABLE IF EXISTS public.rcc_t');
END { eval { $admin->do($_) for @clean; $admin->do('DROP EXTENSION IF EXISTS citext CASCADE') unless $preinstalled } }
$admin->do($_) for @clean, qq{CREATE TABLE public.rcc_t (id INT PRIMARY KEY, ci "$schema".citext)},
    q{INSERT INTO public.rcc_t VALUES (1, 'gold'), (2, 'other')};

my $lookups = 0;
{
    no warnings 'redefine';
    my $lookup = \&Selecto::PostgreSQL::_pg_extension_lookup;
    *Selecto::PostgreSQL::_pg_extension_lookup = sub { $lookups++; return $lookup->(@_) };
}
my $statement = Selecto::Statement->new(sql => q{SELECT id FROM public.rcc_t WHERE ci = 'GOLD'}, params => [],
    adapter_name => 'postgresql');
$statement->{_selecto_relations} = ['public.rcc_t'];
my $read = sub { my ($adapter) = @_; return eval { $adapter->execute_query($statement)->{rows} } // diag $@ };

{
    my $dbh = TestPostgreSQL->connect;
    $dbh->{AutoCommit} = 0;
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    $lookups = 0;
    is_deeply $read->($adapter), [[1]], 'a read in the host transaction answers';
    is_deeply $read->($adapter), [[1]], 'and so does the next';
    is $lookups, 1, 'which reuses the first read\'s extension lookup';
    $dbh->rollback;
    is_deeply $read->($adapter), [[1]], 'a read in the next transaction answers';
    is $lookups, 2, 'after its own lookup';
    $dbh->rollback;
    $dbh->disconnect;
}
{
    my $dbh = TestPostgreSQL->connect;
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    $lookups = 0;
    $read->($adapter) for 1 .. 2;
    is $lookups, 2, 'a statement in a transaction of its own looks the catalog up each time';
    $dbh->begin_work;
    $read->($adapter) for 1 .. 2;
    is $lookups, 3, 'reads in a transaction the host begins share one lookup';
    $dbh->rollback;
    $dbh->disconnect;
}
done_testing;
