use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(refaddr weaken);
use JSON::PP ();
use Selecto::SQLite;
use Selecto::Write;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }

sub command {
    my ($values, %opts) = @_;
    return Selecto::Write::Command->new(operation => 'upsert', relation => $opts{table} // 'items',
        assignments => $values, expected_count => undef,
        metadata => {conflict_target => $opts{target} // ['id'], upsert_update_fields => $opts{mask} // ['name']});
}
sub request {
    my ($subject, %opts) = @_;
    return {field_types => $opts{types} // {id => 'integer', name => 'string', secret => 'string'},
        dependencies => $opts{dependencies} // ['name'], context => $opts{context} // {}, subject => $subject,
        prior => $opts{prior}};
}
sub attempt {
    my ($work) = @_;
    my ($value, $error); my $ok = eval { $value = $work->(); 1 }; $error = $@ unless $ok;
    die "untyped native error: $error" if !$ok && ref($error) ne 'Selecto::Error';
    return ($value, $error);
}
sub pending {
    my ($label, $work, $reason) = @_;
    my (undef, $error) = attempt($work);
    is($error ? $error->code : undef, 'required_data_rule_pending', "$label refuses with native pending");
    is($error ? $error->details->{reason} : undef, $reason, "$label identifies unavailable proof") if defined $reason;
}
sub memory {
    my ($ddl, $work) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    $db->do($_) for @$ddl;
    my $original_temp = $db->selectall_arrayref('SELECT name FROM temp.sqlite_schema ORDER BY name');
    $db->do('CREATE TABLE caller(id INTEGER PRIMARY KEY,value TEXT)');
    $db->do(q{INSERT INTO caller VALUES(1,'committed')});
    $db->begin_work;
    $db->do(q{INSERT INTO caller VALUES(2,'outer sentinel')});
    $db->do('SAVEPOINT caller_proof');
    my $adapter = Selecto::SQLite->new(dbh => $db);
    my (@hooks, @prepare);
    $db->sqlite_update_hook(sub { push @hooks, [@_] if $_[1] eq 'main' });
    $db->sqlite_set_authorizer(sub {
        push @prepare, [@_] if ($_[0] == 9 || $_[0] == 18 || $_[0] == 23) && ($_[3] // '') eq 'main'
            && ($_[1] // '') =~ /\A(?:items|caller)\z/;
        return 0;
    });
    $work->($adapter, $db, \@hooks, \@prepare);
    is(scalar @hooks, 0, 'candidate load/reprojection makes no main row mutations');
    is(scalar @prepare, 0, 'candidate load/reprojection prepares no main DML');
    is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), [[1,'committed'],[2,'outer sentinel']],
        'complete original caller rows survive');
    ok(!$db->sqlite_get_autocommit, 'original caller transaction remains active');
    $db->do('ROLLBACK TO caller_proof'); $db->do('RELEASE caller_proof');
    is_deeply($db->selectall_arrayref('SELECT name FROM temp.sqlite_schema ORDER BY name'), $original_temp,
        'rolled-back affinity projections leave no TEMP schema objects');
    $db->sqlite_update_hook(undef); $db->sqlite_set_authorizer(undef);
    $db->rollback;
    is(scalar($db->selectrow_array('PRAGMA temp_store')), 2, 'TEMP remains MEMORY');
    ok(!grep({ length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}), 'all databases are memory databases');
    $db->disconnect;
}
my @ordinary = ('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,secret TEXT DEFAULT \'default secret\')',
    q{INSERT INTO items VALUES(1,'before','stored secret'),(2,'sentinel','private')});

subtest 'receipts are rechecked against the live scope context at dispatch' => sub {
    memory(\@ordinary, sub {
        my ($a, $db, $hooks) = @_;
        my $tenant = {tenant_id => 7}; my $other = {tenant_id => 8};
        my $cmd = command({id => 1, name => 'after'});
        $a->rule_upsert_scope(sub {
            pending('projection under another context', sub {
                $a->rule_upsert_candidate($cmd, request([], context => $other)) }, 'receipt_context_mismatch');
            my $state = $a->rule_upsert_candidate($cmd, request([], context => $tenant));
            ok($a->rule_upsert_validate_command($cmd), 'receipt validates under its own live context');
            $a->rule_upsert_scope(sub {
                pending('nested scope with another context', sub { $a->rule_upsert_validate_command($cmd) },
                    'receipt_context_mismatch');
                pending('nested dispatch with another context', sub { $a->execute_write_unsafe($cmd) },
                    'receipt_context_mismatch');
            }, context => $other);
            ok($a->rule_upsert_validate_command($cmd), 'leaving the nested scope restores the live context');
            $a->rule_upsert_scope(sub {
                ok($a->rule_upsert_validate_command($cmd), 'a nested scope with the same context keeps the receipt');
            }, context => {tenant_id => 7});
        }, context => $tenant);
        pending('untrusted scope option', sub { $a->rule_upsert_scope(sub { 1 }, actor => 'x') });
        is(scalar @$hooks, 0, 'refused dispatch performed no business DML');
    });
};

subtest 'capability report requires authentic native DBI support' => sub {
    {
        package UpsertForgedNativeHandle;
        our @ISA = ('DBI::db');
        sub selectrow_array { return '3.51.1' }
        sub sqlite_get_autocommit { return 0 }
        sub sqlite_table_column_metadata { return {} }
        sub DESTROY { }
    }
    my $fake = bless {Driver => {Name => 'SQLite'}}, 'UpsertForgedNativeHandle';
    my $adapter = Selecto::SQLite->new(dbh => $fake);
    is($adapter->write_capabilities->{protected_upsert_candidates}, 0, 'forged blessed DBI HASH advertises no native candidate protection');
    pending('forged handle projection', sub {
        $adapter->rule_upsert_candidate(command({id => 1, name => 'after'}), request([]));
    });
    bless $fake, 'UpsertDiscardedFakeHandle';
    memory(\@ordinary, sub {
        my ($a) = @_;
        is($a->write_capabilities->{protected_upsert_candidates}, 1, 'current actual SQLite driver exposes genuine candidate strategy');
    });
};

subtest 'real conflict mask, insert defaults, no-op and lexical receipt lifetime' => sub {
    memory(\@ordinary, sub {
        my ($a, $db) = @_;
        my $subject = []; my $cmd = command({id => 1, name => 'after', secret => 'ignored'});
        pending('outside actual scope', sub { $a->rule_upsert_candidate($cmd, request($subject)) }, 'transaction_scope_required');
        my ($first, $final, $scope_token);
        $a->rule_upsert_scope(sub {
            $first = $a->rule_upsert_candidate($cmd, request($subject, dependencies => 'all'));
            is($first->{branch}, 'conflict', 'actual unique row chooses conflict branch');
            is($first->{effect}, 'update', 'nonempty native update whitelist chooses update');
            is_deeply($first->{prior_values}, {id => 1, name => 'before', secret => 'stored secret'}, 'complete prior is actual stored row');
            is_deeply($first->{values}, {id => 1, name => 'after', secret => 'stored secret'}, 'ignored insertion field keeps prior storage');
            is($first->{protection}, 'serializable', 'proof reports actual transaction snapshot strategy');
            my $next = $cmd->with_assignments({id => 1, name => 'normalized', secret => 'ignored'});
            $final = $a->rule_upsert_candidate($next, request($subject, dependencies => 'all', prior => $first->{receipt}));
            is($final->{values}{name}, 'normalized', 'reprojection realizes final command values');
            ok($a->rule_upsert_validate_plan([$next]), 'private final command validates before dispatch');
            pending('superseded command', sub { $a->rule_upsert_validate_command($cmd) });
            pending('stale receipt', sub { $a->rule_upsert_candidate($next, request($subject, prior => $first->{receipt})) }, 'stale_receipt');
            my $copy = $next->with_metadata({%{$next->metadata}, required_capabilities => ['protected_upsert_candidates']});
            pending('public reconstruction cannot inherit receipt', sub { $a->rule_upsert_validate_command($copy) }, 'receipt_required');
            my $other = command({id => 3, name => 'new'}, mask => []);
            my $insert = $a->rule_upsert_candidate($other, request([], dependencies => ['name', 'secret']));
            is_deeply($insert->{values}, {id => 3, name => 'new', secret => 'default secret'}, 'insert branch fills only consumed literal default');
            is($insert->{effect}, 'insert', 'empty conflict mask still inserts absent row');
            my $noop = command({id => 2, name => 'ignored'}, mask => []);
            my $state = $a->rule_upsert_candidate($noop, request([], dependencies => 'all'));
            is($state->{effect}, 'nothing', 'existing row plus empty mask is actual DO NOTHING');
            is_deeply($state->{values}, {id => 2, name => 'sentinel', secret => 'private'}, 'DO NOTHING candidate ignores insertion values');
            ok($a->rule_upsert_validate_plan([$next, $other]), 'disjoint same-table protected plan is independent');
            my $touch = Selecto::Write::Command->new(operation => 'update', relation => 'items', assignments => {secret => 'x'},
                predicate => Selecto::Expression->eq('id', 1), expected_count => 1);
            pending('same-table update of the protected row', sub { $a->rule_upsert_validate_plan([$next, $touch]) },
                'plan_independence_unavailable');
            my $cleanup = Selecto::Write::Command->new(operation => 'delete', relation => 'items',
                predicate => Selecto::Expression->eq('id', 9), expected_count => undef);
            pending('same-table owned cleanup', sub { $a->rule_upsert_validate_plan([$next], [$cleanup]) },
                'plan_independence_unavailable');
            ok($a->rule_upsert_validate_plan([$next], [$cleanup->_with(relation => 'caller')]),
                'other-table cleanup needs no candidate proof');
            $scope_token = $final->{receipt};
        });
        pending('expired receipt cannot reopen', sub { $a->rule_upsert_scope(sub {
            $a->rule_upsert_candidate($cmd, request($subject, prior => $scope_token));
        }) }, 'stale_receipt');
        my $weak_receipt;
        $a->rule_upsert_scope(sub {
            my $ephemeral = command({id => 1, name => 'temporary'});
            my $state = $a->rule_upsert_candidate($ephemeral, request([]));
            $weak_receipt = $state->{receipt}; weaken($weak_receipt);
        });
        ok(!defined($weak_receipt), 'scope exit releases private receipt registry without a self-retaining cycle');
        is_deeply($db->selectall_arrayref('SELECT * FROM items ORDER BY id'), [[1,'before','stored secret'],[2,'sentinel','private']],
            'all business rows stay unchanged through positive and negative projections');
    });
};

subtest 'native affinity, external index and supported collation choose the physical row' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,secret TEXT DEFAULT \'x\')',
        'CREATE UNIQUE INDEX native_name ON items(name COLLATE NOCASE)', q{INSERT INTO items VALUES(1,'Ada','private')}], sub {
        my ($a, $db) = @_;
        $a->rule_upsert_scope(sub {
            my $cmd = command({id => '009', name => 'ada', secret => 'new'}, target => ['name'], mask => ['secret']);
            my $state = $a->rule_upsert_candidate($cmd, request([], dependencies => 'all'));
            is($state->{branch}, 'conflict', 'native NOCASE index matches existing row');
            is_deeply($state->{values}, {id => 1, name => 'Ada', secret => 'new'}, 'physical prior identity and ignored keys remain stored');
            my $insert = $a->rule_upsert_candidate(command({id => '009', name => 'Bea'}), request([], dependencies => ['id', 'name']));
            is($insert->{values}{id}, 9, 'real INTEGER storage affinity converts numeric text');
            my $null = $a->rule_upsert_candidate(command({id => 10, name => undef}, target => ['name']), request([]));
            is($null->{branch}, 'insert', 'NULL unique key cannot select an existing row');
        });
    });
};

