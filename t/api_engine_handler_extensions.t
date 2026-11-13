use 5.034;
use strict;
use warnings;
use feature qw(signatures);
no warnings qw(experimental::signatures);

use Test::More;
use DBI ();
use Selecto ();
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# The trusted filter_groups and aggregate_selections extensions: off for the
# canonical API (requests using them are refused exactly as before), on for
# hosts such as Selecto::API::Spa.

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', name => 'Handler extensions',
    source => {
        source_table => 'kites', primary_key => 'id',
        fields => [qw(id label maker_id span_cm price notes vault_code)],
        columns => {
            id => {type => 'integer'}, label => {type => 'string'}, maker_id => {type => 'integer'},
            span_cm => {type => 'integer'}, price => {type => 'decimal'}, notes => {type => 'string'},
            vault_code => {type => 'string', internal => 1},
        },
        associations => {
            maker => {queryable => 'makers', owner_key => 'maker_id', related_key => 'id', cardinality => 'one'},
            tails => {queryable => 'tails', owner_key => 'id', related_key => 'kite_id', cardinality => 'many'},
        },
    },
    schemas => {
        makers => {source_table => 'makers', primary_key => 'id', fields => [qw(id title)],
            columns => {id => {type => 'integer'}, title => {type => 'string'}}, associations => {}},
        tails => {source_table => 'tails', primary_key => 'id', fields => [qw(id kite_id length_cm)],
            columns => {id => {type => 'integer'}, kite_id => {type => 'integer'}, length_cm => {type => 'integer'}},
            associations => {}},
    },
    joins => {maker => {type => 'left'}},
});

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do($_) for (
    'CREATE TABLE makers (id INTEGER PRIMARY KEY, title TEXT NOT NULL)',
    'CREATE TABLE kites (id INTEGER PRIMARY KEY, label TEXT NOT NULL, maker_id INTEGER, span_cm INTEGER, price NUMERIC, notes TEXT, vault_code TEXT)',
    'CREATE TABLE tails (id INTEGER PRIMARY KEY, kite_id INTEGER, length_cm INTEGER)',
    "INSERT INTO makers VALUES (1, 'Gull Works'), (2, 'Updraft')",
    "INSERT INTO kites VALUES (1, 'Box', 1, 90, 12.5, NULL, 'a'), (2, 'Delta', 1, 140, 30, 'fast', 'b'),"
        . " (3, 'Sled', 2, 70, 8, NULL, 'c'), (4, 'Diamond', 2, 110, 15, 'classic', 'd'), (5, 'Parafoil', NULL, 200, 55, NULL, 'e')",
    'INSERT INTO tails VALUES (1, 1, 300), (2, 1, 250), (3, 2, 400)',
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
my $canonical = Selecto::API::EngineHandler->new;
my $extended = Selecto::API::EngineHandler->new(filter_groups => 1, aggregate_selections => 1, max_filters => 4);

sub code_of ($handler, $body) {
    my $ok = eval { $handler->query($engine, $body); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : "died: $@";
}
sub ids ($result) { return [map { $_->[0] } @{$result->{rows}}] }

subtest 'the canonical handler still refuses groups and aggregate entries' => sub {
    is code_of($canonical, {select => ['id'], filters => [{any => [{field => 'id', op => 'eq', value => 1}]}]}),
        'invalid_api_query', 'a filter group is an unsupported filter property';
    my $ok = eval { $canonical->query($engine, {select => ['id'], filters => [{any => []}]}); 1 };
    like $@->message, qr/unsupported properties/, 'with the same message as before';
    is code_of($canonical, {select => [{aggregate => 'count', alias => 'n'}]}),
        'invalid_api_query', 'an aggregate select entry is refused';
    is_deeply [sort @{($@ && $@->details->{properties}) // []}], ['aggregate'],
        'naming the unsupported properties';
    eval { Selecto::API::EngineHandler->new(filter_groups => 2) };
    is $@->code, 'invalid_api_handler', 'the extension flags are trusted booleans';
};

subtest 'filter groups' => sub {
    my $result = $extended->query($engine, {select => ['id'], order_by => [{field => 'id'}],
        filters => [{any => [
            {field => 'span_cm', op => 'gte', value => 140},
            {all => [{field => 'maker.title', op => 'eq', value => 'Updraft'}, {field => 'price', op => 'lt', value => 10}]},
        ]}]});
    is_deeply ids($result), [2, 3, 5], 'any/all groups nest';
    is_deeply ids($extended->query($engine, {select => ['id'], order_by => [{field => 'id'}],
        filters => [{all => [{field => 'notes', op => 'is_null'}]}, {field => 'id', op => 'not_in', value => [5]}]})),
        [1, 3], 'a one-member group is its member; top-level filters are still ANDed';
    is code_of($extended, {select => ['id'], filters => [{any => []}]}), 'invalid_api_query', 'an empty group is refused';
    is code_of($extended, {select => ['id'], filters => [{any => [{field => 'id', op => 'eq', value => 1}], all => []}]}),
        'invalid_api_query', 'a group has exactly one conjunction';
    is code_of($extended, {select => ['id'], filters => [{any => [{field => 'vault_code', op => 'eq', value => 'a'}]}]}),
        'hidden_field', 'members are governed like top-level filters';
    is code_of($extended, {select => ['id'], filters => [{any => [map { +{field => 'id', op => 'eq', value => $_} } 1 .. 5]}]}),
        'invalid_api_query', 'every leaf counts against max_filters';
    my $deep = {field => 'id', op => 'eq', value => 1};
    $deep = {all => [$deep]} for 1 .. 4;
    is code_of($extended, {select => ['id'], filters => [$deep]}), 'ok', 'four nested groups are within max_filter_depth';
    is code_of($extended, {select => ['id'], filters => [{any => [$deep]}]}), 'invalid_api_query', 'a fifth is refused';
};

subtest 'aggregate selections' => sub {
    my $result = $extended->query($engine, {
        select => ['maker.title', {aggregate => 'count', alias => 'kites'}, {aggregate => 'sum', field => 'span_cm', alias => 'span'},
            {aggregate => 'max', field => 'label', alias => 'last_label'}, {aggregate => 'count_distinct', field => 'notes', alias => 'noted'}],
        group_by => ['maker.title'], order_by => [{field => 'maker.title'}],
    });
    is_deeply $result->{rows}, [[undef, 1, 200, 'Parafoil', 0], ['Gull Works', 2, 230, 'Delta', 1], ['Updraft', 2, 180, 'Sled', 1]],
        'grouped aggregates';
    is_deeply $extended->query($engine, {select => [{aggregate => 'count', alias => 'n'}, {aggregate => 'avg', field => 'span_cm', alias => 'mean'}],
        filters => [{field => 'maker_id', op => 'eq', value => 1}]})->{rows}, [[2, 115]], 'a summary row without group_by';
    is code_of($extended, {select => ['label', {aggregate => 'count', alias => 'n'}]}), 'invalid_api_query',
        'without group_by every selection is an aggregate';
    is code_of($extended, {select => [{aggregate => 'count', alias => 'n'}], order_by => [{field => 'id'}]}), 'invalid_api_query',
        'and nothing is ordered';
    is code_of($extended, {select => [{aggregate => 'sum', field => 'label', alias => 's'}]}), 'invalid_api_query', 'sum needs a number';
    is code_of($extended, {select => [{aggregate => 'median', field => 'span_cm', alias => 's'}]}), 'invalid_api_query', 'unknown function';
    is code_of($extended, {select => [{aggregate => 'max', field => 'span_cm'}]}), 'invalid_api_query', 'the alias is required';
    is code_of($extended, {select => [{aggregate => 'max', alias => 'm'}]}), 'invalid_api_query', 'only count omits the field';
    is code_of($extended, {select => [{aggregate => 'max', field => 'vault_code', alias => 'm'}]}), 'hidden_field', 'hidden fields stay hidden';
    is code_of($extended, {select => [{aggregate => 'sum', field => 'tails.length_cm', alias => 'm'}]}), 'invalid_api_query',
        'a to-many path is refused';
    is code_of($extended, {select => [{aggregate => 'count', alias => 'id'}, 'id'], group_by => ['id']}), 'invalid_api_query',
        'aliases still produce unique columns';
};

done_testing;
