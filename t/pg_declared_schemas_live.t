use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();
use lib 't/lib';
use TestPostgreSQL ();

# The adapter's schemas option, and without it the root's schema: a reference
# guard or a joined relation never falls to whatever the reset path finds first
# (R59). app.parents is real; public.parents is a namesake that would pass the
# guard for parent 2, which is another tenant's.
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not set' unless ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} // '') ne '';
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my $x = 'Selecto::Expression';
my $admin = TestPostgreSQL->connect;
$admin->do('SET client_min_messages TO warning');
my @clean = ('DROP SCHEMA IF EXISTS r59_app CASCADE', 'DROP SCHEMA IF EXISTS r59_shared CASCADE', 'DROP TABLE IF EXISTS public.r59_parents, public.r59_children');
END { eval { $admin->do($_) for @clean } }
$admin->do($_) for @clean, 'CREATE SCHEMA r59_app', 'CREATE SCHEMA r59_shared',
    'CREATE TABLE r59_app.r59_parents (id INT PRIMARY KEY, org TEXT NOT NULL)',
    q{INSERT INTO r59_app.r59_parents VALUES (1, 't1'), (2, 't2')},
    'CREATE TABLE r59_app.r59_children (id INT PRIMARY KEY, org TEXT NOT NULL, parent_id INT, note TEXT)',
    q{INSERT INTO r59_app.r59_children VALUES (1, 't1', 1, 'n')},
    'CREATE TABLE r59_shared.r59_regions (id INT PRIMARY KEY, org TEXT NOT NULL)', q{INSERT INTO r59_shared.r59_regions VALUES (1, 't1')},
    'CREATE TABLE r59_app.r59_sites (id INT PRIMARY KEY, org TEXT NOT NULL, region_id INT)', q{INSERT INTO r59_app.r59_sites VALUES (1, 't1', 1)};
my $plant = sub { $admin->do($_) for 'DROP TABLE IF EXISTS public.r59_parents', 'CREATE TABLE public.r59_parents (id INT PRIMARY KEY, org TEXT NOT NULL)',
    q{INSERT INTO public.r59_parents VALUES (2, 't1')} };
