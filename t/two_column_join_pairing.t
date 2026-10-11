use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();

# Lesson 41a: on a two-column root (writes.scope.tenant on site_id, bound to
# the engine tenant; source.tenant_field tenant_id, bounded by the required
# predicate) reads pair tenant columns by name, never by position. A target
# declaring site_id joins on s0.site_id, not s0.tenant_id; a target tenant
# column matching neither root column is refused with invalid_domain
# (foreign_key_tenant_scope_undeclared); the engine tenant bounds only the
# site_id column of the root, and query members carry the root column of
# their own tenant column's name.

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
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 1, 7, 1), (2, 1, 8, 1), (3, 2, 7, 1)");
        # Account 1 exists once per site. Row 3's site_id equals order 1's
        # tenant_id, row 4's equals order 3's: positional pairing finds them.
        $dbh->do("INSERT INTO $t{accounts} VALUES (1, 1, 1, 7, 1, 'site 7'), (2, 1, 1, 8, 1, 'site 8'),"
            . " (3, 1, 2, 1, 1, 'site 1'), (4, 1, 7, 2, 1, 'site 2')");
        my $domain = sub {
            my ($target_tenant, %o) = @_;
            return Selecto::Domain->parse({schema_version => 1, name => 'Orders',
                source => {%{relation($t{orders}, qw(id tenant_id site_id account_id))}, tenant_field => 'tenant_id',
                    associations => {account => {queryable => 'account', owner_key => 'account_id', related_key => 'id',
                        ($o{keys} ? (source_scope_key => $o{keys}[0], target_scope_key => $o{keys}[1]) : ())}}},
                schemas => {account => {%{relation($t{accounts}, qw(id tenant_id site_id org_id name))}, tenant_field => $target_tenant}},
                joins => {account => {type => 'left'}},
                query_members => {ctes => {named => {source => 'account',
                    query => {select => ['id', 'name']}, join => {owner_key => 'account_id', related_key => 'id'}}}},
                writes => {operations => {update => {enabled => 1}}, fields => {account_id => {updatable => 1}},
                    scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}},
                ($o{required} ? (required_filters => [['tenant_id', 1]]) : ())});
        };
        my $engine = sub { Selecto::Engine->new(domain => $domain->(@_), adapter => $adapter, scope => {tenant => 7}) };
        my $rows = sub { my ($e, @select) = @_; $e->all($e->query->select(@select)->order_by('id'))->{rows} };

        my $root = $engine->('site_id');
        is_deeply($rows->($root, 'id'), [[1], [3]], 'the engine tenant bounds the site_id column of the root');
        my $bounded = $engine->('site_id', required => 1);
        is_deeply($rows->($bounded, 'id'), [[1]], 'the required predicate bounds tenant_id and the engine tenant site_id');
        is_deeply($rows->($bounded, 'id', 'account.name'), [[1, 'site 7']], 'a target declaring site_id pairs with site_id');
        unlike($bounded->compile($bounded->query->select('id', 'account.name'))->sql, qr/"tenant_id" = "j_account"\."site_id"/,
            'site_id is never paired with tenant_id');
        is_deeply($rows->($engine->('site_id', required => 1, keys => [qw(tenant_id org_id)]), 'id', 'account.name'),
            [[1, 'site 7']], 'authored keys on another column still pair site_id by name');
        is_deeply($bounded->all($bounded->query->with_member('named')->select('id', 'named.name')->order_by('id'))->{rows}, [[1, 'site 7']],
            'a member over a site_id relation carries the site_id bound');

        my $by_tenant = $engine->('tenant_id', required => 1);
        like($by_tenant->compile($by_tenant->query->select('id', 'account.name'))->sql,
            qr/"s0"\."tenant_id" = "j_account"\."tenant_id"/, 'a target declaring tenant_id pairs with tenant_id');
        is_deeply($rows->($by_tenant, 'id', 'account.name'), [[1, 'site 7'], [1, 'site 8']],
            'and admits the tenant_id rows the required predicate bounds');

        my $error = error_of(sub { $domain->('org_id') });
        is($error && blessed($error) && $error->code, 'invalid_domain', 'a target tenant column matching neither root column is refused');
        is($error && blessed($error) && $error->details->{code}, 'foreign_key_tenant_scope_undeclared', 'with foreign_key_tenant_scope_undeclared');

        $dbh->do("DROP TABLE $t{$_}") for sort keys %t;
    };
}

done_testing;
