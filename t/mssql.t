use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Write ();

my $adapter = Selecto->adapter(mssql => (dbh => TestSelecto::DBH->new));
is($adapter->name, 'mssql', 'SQL Server has its own adapter identity');
is($adapter->dialect, 'Selecto::MSSQL', 'SQL Server reports its concrete dialect');
is($adapter->placeholder(1), '?', 'SQL Server uses native DBI positional parameters');
is($adapter->quote_identifier(q{odd`"name]}), q{[odd`"name]]]}, 'SQL Server escapes closing brackets');
is($adapter->normalize_type('numeric'), 'decimal', 'SQL Server normalizes numeric');
ok($adapter->supports('transactions'), 'SQL Server declares transactions');
ok(!$adapter->supports('returning'), 'SQL Server does not claim portable RETURNING');

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'items', fields => { id => 'integer', name => 'string' },
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $query = $engine->query->select('id', 'name')->order_by('id')->limit(10)->offset(5);
my $statement = $engine->compile($query);
like($statement->sql, qr/ORDER BY \[s0\]\.\[id\] ASC OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY\z/, 'SQL Server uses ordered OFFSET/FETCH');

my $unordered = $engine->query->select('id')->limit(1);
my $ok = eval { $engine->compile($unordered); 1 };
ok(!$ok, 'SQL Server pagination without an order fails closed');
is($@->code, 'invalid_query', 'unordered pagination returns a portable error');

my $command = Selecto::Write::Command->new(
    operation => 'upsert', relation => 'items',
    assignments => { external_id => 'one', id => 1, name => 'updated' },
    metadata => {
        conflict_target => ['external_id'],
        upsert_update_fields => ['name'],
    },
);
my $preview = $adapter->preview_write($command);
like($preview->{sql}, qr/\AMERGE INTO \[items\] WITH \(HOLDLOCK\)/, 'SQL Server uses guarded native MERGE');
like($preview->{sql}, qr/USING \(VALUES \(\?, \?, \?\)\) AS source \(\[external_id\], \[id\], \[name\]\)/, 'MERGE values remain bound');
like($preview->{sql}, qr/target\.\[external_id\] = source\.\[external_id\]/, 'MERGE uses the declared conflict target');
is_deeply($preview->{params}, ['one', 1, 'updated'], 'MERGE parameters follow deterministic field order');
is($adapter->_logical_affected_rows('upsert', 1), 1, 'SQL Server normalizes logical upsert rows');

is($adapter->_decode('1234567890123456789012345678.90', DBI::SQL_NUMERIC()), '1234567890123456789012345678.9', 'SQL Server preserves an exact high-precision decimal string');
is($adapter->_decode('2024-02-01 09:15:00.0000000', DBI::SQL_TYPE_TIMESTAMP()), '2024-02-01T09:15:00', 'SQL Server normalizes datetime2 values');

done_testing;
