use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();

# An association's source_scope_key that is not a root tenant column (here
# region_id) relates rows within a tenant. It must never turn its
# target_scope_key into the tenant guard column, which would admit another
# tenant's row from the same region. On a single-column root the reference is
# guarded by the target's declared tenancy and refused when the target
# declares none; on a two-column root it is refused outright.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; require Selecto::Certification; 1 };
}

sub error_of {
    my ($code) = @_;
    return undef if eval { $code->(); 1 };
    return $@;
}
sub code_of {
    my $error = error_of(@_);
    return 'ok' unless defined $error;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}
sub relation {
    my ($table, @fields) = @_;
    return {source_table => $table, primary_key => 'id', fields => [@fields],
        columns => {map { ($_ => {type => 'integer'}) } @fields}, associations => {}};
}

# $o{root}: tenant (source.tenant_field), scope (writes.scope.tenant only) or
# two_column (both, on different columns). $o{target_tenant} declares the
# customers schema's tenant_field.
sub contract {
    my ($t, %o) = @_;
    my $root = $o{root};
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation($t->{orders}, qw(id tenant_id site_id region_id customer_id))},
            ($root ne 'scope' ? (tenant_field => 'tenant_id') : ()),
            associations => {customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id',
                source_scope_key => 'region_id', target_scope_key => 'region_id'}}},
        schemas => {customer => {%{relation($t->{customers}, qw(id tenant_id region_id))},
            ($o{target_tenant} ? (tenant_field => 'tenant_id') : ())}},
        joins => {},
        writes => {
            operations => {insert => {enabled => 1}},
            fields => {map { ($_ => {insertable => 1}) } qw(id tenant_id site_id region_id customer_id)},
            ($root ne 'tenant' ? (scope => {tenant => {
                field => $root eq 'scope' ? 'tenant_id' : 'site_id', satisfied_by => ['trusted_context']}}) : ()),
        },
    };
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "non-tenant scope keys on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_sk_${_}_$suffix") } qw(orders customers);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, region_id integer, customer_id integer)");
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, region_id integer)");
        # Customer 60 belongs to tenant 2 in region 1; 61 to tenant 1 in region 1.
        $dbh->do("INSERT INTO $t{customers} VALUES (60, 2, 1), (61, 1, 1)");
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $orders = sub { $dbh->selectall_arrayref("SELECT id, customer_id FROM $t{orders} ORDER BY id") };
        my $engine = sub {
            my (%o) = @_;
            my $domain = Selecto::Domain->parse(contract(\%t, %o));
            return Selecto::Engine->new(adapter => $adapter, scope => {tenant => 1},
                domain => $o{root} eq 'two_column' ? $domain->with_required_predicate(Selecto::Expression->eq('tenant_id', 1)) : $domain);
        };
        my $insert = sub {
            my ($engine, $id, $customer) = @_;
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert',
                relation => $t{orders}, assignments => {id => $id, region_id => 1, customer_id => $customer})) });
        };

        for my $root (qw(tenant scope)) {
            # Reference failure P4: the target declares no tenancy, so the
            # region scope key cannot guard it.
            my $error = error_of(sub { $engine->(root => $root)->execute_write(Selecto::Write::Command->new(
                operation => 'insert', relation => $t{orders}, assignments => {id => 1, region_id => 1, customer_id => 60})) });
            is($error && $error->code, 'invalid_domain', "$root root: an undeclared target behind a region scope key is refused");
            is($error && $error->details->{code}, 'foreign_key_tenant_scope_undeclared', "$root root: refusal code");
            is_deeply($orders->(), [], "$root root: tenant 2's customer was not written");

            # The target declares tenant_id: the guard is tenant_id IN <tenants>.
            my $declared = $engine->(root => $root, target_tenant => 1);
            is($insert->($declared, 1, 60), 'cardinality_mismatch', "$root root: another tenant's customer in the same region is refused");
            is_deeply($orders->(), [], "$root root: the refused reference wrote nothing");
            is($insert->($declared, 1, 61), 'ok', "$root root: the tenant's own customer is accepted");
            is_deeply($orders->(), [[1, 61]], "$root root: the own-tenant order was written");
            $dbh->do("DELETE FROM $t{orders}");
        }

        my $two_column = error_of(sub { $engine->(root => 'two_column', target_tenant => 1) });
        is($two_column && $two_column->code, 'invalid_domain', 'a two-column root refuses a non-tenant scope key outright');
        is($two_column && $two_column->details->{code}, 'foreign_key_tenant_scope_undeclared', 'two-column refusal code');
        is_deeply($orders->(), [], 'nothing was written on the two-column root');
        $dbh->do("DROP TABLE $_") for values %t;
        $dbh->disconnect;
    };
}

done_testing;
