use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();

# A declared foreign key and the associations on the same owner key describe
# one reference. When they disagree on the referenced relation or on the
# tenant columns they pair, one declaration would silently drop the other's
# tenant guard, so the domain is refused (invalid_domain,
# foreign_key_tenant_scope_undeclared) before any query or write.

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
        columns => {map { ($_ => {type => $_ eq 'name' ? 'string' : 'integer'}) } @fields}, associations => {}};
}

# Orders (id, tenant_id, site_id, customer_id) reference customers. %o shapes
# the declarations on customer_id:
#   fk          => foreign-key references (relation key from %t, optional tenant_field)
#   association => [[name, schema, %association options], ...]
#   two_column  => writes.scope.tenant.field site_id beside source.tenant_field tenant_id
sub contract {
    my ($t, %o) = @_;
    my %schemas = (
        customer => {%{relation($t->{customers}, qw(id tenant_id site_id region_id name))}, tenant_field => 'tenant_id'},
        site_customer => {%{relation($t->{site_customers}, qw(id tenant_id site_id name))}, tenant_field => 'site_id'},
        person => {%{relation($t->{customers}, qw(id tenant_id site_id region_id name))}, tenant_field => 'tenant_id'},
    );
    my %associations = map {
        my ($name, $schema, %options) = @$_;
        ($name => {queryable => $schema, owner_key => 'customer_id', related_key => 'id', %options});
    } @{$o{association} // []};
    my %fk = $o{fk} ? (customer_id => {source => 'input', references => {
        relation => $t->{$o{fk}{relation}}, field => 'id',
        (exists $o{fk}{tenant_field} ? (tenant_field => $o{fk}{tenant_field}) : ())}}) : ();
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation($t->{orders}, qw(id tenant_id site_id customer_id))},
            tenant_field => 'tenant_id', associations => \%associations},
        schemas => \%schemas, joins => {},
        writes => {
            operations => {insert => {enabled => 1}},
            fields => {map { ($_ => {insertable => 1}) } qw(id tenant_id site_id customer_id)},
            constraints => {foreign_keys => \%fk},
            ($o{two_column} ? (scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}) : ()),
        },
    };
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "reference agreement on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_ra_${_}_$suffix") } qw(orders customers site_customers);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, customer_id integer)");
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, site_id integer, region_id integer, name varchar(20))");
        $dbh->do("CREATE TABLE $t{site_customers} (id integer primary key, tenant_id integer, site_id integer, name varchar(20))");
        # Customer 50 belongs to tenant 5 (site 1); 51 to tenant 1 (site 5);
        # 22 to tenant 2 in region 1.
        $dbh->do("INSERT INTO $t{customers} VALUES (50, 5, 1, 9, 'theirs'), (51, 1, 5, 1, 'ours'), (22, 2, 9, 1, 'regional')");
        $dbh->do("INSERT INTO $t{site_customers} VALUES (50, 1, 1, 'site one'), (51, 1, 5, 'site five')");
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $orders = sub { $dbh->selectall_arrayref("SELECT id, customer_id FROM $t{orders} ORDER BY id") };
        my $engine = sub {
            my (%o) = @_;
            my $domain = Selecto::Domain->parse(contract(\%t, %o));
            return Selecto::Engine->new(adapter => $adapter,
                ($o{two_column}
                    ? (domain => $domain->with_required_predicate(Selecto::Expression->eq('tenant_id', 1)), scope => {tenant => 5})
                    : (domain => $domain, scope => {tenant => 1})));
        };
        my $insert = sub {
            my ($engine, $id, $customer, %extra) = @_;
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert',
                relation => $t{orders}, assignments => {id => $id, customer_id => $customer, %extra})) });
        };
        my $refused = sub {
            my ($label, %o) = @_;
            my $error = error_of(sub {
                my $built = $engine->(%o);
                $built->execute_write(Selecto::Write::Command->new(operation => 'insert',
                    relation => $t{orders}, assignments => {id => 1, customer_id => $o{value} // 50,
                        ($o{two_column} ? () : (tenant_id => 1))}));
            });
            is($error && $error->code, 'invalid_domain', "$label is refused");
            is($error && $error->details->{code}, 'foreign_key_tenant_scope_undeclared', "$label: refusal code");
            is_deeply($orders->(), [], "$label: no order was written");
        };

        # Different relations on one owner key, single-column root: refused
        # for a foreign tenant's customer and for the tenant's own alike.
        my %different = (fk => {relation => 'site_customers', tenant_field => 'tenant_id'},
            association => [[customer => 'customer']]);
        $refused->('foreign key and association to different relations', %different);
        $refused->('the contradictory domain with an own-tenant customer', %different, value => 51);
        # Two-column root (reference failure P3): an FK to site customers by
        # site_id beside an association to customers.
        $refused->('two-column root foreign key and association to different relations',
            two_column => 1, fk => {relation => 'site_customers', tenant_field => 'site_id'},
            association => [[customer => 'customer']]);
        # Two associations on one owner key to different relations.
        $refused->('two associations on one owner key to different relations',
            association => [[customer => 'customer'], [site_customer => 'site_customer']]);
        # Same relation, but an explicit FK tenant column other than the one
        # the association guards: customer 22 (tenant 2, region 1) must not be
        # admitted by a region guard for tenant 1.
        $refused->('a foreign key tenant column that disagrees with the association',
            fk => {relation => 'customers', tenant_field => 'region_id'},
            association => [[customer => 'customer']], value => 22);
        # Two-column root: the FK pairs with site_id, the association's scope
        # keys pair customers.tenant_id with the root's tenant_id.
        $refused->('a foreign key and association pairing different root tenant columns',
            two_column => 1, fk => {relation => 'customers', tenant_field => 'tenant_id'},
            association => [[customer => 'customer', source_scope_key => 'tenant_id', target_scope_key => 'tenant_id']]);
        is(code_of(sub { $engine->(%different)->query->select('id') }), 'invalid_domain',
            'the contradictory domain is refused before any query');

        # An agreeing FK and association are applied once.
        my $agreeing = $engine->(fk => {relation => 'customers', tenant_field => 'tenant_id'},
            association => [[customer => 'customer']]);
        is($insert->($agreeing, 1, 50, tenant_id => 1), 'cardinality_mismatch', "an agreeing reference refuses another tenant's customer");
        is_deeply($orders->(), [], 'the refused reference wrote nothing');
        is($insert->($agreeing, 1, 51, tenant_id => 1), 'ok', "an agreeing reference admits the tenant's own customer");
        is_deeply($orders->(), [[1, 51]], 'the own-tenant order was written');
        $dbh->do("DELETE FROM $t{orders}");

        # AWF003: an explicit shared FK (tenant_field false) is authoritative
        # beside a tenant-scoped association to the same relation.
        my $shared = $engine->(fk => {relation => 'customers', tenant_field => JSON::PP::false},
            association => [[person => 'person']]);
        is($insert->($shared, 2, 50, tenant_id => 1), 'ok', 'an explicit shared reference stays usable');
        is_deeply($orders->(), [[2, 50]], 'the shared reference was written');
        $dbh->do("DROP TABLE $_") for values %t;
        $dbh->disconnect;
    };
}

done_testing;
