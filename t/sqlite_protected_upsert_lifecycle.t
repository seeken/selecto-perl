use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::SQLite ();
use Selecto::Write::Operation ();
use Selecto::Domain::Choices ();
BEGIN { eval { require DBI; require DBD::SQLite; 1 }
    or plan skip_all => 'DBD::SQLite is optional' }

sub domain {
    my (%options) = @_;
    my $raw = {name => 'Native protected UPSERT lifecycle',
        source => {source_table => 'items', primary_key => 'id', fields => [qw(id name code extra secret spare)],
            columns => {id => {type => 'integer'}, map { $_ => {type => 'string'} } qw(name code extra secret spare)},
            associations => {}}, schemas => {},
        writes => {operations => {upsert => {enabled => JSON::PP::true, conflict_targets => [['id']],
            expected_cardinality => ['at_most', 1]}},
            fields => {id => {insertable => JSON::PP::true, immutable => JSON::PP::true},
                code => {insertable => JSON::PP::true, immutable => JSON::PP::true},
                map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} } qw(name extra secret spare)}},
        rules => {schema => 'selecto.data_rules.v1', definitions => {
            present => {version => 1, test => {op => 'text.nonblank'}}},
            normalizers => {}, bindings => {present => {subject => {scope => 'candidate', path => ['name']},
                operations => ['upsert'], rule => {id => 'present', version => 1}}}}};
    if ($options{choices}) {
        $raw->{source}{columns}{$_}{choice_source} = 'names' for qw(name code extra);
        $raw->{choice_sources} = {names => {domain => 'names', value_field => 'id', label_field => 'name'}};
    }
    if ($options{normalize}) {
        $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
        $raw->{rules}{bindings}{present}{normalizer} = {id => 'trim', version => 1};
    }
    if ($options{extra_normalizer}) {
        $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
        $raw->{rules}{bindings}{extra} = {subject => {scope => 'candidate', path => ['extra']}, operations => ['upsert'],
            normalizer => {id => 'trim', version => 1}, rule => {id => 'present', version => 1}};
    }
    return $raw;
}
sub rows { $_[0]->selectall_arrayref('SELECT * FROM items ORDER BY id') }
sub attempt {
    my ($work) = @_;
    my $result;
    return ($result, undef) if eval { $result = $work->(); 1 };
    my $error = $@;
    die "untyped native failure: $error" unless ref($error) eq 'Selecto::Error';
    return (undef, $error->code);
}
sub memory {
    my ($work, %options) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $db->do('PRAGMA temp_store=MEMORY');
    my $default = $options{volatile} ? '(lower(hex(randomblob(4))))' : q{'literal spare'};
    $db->do("CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,code TEXT,extra TEXT,secret TEXT,spare TEXT DEFAULT $default)");
    $db->do(q{INSERT INTO items VALUES(1,' before ','stored code',' extra ','private','stored spare'),(2,'sentinel','other','other','other','other')});
    $db->do('CREATE TABLE caller(id INTEGER PRIMARY KEY,value TEXT)');
    $db->do(q{INSERT INTO caller VALUES(1,'committed')});
    my $committed = rows($db);
    $db->begin_work;
    $db->do(q{INSERT INTO caller VALUES(2,'outer sentinel')});
    $db->do('SAVEPOINT caller_owned');
    $work->($db);
    ok(!$db->sqlite_get_autocommit, 'native caller transaction remains open');
    is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), [[1,'committed'],[2,'outer sentinel']],
        'complete caller work survives the operation');
    $db->do('ROLLBACK TO caller_owned');
    is_deeply(rows($db), $committed, 'caller savepoint restores complete business rows');
    $db->do('RELEASE caller_owned');
    $db->rollback;
    is_deeply($db->selectall_arrayref('SELECT * FROM caller ORDER BY id'), [[1,'committed']], 'outer rollback remains caller-owned');
    ok($db->sqlite_get_autocommit, 'outer rollback restores native autocommit');
    is(scalar($db->selectrow_array('PRAGMA temp_store')), 2, 'TEMP remains in memory');
    ok(!grep({length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}), 'all attached databases remain in memory');
    $db->disconnect;
}
sub compiled {
    my ($raw, $attrs, $resolver) = @_;
    return Selecto::Write::Operation->new($raw)->upsert($attrs)->conflict_target(['id'])->compile(
        defined($resolver) ? (choice_membership_resolver => $resolver) : ())->{command};
}
sub host {
    my ($raw, $db) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
}

