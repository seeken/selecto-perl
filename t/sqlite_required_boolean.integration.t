use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::InsertAdmission;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }

sub attempt {
    my ($run) = @_;
    my $result;
    return ('ok', $result) if eval { $result = $run->(); 1 };
    my $error = $@;
    return ($error->code, undef) if ref($error) && $error->can('code');
    die $error;
}
sub engine {
    my ($db, $predicate, $direct) = @_;
    my $domain = TestSelecto::writable_domain(name => 'Boolean inserts', table => 'bool_items',
        fields => {id => 'integer', active => 'boolean'});
    if ($direct) {
        $domain = $domain->with_required_predicate(Selecto::Expression->eq('active', $predicate->[2]));
        return Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => dbh => $db));
    }
    my $raw = $domain->as_contract;
    $raw->{required_filters} = [$predicate];
    return Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto->adapter(sqlite => dbh => $db));
}
sub insert {
    my ($id, $value) = @_;
    return Selecto::Write::Command->new(operation => 'insert', relation => 'bool_items', assignments => {id => $id, active => $value});
}

subtest 'required JSON booleans agree with actual SQLite stored candidates' => sub {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $db->do('PRAGMA temp_store=MEMORY');
    $db->do('CREATE TABLE bool_items(id INTEGER PRIMARY KEY,active BOOLEAN)');
    my $id = 0;
    for my $case ([JSON::PP::true, 1], [JSON::PP::false, 0],
        [JSON::PP::true, JSON::PP::true], [JSON::PP::false, JSON::PP::false],
        [JSON::PP::true, Selecto::Write::Expression->literal(JSON::PP::true)],
        [JSON::PP::true, 1, 1], [JSON::PP::false, 0, 1]) {
        my ($expected, $value, $direct) = @$case;
        my $engine = engine($db, ['eq', 'active', $expected], $direct);
        my ($code, $result) = attempt(sub { $engine->execute_write(insert(++$id, $value)) });
        is($code, 'ok', 'canonical JSON guard and scalar/JSON/literal candidate are admitted');
        my $stored = $db->selectrow_arrayref('SELECT active,typeof(active) FROM bool_items WHERE id=?', undef, $id);
        is_deeply($stored, [0 + $expected, 'integer'], 'actual stored boolean remains canonical integer');
    }
    my $false = engine($db, ['eq', 'active', JSON::PP::false]);
    my @dml;
    my $prepare = \&DBI::db::prepare;
    {
        no warnings 'redefine';
        local *DBI::db::prepare = sub { push @dml, $_[1] if $_[1] =~ /\A\s*INSERT\b/i; return $prepare->(@_) };
        my ($code) = attempt(sub { $false->execute_write(insert(++$id, 1)) });
        is($code, 'query_rule_violation', 'true candidate fails the required false predicate');
        is(scalar(@dml), 0, 'failed boolean predicate prepares no INSERT');
    }
    my $either = engine($db, ['in', 'active', [JSON::PP::false, JSON::PP::true]]);
    my ($code) = attempt(sub { $either->execute_write(insert(++$id, 0)) });
    is($code, 'ok', 'JSON boolean IN operands are admitted');
    for my $value ('true', 'false', 2, -1) {
        my $before = $db->selectrow_array('SELECT count(*) FROM bool_items');
        ($code) = attempt(sub { $false->execute_write(insert(++$id, $value)) });
        is($code, 'query_rule_not_evaluable', 'noncanonical boolean candidate remains refused');
        is($db->selectrow_array('SELECT count(*) FROM bool_items'), $before, 'refused candidate changes no business rows');
    }
    $db->begin_work;
    $db->do('INSERT INTO bool_items VALUES(100,1)');
    ($code) = attempt(sub { $false->execute_write(insert(101, 1)) });
    is($code, 'query_rule_violation', 'boolean refusal works inside caller transaction');
    ok(!$db->{AutoCommit}, 'caller transaction remains open');
    is($db->selectrow_array('SELECT count(*) FROM bool_items WHERE id=100'), 1, 'caller work remains visible');
    $db->rollback;
    is($db->selectrow_array('SELECT count(*) FROM bool_items WHERE id=100'), 0, 'caller rollback retains ownership');
    is($db->selectrow_array('PRAGMA temp_store'), 2, 'TEMP remains memory');
    ok(!(grep { length($_->[2]) } @{$db->selectall_arrayref('PRAGMA database_list')}), 'all SQLite databases remain memory');
    $db->disconnect;
};

subtest 'typed scalar normalization admits only canonical JSON boolean referents' => sub {
    is(Selecto::InsertAdmission::_value('boolean', JSON::PP::true, 'active'), 1, 'true normalizes to scalar1');
    is(Selecto::InsertAdmission::_value('boolean', JSON::PP::false, 'active'), 0, 'false normalizes to scalar0');
    for my $type (qw(integer decimal string)) {
        my ($code) = attempt(sub { Selecto::InsertAdmission::_value($type, JSON::PP::true, 'other') });
        is($code, 'query_rule_not_evaluable', 'boolean ref cannot become a different typed scalar');
    }
    {
        package BoolInsert::Overload;
        use overload '""' => sub { $BoolInsert::Overload::calls++; '1' }, bool => sub { $BoolInsert::Overload::calls++; 1 }, fallback => 1;
        our $calls = 0;
    }
    my ($code) = attempt(sub { Selecto::InsertAdmission::_value('boolean', bless({}, 'BoolInsert::Overload'), 'active') });
    is($code, 'query_rule_not_evaluable', 'unknown blessed values refuse');
    is($BoolInsert::Overload::calls, 0, 'refusal invokes no overload callbacks');
    my $false_class = bless {}, '0';
    ($code) = attempt(sub { Selecto::InsertAdmission::_value('string', $false_class, 'other') });
    is($code, 'query_rule_not_evaluable', 'false-valued class name cannot bypass reference refusal');
    my $nested = bless \$false_class, 'JSON::PP::Boolean';
    ($code) = attempt(sub { Selecto::InsertAdmission::_value('boolean', $nested, 'active') });
    is($code, 'query_rule_not_evaluable', 'canonical boolean wrapper cannot contain a reference');
    for my $input (undef, 2, 'true') {
        my $raw = $input;
        my $fake = bless \$raw, 'JSON::PP::Boolean';
        ($code) = attempt(sub { Selecto::InsertAdmission::_value('boolean', $fake, 'active') });
        is($code, 'query_rule_not_evaluable', 'malformed canonical-class referent refuses');
    }
    {
        package BoolInsert::Tied;
        our $fetches = 0;
        sub TIESCALAR { bless {}, shift }
        sub FETCH { $fetches++; 1 }
    }
    tie my $slot, 'BoolInsert::Tied';
    my $tied = bless \$slot, 'JSON::PP::Boolean';
    ($code) = attempt(sub { Selecto::InsertAdmission::_value('boolean', $tied, 'active') });
    is($code, 'query_rule_not_evaluable', 'tied canonical-class referent refuses');
    is($BoolInsert::Tied::fetches, 0, 'refusal invokes zero tied FETCH callbacks');
};

done_testing;
