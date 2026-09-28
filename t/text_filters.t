use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::PostgreSQL;
use Selecto::DuckDB;
use Selecto::API::EngineHandler;
{
    package TextFilters::PostgreSQL;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;
    sub execute_query ($self, $statement) {
        $self->{last} = $statement;
        return {columns => $statement->columns, rows => []};
    }
    package TextFilters::DuckDB;
    use Mojo::Base 'Selecto::DuckDB', -signatures;
    sub execute_query ($self, $statement) {
        return TextFilters::PostgreSQL::execute_query($self, $statement);
    }
}

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Text filters',
    source => {source_table => 'records', primary_key => 'id',
        fields => [qw(id name private_name)],
        columns => {id => {type => 'integer'}, name => {type => 'string'},
            private_name => {type => 'string', internal => 1}}, associations => {}},
    schemas => {}, joins => {},
});
my $handler = Selecto::API::EngineHandler->new;
for my $adapter_class (qw(TextFilters::PostgreSQL TextFilters::DuckDB)) {
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => $adapter_class->new(dbh => bless({}, 'TextFilters::DBH')));
    for my $op (qw(starts_with starts_with_ci text_contains text_contains_ci ends_with ends_with_ci)) {
        my $expression = Selecto::Expression->from_filter_ast([$op, 'name', 'MiX%_!']);
        my $sql = $engine->compile($engine->query->select('id')->where($expression));
        my $expected = $op =~ /^text_contains/ ? '%MiX!%!_!!%'
            : $op =~ /^ends_with/ ? '%MiX!%!_!!' : 'MiX!%!_!!%';
        is_deeply $sql->params, [$expected], "$adapter_class $op escapes wildcard and escape characters";
        like $sql->sql, qr/LIKE .* ESCAPE '!'/, "$op declares its portable escape character";
        is scalar(() = $sql->sql =~ /LOWER\(/g), ($op =~ /_ci$/ ? 2 : 0),
            "$op folds both operands only for an explicit case-insensitive search";
        my $api = $handler->query($engine, {
            select => ['id'], filters => [{field => 'name', op => $op, value => 'MiX%_!'}],
        });
        my $api_sql = $engine->adapter->{last};
        is $api_sql->params->[0], $expected, "API accepts $op with the same literal semantics";
    }
    for my $field (qw(id private_name)) {
        my $ok = eval { $handler->query($engine, {
            select => ['id'], filters => [{field => $field, op => 'text_contains_ci', value => 'x'}],
        }); 1 };
        ok !$ok, "API refuses text search on $field";
    }
    for my $bad (undef, [], {}) {
        my $ok = eval { Selecto::Expression->from_filter_ast(['ends_with_ci', 'name', $bad]); 1 };
        ok !$ok, 'non-literal text search is rejected';
    }
}
SKIP: {
    skip 'DBD::DuckDB is not installed', 6 unless eval { require DBD::DuckDB; require DBI; 1 };
    my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE records (id integer, name varchar)');
    $dbh->do(q{INSERT INTO records VALUES
        (1, 'MiXeD%_!tail'), (2, 'headMiXeD%_!'), (3, 'mixed%_!'), (4, 'MiXeDAX!tail'), (5, NULL)});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto::DuckDB->new(dbh => $dbh));
    for my $case (
        [starts_with => [3]], [starts_with_ci => [1, 3]],
        [text_contains => [3]], [text_contains_ci => [1, 2, 3]],
        [ends_with => [3]], [ends_with_ci => [2, 3]],
    ) {
        my $result = $handler->query($engine, {select => ['id'],
            order_by => [{field => 'id', direction => 'asc'}],
            filters => [{field => 'name', op => $case->[0], value => 'mixed%_!'}]});
        is_deeply [map { $_->[0] } @{$result->{rows}}], $case->[1],
            "DuckDB executes $case->[0] with literal wildcards and the intended case matching";
    }
    $dbh->disconnect;
}
done_testing;
