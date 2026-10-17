use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto::Write::Operation;

my $domain = {source => {source_table => 'items', fields => ['id', 'name']},
    writes => {operations => {insert => {enabled => 1}}, fields => {name => {insertable => 1}}}};
my $base = Selecto::Write::Operation->new($domain);
my $values = {name => 'one'};
my $operation = $base->insert($values)->filter(['id', 7])->with_tenant({tenant_id => 'tenant-a'})
    ->returning(['id'])->expected_cardinality(['exactly', 1]);
$domain->{writes}{operations}{insert}{enabled} = 0;
$values->{name} = 'changed';
is $operation->snapshot->{domain}{writes}{operations}{insert}{enabled}, 1, 'domain is an independent authored snapshot';
is $operation->snapshot->{values}{name}, 'one', 'values are independent';
ok !exists($base->snapshot->{type}), 'builders preserve prior operation';
is_deeply $operation->snapshot->{filters}, [['id', 7]], 'filters preserve ordering';
my $snapshot = $operation->snapshot;
$snapshot->{values}{name} = 'mutated getter';
$snapshot->{tenant}{tenant_id} = 'tenant-b';
is $operation->snapshot->{values}{name}, 'one', 'getter cannot mutate operation values';
is $operation->snapshot->{tenant}{tenant_id}, 'tenant-a', 'getter cannot replace trusted tenant';
my $pairs = $base->insert([['name', 'one'], ['name', 'two']]);
is_deeply $pairs->snapshot->{values}, [['name', 'one'], ['name', 'two']], 'ordered pairs retain ambiguity for compiler rejection';

sub refuses {
    my ($label, $code, $run) = @_;
    my $ok = eval { $run->(); 1 };
    my $error = $@;
    ok !$ok, $label;
    ok blessed($error) && $error->isa('Selecto::Error'), "$label is typed";
    is $error->code, $code, "$label stable code" if blessed($error) && $error->isa('Selecto::Error');
}
my $token = 0;
refuses 'forged scalar operation', 'invalid_write_operation', sub { (bless \$token, 'Selecto::Write::Operation')->snapshot };
refuses 'forged hash operation', 'invalid_write_operation', sub { (bless {}, 'Selecto::Write::Operation')->snapshot };
refuses 'callback in unused metadata', 'invalid_query_contract', sub {
    Selecto::Write::Operation->new({%{$base->snapshot->{domain}}, unrelated => {callback => sub { die 'must never run' }}});
};
my $cycle = {}; $cycle->{self} = $cycle;
refuses 'cyclic metadata', 'invalid_query_contract', sub { $base->insert($cycle) };
refuses 'unknown operation', 'invalid_write_operation', sub { $base->operation('truncate', {}) };
refuses 'invalid filters container', 'invalid_write_filter', sub { $base->filters({id => 1}) };
{
    package Local::FalseWriteInput;
    our $HOOKS = 0;
    use overload bool => sub { ++$HOOKS; 0 }, '""' => sub { ++$HOOKS; 'name' }, fallback => 1;
}
my $false_input = bless {}, 'Local::FalseWriteInput';
refuses 'false-valued class in values', 'invalid_query_contract', sub { $base->insert({name => $false_input}) };
is $Local::FalseWriteInput::HOOKS, 0, 'rejected without boolean or string hooks';
my $real = $base->insert({name => 'real'});
bless $real, 'Local::FalseWriteInput';
refuses 'reblessed genuine operation', 'invalid_write_operation', sub { Selecto::Write::Operation::snapshot($real) };
is $Local::FalseWriteInput::HOOKS, 0, 'identity refusal never calls hooks';
done_testing;
