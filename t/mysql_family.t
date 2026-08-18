use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Write ();

my $dbh = TestSelecto::DBH->new;
my $mysql = Selecto->adapter(mysql => (dbh => $dbh));
my $mariadb = Selecto->adapter(mariadb => (dbh => $dbh));

is($mysql->name, 'mysql', 'MySQL has its own adapter identity');
is($mysql->dialect, 'Selecto::MySQL', 'MySQL reports its concrete dialect');
is($mariadb->name, 'mariadb', 'MariaDB has its own adapter identity');
is($mariadb->dialect, 'Selecto::MariaDB', 'MariaDB reports its concrete dialect');

for my $adapter ($mysql, $mariadb) {
    is($adapter->placeholder(2), '?', $adapter->name . ' uses DBI placeholders');
    is($adapter->quote_identifier(q{odd`"name]}), q{`odd``"name]`}, $adapter->name . ' escapes backticks');
    is($adapter->normalize_type('datetime'), 'naive_datetime', $adapter->name . ' normalizes datetime');
    ok($adapter->supports('transactions'), $adapter->name . ' declares transactions');
    ok(!$adapter->supports('returning'), $adapter->name . ' does not claim RETURNING');

    my $command = Selecto::Write::Command->new(
        operation => 'upsert',
        relation => 'items',
        assignments => { external_id => 'one', name => 'updated' },
        metadata => {
            conflict_target => ['external_id'],
            upsert_update_fields => ['name'],
        },
    );
    my $preview = $adapter->preview_write($command);
    like($preview->{sql}, qr/ON DUPLICATE KEY UPDATE `name` = VALUES\(`name`\)/, $adapter->name . ' uses native upsert syntax');
    is_deeply($preview->{params}, ['one', 'updated'], $adapter->name . ' keeps upsert values bound');
    is($adapter->_logical_affected_rows('upsert', 2), 1, $adapter->name . ' normalizes changed upsert rows');
}

done_testing;