for my $surface (qw(preview execute)) {
    subtest "$surface resolves choices against the actual normalized conflict row" => sub { memory(sub {
        my ($db) = @_;
        my $raw = domain(choices => 1, normalize => 1);
        my @requests;
        my $resolver = sub {
            push @requests, {%{$_[0]}, record => {%{$_[0]{record}}}};
            $_[0]{record}{name} = 'provider mutation';
            return Selecto::Domain::Choices->valid('admitted');
        };
        my $command = compiled($raw, {id => 1, name => ' after ', code => 'ignored insert code'}, $resolver);
        is(scalar @requests, 0, 'pure protected compilation defers membership');
        my $before = rows($db);
        my @hooks; $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my $engine = host($raw, $db);
        my ($result, $error) = attempt(sub { $surface eq 'preview' ? $engine->preview_write($command) : $engine->execute_write($command) });
        $db->sqlite_update_hook(undef);
        is($error, undef, 'public native lifecycle succeeds');
        is(scalar @requests, 1, 'only final updated name requires membership');
        is($requests[0]{field}, 'name', 'insert-only code and unchanged extra choices are excluded');
        is($requests[0]{value}, 'after', 'resolver receives the canonical normalized persisted value');
        is_deeply($requests[0]{record}, {id => 1, name => 'after', code => 'stored code', extra => ' extra ',
            secret => 'private', spare => 'stored spare'}, 'resolver sees complete final stored candidate without ignored insertion intent');
        is_deeply(rows($db), $surface eq 'preview' ? $before : [[1,'after','stored code',' extra ','private','stored spare'], $before->[1]],
            'full persisted rows match the selected surface');
        is(scalar(grep {$_->[1] eq 'main'} @hooks), $surface eq 'preview' ? 0 : 1, 'preview performs zero main DML');
    })};
}
subtest 'normalizer-added choice field persists only with final membership' => sub { memory(sub {
    my ($db) = @_;
    my $raw = domain(choices => 1, extra_normalizer => 1);
    my @requests;
    my $command = compiled($raw, {id => 1, name => 'after'}, sub {
        push @requests, $_[0]; Selecto::Domain::Choices->valid('admitted') });
    my ($result, $error) = attempt(sub {host($raw, $db)->execute_write($command)});
    is($error, undef, 'genuine portable origin authorizes eligible normalizer-added update');
    is_deeply([map {$_->{field}} @requests], [qw(extra name)], 'normalizer-added actual update has its own membership decision');
    is($requests[0]{value}, 'extra', 'added update is validated after normalization');
    is_deeply(rows($db)->[0], [1,'after','stored code','extra','private','stored spare'], 'both admitted final values persist');
})};
for my $failure (qw(choice rule evidence)) {
    subtest "$failure refusal leaves the whole caller-owned state unchanged" => sub { memory(sub {
        my ($db) = @_;
        my $raw = domain(choices => 1, normalize => 1);
        $raw->{rules}{bindings}{evidence} = {subject => {scope => 'evidence', path => ['name']},
            operations => ['upsert'], rule => {id => 'present', version => 1}}
            if $failure eq 'evidence';
        my $calls = 0;
        my $command = compiled($raw, {id => 1, name => $failure eq 'rule' ? ' ' : 'after'}, sub {
            ++$calls; Selecto::Domain::Choices->invalid('not_admitted') });
        my $before = rows($db);
        my @hooks; $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my (undef, $error) = attempt(sub {host($raw, $db)->execute_write($command)});
        $db->sqlite_update_hook(undef);
        is($error, $failure eq 'rule' ? 'data_rule_failed' : $failure eq 'evidence'
            ? 'required_data_rule_pending' : 'choice_membership_invalid', 'required refusal is typed');
        is($calls, $failure eq 'choice' ? 1 : 0, 'external callback is suppressed after internal required failure');
        is_deeply(rows($db), $before, 'every business row remains exact');
        is_deeply([grep {$_->[1] eq 'main'} @hooks], [], 'refusal performs zero main mutation');
    })};
}
for my $name (' after ', 'after') {
    subtest "transaction normalizer cannot pass a rule on an unpersisted value ('$name')" => sub { memory(sub {
        my ($db) = @_;
        my $raw = domain();
        $raw->{rules}{definitions}{trimmed} = {version => 1, test => {op => 'text.length', unit => 'unicode_scalar', max => 5}};
        $raw->{rules}{normalizers}{trim} = {version => 1, steps => [{op => 'text.trim', profile => 'ascii_v1'}]};
        $raw->{rules}{bindings}{trimmed} = {subject => {scope => 'transaction', path => ['name']}, operations => ['upsert'],
            normalizer => {id => 'trim', version => 1}, rule => {id => 'trimmed', version => 1}};
        my $before = rows($db);
        my @hooks; $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my (undef, $error) = attempt(sub {host($raw, $db)->execute_write(compiled($raw, {id => 1, name => $name}))});
        $db->sqlite_update_hook(undef);
        if ($name eq 'after') {
            is($error, undef, 'an unchanged transaction normalization is admitted');
            is_deeply(rows($db)->[0], [1,'after','stored code',' extra ','private','stored spare'], 'admitted value persists');
        } else {
            is($error, 'required_data_rule_pending', 'a transaction normalization that changes the stored value refuses');
            is_deeply(rows($db), $before, 'every business row remains exact');
            is_deeply([grep {$_->[1] eq 'main'} @hooks], [], 'refusal performs zero main mutation');
        }
    })};
}
for my $mismatch (qw(copy rules context)) {
    subtest "$mismatch cannot borrow portable membership authority" => sub { memory(sub {
        my ($db) = @_;
        my $raw = domain(choices => 1);
        my $calls = 0;
        my $command = compiled($raw, {id => 1, name => 'after'}, sub {
            ++$calls; Selecto::Domain::Choices->valid('admitted') });
        $command = $command->with_metadata($command->metadata) if $mismatch eq 'copy';
        $raw->{rules}{definitions}{present}{test} = {op => 'text.length', unit => 'unicode_scalar', min => 2}
            if $mismatch eq 'rules';
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db),
            $mismatch eq 'context' ? (write_context => {actor => 'different host'}) : ());
        my $before = rows($db);
        my @hooks; $db->sqlite_update_hook(sub {push @hooks, [@_]});
        my (undef, $error) = attempt(sub {$engine->execute_write($command)});
        $db->sqlite_update_hook(undef);
        is($error, $mismatch eq 'copy' ? 'choice_membership_resolver_required' : 'compiled_upsert_mismatch',
            'public dispatch rejects changed provenance');
        is($calls, 0, 'changed provenance cannot invoke original resolver');
        is_deeply(rows($db), $before, 'complete business rows stay unchanged');
        is_deeply([grep {$_->[1] eq 'main'} @hooks], [], 'changed provenance performs zero main mutation');
    })};
}
subtest 'DO NOTHING consumes no unused choice provider or volatile insert default' => sub { memory(sub {
    my ($db) = @_;
    my $raw = domain(choices => 1);
    my $command = compiled($raw, {id => 1, code => 'ignored code'});
    my $before = rows($db);
    my @hooks; $db->sqlite_update_hook(sub {push @hooks, [@_]});
    my ($result, $error) = attempt(sub {host($raw, $db)->execute_write($command)});
    $db->sqlite_update_hook(undef);
    is($error, undef, 'real conflict DO NOTHING needs no unused resolver/default proof');
    is($result ? $result->affected_rows : undef, 0, 'actual native effect is nothing');
    is_deeply(rows($db), $before, 'ignored insertion values do not alter stored row');
    is_deeply([grep {$_->[1] eq 'main'} @hooks], [], 'DO NOTHING has no main DML');
}, volatile => 1)};
subtest 'insert membership sees consumed literal defaults and the full canonical row' => sub { memory(sub {
    my ($db) = @_;
    my $raw = domain(choices => 1, normalize => 1);
    my @requests;
    my $command = compiled($raw, {id => 3, name => ' new ', code => 'new code', extra => 'new extra', secret => 'new private'},
        sub {push @requests, $_[0]; Selecto::Domain::Choices->valid('admitted')});
    my ($result, $error) = attempt(sub {host($raw, $db)->execute_write($command)});
    is($error, undef, 'literal consumed native default is provable');
    is_deeply([map {$_->{field}} @requests], [qw(code extra name)], 'all actually inserted choice fields are checked once');
    is_deeply($requests[0]{record}, {id => 3, name => 'new', code => 'new code', extra => 'new extra',
        secret => 'new private', spare => 'literal spare'}, 'resolver sees the actual literal-default candidate');
    is_deeply(rows($db)->[2], [3,'new','new code','new extra','new private','literal spare'], 'default and canonical normalized values actually persist');
})};
done_testing;
