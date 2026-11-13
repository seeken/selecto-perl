use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();
use Selecto::Domain::SchemaV2 ();

# A domain nested in a write relationship may be schema 2. It loads through the
# schema 2 path (its rules, then its schema 1 form), so its tenant is the
# child's writes.scope.tenant, and it writes exactly as its schema 1 form does.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
my $V2 = 'Selecto::Domain::SchemaV2';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub child_v2 {
    return {schema_version => 2, name => 'Notes',
        tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']},
        source => {source_table => 'notes', primary_key => 'id', associations => {},
            columns => {map { ($_ => {type => $_ eq 'body' ? 'string' : 'integer'}) } qw(id item_id tenant_id body)}},
        schemas => {}, joins => {},
        writes => {operations => {map { ($_ => {enabled => JSON::PP::true}) } qw(insert update delete)},
            fields => {id => {insertable => JSON::PP::true}, tenant_id => {insertable => JSON::PP::true}, body => {insertable => JSON::PP::true, updatable => JSON::PP::true}}}};
}

sub parent_v2 {
    my ($child) = @_;
    return {schema_version => 2, name => 'Items',
        tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']},
        source => {source_table => 'items', primary_key => 'id', associations => {},
            columns => {id => {type => 'integer'}, tenant_id => {type => 'integer'}, label => {type => 'string'}}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => JSON::PP::true}}, fields => {label => {updatable => JSON::PP::true}},
            relationships => {notes => {writable => JSON::PP::true, cardinality => 'many', ownership => 'owned', parent_key => 'id', child_key => 'item_id',
                allowed_ops => [qw(insert update delete)], domain => $child}}}};
}

sub run_graph {
    my ($domain, @children) = @_;
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TABLE items (id integer primary key, tenant_id integer, label text)');
    $dbh->do('CREATE TABLE notes (id integer primary key, item_id integer, tenant_id integer, body text)');
    $dbh->do(q{INSERT INTO items VALUES (1, 7, 'mine'), (2, 8, 'theirs')});
    $dbh->do(q{INSERT INTO notes VALUES (10, 1, 7, 'keep'), (13, 1, 8, 'foreign')});
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($domain),
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)))->with_tenant(7);
    my @ids = map { "child$_" } 0 .. $#children;
    my $graph = Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => Selecto::Write::Command->new(operation => 'update', relation => 'items',
            assignments => {label => 'touched'}, predicate => Selecto::Expression->eq('id', 1), expected_count => 1)},
        map { {id => $ids[$_], command => Selecto::Write::Command->new(%{$children[$_]}, relation => 'notes', expected_count => 1),
            bindings => [{from => 'root', key => 'id', field => 'item_id'}]} } 0 .. $#children,
    ]);
    my $code = code_of(sub { $engine->execute_graph($graph) });
    return [$code, $dbh->selectall_arrayref('SELECT id, item_id, tenant_id, body FROM notes ORDER BY id')];
}

my @cases = (
    ['insert under the engine tenant', [{operation => 'insert', assignments => {id => 20, body => 'new'}}]],
    ['insert naming the engine tenant', [{operation => 'insert', assignments => {id => 20, tenant_id => 7, body => 'new'}}]],
    ['insert with a foreign tenant', [{operation => 'insert', assignments => {id => 20, tenant_id => 8, body => 'x'}}]],
    ['update of its own row', [{operation => 'update', assignments => {body => 'edited'}, predicate => Selecto::Expression->eq('id', 10)}]],
    ['update of a foreign tenant row', [{operation => 'update', assignments => {body => 'pwned'}, predicate => Selecto::Expression->eq('id', 13)}]],
);

subtest 'a schema 2 nested domain loads into its schema 1 form' => sub {
    my $domain = Selecto::Domain->parse(parent_v2(child_v2()));
    my $nested = $domain->contract->{writes}{relationships}{notes}{domain};
    is($nested->{source}{tenant_field}, 'tenant_id', 'its tenant is source.tenant_field');
    is_deeply($nested->{writes}{scope}{tenant}, {required => JSON::PP::true, field => 'tenant_id',
        satisfied_by => ['trusted_context']}, 'and writes.scope.tenant');
    is_deeply($nested->{source}{fields}, [qw(body id item_id tenant_id)], 'its columns are the field list');
    my $v1_parent = Selecto::Domain->parse({%{$V2->to_version_1(parent_v2(child_v2()))}});
    is_deeply($v1_parent->contract->{writes}{relationships}{notes}{domain}, $nested,
        'a schema 1 parent loads it the same way');
    my $report = Selecto::Domain->validate_write_contract(parent_v2(child_v2()));
    ok($report->{valid}, 'the write contract validator accepts it') or diag explain $report;
};

