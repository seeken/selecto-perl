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

# Lesson 29e: on a two-column root (writes.scope.tenant on site_id, bound to
# engine tenant 7; source.tenant_field tenant_id, bounded to 1 by the
# required predicate) a reference guard takes the admitted set of the root
# column it pairs with. An authored scope pair (source_scope_key ->
# target_scope_key) pairs the target column with its source column whatever
# the target column is called; a target storing both root columns is guarded
# on each by name. Pairings that disagree are refused with invalid_domain
# (foreign_key_tenant_scope_undeclared) when the engine is built.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

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

# One association from orders.$owner to a target relation; $target_tenant
# declares the target schema's tenant_field.
sub engine_for {
    my ($dbh, $adapter, $t, %o) = @_;
    my @fields = (qw(id tenant_id site_id), $o{owner});
    my $domain = Selecto::Domain->parse({
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation($t->{orders}, @fields)}, tenant_field => 'tenant_id',
            associations => {target => {queryable => 'target', owner_key => $o{owner}, related_key => 'id',
                (defined($o{source}) ? (source_scope_key => $o{source}, target_scope_key => $o{target}) : ())}}},
        schemas => {target => {%{relation($t->{$o{table}}, 'id', @{$o{columns}})},
            (defined($o{target_tenant}) ? (tenant_field => $o{target_tenant}) : ())}},
        joins => {},
        writes => {
            operations => {update => {enabled => 1}},
            fields => {map { ($_ => {insertable => 1, updatable => 1}) } @fields},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
        },
    });
    $domain = $domain->with_required_predicate(Selecto::Expression->eq('tenant_id', 1)) unless $o{unbounded};
    return Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7});
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "two-column scope pairing on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_pair_${_}_$suffix") } qw(orders warehouses depots regions customers sites);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer,"
            . " wh_id integer, depot_id integer, region_id integer, cust_id integer, site_ref integer)");
        $dbh->do("INSERT INTO $t{orders} (id, tenant_id, site_id) VALUES (1, 1, 7)");
        $dbh->do("CREATE TABLE $t{warehouses} (id integer primary key, site_id integer)");
        $dbh->do("INSERT INTO $t{warehouses} VALUES (11, 1), (71, 7)");
        $dbh->do("CREATE TABLE $t{depots} (id integer primary key, tenant_id integer)");
        $dbh->do("INSERT INTO $t{depots} VALUES (17, 7), (19, 1)");
        $dbh->do("CREATE TABLE $t{regions} (id integer primary key, org_id integer)");
        $dbh->do("INSERT INTO $t{regions} VALUES (5, 1), (6, 2), (8, 7)");
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, ref_site integer)");
        $dbh->do("INSERT INTO $t{customers} VALUES (10, 1, 7), (70, 7, 7)");
        $dbh->do("CREATE TABLE $t{sites} (id integer primary key, tenant_id integer, site_id integer)");
        $dbh->do("INSERT INTO $t{sites} VALUES (31, 1, 7), (32, 1, 8), (33, 2, 7), (34, 7, 1)");
        my $assign = sub {
            my ($engine, $field, $value) = @_;
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
                relation => $t{orders}, assignments => {$field => $value},
                predicate => Selecto::Expression->eq('id', 1), expected_count => 1)) });
        };
        my $stored = sub { ($dbh->selectrow_array("SELECT $_[0] FROM $t{orders} WHERE id = 1"))[0] };

        # Authored pairs take their source column's set, whatever the target
        # column is named.
        for my $case (
            ['tenant_id -> warehouses.site_id', owner => 'wh_id', table => 'warehouses', columns => ['site_id'],
                source => 'tenant_id', target => 'site_id', right => 11, wrong => [71]],
            ['site_id -> depots.tenant_id', owner => 'depot_id', table => 'depots', columns => ['tenant_id'],
                source => 'site_id', target => 'tenant_id', right => 17, wrong => [19]],
            ['tenant_id -> regions.org_id', owner => 'region_id', table => 'regions', columns => ['org_id'],
                source => 'tenant_id', target => 'org_id', right => 5, wrong => [6, 8]],
        ) {
            my ($label, %o) = @$case;
            my $engine = engine_for($dbh, $adapter, \%t, %o);
            for my $wrong (@{$o{wrong}}) {
                is($assign->($engine, $o{owner}, $wrong), 'cardinality_mismatch', "$label: the wrong tenant's row $wrong is refused");
                is($stored->($o{owner}), undef, "$label: nothing was written for $wrong");
            }
            is($assign->($engine, $o{owner}, $o{right}), 'ok', "$label: the right tenant's row $o{right} is accepted");
            is($stored->($o{owner}), $o{right}, "$label: and written");
        }

        # A target storing both root columns: each is guarded by name with
        # its own set.
        my $both = engine_for($dbh, $adapter, \%t, owner => 'site_ref', table => 'sites', columns => [qw(tenant_id site_id)],
            target_tenant => 'tenant_id');
        is($assign->($both, 'site_ref', $_), 'cardinality_mismatch', "both columns: row $_ is refused") for 32, 33, 34;
        is($stored->('site_ref'), undef, 'both columns: nothing was written');
        is($assign->($both, 'site_ref', 31), 'ok', 'both columns: the row in both sets is accepted');

        # Without a required predicate nothing bounds tenant_id: a reference
        # paired with it is refused rather than guarded with the site set.
        my $unbounded = engine_for($dbh, $adapter, \%t, owner => 'wh_id', table => 'warehouses', columns => ['site_id'],
            source => 'tenant_id', target => 'site_id', unbounded => 1);
        is($assign->($unbounded, 'wh_id', 71), 'missing_tenant_scope', 'an unbounded paired column refuses the reference');

        # Refusals, all when the engine is built.
        for my $case (
            ['declared tenant_field disagrees with the scope keys', owner => 'cust_id', table => 'customers',
                columns => [qw(tenant_id ref_site)], target_tenant => 'tenant_id', source => 'site_id', target => 'ref_site'],
            ['an authored pair and the declared tenant_field give one column two sets (29j)', owner => 'wh_id',
                table => 'warehouses', columns => ['site_id'], target_tenant => 'site_id', source => 'tenant_id', target => 'site_id'],
            ['an authored pair crosses names on a target storing both root columns', owner => 'site_ref',
                table => 'sites', columns => [qw(tenant_id site_id)], source => 'tenant_id', target => 'site_id'],
        ) {
            my ($label, %o) = @$case;
            my $error = error_of(sub { engine_for($dbh, $adapter, \%t, %o) });
            is($error && blessed($error) && $error->code, 'invalid_domain', "$label: invalid_domain");
            is($error && blessed($error) && $error->details->{code}, 'foreign_key_tenant_scope_undeclared',
                "$label: foreign_key_tenant_scope_undeclared");
        }
        $dbh->do("DROP TABLE $t{$_}") for sort keys %t;
    };
}

done_testing;