subtest 'private receipts bind the actual native inner connection' => sub {
    memory(\@ordinary, sub {
        my ($a, $db) = @_;
        my $other = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $other->do('PRAGMA temp_store=MEMORY');
        $other->do($_) for @ordinary;
        $other->do('CREATE TABLE caller(id INTEGER PRIMARY KEY,value TEXT)');
        $other->do(q{INSERT INTO caller VALUES(1,'second committed')});
        $other->begin_work;
        $other->do(q{INSERT INTO caller VALUES(2,'second outer sentinel')});
        $other->do('SAVEPOINT second_proof');
        my $business = $other->selectall_arrayref('SELECT * FROM items ORDER BY id');
        my $other_caller = $other->selectall_arrayref('SELECT * FROM caller ORDER BY id');
        my $first_caller = $db->selectall_arrayref('SELECT * FROM caller ORDER BY id');
        my @other_hooks;
        $other->sqlite_update_hook(sub { push @other_hooks, [@_] if $_[1] eq 'main' });
        $a->rule_upsert_scope(sub {
            my $cmd = command({id => 1, name => 'after'});
            my $state = $a->rule_upsert_candidate($cmd, request([]));
            my $valid = $a->rule_upsert_validate_command($cmd);
            is($valid, 1, 'public validation returns only canonical success');
            ok(!ref($valid), 'public validation exposes no mutable private registry entry');
            $state->{values}{name} = 'mutated public copy';
            is($a->rule_upsert_validate_command($cmd), 1, 'public candidate copy cannot alter the private proof');
            my (undef, $first_inner) = DBI::_handles($db);
            my (undef, $second_inner) = DBI::_handles($other);
            ok($db->swap_inner_handle($other), 'actual DBI swaps the two native connections');
            my $ok = eval {
                my (undef, $swapped_inner) = DBI::_handles($db);
                is(refaddr($swapped_inner), refaddr($second_inner), 'same outer handle now owns the other native connection');
                isnt(refaddr($swapped_inner), refaddr($first_inner), 'actual native inner identity changed');
                is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), $other_caller,
                    'native caller rows independently witness the second connection');
                pending('swapped connection command', sub { $a->rule_upsert_validate_command($cmd) }, 'transaction_connection_changed');
                pending('swapped connection plan', sub { $a->rule_upsert_validate_plan([$cmd]) }, 'transaction_connection_changed');
                1;
            };
            my $error = $@;
            $db->swap_inner_handle($other) or die 'native connection restoration failed';
            die $error unless $ok;
            is($a->rule_upsert_validate_command($cmd), 1, 'restoring the actual original connection retains its live proof');
        });
        is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), $first_caller,
            'first original caller work survives swap and refusal');
        is_deeply($other->selectall_arrayref('SELECT * FROM caller ORDER BY id'), $other_caller,
            'second original caller work survives swap and refusal');
        is_deeply($db->selectall_arrayref('SELECT * FROM items ORDER BY id'), $business, 'first complete business rows remain unchanged');
        is_deeply($other->selectall_arrayref('SELECT * FROM items ORDER BY id'), $business, 'second complete business rows remain unchanged');
        is_deeply(\@other_hooks, [], 'second native connection has no business mutations');
        ok(!$other->sqlite_get_autocommit, 'second original transaction remains active');
        $other->do('ROLLBACK TO second_proof'); $other->do('RELEASE second_proof');
        $other->rollback;
        is_deeply($other->selectall_arrayref('SELECT * FROM caller ORDER BY id'), [[1,'second committed']],
            'second original savepoint and full caller rollback remain usable');
        is(scalar($other->selectrow_array('PRAGMA temp_store')), 2, 'second TEMP database remains memory');
        ok(!grep({ length($_->[2]) } @{$other->selectall_arrayref('PRAGMA database_list')}), 'second native database remains memory');
        $other->sqlite_update_hook(undef); $other->disconnect;
    });
};

