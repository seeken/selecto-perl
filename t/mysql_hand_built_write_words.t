use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Statement;

# In the host's transaction nothing stops a hand-built write, so its words decide
# (R73): the main verb past a WITH list. This stops honest mistakes, not evasion.
my $adapter = Selecto->adapter(mysql => (dbh => TestSelecto::DBH->new));
my %cases = (
    'WITH x AS (SELECT 1) UPDATE vt SET a = 1' => 1,
    'WITH x AS (SELECT 1) DELETE FROM vt' => 1,
    'with x as (select 1) update vt set a = 1' => 1,
    'WITH x AS (SELECT 1), y AS (SELECT 2) UPDATE vt SET a = 1' => 1,
    'WITH x AS (SELECT 1) SELECT * FROM vt' => 0,
    'WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r' => 0,
    'WITH x AS (SELECT `update` FROM vt) SELECT * FROM x' => 0,
);
for my $sql (sort keys %cases) {
    my $statement = Selecto::Statement->new(sql => $sql, adapter_name => 'mysql');
    is !!$adapter->_hand_built_may_write($sql, $statement), !!$cases{$sql}, ($cases{$sql} ? 'refuses: ' : 'runs: ') . $sql;
}

done_testing;
