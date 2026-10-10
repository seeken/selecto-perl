use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Write::Policy;

sub refusal {
    my ($label, $code, $run) = @_;
    my $ok = eval { $run->(); 1 }; my $error = $@;
    ok !$ok, $label;
    is blessed($error) && $error->isa('Selecto::Error') ? $error->code : 'untyped', $code, "$label code";
}
my $policy = 'Selecto::Write::Policy';
is_deeply $policy->resolve_cardinality({expected_cardinality => ['between', 1, 3]}, ['exactly', 2]), ['exactly', 2], 'caller may narrow a range';
refusal 'caller cannot remove lower bound', 'expected_cardinality_policy_violation', sub {
    $policy->resolve_cardinality({expected_cardinality => ['between', 1, 3]}, ['at_most', 3]);
};
refusal 'caller cannot remove upper bound', 'expected_cardinality_policy_violation', sub {
    $policy->resolve_cardinality({expected_cardinality => ['at_most', 3]}, 'many');
};
is_deeply $policy->resolve_cardinality({bulk => 1}, ['at_most', 2]), ['at_most', 2], 'explicit bulk permits caller bound';
refusal 'ordinary single operation cannot become bulk', 'expected_cardinality_policy_violation', sub {
    $policy->resolve_cardinality({}, 'many');
};
for my $bad (['exactly', 0], ['between', 3, 1], ['at_least', -1], ['at_most', 2, 3], {exactly => 1}) {
    refusal 'invalid cardinality rejected', 'invalid_expected_cardinality', sub { $policy->normalize_cardinality($bad) };
}
my $fields = {id => 'integer', name => 'string', secret => 'string'};
is_deeply $policy->resolve_returning({returning => ['id', 'name']}, ['name'], $fields), ['name'], 'caller may narrow returning';
refusal 'caller cannot expand returning', 'returning_policy_violation', sub {
    $policy->resolve_returning({returning => ['id']}, ['secret'], $fields);
};
refusal 'explicit no-returning policy cannot become all', 'returning_policy_violation', sub {
    $policy->resolve_returning({returning => 'none'}, 'all', $fields);
};
refusal 'returning ambiguity retained', 'duplicate_returning_identifier', sub {
    $policy->resolve_returning({returning => 'all'}, ['name', 'name'], $fields);
};
refusal 'returning requires root field authority', 'undeclared_write_identifier', sub {
    $policy->resolve_returning({returning => 'all'}, ['other'], $fields);
};
for my $bad ([], 23, undef) {
    refusal 'cardinality policy requires an object', 'invalid_write_policy', sub {
        $policy->resolve_cardinality($bad, ['exactly', 1]);
    };
    refusal 'returning policy requires an object', 'invalid_write_policy', sub {
        $policy->resolve_returning($bad, 'all', $fields);
    };
    refusal 'returning field registry requires an object', 'invalid_write_policy', sub {
        $policy->resolve_returning({returning => 'all'}, 'all', $bad);
    };
}
{
    package Local::TiedWriteFields;
    our $HOOKS = 0;
    sub TIEHASH {bless {}, shift}
    sub FIRSTKEY {++$HOOKS; 'secret'}
    sub NEXTKEY {++$HOOKS; undef}
    sub FETCH {++$HOOKS; 'string'}
    sub EXISTS {++$HOOKS; 1}
}
tie my %tied_fields, 'Local::TiedWriteFields';
refusal 'returning admits complete field registry before enumeration', 'invalid_query_contract', sub {
    $policy->resolve_returning({returning => 'all'}, 'all', \%tied_fields);
};
is $Local::TiedWriteFields::HOOKS, 0, 'field registry tie hooks never run';
refusal 'literal mutation cannot satisfy required field with blank text', 'missing_required_write_fields', sub {
    $policy->apply(Selecto::Write::Command->new(operation => 'insert', relation => 'items',
        assignments => {name => Selecto::Write::Expression->literal(' ')}),
        {operations => {insert => {enabled => 1}}, fields => {name => {insertable => 1, required_on => ['insert']}}}, $fields);
};
my $once = Selecto::Write::Command->new(operation => 'update', relation => 'items', assignments => {name => 'one'},
    predicate => Selecto::Expression->eq('id', 1));
my $once_writes = {operations => {update => {enabled => 1}}, fields => {name => {updatable => 1, write_once => 1}}};
my $once_governed = $policy->apply($once, $once_writes, $fields);
my $once_repeated = $policy->apply($once_governed, $once_writes, $fields);
is_deeply $once_repeated->predicate, $once_governed->predicate,
    'repeated governance preserves one write-once predicate';
my $intersect = $policy->apply(Selecto::Write::Command->new(operation => 'update', relation => 'items',
    assignments => {name => 'changed'}, expected_count => 1, metadata => {expected_cardinality => ['at_most', 2]}),
    {operations => {update => {enabled => 1, expected_cardinality => 'many'}}, fields => {name => {updatable => 1}}}, $fields);
is $intersect->expected_count, 1, 'governance retains an additional legacy exact count';
is_deeply $intersect->metadata->{expected_cardinality}, ['exactly', 1], 'effective range is the intersection of both caller constraints';

