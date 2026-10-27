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

# DuckDB: query members joined to their root by a text identity key (the
# tenant, or a column the host's required predicate compares) group and
# correlate by bytes, as PostgreSQL does, under a NOCASE column or
# default_collation 'nocase': rows of 'T1' are never merged into the root's
# 't1' group or correlated with it. Lateral members are refused on DuckDB.
my $x = 'Selecto::Expression';
plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
my @backends = (['duckdb', sub { DBI->connect('dbi:DuckDB:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1}) }, 'VARCHAR COLLATE NOCASE'],
  ['duckdb-defaultnocase', sub { my $d = DBI->connect('dbi:DuckDB:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1}); $d->do("SET default_collation='nocase'"); $d }, 'VARCHAR'],
  ['duckdb-int-vs-text', sub { DBI->connect('dbi:DuckDB:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,AutoCommit=>1}) }, 'VARCHAR']);

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

my $grouped = {select => ['org_key', {as => 'total', aggregate => 'sum', field => 'amount'}], group_by => ['org_key']};
for my $backend (@backends) {
    my ($label0, $connect, $ctype) = @$backend; my $name = 'duckdb';
    my $dbh = $connect->();
    $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_mg_root selecto_mg_mem);
    $dbh->do('CREATE TABLE selecto_mg_root (id INT PRIMARY KEY, org_key VARCHAR)');
    $dbh->do("CREATE TABLE selecto_mg_mem (id INT PRIMARY KEY, parent_id INT NULL, org_key $ctype, amount INT)");
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
            }});
        $domain = $domain->with_required_predicate($x->eq('org_key', 't1')) unless $tenant;
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain,
            ($tenant ? (scope => {tenant => 't1'}) : ()));
        my $values = sub {
            my ($member, $column) = @_;
            my $rows = eval { $engine->all($engine->query->with_member($member)->select('id', "$member.$column"))->{rows} };
            return blessed($@) ? 'ERR ' . $@->code : defined($@) && $@ ne '' ? "died: $@" : join(',', sort map { $_->[1] // 'null' } @$rows);
        };
        is($values->('tot', 'total'), '1', "$label0 $label: a grouped CTE member sums only the exact key");
        is($values->('stot', 'total'), '1', "$label0 $label: a grouped subquery member sums only the exact key");
        is($values->('atot', 'total'), '1', "$label0 $label: an aliased joined key groups exactly");
        is($values->('vtot', 'total'), '1', "$label0 $label: a value expression over the joined key groups exactly");
        is($values->('tree', 'id'), '1', "$label0 $label: a recursive member joins only the exact key");
    }
    $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_mg_root selecto_mg_mem);
}

done_testing;
