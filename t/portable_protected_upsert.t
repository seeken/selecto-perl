use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::Operation;
use Selecto::Write::PortableCommand;
use Selecto::Domain::Choices;

{
    package ProtectedOriginAdapter;
    use parent 'Selecto::SQLite';
    sub requires_dbh { 0 }
    sub write_capabilities { die 'unexpected capability provider' }
    sub execute_query { die 'unexpected stored query' }
}
my $compiler = 'Selecto::Write::PortableCommand';
sub domain {
    return {name => 'Protected portable origin', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id name code added secret)], columns => {id => {type => 'integer'},
            map { $_ => {type => 'string'} } qw(name code added secret)}, associations => {}}, schemas => {},
        writes => {operations => {upsert => {enabled => JSON::PP::true, conflict_targets => [['id']], returning => 'all'}},
            fields => {id => {insertable => JSON::PP::true, immutable => JSON::PP::true},
                code => {insertable => JSON::PP::true, immutable => JSON::PP::true},
                map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} } qw(name added secret)}},
        rules => {schema => 'selecto.data_rules.v1', definitions => {present => {version => 1, test => {op => 'text.nonblank'}}},
            normalizers => {}, bindings => {name => {subject => {scope => 'candidate', path => ['name']},
                operations => ['upsert'], rule => {id => 'present', version => 1}}}}};
}
sub choices {
    my $raw = domain();
    $raw->{source}{columns}{$_}{choice_source} = 'names' for qw(name code);
    $raw->{choice_sources} = {names => {domain => 'names', value_field => 'id', label_field => 'name'}};
    return $raw;
}
sub compile {
    my ($raw, $values, %opts) = @_;
    return Selecto::Write::Operation->new($raw)->upsert($values)->compile(%opts)->{command};
}
sub engine {
    my ($raw, %opts) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => ProtectedOriginAdapter->new, %opts);
}
sub error {
    my ($work) = @_;
    return undef if eval { $work->(); 1 };
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return $error->code;
}

