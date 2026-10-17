use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::SQLite ();
use Selecto::Write ();
use Selecto::Write::Operation ();
BEGIN { eval { require DBI; require DBD::SQLite; require DBD::SQLite::Constants; 1 }
    or plan skip_all => 'DBD::SQLite is optional' }

# Two connections share one named in-memory cache. With PRAGMA read_uncommitted
# the governing connection takes no table read locks, so its candidate proof can
# rest on another connection's uncommitted rows, which that connection may roll
# back (or commit over) before the business DML runs.
my $raw = {name => 'Shared-cache protected UPSERT',
    source => {source_table => 'items', primary_key => 'id', fields => [qw(id name extra)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, extra => {type => 'string'}},
        associations => {}}, schemas => {},
    writes => {operations => {upsert => {enabled => JSON::PP::true, conflict_targets => [['id']],
        expected_cardinality => ['at_most', 1]}},
        fields => {id => {insertable => JSON::PP::true, immutable => JSON::PP::true},
            map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} } qw(name extra)}},
    rules => {schema => 'selecto.data_rules.v1',
        definitions => {present => {version => 1, test => {op => 'text.nonblank'}}}, normalizers => {},
        bindings => {extra => {subject => {scope => 'candidate', path => ['extra']},
            operations => ['upsert'], rule => {id => 'present', version => 1}}}}};
