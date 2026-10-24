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
use Selecto::QueryEnforcement ();
use Selecto::Write ();

# Items 33/33a: when a graph's root is bound (engine tenant, trusted tenant
# pin, host scope, query enforcement), every descendant delete and update
# runs the bound-scope target contract (table lock, READ COMMITTED, no
# deferrable trigger, statement-level trigger or rule for the event, checked
# before and after the statement), even on tables without a tenant column:
# child delta deletes, join-table unlinks, depth-2 grandchild deletes and
# child updates. A statement trigger or DO ALSO rule on such a table used to
# rewrite the other tenant's parent row ('pwned').
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless defined($url) && $url ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; require Selecto::Certification; 1 };
my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('SET client_min_messages TO warning');
my $x = 'Selecto::Expression';
my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}
my $grandchild = {schema_version => 1, name => 'GC', source => relation('selecto_gb_gc', id => 'integer', child_id => 'integer', note => 'string'),
    schemas => {}, joins => {}, writes => {operations => {delete => {enabled => 1}}, fields => {}}};
my $child = {schema_version => 1, name => 'C', source => relation('selecto_gb_c', id => 'integer', parent_id => 'integer', note => 'string'),
    schemas => {}, joins => {}, writes => {operations => {delete => {enabled => 1}, update => {enabled => 1}}, fields => {note => {updatable => 1}},
        relationships => {gcs => {writable => 1, table => 'selecto_gb_gc', parent_key => 'id', child_key => 'child_id', allowed_ops => ['delete'],
            domain => $grandchild}}}};
my $link = {schema_version => 1, name => 'L', source => relation('selecto_gb_link', id => 'integer', parent_id => 'integer', tag_id => 'integer'),
    schemas => {}, joins => {}, writes => {operations => {delete => {enabled => 1}}, fields => {}}};
