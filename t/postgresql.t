use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;

my $dbh = TestSelecto::DBH->new({
    rows => [[1, '10.500', 't'], [2, undef, 'f']],
    types => ['int4', 'numeric', 'bool'],
});
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $statement = Selecto::PostgreSQL::Statement->new(
    sql => 'SELECT id, score, active FROM people',
    params => [],
    columns => ['id', 'score', 'active'],
);
is_deeply($adapter->execute_query($statement), {
    columns => ['id', 'score', 'active'],
    rows => [[1, '10.5', 1], [2, undef, 0]],
}, 'DBI rows are normalized by PostgreSQL type');

is($adapter->quote_identifier(q{odd`"name]}), q{"odd`""name]"}, 'identifier quoting doubles embedded quotes');
is($adapter->placeholder(2), '$2', 'PostgreSQL placeholder numbering is explicit');
is($adapter->normalize_type('timestamptz'), 'utc_datetime', 'adapter type normalization is portable');
ok($adapter->supports('transactions'), 'transactions are declared supported');
ok(!$adapter->supports('cte'), 'deferred capability is declared unsupported');

done_testing;

