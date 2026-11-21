use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util ();
use Selecto::Expression;
use Selecto::Limits;
use Selecto::Write;
use Selecto::Write::Capabilities;

# Write admission keeps what it charged for an expression or a limits record
# it admitted, and a later admission charges that instead of walking the
# record again. The oracle is a structurally identical twin that no walk has
# seen (blessed here by hand), which is walked in full: both must give the
# same requirements or the same refusal, at every limit's boundary.

my $api = 'Selecto::Write::Capabilities';
my $limits = Selecto::Limits->new;

sub outcome {
    my ($write) = @_;
    my $result = eval { $api->requirements($write) };
    return {result => $result} unless $@;
    my $error = $@;
    return {error => Scalar::Util::blessed($error) && $error->isa('Selecto::Error')
        ? [$error->code, $error->message] : "$error"};
}

# The same tree with every expression and limits record replaced by an
# unwalked twin.
sub bare {
    my ($value) = @_;
    my $class = Scalar::Util::blessed($value) // '';
    return bless({map { ($_ => bare($value->{$_})) } keys %$value}, $class)
        if $class eq 'Selecto::Expression' || $class eq 'Selecto::Limits';
    return [map { bare($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => bare($value->{$_})) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}

sub command {
    my (%metadata) = @_;
    return Selecto::Write::Command->new(operation => 'update', relation => 'items',
        assignments => {name => 'safe'}, metadata => \%metadata);
}

sub scope {
    return Selecto::Expression->all(
        Selecto::Expression->eq('tenant_id', 3),
        Selecto::Expression->any(Selecto::Expression->eq('status', 'open'), Selecto::Expression->eq('flag', JSON::PP::true)),
    );
}
my $expression = scope();
my $record = $limits->intersect(Selecto::Limits->new(max_collection_rows => 5));

# Admitted once, so both records are measured.
ok($api->requirements(command(scope => $expression, limits => $record)), 'records are admitted');
is_deeply(outcome(command(scope => $expression, limits => $record, again => $expression)),
    outcome(command(scope => bare($expression), limits => bare($record), again => bare($expression))),
    'measured records give the requirements a full walk gives');

# The largest filler that a full walk admits, and the outcome on each side of
# it, for the twin and for the measured records. Where two limits break, the
# walk refuses for the one it meets first, which follows hash order: the twin
# has its own hashes, so against it only the code is compared, and the exact
# refusal is compared on the very same tree, first with records no walk has
# seen and then again with whatever that first walk measured.
sub boundary {
    my ($label, $build, $high) = @_;
    my ($low) = (0);
    while ($low < $high) {
        my $mid = int(($low + $high + 1) / 2);
        if (exists outcome($build->($mid, 'twin'))->{result}) { $low = $mid } else { $high = $mid - 1 }
    }
    ok(exists outcome($build->($low, 'twin'))->{result}, "$label: the twin is admitted at the boundary");
    ok(exists outcome($build->($low + 1, 'twin'))->{error}, "$label: the twin is refused past it");
    for my $size ($low, $low + 1) {
        my $at = $size - $low;
        my ($measured, $twin) = (outcome($build->($size, 'measured')), outcome($build->($size, 'twin')));
        is_deeply($measured->{result} // $measured->{error}[0], $twin->{result} // $twin->{error}[0],
            "$label: measured records match the full walk at +$at");
        my $tree = $build->($size, 'fresh');
        my $first = outcome($tree);
        is_deeply(outcome($tree), $first, "$label: the same tree, walked again, at +$at");
    }
}

sub records {
    my ($kind, $expression, $record) = @_;
    return (bare($expression), bare($record)) if $kind eq 'twin';
    return (scope(), $record->intersect(Selecto::Limits->new)) if $kind eq 'fresh';
    return ($expression, $record);
}

boundary('nodes', sub {
    my ($size, $kind) = @_;
    my ($scope, $limit) = records($kind, $expression, $record);
    return command(scope => $scope, limits => $limit, filler => [(1) x $size]);
}, $limits->get('max_response_nodes'));

boundary('bytes', sub {
    my ($size, $kind) = @_;
    my ($scope, $limit) = records($kind, $expression, $record);
    return command(scope => $scope, limits => $limit, filler => 'x' x $size);
}, $limits->get('max_response_bytes'));

# Depth: the measured expression sits under more and more levels of arrays.
sub deep {
    my $deep = Selecto::Expression->eq('tenant_id', 3);
    $deep = Selecto::Expression->all($deep, Selecto::Expression->eq('n', $_)) for 1 .. 12;
    return $deep;
}
my $deep = deep();
ok($api->requirements(command(scope => $deep)), 'a deep expression is admitted');
boundary('depth', sub {
    my ($size, $kind) = @_;
    my $scope = $kind eq 'twin' ? bare($deep) : $kind eq 'fresh' ? deep() : $deep;
    $scope = [$scope] for 1 .. $size;
    return command(scope => $scope);
}, $limits->get('max_expression_depth'));

# A subclass is walked, never charged from a measure.
{
    package Local::Expression;
    our @ISA = ('Selecto::Expression');
}
my $sub = bless {%$expression}, 'Local::Expression';
like(outcome(command(scope => $sub))->{error}[1], qr/unsupported executable or object input/,
    'a subclass of a measured class is still refused');

# Portable (non-native) admission still refuses every record.
my $refused = eval { $api->supported({protocol_version => 1, insert => 1}, $expression); 1 } ? undef : $@;
is($refused && $refused->code, 'invalid_write', 'portable admission refuses a measured record');

done_testing;
