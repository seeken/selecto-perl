use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::PostgreSQL::Qualify ();
use Selecto::Statement;
use lib 't/lib';
use TestPostgreSQL ();

# Every spelling of a cast to an extension's type gives the operand that type,
# and with it the extension's operator: the same answer as the database's.
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
my $common = Selecto::PostgreSQL::Qualify::_common_entry({"\0unknown" => 1}, {"\0unknown" => 1});
ok($common->{"\0unknown"}, 'operands of no known type have no common one');
is_deeply(\@warnings, [], 'and saying so does not warn');

plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
plan skip_all => 'citext cannot be installed' unless $preinstalled || eval { $admin->do('CREATE EXTENSION citext'); 1 };
my $schema = ($admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'}))[0];
my @clean = ('DROP TABLE IF EXISTS public.cf_t');
END { eval { $admin->do($_) for @clean; $admin->do('DROP EXTENSION IF EXISTS citext CASCADE') unless $preinstalled } }
$admin->do($_) for @clean, qq{CREATE TABLE public.cf_t (id INT PRIMARY KEY, ci "$schema".citext)}, q{INSERT INTO public.cf_t VALUES (1, 'gold'), (2, 'other')};
my $dbh = TestPostgreSQL->connect;
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
for my $where ("ci = 'GOLD'::citext", qq{ci = 'GOLD'::"$schema".citext}, "ci = CAST('GOLD' AS citext)", qq{ci = CAST('GOLD' AS "$schema".citext)},
    "ci = 'GOLD'::CITEXT", "'GOLD'::citext = ci") {
    my $statement = Selecto::Statement->new(sql => "SELECT id FROM public.cf_t WHERE $where", params => [], adapter_name => 'postgresql');
    $statement->{_selecto_relations} = ['public.cf_t'];
    is_deeply(eval { $adapter->execute_query($statement)->{rows} }, $admin->selectall_arrayref($statement->sql), $where) or diag $@;
}
# An alias is not a cast, and a keyword for one must not fail the lookup.
for my $sql (q{SELECT id AS citext FROM public.cf_t WHERE id = 1}, q{SELECT x.select FROM (SELECT id AS "select" FROM public.cf_t WHERE id = 1) x}) {
    my $statement = Selecto::Statement->new(sql => $sql =~ s/x\.select/x."select"/r, params => [], adapter_name => 'postgresql');
    $statement->{_selecto_relations} = ['public.cf_t'];
    is_deeply(eval { $adapter->execute_query($statement)->{rows} }, [[1]], $sql) or diag $@;
}
is_deeply(\@warnings, [], 'nothing warned');
$dbh->disconnect;
done_testing;