my $serial = 0;
sub shared {
    my ($name, %attrs) = @_;
    my $db = DBI->connect("dbi:SQLite:dbname=file:$name?mode=memory&cache=shared", '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            sqlite_open_flags => DBD::SQLite::Constants::SQLITE_OPEN_URI(), %attrs});
    $db->do('PRAGMA temp_store=MEMORY');
    return $db;
}
sub pair {
    my (%attrs) = @_;
    my $name = 'selecto_shared_isolation_' . $$ . '_' . ++$serial;
    my $a = shared($name, %attrs); my $b = shared($name);
    $a->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,extra TEXT)');
    # Caller work lives in this connection's TEMP schema: a deferred transaction
    # that has written main would hold the shared cache's only write lock.
    $a->do('CREATE TEMP TABLE caller(id INTEGER PRIMARY KEY,value TEXT)');
    $a->do(q{INSERT INTO caller VALUES(1,'committed')});
    return ($a, $b);
}
sub rows { $_[0]->selectall_arrayref("SELECT * FROM $_[1] ORDER BY id") }
sub engine { Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $_[0])) }
sub upsert { Selecto::Write::Operation->new($raw)->upsert($_[0])->conflict_target(['id'])->compile->{command} }
sub attempt {
    my ($work) = @_;
    return undef if eval { $work->(); 1 };
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return $error;
}
sub refused {
    my ($error, $label) = @_;
    is($error ? $error->code : undef, 'required_data_rule_pending', "$label refuses before business DML");
    is($error ? $error->details->{reason} : undef, 'read_uncommitted_isolation', "$label names the isolation hazard");
}
# Another connection acts between the governing connection's final receipt
# check and its business DML: the window a shared-cache peer can use.
sub race {
    my ($a, $work) = @_;
    my $fired = 0;
    $a->{Callbacks} = {prepare => sub {
        return if $fired || ($_[1] // '') !~ /\AINSERT INTO "items"/;
        $fired = 1; $work->(); return;
    }};
    return \$fired;
}
sub isolated_memory {
    my ($db) = @_;
    is(scalar($db->selectrow_array('PRAGMA temp_store')), 2, 'TEMP remains in memory');
    ok(!grep({ length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}), 'every database is in memory');
}

for my $surface (qw(execute preview)) {
    subtest "$surface: caller deferred transaction with read_uncommitted refuses a dirty conflict row" => sub {
        my ($a, $b) = pair();
        $a->do('PRAGMA read_uncommitted=1');
        $b->do('BEGIN');
        $b->do(q{INSERT INTO items VALUES(5,'peer','uncommitted peer')});
        is_deeply(rows($a, 'items'), [[5,'peer','uncommitted peer']], 'probe: read_uncommitted sees the peer row');
        $a->do('BEGIN DEFERRED');
        $a->do(q{INSERT INTO caller VALUES(2,'outer sentinel')});
        $a->do('SAVEPOINT caller_owned');
        my $fired = race($a, sub { $b->rollback });
        my @hooks; $a->sqlite_update_hook(sub { push @hooks, [@_] if $_[1] eq 'main' });
        my $engine = engine($a); my $command = upsert({id => 5, name => 'governed'});
        refused(attempt(sub { $surface eq 'execute' ? $engine->execute_write($command) : $engine->preview_write($command) }),
            $surface);
        $a->sqlite_update_hook(undef); delete $a->{Callbacks};
        is($$fired, 0, 'business DML was never prepared');
        is(scalar @hooks, 0, 'no main row changed');
        ok(!$a->sqlite_get_autocommit, 'caller transaction remains open');
        is_deeply(rows($a, 'caller'), [[1,'committed'],[2,'outer sentinel']], 'caller work survives');
        $a->do('ROLLBACK TO caller_owned'); $a->do('RELEASE caller_owned');
        is(scalar($a->selectrow_array('PRAGMA read_uncommitted')), 1, 'caller isolation setting is unchanged');
        $a->do('COMMIT');
        is_deeply(rows($a, 'caller'), [[1,'committed'],[2,'outer sentinel']], 'caller commits its own work');
        is_deeply(rows($b, 'items'), [[5,'peer','uncommitted peer']], 'peer transaction is untouched');
        $b->rollback;
        is_deeply(rows($b, 'items'), [], 'nothing unproved was committed');
        isolated_memory($a);
    };
}

subtest 'read_uncommitted refuses an insert proof a committing peer would turn into an update' => sub {
    my ($a, $b) = pair();
    $a->do('PRAGMA read_uncommitted=1');
    $a->do('BEGIN DEFERRED');
    my $fired = race($a, sub { $b->do(q{INSERT INTO items VALUES(5,'peer','peer extra')}) });
    refused(attempt(sub { engine($a)->execute_write(upsert({id => 5, name => 'governed', extra => 'own'})) }), 'execute');
    delete $a->{Callbacks};
    is($$fired, 0, 'business DML was never prepared');
    $a->do('ROLLBACK');
    is_deeply(rows($b, 'items'), [], 'no row was written');
};

subtest 'adapter-owned deferred transaction with read_uncommitted refuses and restores autocommit' => sub {
    my ($a, $b) = pair(sqlite_use_immediate_transaction => 0);
    $a->do('PRAGMA read_uncommitted=1');
    $b->do('BEGIN');
    $b->do(q{INSERT INTO items VALUES(5,'peer','uncommitted peer')});
    my $fired = race($a, sub { $b->rollback });
    refused(attempt(sub { engine($a)->execute_write(upsert({id => 5, name => 'governed'})) }), 'adapter-owned execute');
    delete $a->{Callbacks};
    is($$fired, 0, 'business DML was never prepared');
    ok($a->sqlite_get_autocommit, 'adapter-owned transaction is closed');
    $b->rollback;
    is_deeply(rows($b, 'items'), [], 'nothing was committed');
};

subtest 'read_uncommitted enabled after projection refuses the dispatch recheck' => sub {
    my ($a) = pair();
    my $adapter = Selecto::SQLite->new(dbh => $a);
    my $command = Selecto::Write::Command->new(operation => 'upsert', relation => 'items',
        assignments => {id => 5, name => 'governed'}, expected_count => undef,
        metadata => {conflict_target => ['id'], upsert_update_fields => ['name']});
    $a->do('BEGIN DEFERRED');
    $adapter->rule_upsert_scope(sub {
        my $state = $adapter->rule_upsert_candidate($command, {field_types => {id => 'integer', name => 'string'},
            dependencies => ['name'], context => {}, subject => []});
        is($state->{protection}, 'serializable', 'locked read isolation reports the serializable strategy');
        ok($adapter->rule_upsert_validate_command($command), 'unchanged isolation admits the receipt');
        $a->do('PRAGMA read_uncommitted=1');
        refused(attempt(sub { $adapter->rule_upsert_validate_command($command) }), 'dispatch recheck');
        $a->do('PRAGMA read_uncommitted=0');
    });
    $a->do('ROLLBACK');
};

# Pins the lock the protected path actually holds in a caller's deferred
# transaction: the scope opens no write transaction (no BEGIN IMMEDIATE, no
# write), so isolation rests on SQLite's table read locks alone. A peer can
# still commit to an unread main table, but not to the proved table.
subtest 'shared cache with locking reads holds table read locks, not the write lock' => sub {
    my ($a, $b) = pair();
    $a->do('CREATE TABLE unrelated(id INTEGER PRIMARY KEY)');
    is(scalar($a->selectrow_array('PRAGMA read_uncommitted')), 0, 'default read isolation');
    $a->do('BEGIN DEFERRED');
    my %peer;
    my $fired = race($a, sub {
        for my $table (qw(unrelated items)) {
            my $values = $table eq 'items' ? q{(5,'peer','peer extra')} : '(1)';
            $peer{$table} = eval { $b->do('BEGIN'); $b->do("INSERT INTO $table VALUES$values"); $b->commit; 'committed' }
                // ($@ =~ /locked/ ? 'locked' : "failed: $@");
            $b->rollback unless $b->sqlite_get_autocommit;
        }
    });
    is(attempt(sub { engine($a)->execute_write(upsert({id => 5, name => 'governed', extra => 'own'})) }), undef,
        'protected UPSERT is admitted');
    delete $a->{Callbacks};
    is($$fired, 1, 'peer acted inside the race window');
    is($peer{unrelated}, 'committed', 'no shared-cache write lock is held before the business DML');
    is($peer{items}, 'locked', 'held table read lock refuses the peer write to the proved table');
    $a->do('COMMIT');
    is_deeply(rows($b, 'items'), [[5,'governed','own']], 'only the proved insert is committed');
    is_deeply(rows($b, 'unrelated'), [[1]], 'peer commit to the unread table stands');
    isolated_memory($a);
};

subtest 'private memory connection also refuses read_uncommitted' => sub {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    $db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,extra TEXT)');
    $db->do(q{INSERT INTO items VALUES(5,'before','stored')});
    $db->do('PRAGMA read_uncommitted=1');
    refused(attempt(sub { engine($db)->execute_write(upsert({id => 5, name => 'after'})) }), 'private read_uncommitted');
    $db->do('PRAGMA read_uncommitted=0');
    is(attempt(sub { engine($db)->execute_write(upsert({id => 5, name => 'after'})) }), undef, 'default isolation is admitted');
    is_deeply(rows($db, 'items'), [[5,'after','stored']], 'admitted update persisted');
    isolated_memory($db);
};

done_testing;