subtest 'a schema 2 nested domain writes as its schema 1 form does' => sub {
    for my $case (@cases) {
        my ($label, $children) = @$case;
        my $v2 = run_graph(parent_v2(child_v2()), @$children);
        my $v1 = run_graph(parent_v2($V2->to_version_1(child_v2())), @$children);
        is_deeply($v2, $v1, "$label: same outcome and rows") or diag explain [$v2, $v1];
    }
    my ($code, $rows) = @{run_graph(parent_v2(child_v2()), @{$cases[0][1]})};
    is($code, 'ok', 'an insert under the engine tenant succeeds');
    is_deeply($rows->[-1], [20, 1, 7, 'new'], 'the child takes the bound parent and the engine tenant');
    is(run_graph(parent_v2(child_v2()), @{$cases[2][1]})->[0], 'tenant_mismatch', 'a foreign tenant insert refuses');
    is_deeply(run_graph(parent_v2(child_v2()), @{$cases[2][1]})->[1], [[10, 1, 7, 'keep'], [13, 1, 8, 'foreign']],
        'and changes nothing');
    is(run_graph(parent_v2(child_v2()), @{$cases[4][1]})->[0], 'cardinality_mismatch', 'a foreign tenant row is not updated');
    my $untenanted = $V2->to_version_1(child_v2());
    delete $untenanted->{source}{tenant_field};
    delete $untenanted->{writes}{scope};
    is(run_graph(parent_v2($untenanted), @{$cases[0][1]})->[0], 'missing_tenant_scope',
        'without its tenant the same child has no write authority, so the schema 2 tenant is what authorizes it');
};

subtest 'an invalid nested domain refuses as a top-level one does' => sub {
    my %bad = (
        fields_removed => sub { $_[0]{source}{fields} = [qw(id item_id tenant_id body)] },
        invalid_tenant_field => sub { $_[0]{tenant}{field} = 'missing' },
        writes_scope_tenant_removed => sub { $_[0]{writes}{scope}{tenant} = {field => 'tenant_id'} },
        domain_fingerprint_mismatch => sub { $_[0]{domain_fingerprint} = 'notes-v1' },
    );
    for my $reason (sort keys %bad) {
        my $child = child_v2();
        $bad{$reason}->($child);
        my $error = eval { Selecto::Domain->parse(parent_v2($child)); 1 } ? undef : $@;
        is(blessed($error) && $error->code, 'invalid_domain', "$reason refuses");
        is(blessed($error) && $error->details->{reason}, $reason, "with reason $reason");
        is_deeply(blessed($error) ? [@{$error->details->{path}}[0 .. 3]] : undef, [qw(writes relationships notes domain)],
            'at the nested domain');
        ok(!Selecto::Domain->validate_write_contract(parent_v2($child))->{valid}, "$reason: the write contract validator refuses too");
    }
    my $child = child_v2();
    $child->{schema_version} = 1;
    for my $version (1, '2') {
        $child->{schema_version} = $version;
        my $error = eval { Selecto::Domain->parse(parent_v2($child)); 1 } ? undef : $@;
        is(blessed($error) && $error->code, 'unknown_domain_key',
            "a top-level tenant on a nested schema_version $version domain refuses");
    }
    my $deeper = child_v2();
    $deeper->{writes}{relationships}{tags} = {writable => JSON::PP::true, parent_key => 'id', child_key => 'note_id',
        domain => {%{child_v2()}, tenant => {field => 'nope'}}};
    my $error = eval { Selecto::Domain->parse(parent_v2($deeper)); 1 } ? undef : $@;
    is_deeply(blessed($error) && $error->details->{path}, [qw(writes relationships notes domain writes relationships tags domain tenant field)],
        'a nested domain inside a nested domain loads the same way');
};

done_testing;
