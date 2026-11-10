use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::PostgreSQL ();
use Selecto::Statement;
use lib 't/lib';
use TestPostgreSQL ();

# catalog_trust => 'domain': a compiled read that locks no rows takes the
# domain's word for its relations and the session. Writes, locking reads and
# hand-built statements are checked in full, and the host's settings and
# transaction come through a trusted read as they went in.
my $refused = eval { Selecto->adapter(postgresql => (dbh => undef, catalog_trust => 'all')); 1 } ? undef : $@;
is eval { $refused->code }, 'invalid_adapter', 'catalog_trust is the empty string or domain';

unless (($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '' && eval { require DBD::Pg; 1 }) {
    done_testing;
    exit 0;
}
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my $preinstalled = ($admin->selectrow_array(q{SELECT count(*) FROM pg_extension WHERE extname = 'citext'}))[0];
unless ($preinstalled || eval { $admin->do('CREATE EXTENSION citext'); 1 }) {
    done_testing;
    exit 0;
}
my $schema = ($admin->selectrow_array(q{SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'citext'}))[0];
my @clean = ('DROP TABLE IF EXISTS public.ct_t');
END { eval { $admin->do($_) for @clean; $admin->do('DROP EXTENSION IF EXISTS citext CASCADE') unless $preinstalled } }
$admin->do($_) for @clean, qq{CREATE TABLE public.ct_t (id INT PRIMARY KEY, ci "$schema".citext)},
    q{INSERT INTO public.ct_t VALUES (1, 'gold'), (2, 'other')};

my %calls;
{
    no warnings 'redefine';
    for my $name (qw(_pg_check_relations _pg_admit_session _pg_session_state _pg_extension_lookup)) {
        my $original = Selecto::PostgreSQL->can($name);
        no strict 'refs';
        *{"Selecto::PostgreSQL::$name"} = sub { $calls{$name}++; return $original->(@_) };
    }
}
my $compiled = sub {
    my ($sql, %extra) = @_;
    my $statement = Selecto::Statement->new(sql => $sql, params => [], adapter_name => 'postgresql');
    $statement->{_selecto_relations} = ['public.ct_t'];
    $statement->{$_} = $extra{$_} for keys %extra;
    return $statement;
};
my $read = $compiled->(q{SELECT id FROM public.ct_t WHERE ci = 'GOLD'});
my $rows = sub {
    my ($adapter, $statement) = @_;
    return eval { $adapter->execute_query($statement // $read)->{rows} } // diag $@;
};
my $setting = sub { my ($dbh, $name) = @_; return ($dbh->selectrow_array('SELECT pg_catalog.current_setting(?)', undef, $name))[0] };

{
    my $dbh = TestPostgreSQL->connect;
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh, catalog_trust => 'domain'));
    $dbh->do(q{SET TimeZone TO 'Asia/Tokyo'});
    %calls = ();
    is_deeply $rows->($adapter), [[1]], 'a trusted read answers';
    is $calls{_pg_check_relations} // 0, 0, 'without rechecking its relations';
    is(($calls{_pg_admit_session} // 0) + ($calls{_pg_session_state} // 0), 0, 'or reading the session before and after it');
    is $setting->($dbh, 'TimeZone'), 'Asia/Tokyo', "and in autocommit the host's own setting comes back";

    $dbh->begin_work;
    $dbh->do(q{SET LOCAL TimeZone TO 'Europe/Paris'});
    is_deeply $rows->($adapter), [[1]], "a trusted read in the host's transaction answers";
    is $setting->($dbh, 'TimeZone'), 'Europe/Paris', "and the host's setting comes back";
    is $setting->($dbh, 'transaction_read_only'), 'off', 'and the host transaction is not left read-only';
    $dbh->rollback;

    my $locking = $compiled->(q{SELECT id FROM public.ct_t WHERE id = 1 FOR UPDATE}, _selecto_row_lock => 1);
    $dbh->begin_work;
    %calls = ();
    is_deeply $rows->($adapter, $locking), [[1]], 'a trusted row-locking read answers';
    is $calls{_pg_check_relations}, 1, 'after rechecking its relations';
    $dbh->rollback;

    # A hand-built read is the host's own SQL (R71): still read only (R55).
    my $hand = Selecto::Statement->new(sql => 'WITH d AS (DELETE FROM public.ct_t WHERE id = 2 RETURNING id) SELECT id FROM d',
        params => [], adapter_name => 'postgresql');
    ok !eval { $adapter->execute_query($hand); 1 }, "a host's hand-built read that writes is refused under trust";
    is(($admin->selectrow_array('SELECT count(*) FROM public.ct_t WHERE id = 2'))[0], 1, 'and writes nothing');
    $dbh->disconnect;
}
{
    my $dbh = TestPostgreSQL->connect;
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    %calls = ();
    is_deeply $rows->($adapter), [[1]], 'an untrusted read answers';
    is $calls{_pg_check_relations}, 1, 'after rechecking its relations';
    ok $calls{_pg_admit_session} && $calls{_pg_session_state}, 'and reading the session before and after it';
    $dbh->disconnect;
}
{
    my $dbh = TestPostgreSQL->connect;
    my $adapter = Selecto->adapter(postgresql => (dbh => $dbh, catalog_trust => 'domain'));
    $rows->($adapter);
    %calls = ();
    $rows->($adapter) for 1 .. 2;
    is $calls{_pg_extension_lookup} // 0, 0, "trusted reads in later transactions reuse the process's extension lookup";
    local $Selecto::PostgreSQL::TRUSTED_CATALOG_SECONDS = 0;
    $rows->($adapter);
    is $calls{_pg_extension_lookup}, 1, 'until it expires';
    $dbh->disconnect;
}
done_testing;
