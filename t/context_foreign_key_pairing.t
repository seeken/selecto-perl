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
use Selecto::Write::Context ();

# Item 34: a context-sourced foreign key (source ['context', k]) is paired
# like an input foreign key. On a two-column root (writes.scope.tenant on
# site_id, bound to engine tenant 7; source.tenant_field tenant_id, bounded
# to 1 by the required predicate) a reference to people, which store
# tenant_id, is guarded with the tenant_id set, never the site value. The
# context-owned existence-only exemption applies only when nothing declares
# the target's tenancy, and crossed or contradictory pairings are refused
# with invalid_domain (foreign_key_tenant_scope_undeclared).

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

# %o: references (extra references keys), people_tenant (people schema
# tenant_field), association (scope keys of an association on person_id).
sub contract {
    my ($t, %o) = @_;
    my @fields = qw(id tenant_id site_id person_id);
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation($t->{orders}, @fields)}, tenant_field => 'tenant_id',
            ($o{association} ? (associations => {person => {queryable => 'person', owner_key => 'person_id',
                related_key => 'id', %{$o{association}}}}) : ())},
        schemas => {person => {%{relation($t->{people}, qw(id tenant_id org_id))},
            (defined($o{people_tenant}) ? (tenant_field => $o{people_tenant}) : ())}},
        joins => {},
        writes => {
            operations => {insert => {enabled => 1}},
            fields => {map { ($_ => {insertable => 1}) } @fields},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
            constraints => {foreign_keys => {person_id => {source => ['context', 'person_id'], required => JSON::PP::true,
                references => {relation => $t->{people}, field => 'id', %{$o{references} // {}}}}}},
        },
    };
}
sub engine_for {
    my ($adapter, $t, $person, %o) = @_;
    my $domain = Selecto::Domain->parse(contract($t, %o))->with_required_predicate(Selecto::Expression->eq('tenant_id', 1));
    return Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7},
        write_context => {person_id => $person});
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "context-sourced foreign keys on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_ctxfk_${_}_$suffix") } qw(orders people);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, person_id integer)");
        $dbh->do("CREATE TABLE $t{people} (id integer primary key, tenant_id integer, org_id integer)");
        # 51 belongs to tenant 1; 57 is tagged with the site value 7; 52 to tenant 2.
        $dbh->do("INSERT INTO $t{people} VALUES (51, 1, 1), (57, 7, 7), (52, 2, 2)");
        my $id = 0;
        my $insert = sub {
            my ($person, %o) = @_;
            my $engine = engine_for($adapter, \%t, $person, %o);
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert',
                relation => $t{orders}, assignments => {id => ++$id, tenant_id => 1}, expected_count => 1)) });
        };
        my $stored = sub { [map { $_->[0] } @{$dbh->selectall_arrayref("SELECT person_id FROM $t{orders} ORDER BY id")}] };

        for my $case (
            ['people.tenant_field', people_tenant => 'tenant_id'],
            ['references.tenant_field', references => {tenant_field => 'tenant_id'}],
            # Nothing on the foreign key declares the target's tenancy, but
            # the association on the same owner key does: no exemption.
            ['an association on the owner key', association => {source_scope_key => 'tenant_id', target_scope_key => 'tenant_id'}],
        ) {
            my ($label, %o) = @$case;
            $dbh->do("DELETE FROM $t{orders}");
            is($insert->(57, %o), 'cardinality_mismatch', "$label: a person tagged with the site value is refused");
            is($insert->(52, %o), 'cardinality_mismatch', "$label: another tenant's person is refused");
            is_deeply($stored->(), [], "$label: nothing was written");
            is($insert->(51, %o), 'ok', "$label: the tenant's own person is accepted");
            is_deeply($stored->(), [51], "$label: and written");
        }

        # A target nothing declares stays existence-only for a context key.
        $dbh->do("DELETE FROM $t{orders}");
        is($insert->(52), 'ok', 'a truly undeclared target is checked for existence only');
        is($insert->(999), 'cardinality_mismatch', 'and a missing person is still refused');

        for my $case (
            ['a tenant column pairing with no root column', references => {tenant_field => 'org_id'}],
            ['a foreign key and association that disagree', people_tenant => 'tenant_id',
                association => {source_scope_key => 'site_id', target_scope_key => 'org_id'}],
        ) {
            my ($label, %o) = @$case;
            my $direct = error_of(sub { engine_for($adapter, \%t, 51, %o)->execute_write(Selecto::Write::Command->new(
                operation => 'insert', relation => $t{orders}, assignments => {id => ++$id, tenant_id => 1}, expected_count => 1)) });
            is($direct && blessed($direct) && $direct->code, 'invalid_domain', "$label: invalid_domain");
            is($direct && blessed($direct) && $direct->details->{code}, 'foreign_key_tenant_scope_undeclared',
                "$label: foreign_key_tenant_scope_undeclared");
        }

        # The portable guard description pairs the same way: the context
        # tenant (the site value) never guards a tenant_id column.
        my $portable = contract(\%t, references => {tenant_field => 'tenant_id'});
        my $guards = Selecto::Write::Context->foreign_key_guards({schemas => $portable->{schemas}},
            {source => $portable->{source}, scope => $portable->{writes}{scope}, constraints => $portable->{writes}{constraints}},
            {person_id => 51}, 'insert', {tenant_id => 7, person_id => 51});
        is(scalar(@$guards), 1, 'the portable path describes one guard');
        ok(!grep({ ($_->{tenant_field} // '') eq 'tenant_id' && grep { $_ == 7 } @{$_->{tenants} // []} } @$guards),
            'the portable guard never pairs the site value with tenant_id');
        $dbh->do("DROP TABLE $t{$_}") for qw(orders people);
    };
}

done_testing;
