use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Write ();
use Selecto::Expression ();

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
    ok(!$adapter->supports('returning'), $adapter->name . ' does not claim native RETURNING');
    ok($adapter->write_capabilities->{returning}, $adapter->name . ' emulates RETURNING by re-read');
    ok($adapter->write_capabilities->{upsert}, $adapter->name . ' advertises proved upserts');
    ok(!$adapter->supports('cte'), $adapter->name . ' refuses version-gated features without a server version');

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
    is($preview->{sql}, 'INSERT INTO `items` (`external_id`, `name`) VALUES (?, ?)',
        $adapter->name . ' previews an upsert by its INSERT branch, never ON DUPLICATE KEY UPDATE');
    my $scoped = $command->with_scope_predicate(Selecto::Expression->eq('tenant_id', 7));
    eval { $adapter->preview_write($scoped) };
    is($@->code, 'unsupported_scope_predicate', $adapter->name . ' refuses a scoped upsert');
    is_deeply($dbh->prepared, [], $adapter->name . ' refuses before database preparation');
}

done_testing;
