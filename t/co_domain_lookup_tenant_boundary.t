use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::CoDomain ();
use Selecto::Engine ();
use Selecto::Expression ();

# Lesson 40: a co-domain lookup into a tenant-scoped target runs under the
# target engine's read boundary: the engine tenant, or the required tenant
# predicate, is ANDed into the lookup query, and a host predicate or a named
# segment on the lookup is intersected with it, never replacing or widening
# it. A search term matching both tenants' rows returns only tenant 7's, and
# a target whose tenant cannot be bound is refused with missing_tenant_scope.
# This pins existing behaviour.

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

my $x = 'Selecto::Expression';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub contract {
    my ($table, $sqlite, %o) = @_;
    my $search = {fields => ['title'], mode => 'prefix', configuration => 'simple'};
    my $result = {value_field => 'id', label_field => 'title'};
    return {schema_version => 1, name => 'Items', source => {
            source_table => $table, primary_key => 'id', fields => [qw(id title tenant_id)],
            columns => {id => {type => 'integer'}, title => {type => 'string'}, tenant_id => {type => 'integer'}},
            associations => {}, tenant_field => 'tenant_id',
            ($sqlite ? (fts5_index => {table => "${table}_search", key => 'id'}) : ())},
        schemas => {}, joins => {},
        query_library => {projections => {lookup => {fields => [qw(id title)]}},
            segments => {tenant8 => {filters => [['eq', 'tenant_id', 8]]}, both => {filters => [['in', 'tenant_id', [7, 8]]]}}},
        co_domains => {
            items => {domain => 'items', projection => 'lookup', search => $search, result => $result},
            tenant8 => {domain => 'items', projection => 'lookup', segments => ['tenant8'], search => $search, result => $result},
            both => {domain => 'items', projection => 'lookup', segments => ['both'], search => $search, result => $result},
        },
        ($o{required} ? (required_filters => $o{required}) : ())};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "co-domain lookups keep the target tenant boundary on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter(($name eq 'sqlite' ? 'sqlite' : 'postgresql') => (dbh => $dbh));
        plan skip_all => 'connected SQLite lacks FTS5' unless $adapter->supports('text_search');
        my $table = 'selecto_l40_items_' . $$ . '_' . int(rand(1_000_000));
        my $sqlite = $name eq 'sqlite';
        $dbh->do("CREATE TABLE $table (id integer primary key, title text, tenant_id integer)");
        $dbh->do("CREATE VIRTUAL TABLE ${table}_search USING fts5(title, content='$table', content_rowid='id')") if $sqlite;
        $dbh->do("INSERT INTO $table VALUES (1, 'Oak seven', 7), (2, 'Oak eight', 8), (3, 'Oak nine', 9)");
        $dbh->do("INSERT INTO ${table}_search(${table}_search) VALUES('rebuild')") if $sqlite;
        my $parse = sub { Selecto::Domain->parse(contract($table, $sqlite, @_)) };
        my $look = sub {
            my ($engine, %args) = @_;
            my $found = Selecto::CoDomain->lookup(source_domain => $engine->domain, engine => $engine,
                co_domain => 'items', query => 'oak', %args);
            return [sort map { $_->{value} } @{$found->{results}}];
        };

        my %roots = (
            'engine tenant' => sub { Selecto::Engine->new(domain => $parse->(), adapter => $adapter, scope => {tenant => 7}) },
            'required_filters only' => sub { Selecto::Engine->new(domain => $parse->(required => [['tenant_id', 7]]), adapter => $adapter) },
            'required predicate only' => sub {
                Selecto::Engine->new(domain => $parse->()->with_required_predicate($x->eq('tenant_id', 7)), adapter => $adapter) },
        );
        for my $boundary (sort keys %roots) {
            my $engine = $roots{$boundary}->();
            is_deeply($look->($engine), ['1'], "$boundary: a search matching every tenant returns only tenant 7");
            is_deeply($look->($engine, predicate => $x->eq('tenant_id', 8)), [],
                "$boundary: a host scope naming tenant 8 is intersected, not substituted");
            is_deeply($look->($engine, predicate => $x->in('tenant_id', [7, 8])), ['1'],
                "$boundary: a wider host scope cannot widen the boundary");
            is_deeply($look->($engine, predicate => $x->any($x->eq('tenant_id', 8), $x->gt('id', 0))), ['1'],
                "$boundary: a disjunctive host scope cannot widen the boundary");
            is_deeply($look->($engine, co_domain => 'tenant8'), [],
                "$boundary: a named segment naming tenant 8 is intersected");
            is_deeply($look->($engine, co_domain => 'both'), ['1'],
                "$boundary: a wider named segment cannot widen the boundary");
        }

        is(code_of(sub { $look->(Selecto::Engine->new(domain => $parse->(), adapter => $adapter)) }),
            'missing_tenant_scope', 'an unbounded tenant-scoped target is refused');
        is(code_of(sub { $look->(Selecto::Engine->new(domain => $parse->(required => [['id', 1]]), adapter => $adapter)) }),
            'missing_tenant_scope', 'a required predicate without a tenant condition is refused');

        $dbh->do("DROP TABLE ${table}_search") if $sqlite;
        $dbh->do("DROP TABLE $table");
    };
}

done_testing;
