use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::PostgreSQL;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is optional' }
use Selecto::SQLite;

# An empty UPSERT update mask compiles to DO NOTHING only on the protected
# SQLite path, where the native branch is proved and receipted. Every other
# adapter or unprotected engine refuses it as before.
{
    package EmptyMaskPostgreSQL;
    use parent -norequire, 'Selecto::PostgreSQL';
    sub requires_dbh { 0 }
}
sub domain {
    my (%options) = @_;
    my $raw = {name => 'Empty masks', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id name code)], columns => {id => {type => 'integer'}, name => {type => 'string'},
            code => {type => 'string'}}, associations => {}}, schemas => {},
        writes => {operations => {upsert => {enabled => JSON::PP::true, conflict_targets => [['id']],
                expected_cardinality => ['at_most', 1]}},
            fields => {id => {insertable => JSON::PP::true}, code => {insertable => JSON::PP::true},
                name => {insertable => JSON::PP::true, updatable => JSON::PP::true}}},
        actions => {seed => {type => 'create', label => 'Seed',
            execution => {kind => 'updato', operation => 'upsert', set => {id => 1, code => 'seeded'}}}}};
    my $stage = $options{stage};
    $raw->{rules} = {schema => 'selecto.data_rules.v1',
        definitions => {present => {version => 1, test => {op => 'text.nonblank'}}}, normalizers => {},
        bindings => {name => {subject => {scope => $stage, path => ['name']}, operations => ['upsert'],
            rule => {id => 'present', version => 1}}}} if $stage;
    return $raw;
}
sub upsert {
    my (%metadata) = @_;
    return Selecto::Write::Command->new(operation => 'upsert', relation => 'items',
        assignments => {id => 1, code => 'ignored'},
        metadata => {conflict_target => ['id'], upsert_update_fields => [], expected_cardinality => ['at_most', 1], %metadata},
        expected_count => undef);
}
sub code_of {
    my ($work) = @_;
    return 'ok' if eval { $work->(); 1 };
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return $error->code;
}

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$db->do('PRAGMA temp_store=MEMORY');
$db->do(q{CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'stored', code TEXT)});
$db->do(q{INSERT INTO items VALUES(1, 'stored', 'original')});
my @hooks; $db->sqlite_update_hook(sub { push @hooks, [@_] });
my $sqlite = sub { Selecto::Engine->new(domain => Selecto::Domain->parse(domain(@_)), adapter => Selecto::SQLite->new(dbh => $db)) };
my $postgres = sub { Selecto::Engine->new(domain => Selecto::Domain->parse(domain(@_)), adapter => EmptyMaskPostgreSQL->new) };

subtest 'unprotected engines and other adapters refuse empty masks' => sub {
    for my $case (['SQLite without rules', $sqlite->()], ['SQLite with INPUT-only rules', $sqlite->(stage => 'input')]) {
        my ($label, $engine) = @$case;
        is(code_of(sub { $engine->execute_write(upsert()) }), 'invalid_write', "$label: execution refuses");
        is(code_of(sub { $engine->preview_write(upsert()) }), 'invalid_write', "$label: preview refuses");
        is(code_of(sub { $engine->action_command($engine->plan_action({action => 'seed'})) }), 'invalid_action_plan',
            "$label: an upsert action with no updatable change refuses");
    }
    for my $stage (undef, 'candidate') {
        my $engine = $postgres->(defined($stage) ? (stage => $stage) : ());
        my $label = 'PostgreSQL ' . ($stage ? 'with stored rules' : 'without rules');
        is(code_of(sub { $engine->governed_write(upsert()) }), 'invalid_write', "$label: governance refuses");
        is(code_of(sub { $engine->action_command($engine->plan_action({action => 'seed'})) }), 'invalid_action_plan', "$label: action refuses");
    }
    my $adapter = EmptyMaskPostgreSQL->new;
    is(code_of(sub { $adapter->preview_write(upsert()) }), 'invalid_write', 'PostgreSQL compilation refuses an empty mask');
    is(code_of(sub { $adapter->preview_write(upsert(required_capabilities => ['upsert', 'protected_upsert_candidates'])) }),
        'write_capability_missing', 'a forged protected capability is not a PostgreSQL capability');
    my $native = Selecto::SQLite->new(dbh => $db);
    is(code_of(sub { $native->preview_write(upsert()) }), 'invalid_write', 'unprotected SQLite compilation refuses an empty mask');
    is(code_of(sub { $native->execute_write_unsafe(upsert(required_capabilities => ['upsert', 'protected_upsert_candidates'])) }),
        'required_data_rule_pending', 'a forged protected capability without its private receipt refuses at dispatch');
    is(scalar(grep { ($_->[1] // '') eq 'main' } @hooks), 0, 'no refused write mutated a MAIN row');
    is_deeply($db->selectall_arrayref('SELECT * FROM items'), [[1, 'stored', 'original']], 'stored row unchanged');
};

subtest 'the protected SQLite path keeps DO NOTHING' => sub {
    my $engine = $sqlite->(stage => 'candidate');
    my $preview = $engine->preview_write(upsert());
    like($preview->{sql}, qr/ON CONFLICT \("id"\) DO NOTHING\z/, 'protected preview renders DO NOTHING');
    is($engine->execute_write(upsert())->affected_rows, 0, 'protected conflict performs no update');
    is(scalar(grep { ($_->[1] // '') eq 'main' } @hooks), 0, 'DO NOTHING mutates no MAIN row');
    is(code_of(sub { $engine->action_command($engine->plan_action({action => 'seed'})) }), 'ok', 'protected upsert action may have an empty mask');
    is_deeply($db->selectall_arrayref('SELECT * FROM items'), [[1, 'stored', 'original']], 'stored row unchanged');
};

$db->sqlite_update_hook(undef);
$db->disconnect;
done_testing;