subtest 'native SQLite governance and atomic policy enforcement' => sub {
    plan skip_all => 'SQLite unavailable' unless eval { require DBI; require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('PRAGMA temp_store=MEMORY');
    is(($dbh->selectrow_array('PRAGMA temp_store'))[0], 2, 'SQLite temporary storage is in memory');
    is(($dbh->selectrow_array('PRAGMA database_list'))[2], '', 'SQLite main database is in memory');
    $dbh->do('CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,code TEXT,once_value TEXT,managed TEXT)');
    $dbh->do(q{INSERT INTO items VALUES(1,'one','original',NULL,'host'),(2,'two','second',NULL,'host')});
    my $raw = {name => 'Items', source => {source_table => 'items', primary_key => 'id',
        fields => [qw(id name code once_value managed)], columns => {id => {type => 'integer'},
            map {$_ => {type => 'string'}} qw(name code once_value managed)}, associations => {}}, schemas => {},
        writes => {operations => {insert => {enabled => 1, returning => 'none'},
            update => {enabled => 1, expected_cardinality => ['exactly', 1], require_filter => 1, returning => ['id', 'name']},
            upsert => {enabled => 1, conflict_targets => [['id']]}},
            fields => {id => {insertable => 1}, name => {insertable => 1, updatable => 1, required_on => ['insert']},
                code => {insertable => 1, updatable => 1, immutable => 1},
                once_value => {insertable => 1, updatable => 1, write_once => 1},
                managed => {insertable => 1, updatable => 1, server_managed => 1}}}};
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
    my $command = sub {
        my (%extra) = @_;
        return Selecto::Write::Command->new(operation => 'update', relation => 'items',
            assignments => {name => 'changed'}, predicate => Selecto::Expression->eq('id', 1), %extra);
    };
    refusal 'native caller cannot weaken exact domain bound', 'expected_cardinality_policy_violation', sub {
        $engine->execute_write($command->(expected_count => undef));
    };
    refusal 'native returning ceiling is enforced', 'returning_policy_violation', sub {
        $engine->execute_write($command->(metadata => {returning => ['managed']}));
    };
    refusal 'native immutable field cannot be changed', 'write_field_not_writable', sub {
        $engine->execute_write($command->(assignments => {code => 'replaced'}));
    };
    refusal 'native server-managed field cannot be changed', 'write_field_not_writable', sub {
        $engine->execute_write($command->(assignments => {managed => 'caller'}));
    };
    refusal 'native required_on is enforced', 'missing_required_write_fields', sub {
        $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'items', assignments => {code => 'new'}));
    };
    is_deeply $dbh->selectall_arrayref('SELECT id,name,code,once_value,managed FROM items ORDER BY id'),
        [[1,'one','original',undef,'host'],[2,'two','second',undef,'host']], 'every refused policy preserves all rows';
    my $set_once = $command->(assignments => {once_value => 'first'});
    is $engine->execute_write($set_once)->affected_rows, 1, 'write-once can set a null value';
    refusal 'write-once cannot replace stored value', 'cardinality_mismatch', sub {
        $engine->execute_write($command->(assignments => {once_value => 'second'}));
    };
    is(($dbh->selectrow_array('SELECT once_value FROM items WHERE id=1'))[0], 'first', 'atomic guard preserves first value');
    ok $dbh->{AutoCommit}, 'refusal restores transaction state';
    for my $field (qw(code once_value managed)) {
        my $before = $dbh->selectall_arrayref('SELECT * FROM items ORDER BY id');
        for my $assigned (0, 1) {
            refusal "upsert cannot rewrite protected $field even when excluded is unassigned", 'write_field_not_writable', sub {
                $engine->execute_write(Selecto::Write::Command->new(operation => 'upsert', relation => 'items',
                    assignments => {id => 1, name => 'conflict', $assigned ? ($field => 'replacement') : ()},
                    metadata => {conflict_target => ['id'], upsert_update_fields => [$field]}));
            };
        }
        is_deeply $dbh->selectall_arrayref('SELECT * FROM items ORDER BY id'), $before,
            "protected $field survives every refused conflict branch";
    }
    is $engine->execute_write(Selecto::Write::Command->new(operation => 'upsert', relation => 'items',
        assignments => {id => 1, name => 'allowed'}, metadata => {conflict_target => ['id'], upsert_update_fields => ['name']}))->affected_rows,
        1, 'allowed upsert still updates the actual conflict row';
    is_deeply $dbh->selectrow_arrayref('SELECT name,code,once_value,managed FROM items WHERE id=1'),
        ['allowed','original','first','host'], 'allowed upsert preserves all protected fields';
    my $bulk_raw = JSON::PP->new->decode(JSON::PP->new->encode($raw));
    $bulk_raw->{writes}{operations}{update}{expected_cardinality} = 'many';
    my $bulk = Selecto::Engine->new(domain => Selecto::Domain->parse($bulk_raw), adapter => $engine->adapter);
    my $before_intersection = $dbh->selectall_arrayref('SELECT * FROM items ORDER BY id');
    refusal 'a permissive domain cannot erase the caller exact constraint', 'cardinality_mismatch', sub {
        $bulk->execute_write($command->(predicate => Selecto::Expression->lte('id', 2), expected_count => 1,
            metadata => {expected_cardinality => ['at_most', 2]}));
    };
    is_deeply $dbh->selectall_arrayref('SELECT * FROM items ORDER BY id'), $before_intersection,
        'additional exact count refuses a two-row mutation atomically';
    is $bulk->execute_write($command->(predicate => Selecto::Expression->eq('id', 99), expected_count => 0,
        metadata => {expected_cardinality => ['at_most', 1]}))->affected_rows, 0,
        'legacy exact zero remains valid inside an explicitly zero-admitting range';
    my $result = $engine->execute_write($command->(metadata => {returning => ['name']}));
    is_deeply $result->values, {name => 'changed'}, 'allowed native returning materializes actual SQLite row';
    $dbh->disconnect;
};
done_testing;
