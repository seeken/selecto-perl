use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;

# Query members joined to their root by a text identity key (the tenant, or a
# column the host's required predicate compares) group and correlate exactly
# on MySQL and MariaDB, as PostgreSQL does: rows of 'T1', 't1 ' and 'tı' are
# never merged into the root's 't1' group or correlated with it.
my $x = 'Selecto::Expression';
my @backends;
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no live PostgreSQL, MySQL or MariaDB is configured' unless @backends;

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

my $grouped = {select => ['org_key', {as => 'total', aggregate => 'sum', field => 'amount'}], group_by => ['org_key']};
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_mg_root selecto_mg_mem);
    $dbh->do('CREATE TABLE selecto_mg_root (id INT PRIMARY KEY, org_key VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_mg_mem (id INT PRIMARY KEY, parent_id INT NULL, org_key VARCHAR(16), amount INT)');
    $dbh->do(q{INSERT INTO selecto_mg_root VALUES (1, 't1')});
    my $insert = $dbh->prepare('INSERT INTO selecto_mg_mem VALUES (?, NULL, ?, ?)');
    $insert->execute(@$_) for [1, 't1', 1], [2, 'T1', 10], [3, 't1 ', 100], [4, "t\x{131}", 1000];
    for my $bound (['engine tenant', 1], ['required predicate', 0]) {
        my ($label, $tenant) = @$bound;
        my $source = relation('selecto_mg_root', id => 'integer', org_key => 'string');
        $source->{tenant_field} = 'org_key' if $tenant;
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'MemberGroups', source => $source,
            schemas => {mem => relation('selecto_mg_mem', id => 'integer', parent_id => 'integer', org_key => 'string', amount => 'integer')},
            joins => {},
            query_members => {
                ctes => {
                    tot => {source => 'mem', query => $grouped, join => {owner_key => 'org_key', related_key => 'org_key', type => 'left'}},
                    # The joined output spelled as an alias of the field, and
                    # as a value expression over it.
                    atot => {source => 'mem', query => {select => [{as => 'k', value => ['field', 'org_key']},
                        {as => 'total', aggregate => 'sum', field => 'amount'}], group_by => ['org_key']},
                        join => {owner_key => 'org_key', related_key => 'k', type => 'left'}},
                    vtot => {source => 'mem', query => {select => [{as => 'k', value => ['coalesce', ['field', 'org_key'], ['literal', 'x']]},
                        {as => 'total', aggregate => 'sum', field => 'amount'}], group_by => ['org_key']},
                        join => {owner_key => 'org_key', related_key => 'k', type => 'left'}},
                    tree => {kind => 'recursive', source => 'mem',
                        base => {select => ['id', 'parent_id', 'org_key'], filter => ['is_null', 'parent_id']},
                        step => {select => ['id', 'parent_id', 'org_key']},
                        step_join => {owner_key => 'parent_id', related_key => 'id'},
                        join => {owner_key => 'org_key', related_key => 'org_key', type => 'left'}},
                },
                subqueries => {stot => {source => 'mem', query => $grouped, on => [{left => 'org_key', right => 'org_key'}], type => 'left'}},
                laterals => {lat => {source => 'mem', query => {select => ['amount'], order_by => [['id', 'asc']], limit => 10},
                    correlations => {org_key => 'org_key'}, join_type => 'left'}},
            }});
        $domain = $domain->with_required_predicate($x->eq('org_key', 't1')) unless $tenant;
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain,
            ($tenant ? (scope => {tenant => 't1'}) : ()));
        my $values = sub {
            my ($member, $column) = @_;
            my $rows = eval { $engine->all($engine->query->with_member($member)->select('id', "$member.$column"))->{rows} };
            return blessed($@) ? 'ERR ' . $@->code : defined($@) && $@ ne '' ? "died: $@" : join(',', sort map { $_->[1] // 'null' } @$rows);
        };
        is($values->('tot', 'total'), '1', "$name $label: a grouped CTE member sums only the exact key");
        is($values->('stot', 'total'), '1', "$name $label: a grouped subquery member sums only the exact key");
        is($values->('atot', 'total'), '1', "$name $label: an aliased joined key groups exactly");
        is($values->('vtot', 'total'), '1', "$name $label: a value expression over the joined key groups exactly");
        is($values->('tree', 'id'), '1', "$name $label: a recursive member joins only the exact key");
        is($values->('lat', 'amount'), '1', "$name $label: a lateral member correlates only the exact key");
    }
    $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_mg_root selecto_mg_mem);
}

done_testing;