subtest 'WITHOUT ROWID witness and permutation of compound unique target' => sub {
    memory(['CREATE TABLE items(id INTEGER,name TEXT,secret TEXT,PRIMARY KEY(name,id)) WITHOUT ROWID',
        q{INSERT INTO items VALUES(1,'a','private')}], sub {
        my ($a) = @_;
        $a->rule_upsert_scope(sub {
            my $state = $a->rule_upsert_candidate(command({id => 1, name => 'a', secret => 'after'},
                target => ['id', 'name'], mask => ['secret']), request([], dependencies => 'all'));
            is($state->{branch}, 'conflict', 'compound native PK matches target permutation');
            is($state->{values}{secret}, 'after', 'actual WITHOUT ROWID prior supports bounded update');
        });
    });
};

subtest 'consumed defaults and generated identities fail closed' => sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,secret TEXT DEFAULT (lower(\'A\')))'], sub {
        my ($a) = @_;
        $a->rule_upsert_scope(sub {
            my $cmd = command({name => 'new'});
            my $state = $a->rule_upsert_candidate($cmd, request([]));
            is_deeply($state->{values}, {name => 'new'}, 'unconsumed generated key and function default are not invented');
            pending('consumed generated rowid', sub { $a->rule_upsert_candidate($cmd, request([], dependencies => ['id'])) }, 'generated_dependency_unavailable');
            pending('consumed volatile/nonliteral default', sub { $a->rule_upsert_candidate($cmd, request([], dependencies => ['secret'])) }, 'nonliteral_default');
        });
    });
};

