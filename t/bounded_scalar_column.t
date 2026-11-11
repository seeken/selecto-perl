use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use Selecto;
use Selecto::BoundedQuery;
use Selecto::SQLite;
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };

# A canned page carries its total on its rows (scalar_column_statement). Under
# explicit read tenant policy the combined bundle needs the same prepared read
# evidence as its parts, or bounded execution refuses it.
{
    package Local::TotalSQLite;
    our @ISA = ('Selecto::SQLite');
    sub scalar_column_statement {
        my ($self, $rows, $scalar, $alias) = @_;
        return Selecto::Statement->new(
            sql => 'SELECT selecto_rows.*, (' . $scalar->sql . ') AS ' . $self->quote_identifier($alias)
                . ' FROM (' . $rows->sql . ') AS selecto_rows',
            params => [@{$scalar->params}, @{$rows->params}],
            columns => [@{$rows->columns}, $alias],
            adapter_name => $rows->adapter_name,
        );
    }
}

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
$db->do(q{CREATE TABLE accounts(id INTEGER PRIMARY KEY, name TEXT, tenant_id TEXT)});
$db->do(q{INSERT INTO accounts VALUES(1,'Ada','tenant-a'),(2,'Lin','tenant-b'),(3,'Bo','tenant-a')});
my $adapter = Local::TotalSQLite->new(dbh => $db);
my $raw = {name => 'Accounts', tenant_required => JSON::PP::true,
    source => {source_table => 'accounts', primary_key => 'id', fields => [qw(id name tenant_id)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, tenant_id => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {}};
sub engine { Selecto::Engine->new(domain => Selecto::Domain->parse(JSON::PP->new->decode(JSON::PP->new->encode($raw))), adapter => $adapter) }
sub code { my ($run) = @_; return eval { $run->(); 1 } ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@"; }

my $engine = engine()->with_tenant({tenant_id => 'tenant-a'})->apply_tenant_scope;
my $rows = Selecto::BoundedQuery->prepare($engine, $engine->query->select('id')->order_by('id'));
my $total = Selecto::BoundedQuery->prepare($engine,
    $engine->query->select(Selecto::Expression->count_distinct('id')->as('total')));

my $combined = Selecto::BoundedQuery->prepare_scalar_column($engine, $rows, $total, 'selecto_total');
is_deeply(Selecto::BoundedQuery->execute($engine, $combined)->{rows}, [[1, 2], [3, 2]],
    'a combined bundle runs under explicit read tenant policy, its total on every row');
is(code(sub { Selecto::BoundedQuery->execute($engine,
    {%$rows, statement => $adapter->scalar_column_statement($rows->{statement}, $total->{statement}, 'selecto_total')}) }),
    'domain_modified_after_configuration', 'a hand-built combination carries no read evidence');

my $other = engine()->with_tenant({tenant_id => 'tenant-b'})->apply_tenant_scope;
my $other_total = Selecto::BoundedQuery->prepare($other,
    $other->query->select(Selecto::Expression->count_distinct('id')->as('total')));
is(code(sub { Selecto::BoundedQuery->prepare_scalar_column($engine, $rows, $other_total, 'selecto_total') }),
    'domain_modified_after_configuration', 'another tenant context cannot supply the scalar');
is(code(sub { Selecto::BoundedQuery->prepare_scalar_column($other, $rows, $other_total, 'selecto_total') }),
    'domain_modified_after_configuration', 'nor can it adopt the rows');

my $plain = Selecto::Engine->new(domain => Selecto::Domain->parse(do { my %r = %$raw; delete $r{tenant_required}; \%r }),
    adapter => $adapter);
my $plain_rows = Selecto::BoundedQuery->prepare($plain, $plain->query->select('id')->order_by('id'));
my $plain_total = Selecto::BoundedQuery->prepare($plain,
    $plain->query->select(Selecto::Expression->count_distinct('id')->as('total')));
is_deeply(Selecto::BoundedQuery->execute($plain,
    Selecto::BoundedQuery->prepare_scalar_column($plain, $plain_rows, $plain_total, 'selecto_total'))->{rows},
    [[1, 3], [2, 3], [3, 3]], 'without read tenant policy the combination runs as before');

done_testing;
