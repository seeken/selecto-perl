use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto ();
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();

# Public API writes are confined to each operation's authored grants. An
# operation without expected_cardinality permits exactly one row, even with
# bulk, and one without returning returns no fields. Both refusals happen at
# request admission, before any statement reaches the database.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; require Selecto::Certification; 1 };
}

sub domain_for {
    my ($table, $operations) = @_;
    return Selecto::Domain->parse({
        schema_version => 1, domain_version => '1.0.0',
        domain_fingerprint => 'sha256:api-write-grants', name => 'Records',
        source => {source_table => $table, primary_key => 'id', fields => [qw(id name tenant_id)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}, tenant_id => {type => 'integer'}},
            associations => {}},
        schemas => {}, joins => {},
        writes => {operations => $operations,
            fields => {id => {insertable => 1}, name => {insertable => 1, updatable => 1},
                tenant_id => {insertable => 1}}},
    });
}

sub refusal {
    my ($code) = @_;
    my $error = eval { $code->(); undef } // $@;
    return ref($error) && $error->can('code') ? $error->code : "$error";
}

my $handler = Selecto::API::EngineHandler->new;
my $bulk_update = {operation => 'update', assignments => {name => 'bulk'},
    filters => [{field => 'id', op => 'gte', value => 1}], expected_count => 2};
my $bulk_delete = {operation => 'delete',
    filters => [{field => 'id', op => 'in', value => [1, 2, 3]}], expected_count => 2};

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "API write grants on $name" => sub {
        my $dbh = $connect->();
        my $table = "selecto_api_write_grants_${$}_" . int(rand(1_000_000));
        $dbh->do("CREATE TABLE $table (id integer primary key, name varchar(40) not null, tenant_id integer)");
        my $reset = sub {
            $dbh->do("DELETE FROM $table");
            $dbh->do("INSERT INTO $table VALUES (1, 'a', 7), (2, 'b', 8), (3, 'c', 7)");
        };
        my $rows = sub { $dbh->selectall_arrayref("SELECT id, name, tenant_id FROM $table ORDER BY id") };
        my $baseline = [[1, 'a', 7], [2, 'b', 8], [3, 'c', 7]];
        my $statements = 0;
        my $counting = {map { my $method = $_; ($method => sub { $statements++; return }) }
            qw(prepare prepare_cached do)};
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $engine_for = sub {
            my ($operations) = @_;
            return Selecto::Engine->new(adapter => $adapter,
                domain => domain_for($table, $operations)->with_required_predicate(Selecto::Expression->eq('tenant_id', 7)));
        };
        my $refused_before_sql = sub {
            my ($engine, $body, $label) = @_;
            $reset->();
            $statements = 0;
            local $dbh->{Callbacks} = $counting;
            is refusal(sub { $handler->write($engine, $body) }), 'invalid_api_write', "$label is refused";
            is $statements, 0, "$label: no statement reached the database";
            is_deeply $rows->(), $baseline, "$label: no row changed";
        };

        # Bulk-enabled operations without authored grants.
        my $ungranted = $engine_for->({
            insert => {enabled => 1},
            update => {enabled => 1, bulk => 1},
            delete => {enabled => 1, bulk => 1},
        });
        $refused_before_sql->($ungranted, $bulk_update, 'bulk alone: update count 2');
        $refused_before_sql->($ungranted, $bulk_delete, 'bulk alone: delete count 2');
        $refused_before_sql->($ungranted, {operation => 'update', assignments => {name => 'one'},
            filters => [{field => 'id', op => 'eq', value => 1}], returning => ['id']},
            'ungranted update returning');
        $refused_before_sql->($ungranted, {operation => 'insert',
            assignments => {id => 4, name => 'new', tenant_id => 7}, returning => ['id']},
            'ungranted insert returning');
        $reset->();
        $statements = 0;
        {
            local $dbh->{Callbacks} = $counting;
            is_deeply $handler->write($ungranted, {operation => 'update', assignments => {name => 'one'},
                filters => [{field => 'id', op => 'eq', value => 1}], returning => []}),
                {operation => 'update', affected_rows => 1}, 'the strict default still admits one row without returning';
        }
        ok $statements > 0, 'the statement counter observes an admitted write';
        is_deeply $rows->(), [[1, 'one', 7], [2, 'b', 8], [3, 'c', 7]], 'the single-row write applied';

        # A cardinality grant does not replace the bulk prerequisite, and a
        # bounded grant refuses counts outside it.
        my $bounded = $engine_for->({
            update => {enabled => 1, expected_cardinality => 'many'},
            delete => {enabled => 1, bulk => 1, expected_cardinality => ['at_most', 1]},
        });
        $refused_before_sql->($bounded, $bulk_update, 'cardinality grant without bulk');
        $refused_before_sql->($bounded, $bulk_delete, 'count above an at_most grant');

        # Authored grants admit bulk counts and returning within their bounds.
        my $granted = $engine_for->({
            insert => {enabled => 1, returning => ['id', 'name']},
            update => {enabled => 1, bulk => 1, expected_cardinality => 'many', returning => ['id', 'name']},
            delete => {enabled => 1, bulk => 1, expected_cardinality => ['between', 1, 2], returning => 'all'},
        });
        $refused_before_sql->($granted, {%$bulk_update, returning => ['tenant_id']},
            'returning outside the field grant');
        $refused_before_sql->($granted, {%$bulk_delete, filters => [{field => 'id', op => 'gte', value => 1}],
            expected_count => 3}, 'count above a between grant');
        $reset->();
        is_deeply $handler->write($granted, {%$bulk_update, returning => ['name']}),
            {operation => 'update', affected_rows => 2, values => {name => 'bulk'}},
            'a granted bulk update returns granted fields';
        is_deeply $rows->(), [[1, 'bulk', 7], [2, 'b', 8], [3, 'bulk', 7]],
            'the granted bulk update stays inside the required predicate';
        is_deeply $handler->write($granted, {operation => 'insert',
            assignments => {id => 4, name => 'new', tenant_id => 7}, returning => ['id']}),
            {operation => 'insert', affected_rows => 1, values => {id => 4}}, 'granted insert returning';
        my $deleted = $handler->write($granted, {%$bulk_delete, filters => [{field => 'id', op => 'in', value => [1, 2, 3]}],
            returning => ['tenant_id']});
        is $deleted->{affected_rows}, 2, 'a granted bulk delete applies';
        is_deeply $deleted->{values}, {tenant_id => 7}, 'an all returning grant admits any public field';
        is_deeply $rows->(), [[2, 'b', 8], [4, 'new', 7]], 'the granted delete removed only scoped rows';
        is refusal(sub { $handler->write($granted, {%$bulk_update, expected_count => 2}) }), 'cardinality_mismatch',
            'a granted count is still enforced against the scoped match';
        is_deeply $rows->(), [[2, 'b', 8], [4, 'new', 7]], 'the mismatched write rolled back';
        $dbh->do("DROP TABLE $table");
        $dbh->disconnect;
    };
}

done_testing;
