use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;

sub report { Selecto::Domain->validate_query_members($_[0]) }
sub codes { [sort map { $_->{code} } @{report($_[0])->{errors}}] }
sub caught { my ($run) = @_; my $ok = eval { $run->(); 1 }; my $e = $@; return $ok ? 'ok' : ref($e) && UNIVERSAL::isa($e, 'Selecto::Error') ? $e->code : die $e }
my $marker = {kind => 'declared_callback'};
my $raw = {name => 'All metadata', query_members => {
    ctes => {plain => {query => $marker, columns => ['id']}, recursive => {type => 'recursive', base_query => $marker, recursive_query => $marker}},
    values => {labels => {rows => [[1,'One'],[2,'Two']], columns => ['id','label'], join => [['owner_key','id'],['related_key','id']]}},
    subqueries => {children => {query => $marker, kind => 'join', type => 'left', on => [{left => 'id', right => 'id'}]}},
    laterals => {series => {source => ['function','bounded_rows',[1,3]], join_type => 'inner'}},
    unnests => {tokens => {array_field => 'tags', ordinality => 'position'}}},
    functions => {unrelated => {kind => 'scalar', sql_name => 'ordinary'}}, extension_metadata => {preserved => JSON::PP::true}};
ok(report($raw)->{valid}, 'all five declaration families and recursive callback metadata validate');
my $p = Selecto::Domain->project_query_members($raw);
is_deeply($p->{declaration}, $raw, 'full declaration including unrelated sections and extensions is retained');
is_deeply([map { $_->{id} } @{$p->{query_members}{ctes}}], ['plain','recursive'], 'descriptors have stable sorted identities');
$p->{query_members}{values}[0]{rows}[0][1] = 'changed';
is($raw->{query_members}{values}{labels}{rows}[0][1], 'One', 'descriptors are independent of original input');
$p->{declaration}{name} = 'changed';
is($raw->{name}, 'All metadata', 'whole declaration copy is independent');
${$p->{declaration}{extension_metadata}{preserved}} = 0;
ok($raw->{extension_metadata}{preserved}, 'Boolean referents are independent');
${report($raw)->{valid}} = 0;
ok(report($raw)->{valid}, 'report Boolean is independent across calls');
for my $pair (
    ['family', sub { $_[0]{query_members}{ctes} = [] }, 'invalid_query_member_group'],
    ['spec', sub { $_[0]{query_members}{values}{labels} = [] }, 'invalid_query_member_spec'],
    ['rows', sub { $_[0]{query_members}{values}{labels}{rows} = {} }, 'invalid_query_member_rows'],
    ['columns', sub { $_[0]{query_members}{values}{labels}{columns} = {} }, 'invalid_query_member_columns'],
    ['callback marker', sub { $_[0]{query_members}{ctes}{plain}{query} = {kind => 'declared_callback', extra => 1} }, 'invalid_query_member_spec'],
    ['subquery kind', sub { $_[0]{query_members}{subqueries}{children}{kind} = 'source' }, 'invalid_query_member_kind'],
    ['subquery join', sub { $_[0]{query_members}{subqueries}{children}{on} = {} }, 'invalid_query_member_on'],
    ['join type', sub { $_[0]{query_members}{subqueries}{children}{type} = 'raw SQL' }, 'invalid_query_member_join_type'],
    ['function source', sub { $_[0]{query_members}{laterals}{series}{source} = 5 }, 'invalid_query_member_source'],
    ['unnest field', sub { $_[0]{query_members}{unnests}{tokens}{array_field} = {} }, 'invalid_query_member_field'],
) {
    my ($label, $edit, $expected) = @$pair; my $bad = dclone($raw); $edit->($bad);
    ok(grep($_ eq $expected, @{codes($bad)}), "malformed $label has its structural diagnostic");
    is(caught(sub { Selecto::Domain->project_query_members($bad) }), 'invalid_query_members', "malformed $label cannot publish a successful projection");
}
my $hooks = 0;
for my $entry (
    ['values', 'labels', 'as', 'invalid_query_member_alias'],
    ['subqueries', 'children', 'join_id', 'invalid_query_member_join_id'],
    ['unnests', 'tokens', 'array_field', 'invalid_query_member_field'],
    ['unnests', 'tokens', 'ordinality', 'invalid_query_member_ordinality'],
) {
    my ($family, $id, $key, $code) = @$entry;
    my $bad = dclone($raw); $bad->{query_members}{$family}{$id}{$key} = 123;
    ok(grep($_ eq $code, @{codes($bad)}), "numeric $family $key is not a metadata name");
    $bad->{query_members}{$family}{$id}{$key} = '123';
    ok(report($bad)->{valid}, "authored string $family $key remains metadata (native identifiers validate separately)");
}
my $data_member = {query_members => {ctes => {by_source => {
    source => 123, query => {select => ['id']}, join => {owner_key => 'id', related_key => 'id'}
}}}};
ok(grep($_ eq 'invalid_query_member_spec', @{codes($data_member)}), 'numeric native-data source is not a metadata name');
$data_member->{query_members}{ctes}{by_source}{source} = '123';
ok(report($data_member)->{valid}, 'authored numeric-looking source string remains valid metadata');
{ package Member::Hooks; use overload '""' => sub { ++$hooks; 'plain' }, bool => sub { ++$hooks; 0 }, fallback => 1;
  sub TO_JSON { ++$hooks; {} } sub STORABLE_freeze { ++$hooks; '' } }
