use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr);
use Selecto;
use Selecto::SQLite;
use Selecto::Write;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }

sub document {
    my ($table) = @_; $table //= 'items';
    return {name => 'Physical rollback authority', source => {source_table => $table, primary_key => 'id',
        fields => [qw(id name secret root_id)], columns => {id => {type => 'integer'}, name => {type => 'string'},
            secret => {type => 'string'}, root_id => {type => 'integer'}}, associations => {}}, schemas => {},
        writes => {operations => {map { $_ => {enabled => 1, ($_ eq 'upsert' ? (conflict_targets => [['id']]) : ())} }
                qw(insert update delete upsert)},
            fields => {map { $_ => {insertable => 1, updatable => 1} } qw(id name secret root_id)}}};
}
sub writer {
    my ($db, $raw, $adapter) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse($raw // document()),
        adapter => $adapter // Selecto::SQLite->new(dbh => $db));
}
sub command {
    my ($operation, $id, $name, $table) = @_; $table //= 'items';
    return Selecto::Write::Command->new(operation => $operation, relation => $table,
        ($operation eq 'delete' ? () : (assignments => {$operation eq 'update' ? () : (id => $id), name => $name})),
        ($operation eq 'update' || $operation eq 'delete' ? (predicate => Selecto::Expression->eq('id', $id)) : ()),
        ($operation eq 'upsert' ? (metadata => {conflict_target => ['id'], upsert_update_fields => ['name']}) : ()));
}
sub ddl {
    my ($constraint, $policy) = @_;
    return "CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT NOT NULL" .
        ($constraint eq 'not_null' ? " ON CONFLICT $policy" : '') .
        ",secret TEXT NOT NULL DEFAULT 'generated',root_id INTEGER" .
        ($constraint eq 'unique' ? ",UNIQUE(name) ON CONFLICT $policy" : '') . ')';
}
sub memory {
    my ($ddl, $work) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY'); $db->do('PRAGMA foreign_keys=ON');
    $db->do($_) for @$ddl;
    $db->do('CREATE TABLE caller_work(id INTEGER PRIMARY KEY,value TEXT)');
    $db->do(q{INSERT INTO caller_work VALUES(10,'committed')});
    my @tables = map { $_->[0] } @{$db->selectall_arrayref(q{SELECT name FROM main.sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name})};
    my %business = map { $_ => 1 } grep { $_ ne 'caller_work' } @tables;
    my (@sql, @prepare, @hooks, @errors);
    my $handler = sub { push @errors, $_[0]; return 0 };
    $db->{HandleError} = $handler;
    $db->sqlite_trace(sub { push @sql, $_[0] });
    $db->sqlite_set_authorizer(sub {
        push @prepare, [@_] if ($_[0] == 9 || $_[0] == 18 || $_[0] == 23) && $business{$_[1] // ''};
        return 0;
    });
    $db->sqlite_update_hook(sub { push @hooks, [@_] if $business{$_[2] // ''} });
    my $snapshot = sub { +{map { $_ => $db->selectall_arrayref('SELECT * FROM main.' . $db->quote_identifier($_) . ' ORDER BY rowid') } @tables} };
    my $observe = sub {
        my ($run) = @_;
        @sql = (); @prepare = (); @hooks = (); @errors = ();
        my ($result, $error); my $ok = eval { $result = $run->(); 1 }; $error = $@ unless $ok;
        die "untyped public failure: $error" if !$ok && ref($error) ne 'Selecto::Error';
        return {code => $ok ? 'ok' : $error->code, result => $result, sql => [@sql], prepare => [@prepare],
            hooks => [@hooks], errors => [@errors]};
    };
    my $refuses = sub {
        my ($label, $run, $code) = @_;
        my $before = $snapshot->(); my $seen = $observe->($run);
        is($seen->{code}, $code // 'required_data_rule_pending', "$label: typed physical refusal");
        is(scalar @{$seen->{prepare}}, 0, "$label: no business DML prepares");
        is(scalar @{$seen->{hooks}}, 0, "$label: no physical business mutation hooks");
        is(scalar(grep { /\A\s*(?:INSERT\b|UPDATE\b|DELETE\b)/i } @{$seen->{sql}}), 0, "$label: no business DML execution");
        is_deeply($snapshot->(), $before, "$label: all business and caller rows remain exact");
        is(scalar @{$seen->{errors}}, 0, "$label: host HandleError sees no native constraint failure");
        is(refaddr($db->{HandleError}), refaddr($handler), "$label: original host handler is preserved");
        return $seen;
    };
    $work->($db, $snapshot, $observe, $refuses);
    ok($db->sqlite_get_autocommit, 'fixture leaves no native transaction');
    is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP remains memory');
    is_deeply([grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'all SQLite databases remain memory');
    $db->sqlite_trace(undef); $db->sqlite_set_authorizer(undef); $db->sqlite_update_hook(undef); $db->disconnect;
}
sub with_caller {
    my ($db, $snapshot, $run, $external) = @_;
    my $committed = $snapshot->();
    $external ? $db->do('BEGIN') : $db->begin_work;
    $db->do(q{INSERT INTO caller_work VALUES(11,'original outer sentinel')});
    $db->do('SAVEPOINT caller_proof');
    my $before = $snapshot->(); $run->();
    is_deeply($snapshot->(), $before, 'original caller sentinel and complete rows survive the public attempt');
    ok(!$db->sqlite_get_autocommit, 'original caller transaction is physically active');
    $db->do(q{INSERT INTO caller_work VALUES(12,'savepoint witness')});
    my $usable = eval { $db->do('ROLLBACK TO SAVEPOINT caller_proof'); $db->do('RELEASE SAVEPOINT caller_proof'); 1 };
    ok($usable, 'original caller savepoint remains usable');
    is_deeply($snapshot->(), $before, 'rollback to original savepoint removes only its later witness');
    if (!$db->sqlite_get_autocommit) { $external ? $db->do('ROLLBACK') : $db->rollback }
    is_deeply($snapshot->(), $committed, 'caller rollback restores exact originally committed rows');
}
my @seed = (q{INSERT INTO items(id,name,secret) VALUES(1,'before','private'),(2,'taken','sentinel')});

for my $constraint (qw(unique not_null)) {
    for my $operation (qw(insert upsert_new upsert_existing update)) {
        subtest "$constraint ROLLBACK $operation refuses before caller effects" => sub {
            memory([ddl($constraint, 'ROLLBACK'), @seed], sub {
                my ($db, $snapshot, $observe, $refuses) = @_;
                my $e = writer($db); my $op = $operation =~ /^upsert/ ? 'upsert' : $operation;
                my $id = $operation eq 'insert' || $operation eq 'upsert_new' ? 3 : 1;
                my $cmd = command($op, $id, $constraint eq 'unique' ? 'taken' : undef);
                with_caller($db, $snapshot, sub {
                    $refuses->('native preview', sub { $e->preview_write($cmd) });
                    $refuses->('native execution', sub { $e->execute_write($cmd) });
                });
            });
        };
    }
}
subtest 'managed transaction and externally begun caller transaction remain intact' => sub {
    memory([ddl('unique', 'ROLLBACK'), @seed], sub {
        my ($db, $snapshot, $observe, $refuses) = @_;
        my $e = writer($db);
        $refuses->('managed unsafe table refuses even nonconflicting values', sub { $e->execute_write(command('insert', 3, 'fresh')) });
    });
    memory([ddl('not_null', 'ROLLBACK'), @seed], sub {
        my ($db, $snapshot, $observe, $refuses) = @_;
        with_caller($db, $snapshot, sub { $refuses->('external caller upsert', sub { writer($db)->execute_write(command('upsert', 1, undef)) }) }, 1);
    });
};
subtest 'ABORT companion errors preserve full original caller state and savepoint' => sub {
    for my $constraint (qw(unique not_null)) {
        memory([ddl($constraint, 'ABORT'), @seed], sub {
            my ($db, $snapshot, $observe) = @_;
            with_caller($db, $snapshot, sub {
                my $e = writer($db);
                for my $op (qw(insert upsert update)) {
                    my $before = $snapshot->(); my $seen = $observe->(sub { $e->execute_write(command($op, $op eq 'insert' ? 3 : 1, $constraint eq 'unique' ? 'taken' : undef)) });
                    is($seen->{code}, 'query_error', "$constraint $op remains an actual native ABORT constraint error");
                    ok(@{$seen->{prepare}}, 'ordinary ABORT statement actually reaches native DML preparation');
                    ok(@{$seen->{errors}}, 'original host handler observes the actual constraint error');
                    is(scalar @{$seen->{hooks}}, 0, 'failed ABORT statement mutates no business row');
                    is_deeply($snapshot->(), $before, 'failed ABORT preserves complete exact rows');
                }
            });
        });
    }
};
subtest 'late unsafe batch and graph targets admit no ordinary prefix' => sub {
    for my $surface (qw(batch graph)) {
        memory(['CREATE TABLE roots(id INTEGER PRIMARY KEY,name TEXT,secret TEXT)',
            'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT UNIQUE ON CONFLICT ROLLBACK,secret TEXT,root_id INTEGER REFERENCES roots(id))',
            q{INSERT INTO roots VALUES(1,'root before','root private')}, q{INSERT INTO items VALUES(2,'taken','child private',1)}], sub {
            my ($db, $snapshot, $observe, $refuses) = @_;
            my $adapter = Selecto::SQLite->new(dbh => $db); my $root = document('roots'); my $child = document();
            $root->{writes}{relationships}{items} = {writable => 1, ownership => 'owned', parent_key => 'id',
                child_key => 'root_id', allowed_ops => ['insert'], domain => $child};
            my $e = writer($db, $root, $adapter); my $prefix = command('update', 1, 'root after', 'roots');
            my $late = command('insert', 3, 'taken');
            with_caller($db, $snapshot, sub {
                if ($surface eq 'batch') {
                    my $batch = Selecto::Write::Batch->new($prefix, $late);
                    $refuses->('whole cross-domain batch', sub { $e->execute_batch($batch, engines => [$e, writer($db, $child, $adapter)]) });
                } else {
                    my $graph = Selecto::Write::Graph->new(nodes => [{id => 'root', command => $prefix},
                        {id => 'child', command => $late, bindings => [{from => 'root', key => 'id', field => 'root_id'}]}]);
                    $refuses->('whole owned graph', sub { $e->execute_graph($graph) });
                }
            });
        });
    }
};
subtest 'guarded INSERT exposes query-rule refusal in preview and execution' => sub {
    memory([ddl('unique', 'ROLLBACK'), @seed], sub {
        my ($db, $snapshot, $observe, $refuses) = @_;
        my $e = writer($db); my $guarded = $e->enforce_query(command('insert', 3, 'taken'),
            $e->query->where(Selecto::Expression->eq('name', 'taken')));
        with_caller($db, $snapshot, sub {
            $refuses->('guarded preview', sub { $e->preview_write($guarded) }, 'query_rule_not_evaluable');
            $refuses->('guarded execution', sub { $e->execute_write($guarded) }, 'query_rule_not_evaluable');
        });
    });
};
subtest 'comments separate real policy tokens; strings and complete identifiers are harmless' => sub {
    memory(["CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT UNIQUE oN /* separated */ cOnFlIcT -- real policy\n rOlLbAcK,secret TEXT)",
        q{INSERT INTO items VALUES(1,'before','private')}], sub {
        my ($db, $snapshot, $observe, $refuses) = @_;
        $refuses->('mixed-case commented real policy', sub { writer($db)->execute_write(command('insert', 2, 'fresh')) });
    });
    for my $extra (
        q{note TEXT DEFAULT 'ON CONFLICT ROLLBACK'}, q{"ON CONFLICT ROLLBACK" TEXT},
        q{`ON CONFLICT ROLLBACK` TEXT}, q{[ON CONFLICT ROLLBACK] TEXT},
        q{ON_CONFLICT_ROLLBACK TEXT,ROLLBACK_suffix TEXT,rollback$tail TEXT},
        q{note TEXT DEFAULT 'escaped '' ON CONFLICT ROLLBACK'},
        q{note TEXT /* ON CONFLICT ROLLBACK */}, "note TEXT -- ON CONFLICT ROLLBACK\n",
        q{note TEXT CHECK(note <> 'ON CONFLICT ROLLBACK')},
    ) {
        memory(["CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT UNIQUE ON CONFLICT ABORT,secret TEXT,$extra)"], sub {
            my ($db, $snapshot, $observe) = @_;
            my $e = writer($db); my $insert = command('insert', 1, 'ordinary');
            my $preview = $observe->(sub { $e->preview_write($insert) });
            is($preview->{code}, 'ok', 'harmless text preview succeeds');
            is(scalar @{$preview->{hooks}}, 0, 'harmless preview is read only');
            is($observe->(sub { $e->execute_write($insert) })->{code}, 'ok', 'harmless policy words allow real INSERT');
            is($observe->(sub { $e->execute_write(command('update', 1, 'after')) })->{code}, 'ok', 'harmless policy words allow real UPDATE');
            is_deeply($db->selectall_arrayref('SELECT id,name FROM items'), [[1,'after']], 'actual authored writes are stored');
        });
    }
};
subtest 'ordinary DELETE and read-only graph anchor do not activate ROLLBACK policy' => sub {
    memory([ddl('unique', 'ROLLBACK'), @seed], sub {
        my ($db, $snapshot, $observe) = @_;
        my $seen = $observe->(sub { writer($db)->execute_write(command('delete', 1)) });
        is($seen->{code}, 'ok', 'ordinary DELETE remains supported on conflict-policy table');
        is(scalar @{$seen->{hooks}}, 1, 'exactly the declared row deletion occurs');
        is_deeply($db->selectall_arrayref('SELECT id,name,secret FROM items'), [[2,'taken','sentinel']], 'unrelated row survives ordinary DELETE');
    });
    memory(['CREATE TABLE roots(id INTEGER PRIMARY KEY ON CONFLICT ROLLBACK,name TEXT,secret TEXT)',
        'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,secret TEXT,root_id INTEGER REFERENCES roots(id))',
        q{INSERT INTO roots VALUES(1,'anchor','private')}], sub {
        my ($db, $snapshot, $observe) = @_;
        my $root = document('roots'); $root->{writes}{relationships}{items} = {writable => 1, ownership => 'owned',
            parent_key => 'id', child_key => 'root_id', allowed_ops => ['insert'], domain => document()};
        my $graph = Selecto::Write::Graph->new(nodes => [
            {id => 'root', reference_only => 1, command => Selecto::Write::Command->new(operation => 'update', relation => 'roots', predicate => Selecto::Expression->eq('id', 1))},
            {id => 'child', command => command('insert', 3, 'child'), bindings => [{from => 'root', key => 'id', field => 'root_id'}]}]);
        my $seen = $observe->(sub { writer($db, $root)->execute_graph($graph) });
        is($seen->{code}, 'ok', 'read-only reference anchor can supply an actual ordinary child binding');
        is_deeply([map { $_->[2] } @{$seen->{hooks}}], ['items'], 'only the declared child mutates');
        is_deeply($db->selectall_arrayref('SELECT * FROM roots'), [[1,'anchor','private']], 'ROLLBACK-policy reference root remains untouched');
        is_deeply($db->selectall_arrayref('SELECT id,name,root_id FROM items'), [[3,'child',1]], 'actual child references existing root');
    });
};
subtest 'host NOCASE replacement cannot substitute a safe table catalog declaration' => sub {
    memory(['CREATE TABLE safe_first(id INTEGER PRIMARY KEY,name TEXT,secret TEXT,root_id INTEGER)',
        q{INSERT INTO safe_first VALUES(1,'safe catalog decoy','retained',NULL)},
        ddl('unique', 'ROLLBACK'), @seed], sub {
        my ($db, $snapshot, $observe, $refuses) = @_;
        $db->sqlite_create_collation('NOCASE', sub { 0 });
        my $e = writer($db);
        with_caller($db, $snapshot, sub {
            $refuses->('native catalog result must identify the actual physical target', sub {
                $e->execute_write(command('insert', 3, 'taken'));
            });
        });
    });
};
done_testing;