my $root = sub {
    my (%o) = @_;
    return {schema_version => 1, name => 'P',
        source => {%{relation('selecto_gb_p', id => 'integer', org_key => 'string', title => 'string')}, ($o{tenant} ? (tenant_field => 'org_key') : ())},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {title => {updatable => 1}},
            relationships => {
                cs => {writable => 1, table => 'selecto_gb_c', parent_key => 'id', child_key => 'parent_id', allowed_ops => ['delete', 'update'], domain => $child},
                links => {writable => 1, table => 'selecto_gb_link', parent_key => 'id', child_key => 'parent_id', allowed_ops => ['delete'], domain => $link}}},
        ($o{required} ? (required_filters => $o{required}) : ())};
};
my %roots = (
    'engine tenant' => sub { (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($root->(tenant => 1)), scope => {tenant => 't1'}), {}) },
    'trusted pin' => sub { (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($root->(tenant => 1, required => [['org_key', 't1']]))), {}) },
    'host scope' => sub { (Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($root->())), {scope_predicate => $x->eq('org_key', 't1')}) },
    'query enforcement' => sub {
        my $d = Selecto::Domain->parse($root->());
        my $e = Selecto::Engine->new(adapter => $adapter, domain => $d);
        ($e, {query_enforcement => Selecto::QueryEnforcement->capture($d, $e->query->where($x->eq('org_key', 't1')))});
    },
);
my %shapes = (
    'a child delta delete' => ['selecto_gb_c', 'DELETE', sub { [{id => 'c', command => Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_gb_c',
        predicate => $x->eq('id', 10)), bindings => [{field => 'parent_id', from => 'root', key => 'id'}]}] }],
    'a join-table unlink' => ['selecto_gb_link', 'DELETE', sub { [{id => 'l', command => Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_gb_link',
        predicate => $x->eq('id', 30)), bindings => [{field => 'parent_id', from => 'root', key => 'id'}]}] }],
    'a depth-2 grandchild delete' => ['selecto_gb_gc', 'DELETE', sub { [
        {id => 'c', command => Selecto::Write::Command->new(operation => 'update', relation => 'selecto_gb_c', assignments => {note => 'u'}, predicate => $x->eq('id', 10)),
            bindings => [{field => 'parent_id', from => 'root', key => 'id'}]},
        {id => 'g', command => Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_gb_gc', predicate => $x->eq('id', 20)),
            bindings => [{field => 'child_id', from => 'c', key => 'id'}]}] }],
    'a child update' => ['selecto_gb_c', 'UPDATE', sub { [{id => 'c', command => Selecto::Write::Command->new(operation => 'update', relation => 'selecto_gb_c',
        assignments => {note => 'u'}, predicate => $x->eq('id', 10)), bindings => [{field => 'parent_id', from => 'root', key => 'id'}]}] }],
);
my $reset = sub {
    $dbh->do('DROP TABLE IF EXISTS selecto_gb_p, selecto_gb_c, selecto_gb_gc, selecto_gb_link CASCADE');
    $dbh->do('CREATE TABLE selecto_gb_p (id INT PRIMARY KEY, org_key VARCHAR(16), title VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_gb_c (id INT PRIMARY KEY, parent_id INT, note VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_gb_gc (id INT PRIMARY KEY, child_id INT, note VARCHAR(16))');
    $dbh->do('CREATE TABLE selecto_gb_link (id INT PRIMARY KEY, parent_id INT, tag_id INT)');
    $dbh->do(q{INSERT INTO selecto_gb_p VALUES (1, 't1', 'a'), (2, 't2', 'theirs')});
    $dbh->do(q{INSERT INTO selecto_gb_c VALUES (10, 1, 'n'), (11, 2, 'n')});
    $dbh->do(q{INSERT INTO selecto_gb_gc VALUES (20, 10, 'n')});
    $dbh->do(q{INSERT INTO selecto_gb_link VALUES (30, 1, 5), (31, 2, 5)});
};
$dbh->do(q{CREATE OR REPLACE FUNCTION selecto_gb_pwn() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN UPDATE selecto_gb_p SET title = 'pwned' WHERE org_key = 't2'; RETURN NULL; END $$});
my $parents = sub { $dbh->selectall_arrayref('SELECT id, title FROM selecto_gb_p ORDER BY id') };
my $run = sub {
    my ($engine, $extra, $nodes) = @_;
    my $graph = Selecto::Write::Graph->new(nodes => [{id => 'root', command => Selecto::Write::Command->new(operation => 'update',
        relation => 'selecto_gb_p', assignments => {title => 'b'}, predicate => $x->eq('id', 1), %$extra)}, @$nodes]);
    return eval { $engine->execute_graph($graph); 'applied' } // (blessed($@) ? $@->code : "died: $@");
};
for my $kind ('a statement trigger', 'a DO ALSO rule') {
    for my $bound (sort keys %roots) {
        for my $shape (sort keys %shapes) {
            my ($table, $event, $nodes) = @{$shapes{$shape}};
            $reset->();
            if ($kind =~ /trigger/) {
                $dbh->do("CREATE TRIGGER selecto_gb_pwn AFTER $event ON $table FOR EACH STATEMENT EXECUTE FUNCTION selecto_gb_pwn()");
            } else {
                $dbh->do("CREATE RULE selecto_gb_pwn AS ON $event TO $table DO ALSO UPDATE selecto_gb_p SET title = 'pwned' WHERE org_key = 't2'");
            }
            my ($engine, $extra) = $roots{$bound}->();
            is($run->($engine, $extra, $nodes->()), 'write_capability_missing', "$bound root, $kind on $table: $shape is refused");
            is_deeply($parents->(), [[1, 'a'], [2, 'theirs']], "$bound root, $kind: $shape, and the graph rolled back untouched");
        }
    }
}
# Controls: without the trigger the same graphs apply; an unbound root's
# descendants are not bound.
for my $shape (sort keys %shapes) {
    $reset->();
    my ($engine, $extra) = $roots{'engine tenant'}->();
    is($run->($engine, $extra, $shapes{$shape}[2]->()), 'applied', "engine tenant root without triggers: $shape applies");
}
{
    $reset->();
    $dbh->do('CREATE TRIGGER selecto_gb_pwn AFTER DELETE ON selecto_gb_c FOR EACH STATEMENT EXECUTE FUNCTION selecto_gb_pwn()');
    my $engine = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse($root->()));
    is($run->($engine, {}, $shapes{'a child delta delete'}[2]->()), 'applied', 'an unbound root: its child delete is not bound');
}
$dbh->do('DROP TABLE IF EXISTS selecto_gb_p, selecto_gb_c, selecto_gb_gc, selecto_gb_link CASCADE');
$dbh->do('DROP FUNCTION IF EXISTS selecto_gb_pwn()');
done_testing;
