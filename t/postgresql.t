use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();

my $dbh = TestSelecto::DBH->new({
    rows => [[1, '10.500', 't'], [2, undef, 'f']],
    types => ['int4', 'numeric', 'bool'],
});
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $statement = Selecto::Statement->new(
    sql => 'SELECT id, score, active FROM people',
    params => [],
    columns => ['id', 'score', 'active'],
    adapter_name => 'postgresql',
);
is_deeply($adapter->execute_query($statement), {
    columns => ['id', 'score', 'active'],
    rows => [[1, '10.5', 1], [2, undef, 0]],
}, 'DBI rows are normalized by PostgreSQL type');

is($adapter->quote_identifier(q{odd`"name]}), q{"odd`""name]"}, 'identifier quoting doubles embedded quotes');
is($adapter->placeholder(2), '$2', 'PostgreSQL placeholder numbering is explicit');
is($adapter->normalize_type('timestamptz'), 'utc_datetime', 'adapter type normalization is portable');
ok($adapter->supports('transactions'), 'transactions are declared supported');
ok($adapter->supports('cte'), 'implemented CTE capability is declared supported');
ok($adapter->supports('recursive_cte'), 'implemented recursive CTE capability is declared supported');
ok($adapter->supports('window_functions'), 'implemented window capability is declared supported');
ok($adapter->supports('set_operations'), 'implemented set-operation capability is declared supported');
ok($adapter->supports('text_search'), 'implemented full-text capability is declared supported');
ok($adapter->supports('lateral_join'), 'implemented lateral capability is declared supported');
ok($adapter->supports('json_rowset'), 'implemented JSON-rowset capability is declared supported');
ok($adapter->supports('stream'), 'implemented streaming capability is declared supported');
isa_ok($adapter, 'Selecto::Adapter', 'PostgreSQL implements the database-neutral adapter contract');
is($statement->adapter_name, 'postgresql', 'generic statement records its compiling adapter');

done_testing;
