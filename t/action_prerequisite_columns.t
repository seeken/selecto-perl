use 5.034;
use strict;
use warnings;

use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Action ();
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();

{
    package TestPrerequisiteColumns::Adapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;

    sub execute_query ($self, $statement) {
        $self->{last_statement} = $statement;
        return {columns => $statement->columns, rows => []};
    }
}

my $base = {
    schema_version => 1,
    name => 'Work Items',
    source => {
        source_table => 'work_items', primary_key => 'id',
        fields => [qw(id state priority eligible owner_id)],
        columns => {
            id => {type => 'integer'}, state => {type => 'string'},
            priority => {type => 'integer'}, eligible => {type => 'boolean'},
            owner_id => {type => 'integer', internal => 1},
        },
        associations => {},
    },
    schemas => {}, joins => {},
    writes => {
        operations => {update => {enabled => 1, require_filter => 1, bulk => 1}},
        fields => {state => {updatable => 1}},
        transitions => {state => {done => ['archived'], open => ['done']}},
    },
    actions => {
        archive => {
            label => 'Archive', type => 'transition', scope => 'row',
            transition => {field => 'state', from => 'done', to => 'archived'},
            execution => {kind => 'updato', operation => 'update', set => {state => 'archived'}},
        },
        finish => {
            label => 'Finish', type => 'transition', scope => 'bulk',
            preconditions => [
                ['eligible', JSON::PP::true], ['<=', 'priority', 3],
                {field => 'owner_id', op => 'in', value => [4, 5]},
                ['!=', 'priority', 0],
            ],
            transition => {field => 'state', from => 'open', to => 'done'},
            execution => {kind => 'updato', operation => 'update', set => {state => 'done'}},
        },
        touch => {
            label => 'Touch', type => 'bulk_action', scope => 'bulk',
            execution => {kind => 'updato', operation => 'update', set => {state => 'open'}},
        },
    },
};

sub parse_with (&) {
    my ($edit) = @_;
    my $contract = dclone($base);
    $edit->($contract);
    return Selecto::Domain->parse($contract, strict => 1);
}

my $domain = Selecto::Domain->parse(dclone($base), strict => 1);
is_deeply $domain->action_prerequisite_fields, {archive => 'can_archive', finish => 'can_finish'},
    'actions with prerequisites get a column; actions without get none';
is $domain->fields->{can_archive}, 'boolean', 'prerequisite columns are boolean fields';
ok $domain->field_is_public('can_finish'),
    'prerequisite columns are public even when a guard reads an internal field';

my $columns = $domain->contract->{source}{columns};
is_deeply $columns->{can_archive}, {
    type => 'boolean', label => 'Archive prerequisites met', action_prerequisites => 'archive',
    computed => {kind => 'predicate', expression => [
        'and', [['not_null', 'state'], ['eq', 'state', 'done']],
    ]},
}, 'a transition requires its source state';
is_deeply $columns->{can_finish}{computed}{expression}, ['and', [
    ['not_null', 'eligible'], ['eq', 'eligible', JSON::PP::true],
    ['not_null', 'priority'], ['lte', 'priority', 3],
    ['not_null', 'owner_id'], ['in', 'owner_id', [4, 5]],
    ['ne', 'priority', 0],
    ['not_null', 'state'], ['eq', 'state', 'open'],
]], 'preconditions come first, then the transition, each null-safe';
is_deeply $domain->components->{filter_choices}{can_archive}, {
    label => 'Archive prerequisites met',
    choices => [{value => 'true', label => 'Yes'}, {value => 'false', label => 'No'}],
}, 'prerequisite columns filter as Yes/No';

is_deeply [map { [@{$_}{qw(type field comparator value)}] } @{Selecto::Action->prerequisites($domain, 'archive')}],
    [['field_equals', 'state', 'eq', 'done']], 'Selecto::Action lists an action\'s prerequisites';
ok !eval { Selecto::Action->prerequisites($domain, 'missing'); 1 }, 'unknown actions have no prerequisites';

my $reparsed = Selecto::Domain->parse($domain->contract, strict => 1);
is $reparsed->fingerprint, $domain->fingerprint, 'reparsing a contract derives the same columns';
is_deeply $reparsed->action_prerequisite_fields, $domain->action_prerequisite_fields,
    'reparsing keeps one column per action';

