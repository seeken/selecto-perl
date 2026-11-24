use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::RowRevision ();
use Selecto::Write::Operation ();
use lib 't/lib';
use TestSelecto;

sub declaration {
    return {name => 'PanelContract', source => {source_table => 'panels', primary_key => 'id', fields => [qw(id owner_id name)],
        columns => {id => {type => 'integer'}, owner_id => {type => 'integer'}, name => {type => 'string'}}, associations => {}}, schemas => {},
        writes => {operations => {update => {enabled => JSON::PP::true}}, fields => {name => {updatable => JSON::PP::true}}}};
}
for my $case (
    [row_revision => {columns => []}],
    [row_revision => {column => 'absent'}],
    [row_revision => {columns => ['name', 'name']}],
    [row_revision => {columns => ['name'], column => 'id'}],
    [row_revision => {columns => ['name'], required => 'yes'}],
    [row_revision => {columns => ['name'], unexpected => 1}],
    [host_bound_fields => {owner_id => {mode => 'unknown', source => ['context', 'user']}}],
    [host_bound_fields => {owner_id => {mode => 'owner', source => ['input', 'user']}}],
    [host_bound_fields => {absent => {mode => 'owner', source => ['context', 'user']}}],
    [unique_keys => {owner_name => [qw(owner_id absent)]}],
    [unique_keys => {owner_name => [qw(owner_id owner_id)]}],
    [unique_keys => {owner_name => []}],
) {
    my $raw = declaration();
    $raw->{writes}{$case->[0]} = $case->[1];
    my $result = Selecto::Domain->validate_write_contract($raw);
    ok(!$result->{valid}, "$case->[0] malformed declaration refused by portable validation");
    eval { Selecto::Domain->parse($raw) };
    is(ref($@) ? $@->code : 'untyped', 'invalid_domain', 'native parser also refuses');
}
my $raw = declaration();
$raw->{source}{columns}{name}{computed} = {operator => 'coalesce', arguments => [{field => 'id'}, {literal => 0}]};
$raw->{writes}{row_revision} = {columns => ['name']};
ok(!Selecto::Domain->validate_write_contract($raw)->{valid}, 'computed SQL fields cannot supply stored revisions');
my $spec = {columns => [qw(a b)]};
my $null = Selecto::RowRevision->token($spec, [undef, ''], ['string', 'string']);
isnt($null, Selecto::RowRevision->token($spec, ['', undef], ['string', 'string']), 'NULL and empty values keep their field identities');
is(Selecto::RowRevision->token($spec, ['1.00', '{"b":2,"a":1}'], ['decimal', 'json']),
    Selecto::RowRevision->token($spec, ['1', '{"a":1,"b":2}'], ['decimal', 'json']), 'canonical decimals and JSON object keys agree');
isnt(Selecto::RowRevision->token($spec, ['01', 'x'], ['string', 'string']),
    Selecto::RowRevision->token($spec, ['1', 'x'], ['string', 'string']), 'text identity preserves leading zeros');

my $domain = Selecto::Domain->parse(declaration());
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => TestSelecto::DBH->new)));
my $command = Selecto::Write::Command->new(operation => 'update', relation => 'panels', assignments => {name => 'x'}, predicate => Selecto::Expression->eq('id', 1));
eval { $engine->governed_write($command->row_revision('untrusted')) };
is($@->code, 'invalid_row_revision', 'a token without a domain declaration refuses');
$raw = declaration();
$raw->{writes}{row_revision} = {columns => ['name'], required => JSON::PP::true};
$domain = Selecto::Domain->parse($raw);
$engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => TestSelecto::DBH->new)));
my $fake = $command->with_metadata({__selecto_row_revision => {column => 'id', required => 0}});
eval { $engine->governed_write($fake) };
is($@->code, 'row_revision_required', 'caller metadata cannot disable required revisions');
eval { $engine->governed_write($command->row_revision({token => 'x'})) };
is($@->code, 'invalid_row_revision', 'object token refuses');
eval { $engine->governed_write($command->_with(predicate => Selecto::Expression->gt('id', 0))->row_revision('sha256:' . '0' x 64)) };
is($@->code, 'row_revision_requires_identity', 'one row token cannot govern a broad mutation');
$raw = declaration();
$raw->{writes}{host_bound_fields} = {owner_id => {mode => 'owner', source => ['context', 'user']}};
$domain = Selecto::Domain->parse($raw);
$engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => TestSelecto::DBH->new)));
eval { $engine->governed_write($command) };
is($@->code, 'missing_host_context', 'missing host identity refuses before DML');
eval { Selecto::Write::Operation->new($raw)->update({name => 'x', owner_id => 11})->filter(['id', 1])->compile(context => {user => 11}) };
is($@->code, 'host_bound_field', 'portable input cannot restate even the correct owner');

done_testing;