subtest 'private origin defers choices until canonical persisted fields exist' => sub {
    my $raw = choices(); my (@requests, $calls);
    my $resolver = sub { push @requests, $_[0]; ++$calls; Selecto::Domain::Choices->valid('allowed') };
    my $command = compile($raw, {id => 1, name => 'insertion intent', code => 'ignored code'},
        choice_membership_resolver => $resolver);
    is($calls // 0, 0, 'protected pure compilation invokes no membership callback');
    my $proof = $compiler->_accepted_protected_upsert($command);
    ok(defined $proof, 'compiler seals protected origin without an INPUT rule');
    ok(!defined $compiler->_accepted_input($command), 'protected origin does not impersonate INPUT evidence');
    my $host = engine($raw);
    is_deeply($compiler->_protected_upsert_dependencies($proof, $host, {effect => 'update'}),
        [qw(added code id name secret)], 'active final choices request the complete canonical root record');
    is_deeply($compiler->_protected_upsert_dependencies($proof, $host, {effect => 'nothing'}), [],
        'DO NOTHING does not consume unused defaults for a resolver');
    my $state = {branch => 'conflict', effect => 'update', values =>
        {id => 1, name => 'canonical stored name', code => 'stored code', added => undef, secret => 'stored secret'}};
    $compiler->_validate_protected_upsert_choices($proof, $host, $command, $state);
    is($calls, 1, 'only the actual updated choice field invokes its resolver');
    is($requests[0]{field}, 'name', 'ignored insert-only choice field is excluded');
    is($requests[0]{value}, 'canonical stored name', 'resolver receives canonical storage value');
    is_deeply($requests[0]{record}, $state->{values}, 'resolver record is the full final candidate');
    $requests[0]{record}{secret} = 'provider mutation';
    is($state->{values}{secret}, 'stored secret', 'resolver receives an independent candidate copy');
    $compiler->_validate_protected_upsert_choices($proof, $host, $command,
        {branch => 'conflict', effect => 'nothing', values => {}});
    is($calls, 1, 'DO NOTHING skips the otherwise configured resolver');
    my $copy = $command->with_metadata({%{$command->metadata}, accepted_upsert => 1});
    ok(!defined $compiler->_accepted_protected_upsert($copy), 'serialized metadata and public copies inherit no private origin');
    is(error(sub { $compiler->_validate_protected_upsert_choices(undef, $host, $copy, $state) }),
        'choice_membership_resolver_required', 'a reconstructed active choice command cannot skip trusted membership');
    is(error(sub { $compiler->_validate_protected_upsert_choices(undef, $host, $copy,
        {branch => 'conflict', effect => 'nothing', values => {}}) }), undef,
        'native DO NOTHING has no unused choice obligation');
    is($calls, 1, 'missing portable origin cannot invoke the original callback');
};

subtest 'origin cannot be manufactured, mutated, retargeted or rebound' => sub {
    my $raw = domain(); my $command = compile($raw, {id => 1, name => 'name'});
    my $proof = $compiler->_accepted_protected_upsert($command);
    ok(defined $proof, 'no-choice protected compiler command still owns origin for mask semantics');
    my $fake = bless \(my $identity = 0), 'Selecto::Write::PortableCommand::_UpsertProof';
    is(error(sub { $compiler->_protected_upsert_dependencies($fake, engine($raw), {effect => 'update'}) }),
        'compiled_upsert_mismatch', 'a same-class manufactured token has no origin');
    my $different = domain(); $different->{rules}{definitions}{present}{test} = {op => 'text.length', unit => 'unicode_scalar', min => 2};
    is(error(sub { $compiler->_protected_upsert_dependencies($proof, engine($different), {effect => 'update'}) }),
        'compiled_upsert_mismatch', 'different host rules cannot reuse portable origin');
    is(error(sub { $compiler->_protected_upsert_dependencies($proof, engine($raw, write_context => {actor => 'different'}),
        {effect => 'update'}) }), 'compiled_upsert_mismatch', 'different trusted context cannot borrow origin');
    $command->{assignments}{name} = 'mutated';
    is(error(sub { $compiler->_accepted_protected_upsert($command) }), 'compiled_upsert_mismatch',
        'direct command mutation fails the complete compiler digest');
};

subtest 'only genuine portable origin extends normalized masks' => sub {
    my $raw = domain(); my $host = engine($raw);
    my $command = compile($raw, {id => 1, name => 'before', code => 'insert-only'});
    my $proof = $compiler->_accepted_protected_upsert($command);
    my $original = $host->governed_write($command);
    my $realized = $original->with_assignments({%{$original->assignments}, name => 'after', added => 'normalized'});
    my $portable = $compiler->_regovern_protected_upsert($proof, $host, $original, $realized, {effect => 'update'});
    is_deeply($portable->metadata->{upsert_update_fields}, [qw(added name)],
        'new permitted normalized field joins genuine portable update mask');
    is($portable->assignments->{code}, 'insert-only', 'ignored insertion intent remains available for insert branch');
    my $native = $compiler->_regovern_protected_upsert(undef, $host, $original, $realized, {effect => 'update'});
    is_deeply($native->metadata->{upsert_update_fields}, ['name'], 'native explicit mask never widens from candidate additions');
    is_deeply($native->metadata->{conflict_target}, ['id'], 'final governance retains actual original conflict target');
};

subtest 'candidate normalizers can require choice record even from initial nothing' => sub {
    my $raw = choices();
    $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
    $raw->{rules}{bindings}{name}{normalizer} = {id => 'trim', version => 1};
    my $command = compile($raw, {id => 1}); my $proof = $compiler->_accepted_protected_upsert($command);
    is_deeply($command->metadata->{upsert_update_fields}, [], 'portable excluded-only assignments produce an actual empty update mask');
    is_deeply($compiler->_protected_upsert_dependencies($proof, engine($raw), {effect => 'nothing'}),
        [qw(added code id name secret)], 'applicable candidate normalizer preserves possible final choice obligation');
    $raw->{rules}{bindings}{name}{subject}{scope} = 'transaction';
    $command = compile($raw, {id => 1}); $proof = $compiler->_accepted_protected_upsert($command);
    is_deeply($compiler->_protected_upsert_dependencies($proof, engine($raw), {effect => 'nothing'}), [],
        'nonpersisted transaction normalization does not invent an update choice check');
};

subtest 'empty mask renders the real SQLite conflict clause' => sub {
    my $adapter = ProtectedOriginAdapter->new;
    is($adapter->_compile_upsert_clause(['id'], []), ' ON CONFLICT ("id") DO NOTHING', 'empty update mask has valid DO NOTHING SQL');
    is($adapter->_compile_upsert_clause(['id'], ['name']), ' ON CONFLICT ("id") DO UPDATE SET "name" = EXCLUDED."name"',
        'ordinary explicit update clause is preserved');
};

subtest 'native DO NOTHING retains caller cardinality and transaction state' => sub {
    plan skip_all => 'DBD::SQLite is optional' unless eval { require DBI; require DBD::SQLite; 1 };
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $db->do('PRAGMA temp_store=MEMORY');
    is(($db->selectrow_array('PRAGMA database_list'))[2], '', 'SQLite main is in memory');
    is(($db->selectrow_array('PRAGMA temp_store'))[0], 2, 'SQLite TEMP is memory');
    $db->do(q{CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT DEFAULT 'default name',code TEXT,added TEXT,secret TEXT)});
    $db->do(q{CREATE TABLE caller(id INTEGER PRIMARY KEY,value TEXT)});
    $db->do(q{INSERT INTO items VALUES(1,'stored name','stored code',NULL,'private')});
    my $raw = domain(); $raw->{writes}{operations}{upsert}{expected_cardinality} = ['at_most', 1];
    my $host = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
    my @hooks; $db->sqlite_update_hook(sub { push @hooks, [@_] });
    $db->begin_work;
    $db->do(q{INSERT INTO caller VALUES(1,'outer sentinel')});
    $db->do('SAVEPOINT caller_saved');
    my $before = $db->selectall_arrayref('SELECT * FROM items ORDER BY id');
    @hooks = ();
    my $exact = Selecto::Write::Command->new(operation => 'upsert', relation => 'items',
        assignments => {id => 1, code => 'ignored'}, metadata => {conflict_target => ['id'], upsert_update_fields => []});
    is(error(sub { $host->execute_write($exact) }), 'cardinality_mismatch',
        'native default exact-one honestly refuses a zero-row conflict result');
    is_deeply($db->selectall_arrayref('SELECT * FROM items ORDER BY id'), $before, 'cardinality refusal leaves complete stored rows unchanged');
    is_deeply([grep { ($_->[1] // '') eq 'main' } @hooks], [],
        'no-op cardinality refusal executes no MAIN business mutation');
    my $allowed = $exact->_with(expected_count => undef,
        metadata => {%{$exact->metadata}, expected_cardinality => ['at_most', 1]});
    my $result = $host->execute_write($allowed);
    is($result->affected_rows, 0, 'explicit at-most-one allows actual DO NOTHING');
    is_deeply([grep { ($_->[1] // '') eq 'main' } @hooks], [],
        'allowed DO NOTHING has no MAIN business hooks');
    is_deeply($db->selectall_arrayref('SELECT * FROM items ORDER BY id'), $before, 'excluded insertion values never rewrite existing row');
    my $portable = compile($raw, {id => 1, code => 'also ignored'});
    is_deeply($portable->metadata->{upsert_update_fields}, [], 'public portable compilation retains genuinely empty mask');
    is($host->execute_write($portable)->affected_rows, 0, 'genuine protected portable no-op respects explicit domain at-most-one');
    $db->do('ROLLBACK TO caller_saved');
    is_deeply($db->selectall_arrayref('SELECT * FROM caller'), [[1, 'outer sentinel']], 'caller savepoint and original sentinel survive');
    $db->rollback;
    is_deeply($db->selectall_arrayref('SELECT * FROM caller'), [], 'caller still owns complete outer rollback');
    $db->disconnect;
};

subtest 'a host without the stored rules cannot skip deferred choices' => sub {
    plan skip_all => 'DBD::SQLite is optional' unless eval { require DBI; require DBD::SQLite; 1 };
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $db->do('PRAGMA temp_store=MEMORY');
    $db->do(q{CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,code TEXT,added TEXT,secret TEXT)});
    my @hooks; $db->sqlite_update_hook(sub { push @hooks, [@_] });
    my $calls = 0; my $verdict = 'invalid';
    my $resolver = sub { ++$calls; $verdict eq 'valid' ? Selecto::Domain::Choices->valid('ok')
        : Selecto::Domain::Choices->invalid('forbidden') };
    my $origin = choices();
    my $plain = choices(); delete $plain->{rules};
    my $advisory = choices(); $advisory->{rules}{bindings}{name}{subject}{scope} = 'input';
    my $build = sub { Selecto::Engine->new(domain => Selecto::Domain->parse($_[0]), adapter => Selecto::SQLite->new(dbh => $db)) };
    my $fresh = sub { compile($origin, {id => $_[0], name => 'forbidden'}, choice_membership_resolver => $resolver) };
    for my $case (['no rules', $plain], ['INPUT-only rules', $advisory]) {
        my ($label, $raw) = @$case; my $host = $build->($raw);
        is(error(sub { $host->execute_write($fresh->(1)) }), 'compiled_upsert_mismatch', "$label: execution refuses the origin");
        is(error(sub { $host->preview_write($fresh->(1)) }), 'compiled_upsert_mismatch', "$label: preview refuses the origin");
        is(error(sub { $host->execute_batch(Selecto::Write::Batch->new($fresh->(1))) }), 'compiled_upsert_mismatch',
            "$label: batch refuses the origin");
    }
    is($calls, 0, 'refused hosts never consult the deferred resolver');
    is_deeply(\@hooks, [], 'refused hosts mutate no row');
    is_deeply($db->selectall_arrayref('SELECT * FROM items'), [], 'no forbidden choice was stored');
    my $host = $build->($origin);
    is(error(sub { $host->execute_write($fresh->(2)) }), 'choice_membership_invalid', 'the originating host still checks membership');
    $verdict = 'valid';
    is(error(sub { $host->execute_write($fresh->(2)) }), undef, 'the originating host admits a valid choice');
    is_deeply($db->selectall_arrayref('SELECT id,name FROM items'), [[2, 'forbidden']], 'positive control stores its row');
    my $ordinary = Selecto::Write::Command->new(operation => 'upsert', relation => 'items', assignments => {id => 3, added => 'a'},
        metadata => {conflict_target => ['id'], upsert_update_fields => ['added']});
    my $ordinary_error = error(sub { $build->($plain)->execute_write($ordinary) });
    is($ordinary_error, undef, 'native commands without an origin are unaffected') or diag($ordinary_error);
    $db->disconnect;
};

done_testing;
