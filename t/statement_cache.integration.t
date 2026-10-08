use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::PostgreSQL::StatementCache ();

# The opt-in statement cache against a real PostgreSQL: named statements on
# the server, the bound, re-preparation, transactions and tenants.

my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && length($url);
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBD::Pg; 1 };
my ($user, $password, $host, $port, $database) = $url =~ m{\Apostgres(?:ql)?://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/]*)(?::(\d+))?/([^?]+)}
    or plan skip_all => 'PostgreSQL test URL is invalid';
my $dsn = "dbi:Pg:dbname=$database" . (length($host) ? ";host=$host" : '') . (defined($port) ? ";port=$port" : '');
my $connect = sub { DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1}) };

my $dbh = $connect->();
$dbh->do('SET client_min_messages TO warning');
$dbh->do('CREATE TEMP TABLE statement_cache_items (id INTEGER PRIMARY KEY, site_id INTEGER NOT NULL, title TEXT NOT NULL)');
$dbh->do(q{INSERT INTO statement_cache_items VALUES (1, 7301, 'alpha'), (2, 7302, 'beta'), (3, 7301, 'gamma'), (4, 7302, 'delta')});

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Statement cache items',
    source => {source_table => 'statement_cache_items', primary_key => 'id', fields => [qw(id site_id title)],
        columns => {id => {type => 'integer'}, site_id => {type => 'integer'}, title => {type => 'string'}},
        associations => {}, tenant_field => 'site_id'},
    schemas => {}, joins => {},
});
my $engine = sub {
    my ($handle, %options) = @_;
    return Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $handle, %options)));
};
my $prepared = sub {
    my ($handle) = @_;
    return $handle->selectall_arrayref('SELECT name, statement FROM pg_prepared_statements ORDER BY name');
};
my $titles = sub { [map { $_->[0] } @{$_[0]->all($_[0]->query->select('title')->order_by('id'))->{rows}}] };

subtest 'off: no named statements' => sub {
    my $scoped = $engine->($dbh)->with_scope(tenant => 7301);
    $titles->($scoped) for 1 .. 3;
    is_deeply $prepared->($dbh), [], 'every call is unnamed';
};

subtest 'on: one named statement per SQL text' => sub {
    my $scoped = $engine->($dbh, statement_cache => 1)->with_scope(tenant => 7301);
    is_deeply $titles->($scoped), [qw(alpha gamma)], 'first call';
    is_deeply $titles->($scoped), [qw(alpha gamma)], 'second call';
    is_deeply $titles->($scoped), [qw(alpha gamma)], 'third call';
    my $sql = $scoped->compile($scoped->query->select('title')->order_by('id'))->sql;
    my $statements = $prepared->($dbh);
    is scalar(@$statements), 1, 'one named statement on the server';
    is $statements->[0][1], $sql, 'for exactly the compiled SQL';
    Selecto::PostgreSQL::StatementCache->forget($dbh);
    $dbh->do('DEALLOCATE ALL');
};

subtest 'tenants share one statement, never each other\'s rows' => sub {
    my $adapter_engine = $engine->($dbh, statement_cache => 1);
    my ($first, $second) = map { $adapter_engine->with_scope(tenant => $_) } 7301, 7302;
    for (1 .. 3) {
        is_deeply $titles->($first), [qw(alpha gamma)], 'tenant 7301 sees only its rows';
        is_deeply $titles->($second), [qw(beta delta)], 'tenant 7302 sees only its rows';
    }
    my $query = $first->query->select('title')->order_by('id');
    my ($one, $two) = map { $_->compile($query) } $first, $second;
    is $one->sql, $two->sql, 'both tenants compile the same SQL text';
    unlike $one->sql, qr/730[12]/, 'the tenant value is not in the SQL text';
    ok((grep { $_ eq 7301 } @{$one->params}) && (grep { $_ eq 7302 } @{$two->params}), 'it is a bound parameter');
    my $statements = $prepared->($dbh);
    is scalar(@$statements), 1, 'one cached statement serves both tenants';
    unlike join(' ', map { @$_ } @$statements), qr/730[12]/, 'no tenant value in a statement name or text';
    unlike join(' ', keys %{$dbh->{CachedKids}}), qr/730[12]/, 'or in a cache key';
    Selecto::PostgreSQL::StatementCache->forget($dbh);
    $dbh->do('DEALLOCATE ALL');
};

subtest 'bounded per connection' => sub {
    my $bounded = $engine->($dbh, statement_cache => 1, statement_cache_size => 2)->with_scope(tenant => 7301);
    for my $limit (1 .. 5) {
        $bounded->all($bounded->query->select('title')->order_by('id')->limit($limit)) for 1 .. 2;
    }
    is scalar(@{$prepared->($dbh)}), 2, 'at most two named statements after five shapes';
    is(Selecto::PostgreSQL::StatementCache->count($dbh), 2, 'two cached handles');
    Selecto::PostgreSQL::StatementCache->forget($dbh);
    $dbh->do('DEALLOCATE ALL');
};

