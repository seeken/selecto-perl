use 5.034;
use strict;
use warnings;
use B ();
use Scalar::Util qw(dualvar);
use Test::More;
use JSON::PP ();
use Selecto::Limits ();
use Selecto::API::ResponsePolicy ();

# check_json's single pass must give the exact walk's byte count, and every
# refusal must be the exact walk's error, for every kind of value: strings
# (UTF-8, raw eight-bit, escapes), numbers (integers, fractions, -0,
# infinities, dual and stringified values), booleans, undef, keys, nesting,
# shared subtrees, cycles and unsupported references. No value's flags may
# change. Numbers other than integers are left to the exact walk (older
# JSON::PP types some of them differently on its first call, so warm it up).
{ my $warm = 2**53; JSON::PP->new->allow_nonref->encode($warm) for 1 .. 2; }

my $P = 'Selecto::API::ResponsePolicy';
my $FLAGS = B::SVf_IOK() | B::SVf_NOK() | B::SVf_POK() | B::SVp_IOK() | B::SVp_NOK() | B::SVp_POK() | B::SVf_UTF8();
sub flags { my ($v) = @_; return defined($v) && !ref($v) ? B::svref_2object(\$_[0])->FLAGS & $FLAGS : -1 }

sub corpus {
    my $stringified = 42; my $s1 = "$stringified";
    my $float_string = 1.5; my $s2 = "$float_string";
    my $numified = '12'; { no warnings; my $n = $numified + 0; }
    my $bad_number = '3abc'; { no warnings; my $n = $bad_number + 0; }
    my $utf8 = "caf\x{e9}"; utf8::upgrade($utf8);
    my $latin1 = "caf\x{e9}"; utf8::downgrade($latin1);
    my $neg_zero = -0.0;
    my $inf = 9**9**9;
    my @values = (
        '', 'a', 'plain text', $utf8, $latin1, "\x{20ac} euro", "\x{1F600}", "\xff\xfe\x80",
        qq{quote " and back \\ slash}, "\x00\x01\x07\x08\t\n\x0b\x0c\r\x0e\x1f", "\x7f", 'x' x 300,
        0, 1, -1, 42, -42, 18446744073709551615, -9223372036854775807, int(3.0), 1e15 + 0 == 1e15 ? 1000000 : 0,
        $stringified, $float_string, $numified, $bad_number, dualvar(5, 'five'), dualvar(7, '7'),
        '42', '-0', '1.50', '1e5', ' 7', '007', undef, JSON::PP::true, JSON::PP::false,
        ($] >= 5.036 ? (!!1, !!0) : ()),
    );
    my @numbers = (1.5, -2.25, 0.1 + 0.2, 3.0, 2**53, 1e15, 1e16, 1e20, 1e300, 1e-7, $neg_zero, $inf, -$inf,
        $inf - $inf);
    my $shared = {k => [1, 'two', undef]};
    return (
        \@values,
        {map { ("k$_" => $values[$_]) } 0 .. $#values},
        (map { [0, 'text', $_] } @numbers),
        {data => {rows => [[1, 'a', 1.5]]}},
        {"caf\x{e9}" => 1, do { my $k = "caf\x{e9}"; utf8::upgrade($k); ($k => 2) },
            "\x{20ac}" => 3, qq{q"\\} => 4, "\x00\x1f\t" => 5, '' => 6, "\xff" => 7},
        [[], {}, [[]], {a => {}}, [undef]],
        {data => {columns => [qw(id name)], rows => [map { {id => $_, name => "n$_", price => $_ / 4} } 1 .. 20]},
            ok => JSON::PP::true},
        {left => $shared, right => $shared, list => [$shared, $shared]},
        [map { [$_, "$_", $_ + 0.5, undef] } -3 .. 3],
    );
}

sub leaves {
    my ($node, $out) = @_;
    if (ref($node) eq 'HASH') { leaves($node->{$_}, $out) for sort keys %$node }
    elsif (ref($node) eq 'ARRAY') { leaves($_, $out) for @$node }
    else { push @$out, flags($node) }
    return $out;
}

sub outcome {
    my ($code) = @_;
    my $result = eval { $code->() };
    my $error = $@;
    return defined($result) ? "ok $result"
        : ref($error) ? join('|', $error->code, $error->message, JSON::PP->new->canonical->encode($error->details // {}))
        : "die $error";
}

my $big = Selecto::Limits->new(max_response_nodes => 100_000, max_response_bytes => 10_000_000,
    max_response_depth => 32);
my $index = 0;
for my $tree (corpus()) {
    $index++;
    my $before = leaves($tree, []);
    my $fast = Selecto::API::ResponsePolicy::_json_bytes_within($tree, $big);
    my $exact = $P->_check_json_exact($tree, $big);
    my $fraction = grep { $_ & (B::SVp_NOK()) } @$before;
    if ($fraction && !defined($fast)) {
        pass("tree $index has a number that is not an integer, left to the exact walk");
    } else {
        ok(defined($fast), "tree $index takes the single pass");
        is($fast, $exact, "tree $index: same JSON bytes ($exact)");
    }
    is($P->check_json($tree, $big), $exact, "tree $index: check_json gives the exact count");
    is_deeply(leaves($tree, []), $before, "tree $index: no value's flags changed");
    # At, and one below, each limit the tree reaches.
    my ($nodes, $depth, $tree_bytes) = (0, 0, 0);
    {
        my $budget = Selecto::OperationBudget->new(limits => $big, code => 'x');
        $tree_bytes = $budget->check_tree($tree, bytes_limit => 'max_response_bytes');
        $nodes = $budget->{counts}{max_response_nodes};
        my @stack = ([$tree, 0]);
        while (my $item = pop @stack) {
            my ($n, $d) = @$item;
            $depth = $d if $d > $depth;
            push @stack, map { [$_, $d + 1] } ref($n) eq 'HASH' ? values %$n : ref($n) eq 'ARRAY' ? @$n : ();
        }
    }
    for my $limit ([max_response_bytes => $exact], [max_response_bytes => $tree_bytes],
        [max_response_nodes => $nodes], [max_response_depth => $depth]) {
        my ($name, $at) = @$limit;
        for my $value ($at - 1, $at, $at + 1) {
            next if $value < 1;
            my $limits = Selecto::Limits->new(max_response_nodes => 100_000, max_response_bytes => 10_000_000,
                max_response_depth => 32, $name => $value);
            is(outcome(sub { $P->check_json($tree, $limits) }), outcome(sub { $P->_check_json_exact($tree, $limits) }),
                "tree $index: $name $value gives the exact walk's outcome");
        }
    }
}

# Anything the single pass does not take ends in the exact walk's outcome.
my $cycle = {a => [1]};
push @{$cycle->{a}}, $cycle;
for my $case (
    ['a scalar root' => 'text'], ['an undef root' => undef], ['a code reference' => {f => sub { 1 }}],
    ['a scalar reference' => [\'x']], ['a blessed hash' => [bless({}, 'Local::Thing')]],
    ['a blessed root' => bless([], 'Local::Thing')], ['a cycle' => $cycle], ['a boolean root' => JSON::PP::true],
) {
    my ($name, $tree) = @$case;
    is(Selecto::API::ResponsePolicy::_json_bytes_within($tree, $big), undef, "$name is left to the exact walk");
    is(outcome(sub { $P->check_json($tree, $big) }), outcome(sub { $P->_check_json_exact($tree, $big) }),
        "$name: same outcome");
}

# EngineHandler's adapter-result checks: the single pass over the result and
# its rows accepts exactly what the one-by-one checks accept, and anything
# else raises their error.
require Selecto::API::EngineHandler;
my $H = 'Selecto::API::EngineHandler';
my ($values) = corpus();
my @results = (
    {columns => [qw(a b c)], rows => [map { [$_, "row $_", undef] } 1 .. 30]},
    {columns => ['v'], rows => [map { [$_] } @$values]},
    {columns => [qw(id lines flag)], rows => [[1, [{sku => 'A', qty => 2}, {sku => "B\x{e9}", qty => undef}],
        JSON::PP::true], [2, [], JSON::PP::false], [3, '[{"sku":"C"}]', ($] >= 5.036 ? !!0 : 0)]]},
    {columns => ['x'], rows => [], extra => {note => 'metadata'}},
    {columns => ['x'], rows => [[1.5], [2]]},
);
$index = 0;
for my $result (@results) {
    $index++;
    my $before = leaves($result, []);
    my $cells = 0;
    for my $row (@{$result->{rows}}) {
        for my $value (@$row) {
            $cells += ref($value) ? $P->_check_json_exact($value, $big) : defined($value) ? do { my $c = $value; use bytes; length($c) } : 0;
        }
    }
    my $budget = Selecto::OperationBudget->new(limits => $big, code => 'x');
    my $tree_bytes = $budget->check_tree($result, bytes_limit => 'max_response_bytes');
    my $nodes = $budget->{counts}{max_response_nodes};
    is(outcome(sub { Selecto::API::EngineHandler::_check_result_cells($result, $big); 1 }), 'ok 1',
        "result $index passes");
    is_deeply(leaves($result, []), $before, "result $index: no value's flags changed");
    for my $limit ([max_response_bytes => $cells], [max_response_bytes => $tree_bytes],
        [max_response_nodes => $nodes], [max_response_depth => 3], [max_response_depth => 5]) {
        my ($name, $at) = @$limit;
        for my $value ($at - 1, $at, $at + 1) {
            next if $value < 1;
            my $limits = Selecto::Limits->new(max_response_nodes => 100_000, max_response_bytes => 10_000_000,
                max_response_depth => 32, $name => $value);
            is(outcome(sub { Selecto::API::EngineHandler::_check_result_cells($result, $limits); 1 }),
                outcome(sub { Selecto::API::EngineHandler::_check_result_cells_exact($result, $limits); 1 }),
                "result $index: $name $value gives the one-by-one outcome");
        }
    }
}
for my $case (
    ['rows missing' => {columns => []}], ['rows not an array' => {rows => {}}],
    ['a row that is a hash' => {rows => [{a => 1}]}], ['a row that is a scalar' => {rows => [1]}],
    ['a blessed row' => {rows => [bless([1], 'Local::Row')]}], ['a code cell' => {rows => [[sub { 1 }]]}],
    ['a result that is an array' => [[1]]],
) {
    my ($name, $result) = @$case;
    (my $exact = outcome(sub { Selecto::API::EngineHandler::_check_result_cells_exact($result, $big); 1 }))
        =~ s/ at \S+ line \d+\.\n?\z//;
    (my $got = outcome(sub { Selecto::API::EngineHandler::_check_result_cells($result, $big); 1 }))
        =~ s/ at \S+ line \d+\.\n?\z//;
    is($got, $exact, "$name: the one-by-one outcome");
}

# canonical_json skips its validation walk only for values it cannot refuse,
# and public_data's traversal check accepts exactly what check_tree accepts.
require Selecto::API;
my $canonical = JSON::PP->new->allow_nonref(1)->ascii(0)->canonical(1)->utf8(1);
my $numified_fraction = '1.5'; { no warnings; my $n = $numified_fraction + 0; }
my $numified_integer = '15'; { no warnings; my $n = $numified_integer + 0; }
$index = 0;
for my $tree (corpus(), [1.5], [-0.0], [$numified_fraction], [$numified_integer], {a => [2.25]},
    [bless({}, 'Local::Thing')], [sub { 1 }], [\'x'], ($] >= 5.036 ? ([!!0], [!!1]) : ()), 'text', 7, 7.5, undef) {
    $index++;
    my $before = defined($tree) && ref($tree) ? leaves($tree, []) : [];
    my $got = outcome(sub { Selecto::API::canonical_json($tree) });
    my $exact = outcome(sub { Selecto::API::_validate_canonical_value($tree, '$'); $canonical->encode($tree) });
    is($got, $exact, "value $index: canonical_json gives the validated outcome");
    is_deeply(defined($tree) && ref($tree) ? leaves($tree, []) : [], $before, "value $index: no value's flags changed");
    next unless ref($tree) eq 'HASH' || ref($tree) eq 'ARRAY';
    for my $value (1, 5, 50, 100_000) {
        my $limits = Selecto::Limits->new(max_response_nodes => $value, max_response_bytes => $value * 10,
            max_response_depth => 32);
        is(outcome(sub { $canonical->encode($P->public_data($tree, 0, $limits)) }),
            outcome(sub { Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')
                ->check_tree($tree, label => 'API result', bytes_limit => 'max_response_bytes', scalar_limit => undef);
                $canonical->encode(Selecto::API::ResponsePolicy::_copy($tree, 0)) }),
            "value $index: public_data at $value nodes gives check_tree's outcome");
    }
}

done_testing;