my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
my $connect = sub {
    my ($path) = @_;
    my ($user, $password) = split /:/, $url->userinfo // '', 2;
    my $db = $url->path->to_string =~ s{\A/}{}r;
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=" . $url->host . ';port=' . $url->port . ";options=-csearch_path=$path", $user, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
    $dbh->do('SET client_min_messages TO error');
    return $dbh;
};
my $relation = sub {
    my ($table, @fields) = @_;
    return {source_table => $table, primary_key => 'id', tenant_field => 'org', fields => \@fields,
        columns => {map { ($_ => {type => /\A(?:id|\w+_id)\z/ ? 'integer' : 'string'}) } @fields}, associations => {}};
};
my $domain = sub {
    my ($source, $target, $key) = @_;
    my ($child, @fields) = @$source;
    my $root = $relation->($child, @fields);
    my %domain = (schema_version => 1, name => "D$child", source => $root, schemas => {par => $relation->($target, 'id', 'org')}, joins => {});
    $root->{associations}{par} = {queryable => 'par', owner_key => $key, related_key => 'id', cardinality => 'one'};
    $domain{joins}{par} = {type => 'left'};
    $domain{writes} = {operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {id => {insertable => 1}, org => {insertable => 1}, $key => {insertable => 1, updatable => 1}, (grep({ $_ eq 'note' } @fields) ? (note => {updatable => 1, insertable => 1}) : ())},
        constraints => {foreign_keys => {$key => {source => 'input', references => {relation => $target, field => 'id', tenant_field => 'org'}}}}};
    return Selecto::Domain->parse(\%domain);
};
my $children = [qw(r59_children id org parent_id note)];
my $engine = sub {
    my ($path, $schemas, $source, $target, $key) = @_;
    my $adapter = Selecto->adapter(postgresql => (dbh => $connect->($path), ($schemas ? (schemas => $schemas) : ())));
    return Selecto::Engine->new(domain => $domain->($source // $children, $target // 'r59_parents', $key // 'parent_id'), adapter => $adapter)->with_scope(tenant => 't1');
};
my $insert = sub {
    my ($e, $parent) = @_;
    return eval {
        $e->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'r59_children',
            assignments => {id => 50, org => 't1', parent_id => $parent}))->affected_rows;
    };
};
my $reason = sub { my ($error) = @_; return blessed($error) ? ($error->details->{reason} // $error->code) : "$error" };
my $reset = sub { $admin->do('DELETE FROM r59_app.r59_children WHERE id = 50') };
my $crossed = sub { ($admin->selectrow_array('SELECT count(*) FROM r59_app.r59_children c JOIN r59_app.r59_parents p ON p.id = c.parent_id WHERE c.org <> p.org'))[0] };

subtest 'nothing declared: the target resolves in the root schema' => sub {
    $plant->();
    my $e = $engine->('r59_app,public');
    is($insert->($e, 1), 1, 'the real parent is found beside the root') or diag $reason->($@);
    $reset->();
    ok(!defined($insert->($e, 2)), "another tenant's parent is not admitted");
    is($crossed->(), 0, 'nothing crossed');
    $reset->();
    # The namesake is ahead of the root's schema on the path.
    $e = $engine->('public,r59_app');
    ok(!defined($insert->($e, 2)), 'the namesake first on the path does not satisfy the guard');
    is($reason->($@), 'relation_ambiguous', 'and it refuses, typed');
    is($crossed->(), 0, 'nothing crossed');
    ok(!eval { $e->all($e->query->select('id', 'par.org')); 1 }, 'an association join refuses the same way');
    is($reason->($@), 'relation_ambiguous', 'typed');
    $admin->do('DROP TABLE public.r59_parents');
    $e = $engine->('public,r59_app');
    is($insert->($e, 1), 1, 'with no namesake the path order does not matter') or diag $reason->($@);
    $reset->();
};

subtest 'nothing declared: a target outside the root schema refuses' => sub {
    # The parent only in public: where the root is not. The base found it.
    $plant->();
    $admin->do('ALTER TABLE r59_app.r59_parents RENAME TO r59_parents_real');
    my $e = $engine->('r59_app,public');
    ok(!defined($insert->($e, 2)), 'a guard target found only outside the root schema refuses');
    is($reason->($@), 'relation_unresolved', 'relation_unresolved');
    ok(!eval { $e->all($e->query->select('id', 'par.org')); 1 }, 'so does an association join');
    is($reason->($@), 'relation_unresolved', 'relation_unresolved');
    $admin->do('ALTER TABLE r59_app.r59_parents_real RENAME TO r59_parents');
    my @sites = ([qw(r59_sites id org region_id)], 'r59_regions', 'region_id');
    my $legit = $engine->('r59_app,r59_shared', undef, @sites);
    ok(!eval { $legit->all($legit->query->select('id', 'par.org')); 1 }, 'a real cross-schema join needs declaring');
    is($reason->($@), 'relation_unresolved', 'relation_unresolved');
    my $declared = $engine->('r59_app,r59_shared', ['r59_app', 'r59_shared'], @sites);
    is_deeply($declared->all($declared->query->select('id', 'par.org'))->{rows}, [[1, 't1']], 'declared, it reads');
};

subtest 'declared schemas' => sub {
    $plant->();
    $admin->do('CREATE TABLE public.r59_children (LIKE r59_app.r59_children)');
    for my $path ('public', 'public,r59_app', 'r59_app,public') {
        my $e = $engine->($path, ['r59_app']);
        is($insert->($e, 1), 1, "$path: the root and the guard resolve in the declared schema") or diag $reason->($@);
        is(($admin->selectrow_array('SELECT count(*) FROM public.r59_children'))[0], 0, "$path: the namesake root is untouched");
        is(($admin->selectrow_array('SELECT count(*) FROM r59_app.r59_children WHERE id = 50'))[0], 1, "$path: the declared one is written");
        $reset->();
        ok(!defined($insert->($e, 2)), "$path: the guard is the declared parent's");
        is($crossed->(), 0, "$path: nothing crossed");
        $reset->();
        my $update = eval {
            $e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'r59_children', assignments => {note => 'seen'},
                predicate => $x->eq('id', 1), expected_count => undef))->affected_rows;
        };
        is($update, 1, "$path: an update's post-image checks read the declared relation") or diag $reason->($@);
        $admin->do(q{UPDATE r59_app.r59_children SET note = 'n'});
        is_deeply($e->all($e->query->select('id', 'par.org')->order_by('id'))->{rows}, [[1, 't1']], "$path: a read joins there too");
        my $s = $e->stream($e->query->select('id')->order_by('id'), bounded => 1, fetch_size => 1);
        is_deeply($s->next, [1], "$path: so does a bounded stream");
        $s->close;
    }
    $admin->do('DROP TABLE public.r59_children');
    my $e = $engine->('r59_app,public', ['r59_shared']);
    ok(!eval { $e->all($e->query->select('id')); 1 }, 'a relation in no declared schema refuses, though the reset path has it');
    is($reason->($@), 'relation_unresolved', 'relation_unresolved');
    for my $bad ('r59_app', [undef], ['']) {
        ok(!eval { Selecto->adapter(postgresql => (dbh => $admin, schemas => $bad)); 1 }, 'schemas must be a list of names');
        is(blessed($@) && $@->code, 'invalid_adapter', 'invalid_adapter');
    }
};

done_testing;