subtest 'a lost statement (26000) is prepared again' => sub {
    my $scoped = $engine->($dbh, statement_cache => 1)->with_scope(tenant => 7302);
    $titles->($scoped) for 1 .. 2;
    $dbh->do('DEALLOCATE ALL');
    is_deeply $titles->($scoped), [qw(beta delta)], 'still answers after DEALLOCATE ALL';
    is scalar(@{$prepared->($dbh)}), 0, 'the replacement is unnamed until reused';
    $titles->($scoped);
    is scalar(@{$prepared->($dbh)}), 1, 'then named again';
    Selecto::PostgreSQL::StatementCache->forget($dbh);
    $dbh->do('DEALLOCATE ALL');
};

subtest 'a changed result type (0A000)' => sub {
    my $own = $connect->();
    $own->do('SET client_min_messages TO warning');
    $own->do('CREATE TABLE IF NOT EXISTS statement_cache_shape (id INTEGER PRIMARY KEY, site_id INTEGER NOT NULL, title TEXT NOT NULL)');
    $own->do('TRUNCATE statement_cache_shape');
    $own->do(q{INSERT INTO statement_cache_shape VALUES (1, 7301, 'alpha')});
    my $shape = Selecto::Domain->parse({
        schema_version => 1, name => 'Shape',
        source => {source_table => 'statement_cache_shape', primary_key => 'id', fields => [qw(id site_id title)],
            columns => {id => {type => 'integer'}, site_id => {type => 'integer'}, title => {type => 'string'}},
            associations => {}},
        schemas => {}, joins => {},
    });
    my $shaped = Selecto::Engine->new(domain => $shape, adapter => Selecto->adapter(postgresql => (dbh => $own, statement_cache => 1)));
    my $read = sub { $shaped->all($shaped->query->select('title')->where(Selecto::Expression->eq('site_id', 7301)))->{rows} };
    $read->() for 1 .. 2;
    $own->do('ALTER TABLE statement_cache_shape ALTER COLUMN title TYPE VARCHAR(40)');
    is_deeply $read->(), [['alpha']], 'outside a transaction: prepared again, same answer';

    $read->();
    $own->do('ALTER TABLE statement_cache_shape ALTER COLUMN title TYPE TEXT');
    $own->begin_work;
    my $error = eval { $read->(); 1 } ? undef : $@;
    is $error && $error->details->{sqlstate}, '0A000', 'inside a transaction: the original error and SQLSTATE';
    is $own->pg_ping, 4, 'the transaction is still the failed one (not rolled back behind the host)';
    $own->rollback;
    is_deeply $read->(), [['alpha']], 'after the host rolls back, the next call prepares afresh';
    $own->do('DROP TABLE statement_cache_shape');
    $own->disconnect;
};

subtest 'writes use named statements and keep error mapping' => sub {
    my $writer = $engine->($dbh, statement_cache => 1);
    my $update = sub {
        Selecto::Write::Command->new(operation => 'update', relation => 'statement_cache_items',
            assignments => {title => $_[0]}, predicate => Selecto::Expression->eq('id', 1), expected_count => 1);
    };
    $writer->adapter->execute_write_unsafe($update->("t$_")) for 1 .. 3;
    like join(' ', map { $_->[1] } @{$prepared->($dbh)}), qr/^UPDATE/, 'the update is a named statement';
    my $insert = Selecto::Write::Command->new(operation => 'insert', relation => 'statement_cache_items',
        assignments => {id => 1, site_id => 7301, title => 'dup'});
    for (1 .. 3) {
        my $error = eval { $writer->adapter->execute_write_unsafe($insert); 1 } ? undef : $@;
        is $error && $error->code, 'database_unique_violation', "duplicate insert $_ maps as without the cache";
    }
    is $dbh->pg_ping, 1, 'every failed write was rolled back';
    Selecto::PostgreSQL::StatementCache->forget($dbh);
    $dbh->do('DEALLOCATE ALL');
};

subtest 'the cache is freed with its connection' => sub {
    my $count = sub { ($dbh->selectrow_array(q{SELECT count(*) FROM pg_stat_activity WHERE application_name = 'selecto_statement_cache_test'}))[0] };
    {
        my $own = $connect->();
        $own->do(q{SET application_name = 'selecto_statement_cache_test'});
        my $adapter = Selecto->adapter(postgresql => (dbh => $own, statement_cache => 1));
        $adapter->execute_query(Selecto::Statement->new(sql => 'SELECT $1::int', params => [$_], columns => ['n'])) for 1 .. 3;
        is(Selecto::PostgreSQL::StatementCache->count($own), 1, 'one cached handle');
        is $count->(), 1, 'connected';
    }
    my $deadline = time + 5;
    select(undef, undef, undef, 0.1) while $count->() && time < $deadline;
    is $count->(), 0, 'dropping the handle closes the connection';
};

$dbh->disconnect;
done_testing;
