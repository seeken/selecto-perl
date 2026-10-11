use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::API::EngineHandler ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Limits ();

# Lesson 42a: the engine tenant survives every domain rebuild. From a shared
# products root through a shared categories hop to tenant-scoped notes, a
# tenant 7 read never returns tenant 8's notes: by join, by multi-hop
# retarget (cat.notes, IN and EXISTS), by retarget to the shared middle hop,
# through the public query handler, after engine copies (with_scope,
# with_limits) and domain rebuilds (as_contract, with_required_predicate),
# and for a directly constructed domain rebuilt through as_contract.

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

sub relation {
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}

my $handler = Selecto::API::EngineHandler->new;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "the engine tenant survives rebuilds on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l42a_${_}_$suffix") } qw(products categories notes);
        $dbh->do("CREATE TABLE $t{products} (id integer primary key, name text, category_id integer)");
        $dbh->do("CREATE TABLE $t{categories} (id integer primary key, name text)");
        $dbh->do("CREATE TABLE $t{notes} (id integer primary key, category_id integer, tenant_id integer, body text)");
        $dbh->do("INSERT INTO $t{products} VALUES (1, 'Widget', 1)");
        $dbh->do("INSERT INTO $t{categories} VALUES (1, 'Tools')");
        $dbh->do("INSERT INTO $t{notes} VALUES (1, 1, 7, 'note 7'), (2, 1, 8, 'note 8')");
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Products',
            source => {%{relation($t{products}, id => 'integer', name => 'string', category_id => 'integer')},
                associations => {cat => {queryable => 'category', owner_key => 'category_id', related_key => 'id'}}},
            schemas => {
                category => {%{relation($t{categories}, id => 'integer', name => 'string')},
                    associations => {notes => {queryable => 'note', owner_key => 'id', related_key => 'category_id', cardinality => 'many'}}},
                note => {%{relation($t{notes}, id => 'integer', category_id => 'integer', tenant_id => 'integer', body => 'string')},
                    tenant_field => 'tenant_id'},
            },
            joins => {cat => {type => 'left', joins => {notes => {type => 'left'}}}}});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7});
        my $check = sub {
            my ($label, $e) = @_;
            is_deeply($e->all($e->query->select('id', 'cat.notes.body'))->{rows}, [[1, 'note 7']], "$label: two-hop join");
            for my $strategy (qw(in exists)) {
                is_deeply($e->all($e->query->retarget('cat.notes', strategy => $strategy)->select('id', 'body')->order_by('id'))->{rows},
                    [[1, 'note 7']], "$label: multi-hop retarget ($strategy)");
            }
            is_deeply($e->all($e->query->retarget('cat')->select('id', 'notes.body'))->{rows}, [[1, 'note 7']],
                "$label: retarget to the shared middle hop");
        };
        $check->('engine', $engine);
        is_deeply($handler->query($engine, {select => ['id', 'cat.notes.body']})->{rows}, [[1, 'note 7']], 'public query handler');
        $check->('with_scope copy', Selecto::Engine->new(domain => $domain, adapter => $adapter)->with_scope(tenant => 7));
        $check->('with_limits copy', $engine->with_limits(Selecto::Limits->new));
        $check->('as_contract rebuild', Selecto::Engine->new(domain => Selecto::Domain->parse($domain->as_contract),
            adapter => $adapter, scope => {tenant => 7}));
        $check->('with_required_predicate rebuild', Selecto::Engine->new(
            domain => $domain->with_required_predicate(Selecto::Expression->eq('name', 'Widget')), adapter => $adapter, scope => {tenant => 7}));

        my $direct = Selecto::Domain->new(name => 'Products', table => $t{products}, primary_key => 'id',
            fields => {id => 'integer', name => 'string', category_id => 'integer'},
            associations => {cat => {table => $t{categories}, fields => {id => 'integer', name => 'string'},
                owner_key => 'category_id', related_key => 'id',
                associations => {notes => {table => $t{notes},
                    fields => {id => 'integer', category_id => 'integer', tenant_id => 'integer', body => 'string'},
                    owner_key => 'id', related_key => 'category_id', cardinality => 'many', target_tenant_field => 'tenant_id'}}}});
        for my $case (['directly constructed', $direct], ['directly constructed, as_contract rebuild', Selecto::Domain->parse($direct->as_contract)]) {
            my ($label, $d) = @$case;
            my $e = Selecto::Engine->new(domain => $d, adapter => $adapter, scope => {tenant => 7});
            is_deeply($e->all($e->query->select('id', 'cat.notes.body'))->{rows}, [[1, 'note 7']], "$label: two-hop join");
        }

        $dbh->do("DROP TABLE $t{$_}") for qw(notes categories products);
    };
}

done_testing;
