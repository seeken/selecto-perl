use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }
use Selecto::SQLite;

# A batch may hold protected UPSERT candidates only when each one is provably
# independent of every other command on its table, before or after it. Every
# hazardous plan refuses before any MAIN business DML; disjoint plans run.
my $E = 'Selecto::Expression';

sub domain {
    my ($table, $columns, %options) = @_;
    my @fields = map { $_->[0] } @$columns;
    my $raw = {name => "Independence $table", source => {source_table => $table, primary_key => 'id', fields => \@fields,
            columns => {map { ($_->[0] => {type => $_->[1]}) } @$columns}, associations => {}}, schemas => {},
        writes => {operations => {insert => {enabled => JSON::PP::true}, update => {enabled => JSON::PP::true, bulk => 1},
                delete => {enabled => JSON::PP::true, bulk => 1},
                upsert => {enabled => JSON::PP::true, conflict_targets => $options{targets}}},
            fields => {map { ($_ => {insertable => JSON::PP::true, updatable => JSON::PP::true}) } @fields}}};
    $raw->{rules} = {schema => 'selecto.data_rules.v1',
        definitions => {present => {version => 1, test => {op => 'presence.non_null'}}}, normalizers => {},
        bindings => {finish => {subject => {scope => 'candidate', path => ['finish']},
            operations => $options{operations} // ['upsert'], rule => {id => 'present', version => 1}}}} if $options{rules};
    return $raw;
}
sub upsert {
    my ($table, $values, $target, $mask) = @_;
    return Selecto::Write::Command->new(operation => 'upsert', relation => $table, assignments => $values,
        metadata => {conflict_target => $target, upsert_update_fields => $mask // ['finish']});
}
sub insert { Selecto::Write::Command->new(operation => 'insert', relation => $_[0], assignments => $_[1]) }
sub update {
    my ($table, $values, $predicate) = @_;
    return Selecto::Write::Command->new(operation => 'update', relation => $table, assignments => $values,
        predicate => $predicate, expected_count => undef);
}
sub remove {
    my ($table, $predicate) = @_;
    return Selecto::Write::Command->new(operation => 'delete', relation => $table, predicate => $predicate, expected_count => undef);
}

# Each case runs in a fresh memory database inside the caller's own
# transaction and savepoint, which a refusal must leave intact.
sub fixture {
    my (%options) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    $db->do($options{ranges_ddl} // q{CREATE TABLE ranges(id INTEGER PRIMARY KEY, start INTEGER, finish INTEGER, note TEXT COLLATE NOCASE DEFAULT 'default')});
    $db->do(q{INSERT INTO ranges(id,start,finish,note) VALUES(1,5,7,'private'),(2,10,11,'other')});
    $db->do($options{names_ddl} // q{CREATE TABLE names(id INTEGER PRIMARY KEY, subject TEXT UNIQUE, code TEXT UNIQUE DEFAULT 'generated', start INTEGER, finish INTEGER)});
    $db->do(q{INSERT INTO names(id,subject,code,start,finish) VALUES(1,'one','one-code',5,7),(2,'two','two-code',10,11)});
    $db->do('CREATE TABLE caller(id INTEGER PRIMARY KEY, value TEXT)');
    my $adapter = Selecto::SQLite->new(dbh => $db);
    my $ranges = [[id => 'integer'], [start => 'integer'], [finish => 'integer'], [note => 'string']];
    my $names = [[id => 'integer'], [subject => 'string'], [code => 'string'], [start => 'integer'], [finish => 'integer']];
    my $build = sub { Selecto::Engine->new(domain => Selecto::Domain->parse(domain(@_)), adapter => $adapter) };
    my %engines = (
        ranges => $build->('ranges', $ranges, targets => [['id']], rules => 1),
        ranges_plain => $build->('ranges', $ranges, targets => [['id']]),
        names => $build->('names', $names, targets => [['subject'], ['code'], ['id']], rules => 1),
        names_plain => $build->('names', $names, targets => [['subject'], ['code'], ['id']]),
        ranges_inserts => $build->('ranges', $ranges, targets => [['id']], rules => 1, operations => ['insert']),
        ranges_updates => $build->('ranges', $ranges, targets => [['id']], rules => 1, operations => ['update']),
    );
    return ($db, \%engines);
}
sub snapshot {
    my ($db) = @_;
    return {map { ($_ => $db->selectall_arrayref("SELECT * FROM $_ ORDER BY id")) } qw(ranges names)};
}
sub run_plan {
    my ($db, $engines, $plan) = @_;
    my @commands = map { $_->[1] } @$plan;
    my @with = map { $engines->{$_->[0]} } @$plan;
    my $ok = eval { $with[0]->execute_batch(Selecto::Write::Batch->new(@commands), engines => \@with); 1 };
    return wantarray ? ('ok', undef) : 'ok' if $ok;
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return wantarray ? ($error->code, $error->details->{reason}) : $error->code;
}
my $PROOF = qr/\A(?:plan_independence_unavailable|generated_identity_unavailable|ambiguous_candidate_identity|nonliteral_default)\z/;
sub refuses {
    my ($label, $plan, %options) = @_;
    subtest $label => sub {
        my ($db, $engines) = fixture(%options);
        my @hooks; $db->sqlite_update_hook(sub { push @hooks, [@_] if $_[1] eq 'main' });
        $db->begin_work;
        $db->do(q{INSERT INTO caller VALUES(1,'outer sentinel')});
        $db->do('SAVEPOINT caller_saved');
        @hooks = ();
        my $before = snapshot($db);
        my ($code, $reason) = run_plan($db, $engines, $plan->());
        is($code, 'required_data_rule_pending', 'plan refuses as pending');
        if (exists $options{reason}) { is($reason, $options{reason}, 'refusal names its whole-plan reason') }
        else { like($reason // '', $PROOF, 'refusal comes from the independence proof') }
        is_deeply([grep { $_->[2] ne 'caller' } @hooks], [], 'no MAIN business DML ran');
        is_deeply(snapshot($db), $before, 'business rows unchanged');
        ok(!$db->{AutoCommit}, 'caller transaction still open');
        $db->do('ROLLBACK TO caller_saved'); $db->do('RELEASE caller_saved');
        is_deeply($db->selectall_arrayref('SELECT * FROM caller'), [[1, 'outer sentinel']], 'caller savepoint and work intact');
        $db->rollback;
        $db->disconnect;
    };
}
sub admits {
    my ($label, $plan, $expected, %options) = @_;
    subtest $label => sub {
        my ($db, $engines) = fixture(%options);
        is(run_plan($db, $engines, $plan->()), 'ok', 'independent plan executes');
        for my $table (sort keys %$expected) {
            is_deeply($db->selectall_arrayref($expected->{$table}[0]), $expected->{$table}[1], "$table rows are exact");
        }
        $db->disconnect;
    };
}

admits('distinct ordinary insert, update, delete and upsert compose with protected rows', sub { [
    [ranges => insert(ranges => {id => 4, start => 30, finish => 31})],
    [ranges => upsert(ranges => {id => 1, start => 5, finish => 6}, ['id'])],
    [ranges => update(ranges => {finish => 12}, $E->eq('id', 2))],
    [ranges => upsert(ranges => {id => 3, start => 20, finish => 21}, ['id'])],
    [ranges_plain => upsert(ranges => {id => 5, start => 40, finish => 41}, ['id'])],
    [ranges => remove(ranges => $E->eq('id', 4))],
] }, {ranges => ['SELECT id,start,finish FROM ranges ORDER BY id', [[1, 5, 6], [2, 10, 12], [3, 20, 21], [5, 40, 41]]]});

for my $operation (qw(update delete)) {
    for my $order ('before', 'after') {
        refuses("a new protected row cannot be selected by an ordinary $operation $order it", sub {
            my $touch = $operation eq 'update' ? update(ranges => {finish => 99}, $E->eq('id', 3)) : remove(ranges => $E->eq('id', 3));
            my $protected = upsert(ranges => {id => 3, start => 5, finish => 6}, ['id']);
            my @plan = ([ranges => insert(ranges => {id => 9, start => 1, finish => 2})]);
            push @plan, $order eq 'before' ? ([ranges => $touch], [ranges => $protected]) : ([ranges => $protected], [ranges => $touch]);
            return \@plan;
        });
    }
    refuses("updated protected values can create an ordinary $operation match", sub { [
        [ranges => upsert(ranges => {id => 1, start => 5, finish => 6}, ['id'])],
        [ranges => $operation eq 'update' ? update(ranges => {note => 'x'}, $E->eq('finish', 6)) : remove(ranges => $E->eq('finish', 6))],
    ] });
    refuses("the stored protected row cannot be selected by an ordinary $operation", sub { [
        [ranges => $operation eq 'update' ? update(ranges => {note => 'x'}, $E->eq('finish', 7)) : remove(ranges => $E->eq('finish', 7))],
        [ranges => upsert(ranges => {id => 1, start => 5, finish => 6}, ['id'])],
    ] });
}

admits('NULL and disjoint predicates remain supported beside new protected rows', sub { [
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
    [ranges => update(ranges => {finish => 12}, $E->eq('id', 2))],
    [ranges => remove(ranges => $E->is_null('note'))],
] }, {ranges => ['SELECT id,finish FROM ranges ORDER BY id', [[1, 7], [2, 12], [3, 6]]]});

for my $case (['NOCASE column collation', $E->eq('note', 'DEFAULT')], ['INTEGER affinity', $E->eq('id', '3')],
    ['consumed literal default', $E->in('note', ['default', 'other'])]) {
    refuses("$case->[0] governs prospective matching", sub { [
        [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
        [ranges => remove(ranges => $case->[1])],
    ] });
}
admits('a predicate the protected row cannot satisfy is admitted', sub { [
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
    [ranges => remove(ranges => $E->eq('note', 'absent'))],
] }, {ranges => ['SELECT id,note FROM ranges ORDER BY id', [[1, 'private'], [2, 'other'], [3, 'default']]]});

refuses('an initially empty key-moving update cannot collide after an ordinary insert', sub { [
    [ranges => insert(ranges => {id => 4, start => 1, finish => 2})],
    [ranges => update(ranges => {id => 3}, $E->eq('id', 4))],
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
] });
admits('a key-moving update to another key is admitted', sub { [
    [ranges => update(ranges => {id => 8}, $E->eq('id', 2))],
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
] }, {ranges => ['SELECT id FROM ranges ORDER BY id', [[1], [3], [8]]]});
refuses('an unknown volatile default cannot prove a prospective predicate', sub { [
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
    [ranges => remove(ranges => $E->eq('note', 'absent'))],
] }, ranges_ddl => q{CREATE TABLE ranges(id INTEGER PRIMARY KEY, start INTEGER, finish INTEGER, note TEXT DEFAULT CURRENT_TIMESTAMP)});

refuses('an unknown generated rowid refuses any other same-table command', sub { [
    [ranges => upsert(ranges => {start => 5, finish => 6}, ['id'])],
    [ranges => insert(ranges => {id => 3, start => 1, finish => 2})],
] });
refuses('an unknown generated rowid cannot invalidate a later explicit protected identity', sub { [
    [ranges => upsert(ranges => {start => 5, finish => 6}, ['id'])],
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
] });
refuses('an ordinary insert with a generated rowid cannot prove a new protected key', sub { [
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
    [ranges => insert(ranges => {start => 1, finish => 2})],
] });
refuses('two protected candidates for the same new key refuse', sub { [
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 8}, ['id'])],
] });
refuses('two protected candidates for the same stored row refuse', sub { [
    [ranges => upsert(ranges => {id => 1, start => 5, finish => 6}, ['id'])],
    [ranges => upsert(ranges => {id => 1, start => 5, finish => 8}, ['id'])],
] });
admits('distinct protected stored rows and new keys compose', sub { [
    [ranges => upsert(ranges => {id => 1, start => 5, finish => 6}, ['id'])],
    [ranges => upsert(ranges => {id => 2, start => 10, finish => 13}, ['id'])],
    [ranges => upsert(ranges => {id => 3, start => 1, finish => 2}, ['id'])],
    [ranges => upsert(ranges => {id => 4, start => 3, finish => 4}, ['id'])],
] }, {ranges => ['SELECT id,finish FROM ranges ORDER BY id', [[1, 6], [2, 13], [3, 2], [4, 4]]]});

# Different unique keys: another UPSERT can reach the protected row through
# its own arbiter even when the keys differ under the protected arbiter.
refuses('another UPSERT arbiter matches a consumed insertion default', sub { [
    [names => upsert(names => {subject => 'new', start => 5, finish => 6}, ['subject'])],
    [names_plain => upsert(names => {subject => 'other', code => 'generated', finish => undef}, ['code'])],
] });
refuses('another UPSERT arbiter matches an updated protected key', sub { [
    [names => upsert(names => {subject => 'one', code => 'generated', finish => 6}, ['subject'], [qw(code finish)])],
    [names_plain => upsert(names => {subject => 'other', code => 'generated', finish => undef}, ['code'])],
] });
admits('known disjoint other-index keys permit mixed UPSERTs', sub { [
    [names => upsert(names => {subject => 'new', start => 5, finish => 6}, ['subject'])],
    [names_plain => upsert(names => {subject => 'other', code => 'other-code', finish => 0}, ['code'])],
] }, {names => ['SELECT id,subject,code,start,finish FROM names WHERE id > 2 ORDER BY id',
    [[3, 'new', 'generated', 5, 6], [4, 'other', 'other-code', undef, 0]]]});
refuses('an index-arbiter insert cannot guess its generated rowid for another UPSERT', sub { [
    [names => upsert(names => {subject => 'new', start => 5, finish => 6}, ['subject'])],
    [names_plain => upsert(names => {id => 3, finish => 0}, ['id'])],
] });
admits('an explicit rowid proves independence under a different rowid arbiter', sub { [
    [names => upsert(names => {id => 3, subject => 'new', start => 5, finish => 6}, ['subject'])],
    [names_plain => upsert(names => {id => 4, subject => 'four', code => 'four-code', finish => 0}, ['id'])],
] }, {names => ['SELECT id,subject FROM names WHERE id > 2 ORDER BY id', [[3, 'new'], [4, 'four']]]});
admits('two protected index-arbiter inserts keep independent generated rowids', sub { [
    [names => upsert(names => {subject => 'new-a', code => 'a', start => 1, finish => 2}, ['subject'])],
    [names => upsert(names => {subject => 'new-b', code => 'b', start => 3, finish => 4}, ['subject'])],
] }, {names => ['SELECT id,subject FROM names WHERE id > 2 ORDER BY id', [[3, 'new-a'], [4, 'new-b']]]});
refuses('an unprovable default consumed only by the other arbiter remains pending', sub { [
    [names => upsert(names => {subject => 'new', start => 5, finish => 6}, ['subject'])],
    [names_plain => upsert(names => {subject => 'other', code => 'x', finish => 0}, ['code'])],
] }, names_ddl => q{CREATE TABLE names(id INTEGER PRIMARY KEY, subject TEXT UNIQUE, code TEXT UNIQUE DEFAULT CURRENT_TIMESTAMP, start INTEGER, finish INTEGER)});

admits('other-table commands need no proof', sub { [
    [ranges => upsert(ranges => {id => 1, start => 5, finish => 6}, ['id'])],
    [names_plain => update(names => {finish => 1}, $E->eq('finish', 6))],
] }, {ranges => ['SELECT id,finish FROM ranges WHERE id = 1', [[1, 6]]]});

# Unchanged whole-plan refusals for stored deltas.
refuses('a stored-rule update in a batch remains pending', sub { [
    [ranges => upsert(ranges => {id => 3, start => 5, finish => 6}, ['id'])],
    [ranges_updates => update(ranges => {finish => 1}, $E->eq('id', 2))],
] }, reason => undef);
refuses('a protected insert beside an ordinary delta remains pending', sub { [
    [ranges_inserts => insert(ranges => {id => 3, start => 1, finish => 2})],
    [ranges_plain => remove(ranges => $E->eq('id', 2))],
] }, reason => undef);

done_testing;