for my $given (sub { ++$hooks }, bless({}, 'Member::Hooks')) {
    my $bad = dclone($raw); $bad->{query_members}{ctes}{plain}{query} = $given;
    is(caught(sub { report($bad) }), 'invalid_query_contract', 'executable metadata is refused before callbacks or clone hooks');
}
{ package Member::Tie; sub TIEHASH { bless {}, shift } sub FIRSTKEY { ++$hooks; die 'FETCH forbidden' } sub FETCH { ++$hooks; die 'FETCH forbidden' } }
my %tied; tie %tied, 'Member::Tie';
is(caught(sub { report(\%tied) }), 'invalid_query_contract', 'tied root refuses without enumerating it');
my $cycle = {}; $cycle->{query_members} = $cycle;
is(caught(sub { report($cycle) }), 'invalid_query_contract', 'cycles are refused before copying');
is($hooks, 0, 'declaration admission has zero callback/tie/overload effects');
require Selecto;
{ package Member::ZeroName; use overload '""' => sub { ++$hooks; 'strict' }, bool => sub { ++$hooks; 0 }, fallback => 1; }
{ no strict 'refs'; @{'0::ISA'} = ('Member::ZeroName'); }
my $zero = bless {}, '0';
my $plain_domain = Selecto::Domain->new(name => 'Plain', table => 'plain', fields => {id => 'integer'});
my $plain_query = Selecto::Query->new->select('id');
my $offline = Selecto->adapter(sqlite => dbh => bless({}, 'Member::Offline'));
for my $route (
    ['mode', 'invalid_query_policy', sub { Selecto::Engine->new(domain => $plain_domain, adapter => $offline, mode => $zero) }],
    ['name', 'invalid_query', sub { Selecto::Query->new->with_member($zero) }],
    ['VALUES name', 'invalid_query_contract', sub { Selecto::Query->new->with_values($zero) }],
    ['family', 'invalid_query', sub { Selecto::Query->new->with_member('plain', group => $zero) }],
    ['subquery type', 'invalid_query', sub { Selecto::Query->new->subquery_join('plain', $plain_domain, $plain_query,
        type => $zero, on => [{left => 'id', right => 'id'}]) }],
    ['subquery column', 'invalid_query', sub { Selecto::Query->new->subquery_join('plain', $plain_domain, $plain_query,
        columns => [$zero], on => [{left => 'id', right => 'id'}]) }],
    ['CTE join type', 'invalid_query', sub { Selecto::Query->new->with_cte('plain', $plain_domain, $plain_query,
        join => {owner_key => 'id', related_key => 'id', type => $zero}) }],
) {
    my ($label, $code, $run) = @$route;
    is(caught($run), $code, "false-named overloaded $label is refused");
    is($hooks, 0, "$label refusal invokes no overload hooks");
}
my $wide = {query_members => {values => {map { ("labels$_" => {columns => ['id'], rows => [[1]]}) } 1 .. 3000}}};
is(caught(sub { report($wide) }), 'invalid_query_contract', 'broad declarations are bounded before descriptor generation');
done_testing;
