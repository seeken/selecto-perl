use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;

my $error;
eval {
    Selecto::Domain->parse(JSON::PP->new->encode({
        schema_version => 1,
        name => 'People',
        source => { table => 'people', fields => { id => 'integer' } },
        untrusted_never_intern => JSON::PP::true,
    }), strict => 1);
};
$error = $@;
ok(blessed($error) && $error->isa('Selecto::Error'), 'unknown key produces a stable error');
is($error->code, 'unknown_domain_key', 'unknown key fails closed');
is_deeply($error->details->{keys}, ['untrusted_never_intern'], 'error identifies rejected keys');

my $domain = TestSelecto::orders_domain();
is($domain->resolve('id')->{type}, 'integer', 'resolves a root field');
is($domain->resolve('person.name')->{type}, 'string', 'resolves a joined field');
like($domain->fingerprint, qr/\Asha256:[0-9a-f]{64}\z/, 'domain is fingerprinted');

my $canonical = Selecto::Domain->parse(JSON::PP->new->encode({
    schema_version => 1,
    domain_version => '1.0.0',
    name => 'Orders',
    source => {
        source_table => 'orders',
        primary_key => 'id',
        fields => ['id', 'person_id'],
        columns => { id => { type => 'integer' }, person_id => { type => 'integer' } },
        associations => {
            person => { queryable => 'people', owner_key => 'person_id', related_key => 'id' },
        },
    },
    schemas => {
        people => {
            source_table => 'people', primary_key => 'id', fields => ['id', 'name'],
            columns => { id => { type => 'integer' }, name => { type => 'string' } },
            associations => {},
        },
    },
    joins => { person => { type => 'inner' } },
    writes => { version => 1 },
    components => { query_params => JSON::PP::false },
}), strict => 1);
is($canonical->table, 'orders', 'canonical source table is parsed');
is($canonical->resolve('person.name')->{type}, 'string', 'canonical association fields resolve');
is($canonical->associations->{person}->join_type, 'inner', 'join metadata is applied');
is($canonical->writes->{version}, 1, 'canonical write metadata remains available to governed consumers');
is($canonical->components->{query_params}, 0, 'canonical component URL-state policy is retained');

my $bad_components = eval {
    Selecto::Domain->new(
        name => 'Bad components', table => 'bad_components', fields => { id => 'integer' },
        components => { query_params => 'sometimes' },
    );
    1;
};
ok(!$bad_components, 'component URL-state policy requires a boolean');
is($@->code, 'invalid_domain', 'invalid component policy fails through the domain boundary');

eval { $canonical->resolve('person.secret') };
$error = $@;
is($error->code, 'unknown_field', 'fields outside the contract are rejected');

done_testing;
