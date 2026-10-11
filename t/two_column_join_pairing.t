use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();

# Lessons 41a and 41c: on a two-column root (source.tenant_field tenant_id;
# writes.scope.tenant site_id) reads pair tenant columns by name, never by
# position, and the engine tenant bounds reads on tenant_id only (41c; 41a
# had bound site_id). The root binds tenant_id to the engine tenant, a target
# declaring tenant_id pairs s0.tenant_id, and a target declaring site_id is
# never bound to the engine value: it pairs s0.site_id with the tenant-bound
# root rows, returning the caller's own site rows. A target tenant column
# matching neither root column is refused with invalid_domain
# (foreign_key_tenant_scope_undeclared). Writes still bind site_id.

use Selecto::Write ();

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
        columns => {map { ($_ => {type => $_ eq 'name' ? 'string' : 'integer'}) } @fields}, associations => {}};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "two-column roots pair tenant columns by name on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l41a_${_}_$suffix") } qw(orders accounts);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, account_id integer)");
        $dbh->do("CREATE TABLE $t{accounts} (row_id integer primary key, id integer, tenant_id integer, site_id integer, org_id integer, name text)");
        # Tenant 7 owns sites 5 and 6, tenant 8 site 7. Order 4's site_id is
        # the engine tenant's value: binding site_id to it (41a) found it.
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 5, 1), (2, 7, 6, 1), (3, 8, 5, 1), (4, 8, 7, 1)");
        # Account 1 exists once per site. Row 3's site_id equals the tenant 7
        # orders' tenant_id: positional pairing (s0.tenant_id = site_id) or a
        # site_id bound to the engine value finds it.
        $dbh->do("INSERT INTO $t{accounts} VALUES (1, 1, 7, 5, 7, 'site 5'), (2, 1, 7, 6, 7, 'site 6'),"
            . " (3, 1, 8, 7, 8, 'site 7 of tenant 8')");
        my $domain = sub {
            my ($target_tenant, %o) = @_;
            return Selecto::Domain->parse({schema_version => 1, name => 'Orders',
                source => {%{relation($t{orders}, qw(id tenant_id site_id account_id))}, tenant_field => 'tenant_id',
                    associations => {account => {queryable => 'account', owner_key => 'account_id', related_key => 'id',
                        ($o{keys} ? (source_scope_key => $o{keys}[0], target_scope_key => $o{keys}[1]) : ())}}},
                schemas => {account => {%{relation($t{accounts}, qw(id tenant_id site_id org_id name))}, tenant_field => $target_tenant}},
                joins => {account => {type => 'left'}},
                ($o{member} ? (query_members => {ctes => {named => {source => 'account',
                    query => {select => ['id', 'name']}, join => {owner_key => 'account_id', related_key => 'id'}}}}) : ()),
                writes => {operations => {update => {enabled => 1}}, fields => {account_id => {updatable => 1}},
                    scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}},
                ($o{required} ? (required_filters => $o{required}) : ())});
        };
        my $engine = sub { Selecto::Engine->new(domain => $domain->(@_), adapter => $adapter, scope => {tenant => 7}) };
        my $rows = sub {
            my ($e, @select) = @_;
            return [sort { $a->[0] <=> $b->[0] || ($a->[1] // '') cmp ($b->[1] // '') }
                @{$e->all($e->query->select(@select))->{rows}}];
        };

        my $root = $engine->('site_id');
        is_deeply($rows->($root, 'id'), [[1], [2]], 'the engine tenant bounds the tenant_id column of the root');
        is_deeply($root->required_filters, [['tenant_id', 7]], 'required_filters reports the tenant_id bound');
        is_deeply($rows->($root, 'id', 'account.name'), [[1, 'site 5'], [2, 'site 6']],
            'a target declaring site_id returns the caller\'s own site rows');
        my $sql = $root->compile($root->query->select('id', 'account.name'))->sql;
        like($sql, qr/"s0"\."site_id" = "j_account"\."site_id"/, 'a site_id target pairs with the root site_id');
        unlike($sql, qr/"j_account"\."site_id" = (?:\?|\$)/, 'a site_id target is never bound to the engine value');
        unlike($sql, qr/"tenant_id" = "j_account"\."site_id"/, 'site_id is never paired with tenant_id');
        is_deeply($rows->($engine->('site_id', keys => [qw(tenant_id org_id)]), 'id', 'account.name'),
            [[1, 'site 5'], [2, 'site 6']], 'authored keys on another column still pair site_id by name');

        is_deeply($rows->($engine->('site_id', required => [['tenant_id', 7]]), 'id'), [[1], [2]],
            'a required predicate agreeing with the engine tenant');
        is_deeply($rows->($engine->('site_id', required => [['tenant_id', ['in', [7, 8]]]]), 'id'), [[1], [2]],
            'a wider required predicate is intersected with the engine tenant');
        like(code_of(sub { my $e = Selecto::Engine->new(domain => $domain->('site_id')->with_required_predicate(
                Selecto::Expression->eq('tenant_id', 8)), adapter => $adapter, scope => {tenant => 7}); $rows->($e, 'id') }),
            qr/\Atenant_(?:mismatch|scope_ambiguous)\z/, 'a required predicate excluding the engine tenant is refused');
        is_deeply($rows->($engine->('site_id', required => [['site_id', 6]]), 'id', 'account.name'), [[2, 'site 6']],
            'a required site_id predicate narrows the tenant-bound rows');

        my $member = $engine->('site_id', member => 1);
        is(code_of(sub { $member->all($member->query->with_member('named')->select('id', 'named.name')) }), 'missing_tenant_scope',
            'a member over a site_id relation, with no site_id bound to carry, is refused');
        is(code_of(sub { $domain->('site_id', member => 1, required => [['tenant_id', 7]]) }), 'missing_tenant_scope',
            'and is refused when the domain is parsed with a tenant_id bound only');
        my $site_bound = $engine->('site_id', member => 1, required => [['site_id', 6]]);
        is_deeply($site_bound->all($site_bound->query->with_member('named')->select('id', 'named.name')->order_by('id'))->{rows},
            [[2, 'site 6']], 'a member over a site_id relation carries a required site_id bound by name');

        my $by_tenant = $engine->('tenant_id', member => 1);
        like($by_tenant->compile($by_tenant->query->select('id', 'account.name'))->sql,
            qr/"s0"\."tenant_id" = "j_account"\."tenant_id"/, 'a target declaring tenant_id pairs with tenant_id');
        is_deeply($rows->($by_tenant, 'id', 'account.name'), [[1, 'site 5'], [1, 'site 6'], [2, 'site 5'], [2, 'site 6']],
            'and admits only the engine tenant\'s rows');
        is_deeply($by_tenant->all($by_tenant->query->with_member('named')->select('id', 'named.name')->order_by('id')->order_by('named.name'))->{rows},
            [[1, 'site 5'], [1, 'site 6'], [2, 'site 5'], [2, 'site 6']], 'a member over a tenant_id relation carries the engine tenant');

        # Writes are unchanged: the engine tenant binds the write-scope column.
        my $assign = sub {
            my ($id) = @_;
            return code_of(sub { $root->execute_write(Selecto::Write::Command->new(operation => 'update',
                relation => $t{orders}, assignments => {account_id => 1},
                predicate => Selecto::Expression->eq('id', $id), expected_count => 1)) });
        };
        is($assign->(4), 'ok', 'a write binds site_id to the engine tenant');
        is($assign->(1), 'cardinality_mismatch', 'and never reaches a row outside that site');

        my $error = error_of(sub { $domain->('org_id') });
        is($error && blessed($error) && $error->code, 'invalid_domain', 'a target tenant column matching neither root column is refused');
        is($error && blessed($error) && $error->details->{code}, 'foreign_key_tenant_scope_undeclared', 'with foreign_key_tenant_scope_undeclared');

        $dbh->do("DROP TABLE $t{$_}") for sort keys %t;
    };
}

done_testing;
