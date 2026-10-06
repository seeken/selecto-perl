use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Expression;

# A filter AST decoded from JSON carries JSON::PP booleans; they are the
# literals 1 and 0, as domain defaults and query-library parameters read them.
my $decoded = JSON::PP->new->decode(
    '["and",["eq","active",true],["ne","archived",false],["in","flag",[true,false]]]');
my $expression = Selecto::Expression->from_filter_ast($decoded);
my ($eq, $ne, $in) = @{$expression->arguments->[0]};
is $eq->kind, 'eq', 'eq over a JSON boolean is accepted';
is $eq->arguments->[1]->arguments->[0], 1, 'JSON true is the literal 1';
ok !ref($eq->arguments->[1]->arguments->[0]), 'the literal is a plain scalar';
is $ne->arguments->[1]->arguments->[0], 0, 'JSON false is the literal 0';
is_deeply $in->arguments->[1], [1, 0], 'in members read JSON booleans as 1 and 0';

for my $bad ([], {}, \'x', bless({}, 'Other::Object')) {
    ok !eval { Selecto::Expression->from_filter_ast(['eq', 'active', $bad]); 1 },
        'other references are still refused as comparison values';
    ok !eval { Selecto::Expression->from_filter_ast(['in', 'active', [$bad]]); 1 },
        'other references are still refused as in members';
}

SKIP: {
    skip 'DBD::SQLite is not installed', 1 unless eval { require DBI; require DBD::SQLite; 1 };
    require Selecto;
    require Selecto::Domain;
    require Selecto::Engine;
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE flags (id INTEGER PRIMARY KEY, active INTEGER)');
    $dbh->do('INSERT INTO flags VALUES (1, 1), (2, 0), (3, 1)');
    my $domain = Selecto::Domain->parse({
        schema_version => 1, name => 'Flags',
        source => {source_table => 'flags', primary_key => 'id', fields => [qw(active id)],
            columns => {id => {type => 'integer'}, active => {type => 'boolean'}}, associations => {}},
        schemas => {}, joins => {},
    });
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my $query = $engine->query->select('id')->order_by('id')
        ->where(Selecto::Expression->from_filter_ast(JSON::PP->new->decode('["eq","active",true]')));
    is_deeply [map { $_->[0] } @{$engine->all($query)->{rows}}], [1, 3], 'a JSON boolean filter executes';
}

done_testing;
