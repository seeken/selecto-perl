use 5.034;
use strict;
use warnings;

use Test::More;
use DBI ();
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

sub exception (&) {
    my ($operation) = @_;
    my $ok = eval { $operation->(); 1 };
    return undef if $ok;
    return $@;
}

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do(q{CREATE TABLE items (id integer primary key, tenant_id integer not null, status text, total decimal not null)});
$dbh->do(q{INSERT INTO items VALUES (1, 7, 'active', 10.5)});

my $domain = Selecto::Domain->new(
    name => 'Items', table => 'items',
    fields => { id => 'integer', tenant_id => 'integer', status => 'string', total => 'decimal' },
    required_predicate => Selecto::Expression->eq('tenant_id', 7),
);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
my $query = $engine->query->select('id')->where(Selecto::Expression->all(
    Selecto::Expression->eq('id', 1), Selecto::Expression->eq('status', 'active'),
))->limit(1);
my $guarded = $engine->enforce_query(Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { status => 'approved' },
), $query);
is_deeply($engine->adapter->preview_write($guarded)->{params}, ['approved', 7, 1, 'active'],
    'effective query guard is added after assignments');

$dbh->do(q{UPDATE items SET status = 'changed' WHERE id = 1});
my $error = exception { $engine->execute_write($guarded) };
isa_ok($error, 'Selecto::Error');
is($error->code, 'cardinality_mismatch', 'intervening eligibility change is rejected');
is($dbh->selectrow_array(q{SELECT status FROM items WHERE id = 1}), 'changed', 'stale write changed nothing');

my $candidate = { id => 2, tenant_id => 7, status => 'active', total => 10.5 };
is(Selecto::QueryEnforcement::evaluate(Selecto::Expression->ne('status', 'blocked'), $candidate), 'true', 'neq evaluates');
is(Selecto::QueryEnforcement::evaluate(Selecto::Expression->lte('id', 2), $candidate), 'true', 'lte evaluates');
is(Selecto::QueryEnforcement::evaluate(Selecto::Expression->not(Selecto::Expression->eq('status', 'blocked')),
    { %$candidate, status => undef }), 'unknown', 'NOT preserves SQL unknown');

my $empty = Selecto::Engine->new(
    domain => Selecto::Domain->new(name => 'Empty', table => 'items', fields => $domain->fields),
    adapter => $engine->adapter,
);
$error = exception { $empty->enforce_query(Selecto::Write::Command->new(
    operation => 'update', relation => 'items', assignments => { status => 'x' },
), $empty->query) };
is($error->code, 'query_enforcement_requires_filter', 'empty query fails closed');

$error = exception { $engine->enforce_query(Selecto::Write::Command->new(
    operation => 'upsert', relation => 'items', assignments => { id => 1 },
), $engine->query->where(Selecto::Expression->eq('id', 1))) };
is($error->code, 'query_enforcement_unsupported_operation', 'guarded upsert fails closed');

my $evidence = Selecto::QueryEnforcement->capture(
    $domain, $engine->query->where(Selecto::Expression->eq('status', 'active')),
);
unlike($evidence->source_metadata->{predicate_fingerprint}, qr/active/, 'metadata contains only a digest');
is(Selecto::QueryEnforcement::shape($evidence->predicate), 'and(eq,eq)', 'shape is deterministic');

done_testing;