my $adapter = TestPrerequisiteColumns::Adapter->new(dbh => bless({}, 'TestPrerequisiteColumns::DBH'));
my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my $statement = $engine->compile(
    $engine->query->select('id', 'can_archive')->where(Selecto::Expression->eq('can_archive', 0)),
);
like $statement->sql,
    qr{\(\("s0"\."state" IS NOT NULL\) AND \("s0"\."state" = \$1\)\) AS "can_archive".*WHERE \(\("s0"\."state" IS NOT NULL\) AND \("s0"\."state" = \$2\)\) = \$3}s,
    'prerequisite columns compile for display and filtering';
is_deeply $statement->params, ['done', 'done', 0], 'prerequisite values stay bound';

my $handler = Selecto::API::EngineHandler->new;
$handler->query($engine, {
    select => ['id', 'can_finish'],
    filters => [{field => 'can_finish', op => 'eq', value => JSON::PP::true}],
});
like $adapter->{last_statement}->sql, qr{AS "can_finish" FROM .* WHERE .*"owner_id" IN .*\) = \$13 LIMIT}s,
    'the API selects and filters prerequisite columns';
is $adapter->{last_statement}->params->[-1], 1, 'the API binds a Yes filter as true';

my $hidden = $domain->without_action_prerequisites('finish', 'touch', 'unknown');
is_deeply $hidden->action_prerequisite_fields, {archive => 'can_archive'},
    'a hidden action loses its prerequisite column';
ok !exists $hidden->fields->{can_finish}, 'the hidden column is not a field';
ok !grep({ $_ eq 'can_finish' } @{$hidden->contract->{source}{fields}}),
    'the hidden column leaves the published contract';
ok !exists $hidden->components->{filter_choices}{can_finish}, 'the hidden column offers no filter';
ok exists $hidden->components->{filter_choices}{can_archive}, 'visible actions keep their filter';
isnt $hidden->fingerprint, $domain->fingerprint, 'hiding changes the fingerprint';
ok exists $domain->fields->{can_finish}, 'hiding does not change the shared domain';
ok !exists Selecto::Domain->parse($hidden->contract, strict => 1)->fields->{can_finish},
    'reparsing a hidden contract keeps the column hidden';
is $domain->without_action_prerequisites('touch'), $domain,
    'hiding actions without columns returns the same domain';
my $hidden_engine = $engine->without_action_prerequisites('finish');
is_deeply $hidden_engine->domain->action_prerequisite_fields, {archive => 'can_archive'},
    'an engine copy hides prerequisite columns';
is $engine->without_action_prerequisites('touch'), $engine,
    'an engine without matching columns is returned as is';
ok !eval {
    $handler->query($hidden_engine, {
        select => ['id'], filters => [{field => 'can_finish', op => 'eq', value => JSON::PP::true}],
    });
    1;
}, 'the API refuses to filter on a hidden prerequisite column';

my $disabled = parse_with { $_[0]{actions}{archive}{prerequisite_column} = JSON::PP::false };
is_deeply [sort keys %{$disabled->action_prerequisite_fields}], ['finish'],
    'prerequisite_column false disables the column';
for my $flag ('yes', [1], undef) {
    my $ok = eval { parse_with { $_[0]{actions}{archive}{prerequisite_column} = $flag }; 1 };
    my $error = $@;
    ok !$ok, 'prerequisite_column must be boolean';
    is blessed($error) && $error->code, 'invalid_domain', 'a non-boolean flag is a domain error';
}

my $declared = parse_with {
    push @{$_[0]{source}{fields}}, 'can_archive';
    $_[0]{source}{columns}{can_archive} = {type => 'integer'};
};
is $declared->fields->{can_archive}, 'integer', 'a declared field of the same name is kept';
ok !exists $declared->action_prerequisite_fields->{archive}, 'and gets no prerequisite column';

my $malformed = parse_with { $_[0]{actions}{finish}{preconditions} = [['like', 'state', '%']] };
ok !exists $malformed->action_prerequisite_fields->{finish},
    'malformed preconditions get no column; plan() still rejects the action';

my $null_guard = parse_with {
    $_[0]{actions}{finish}{preconditions} = [['priority', undef]];
    delete $_[0]{actions}{finish}{transition};
};
is_deeply $null_guard->contract->{source}{columns}{can_finish}{computed}{expression},
    ['and', [['is_null', 'priority'], ['not_null', 'priority']]],
    'a NULL guard never matches, so its column is always false';

my $empty = parse_with { delete $_[0]{actions} };
is_deeply $empty->action_prerequisite_fields, {}, 'domains without actions are unchanged';
is_deeply [sort keys %{$empty->fields}], [sort qw(id state priority eligible owner_id)],
    'and get no extra fields';

done_testing();
