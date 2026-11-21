use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Error;
use Selecto::Expression;
use Selecto::Limits;
use Selecto::OperationBudget;

# An expression is measured when it is built, and a constructor that composes
# it into a larger expression charges that measure instead of walking it
# again. The oracle is check_tree on a structurally identical tree of
# expressions that carry no measure (blessed here by hand), which walks every
# node: both must accept the same trees and leave the same counters. A tree
# that breaks two limits is refused for whichever the walk meets first, which
# follows hash order, so the exact refusal is compared with check_tree on the
# very same tree and only the code with the twin's.

sub outcome {
    my ($run) = @_;
    my @result = eval { $run->() };
    return {result => \@result} unless $@;
    my $error = $@;
    return {error => ref($error) && $error->isa('Selecto::Error')
        ? [$error->code, $error->message, $error->details] : "$error"};
}

# The same tree with every expression replaced by an unmeasured twin.
sub bare {
    my ($value) = @_;
    return [map { bare($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => bare($value->{$_})) } keys %$value} if ref($value) eq 'HASH';
    return bless({kind => $value->{kind}, arguments => bare($value->{arguments}),
        alias_name => $value->{alias_name}}, 'Selecto::Expression') if ref($value) eq 'Selecto::Expression';
    return $value;
}

my @options = (label => 'expression arguments', allowed_classes => ['Selecto::Expression']);
sub compare {
    my ($label, $arguments, %limits) = @_;
    my $limits = Selecto::Limits->new(%limits);
    my $composed = Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query');
    my $walked = Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query');
    my $got = outcome(sub { ($composed->check_composed_tree($arguments, @options))[0] });
    my $expected = outcome(sub { scalar $walked->check_tree(bare($arguments), @options) });
    if ($expected->{error}) {
        my $same = outcome(sub { scalar Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query')
            ->check_tree($arguments, @options) });
        is_deeply($got, $same, "$label: the refusal of the full walk");
        is($got->{error}[0], $expected->{error}[0], "$label: refused like its unmeasured twin");
    } else {
        is_deeply($got, $expected, "$label: same bytes");
        is_deeply($composed->{counts}, $walked->{counts}, "$label: same counters");
    }
    return $expected;
}

my $E = 'Selecto::Expression';
my @leaves = (sub { $E->field('status') }, sub { $E->literal('é' x 3) }, sub { $E->literal(42) },
    sub { $E->literal(JSON::PP::true) }, sub { $E->literal(undef) }, sub { $E->field('total')->as('t') });
sub random_tree {
    my ($depth) = @_;
    return $leaves[int rand @leaves]->() if $depth <= 0 || rand() < 0.2;
    my $pick = int rand 5;
    return $E->new('eq', random_tree($depth - 1), random_tree($depth - 1)) if $pick == 0;
    return $E->new('and', [map { random_tree($depth - 1) } 1 .. 1 + int rand 3]) if $pick == 1;
    return $E->new('in', $E->field('id'), [1 .. 1 + int rand 5]) if $pick == 2;
    return $E->new('case', {when => [random_tree($depth - 1)], else => random_tree($depth - 1)}) if $pick == 3;
    return random_tree($depth - 1)->as('alias' . int rand 100);
}

srand(20261121);
my ($accepted, $refused) = (0, 0);
for my $round (1 .. 150) {
    my $arguments = [map { random_tree(1 + int rand 5) } 1 .. 1 + int rand 3];
    my $free = Selecto::OperationBudget->new;
    my ($bytes, $nodes, $depth) = $free->check_composed_tree($arguments, @options);
    # Each limit at the tree's own size, one below it, and far above it.
    for my $limits ({}, {max_expression_nodes => $nodes}, {max_expression_nodes => $nodes - 1},
        {max_state_bytes => $bytes}, {max_state_bytes => $bytes - 1},
        {max_expression_depth => $depth}, {max_expression_depth => $depth - 1},
        {max_expression_nodes => $nodes - 1, max_state_bytes => $bytes - 1, max_expression_depth => $depth - 1}) {
        next if grep { $_ < 1 } values %$limits;
        my $expected = compare("tree $round (" . join(',', map { "$_=$limits->{$_}" } sort keys %$limits) . ')',
            $arguments, %$limits);
        $expected->{error} ? $refused++ : $accepted++;
    }
}
ok($accepted > 300 && $refused > 300, "both outcomes were exercised ($accepted accepted, $refused refused)");

# A budget that already holds counts keeps adding to them.
{
    my $tree = [$E->eq('id', 1), $E->all([$E->eq('a', 'b')])];
    my @budgets = map { Selecto::OperationBudget->new(code => 'invalid_query') } 1 .. 2;
    $budgets[0]->check_composed_tree($tree, @options) for 1 .. 3;
    $budgets[1]->check_tree(bare($tree), @options) for 1 .. 3;
    is_deeply($budgets[0]{counts}, $budgets[1]{counts}, 'repeated checks accumulate alike');
}

# Shapes the measuring walk hands to the full walk: its refusals are the old ones.
{
    my @cycle = (1); push @cycle, \@cycle;
    my %refusals = (
        cycle => [\@cycle],
        'unsupported reference' => [sub { 1 }],
        'foreign object' => [bless({}, 'Some::Other::Class')],
        'expression subclass' => [bless({kind => 'field', arguments => ['id'], alias_name => undef}, 'My::Expression')],
    );
    for my $name (sort keys %refusals) {
        my $got = outcome(sub { Selecto::OperationBudget->new(code => 'invalid_query')
            ->check_composed_tree($refusals{$name}, @options) });
        my $expected = outcome(sub { Selecto::OperationBudget->new(code => 'invalid_query')
            ->check_tree($refusals{$name}, @options) });
        ok($expected->{error}, "$name is refused");
        is_deeply($got, $expected, "$name: the same refusal");
    }
}

# The constructors themselves, under a construction limit a nested tree meets.
{
    my $inner = $E->all([map { $E->eq("f$_", $_) } 1 .. 20]);
    my %refused;
    for my $nodes_limit (41, 60, 200, 201, 202, 203, 204, 300) {
        local $Selecto::Expression::_CONSTRUCTION_LIMITS = Selecto::Limits->new(max_expression_nodes => $nodes_limit);
        my $got = outcome(sub { ref $E->new('not', $inner) });
        my $expected = outcome(sub { ref $E->new('not', bare($inner)) });
        is_deeply($got, $expected, "constructor under max_expression_nodes $nodes_limit");
        $refused{$nodes_limit} = $expected->{error} ? 1 : 0;
    }
    is_deeply([@refused{41, 300}], [1, 0], 'the constructor limit was met and cleared');
    my $alias = $inner->as('first')->as('second');
    is_deeply(outcome(sub { Selecto::OperationBudget->new->check_composed_tree([$alias], @options) })->{result}[0],
        scalar(Selecto::OperationBudget->new->check_tree([bare($alias)], @options)), 'an alias of an alias keeps its measure');
}

done_testing;