for my $fixture (
    ['partial arbiter', 'CREATE TABLE items(id INTEGER,name TEXT,secret TEXT)', 'CREATE UNIQUE INDEX bad ON items(id) WHERE id>0'],
    ['expression arbiter', 'CREATE TABLE items(id INTEGER,name TEXT,secret TEXT)', 'CREATE UNIQUE INDEX bad ON items(abs(id))'],
    ['generated column', 'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,secret TEXT GENERATED ALWAYS AS(name) STORED)'],
    ['trigger effects', @ordinary, q{CREATE TRIGGER effects AFTER UPDATE ON items BEGIN UPDATE items SET secret='changed'; END}],
    ['unsafe rollback', 'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT UNIQUE ON CONFLICT ROLLBACK,secret TEXT)'],
    ['unsafe replace', 'CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT UNIQUE ON CONFLICT REPLACE,secret TEXT)'],
    ['TEMP shadow', @ordinary, 'CREATE TEMP TABLE items(id INTEGER,name TEXT,secret TEXT)']) {
    subtest "$fixture->[0] refuses before business effects" => sub {
        memory([@$fixture[1 .. $#$fixture]], sub {
            my ($a) = @_;
            $a->rule_upsert_scope(sub { pending($fixture->[0], sub {
                $a->rule_upsert_candidate(command({id => 1, name => 'after'}), request([]));
            }) });
        });
    };
}

subtest 'schema/command/context changes invalidate private proof' => sub {
    memory(\@ordinary, sub {
        my ($a, $db) = @_;
        $a->rule_upsert_scope(sub {
            my $subject = []; my $cmd = command({id => 1, name => 'after'});
            my $state = $a->rule_upsert_candidate($cmd, request($subject));
            pending('context mismatch', sub { $a->rule_upsert_candidate($cmd,
                request($subject, prior => $state->{receipt}, context => {tenant_id => 2})) }, 'receipt_context_mismatch');
            $cmd->{assignments}{name} = 'tampered';
            pending('exact command mutation', sub { $a->rule_upsert_validate_command($cmd) }, 'receipt_mismatch');
            my $fresh = command({id => 2, name => 'after'});
            $a->rule_upsert_candidate($fresh, request([]));
            $db->do('CREATE INDEX newly_added ON items(secret)');
            pending('fresh schema change', sub { $a->rule_upsert_validate_command($fresh) }, 'schema_changed');
        });
    });
};

subtest 'stored-row replacement cannot reuse the earlier physical witness' => sub {
    memory(\@ordinary, sub {
        my ($a, $db, $hooks, $prepares) = @_;
        $a->rule_upsert_scope(sub {
            my $cmd = command({id => 1, name => 'after'});
            $a->rule_upsert_candidate($cmd, request([]));
            $db->do(q{UPDATE items SET secret='changed outside the proof' WHERE id=1});
            @$hooks = (); @$prepares = ();
            pending('changed complete prior row', sub { $a->rule_upsert_validate_command($cmd) }, 'protected_branch_changed');
            is(scalar($db->selectrow_array('SELECT name FROM items WHERE id=1')), 'before', 'receipt refusal makes no additional mutation');
        });
    });
};

subtest 'plain request refusal precedes native reads and preserves read-only state' => sub {
    memory(\@ordinary, sub {
        my ($a, $db) = @_;
        my $cmd = command({id => 1, name => 'after'});
        my ($calls, $reads) = (0, 0);
        {
            package UpsertTiedRequest;
            sub TIEHASH { bless $_[1], $_[0] }
            sub FIRSTKEY { ++${$_[0]}; return undef }
            sub FETCH { ++${$_[0]}; return undef }
            sub SCALAR { ++${$_[0]}; return 0 }
        }
        tie my %bad, 'UpsertTiedRequest', \$calls;
        $db->sqlite_trace(sub { ++$reads });
        pending('tied request', sub { $a->rule_upsert_candidate($cmd, \%bad) }, 'invalid_request');
        is($calls, 0, 'tied request invokes no hooks');
        is($reads, 0, 'malformed request performs no native statement');
        $db->sqlite_trace(undef);
        $db->do('PRAGMA query_only=ON');
        $a->rule_upsert_scope(sub { pending('query-only affinity projection', sub {
            $a->rule_upsert_candidate($cmd, request([]));
        }) });
        is(scalar($db->selectrow_array('PRAGMA query_only')), 1, 'failed projection preserves original query_only');
        $db->do('PRAGMA query_only=OFF');
    });
};

done_testing;
