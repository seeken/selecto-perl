use strict;
use warnings;
use Test::More;
use File::Find;
use Selecto::Limits;

# Files that read their default limits straight from the object hash
# ($LIMITS->{name}) must only name limits that exist: a typo would be undef, not an error.
my $limits = Selecto::Limits->new;
my %used;
find({ wanted => sub {
    return unless /\.pm\z/;
    open my $fh, '<', $_ or die "$_: $!";
    local $/;
    my $source = <$fh>;
    $used{$1}++ while $source =~ /\$LIMITS->\{(\w+)\}/g;
}, no_chdir => 1 }, 'lib');

ok(scalar(keys %used) >= 3, 'direct limit reads were found');
for my $name (sort keys %used) {
    ok(eval { defined $limits->get($name) }, "limit $name exists");
}

is($limits->get('max_expression_nodes'), 10_000, 'get returns a default');
is(Selecto::Limits->new(max_expression_nodes => 7)->get('max_expression_nodes'), 7, 'get returns an override');
is(Selecto::Limits->new->tightened(max_expression_nodes => 5)->get('max_expression_depth'),
    $limits->get('max_expression_depth'), 'a tightened copy keeps every other limit');
my $error = eval { $limits->get('max_nonsense'); 1 } ? undef : $@;
ok($error && $error->code eq 'invalid_limits', 'an unknown limit is refused');

# intersect reads the two records directly. The line it replaced, a tightened()
# step per limit of the other object, is the oracle: the same limits, and the
# same refusal for a record that was not built by new() or tightened().
{
    package Local::SubLimits;
    our @ISA = ('Selecto::Limits');
}
sub reference_intersect {
    my ($self, $other) = @_;
    return $self->tightened(map { $_ => $other->get($_) } keys %{Selecto::Limits->new});
}
sub refusal { my ($work) = @_; return eval { $work->(); 1 } ? 'none' : ref($@) ? $@->code . ': ' . $@->message : "$@" }
srand(20261121);
my @names = sort keys %$limits;
for my $round (1 .. 40) {
    my @pair = map {
        my $made = Selecto::Limits->new(map { $_ => 1 + int rand 2000 } grep { rand() < 0.5 } @names);
        rand() < 0.3 ? $made->tightened(map { $_ => int rand 3 } grep { rand() < 0.2 } @names) : $made;
    } 1 .. 2;
    my $got = $pair[0]->intersect($pair[1]);
    is_deeply({%$got}, {%{reference_intersect(@pair)}}, "intersect $round holds the smaller of every limit");
    is(ref($got), 'Selecto::Limits', "intersect $round is a limits object") if $round == 1;
}
is_deeply({%{$limits->intersect($limits)}}, {%$limits}, 'limits intersected with themselves are unchanged');
is_deeply({%{bless({%$limits}, 'Local::SubLimits')->intersect(Selecto::Limits->new(max_fields => 3))}},
    {%$limits, max_fields => 3}, 'a subclass still intersects');
for my $forged ({max_fields => 'many'}, {max_fields => undef}, {max_fields => [1]}, {max_fields => -1}) {
    my $other = bless {%$limits, %$forged}, 'Selecto::Limits';
    is(refusal(sub { $limits->intersect($other) }), refusal(sub { reference_intersect($limits, $other) }),
        'a forged limit is refused as before');
    isnt(refusal(sub { $limits->intersect($other) }), 'none', 'and it is refused');
}
{
    my $short = bless {%$limits}, 'Selecto::Limits';
    delete $short->{max_fields};
    is(refusal(sub { $limits->intersect($short) }), 'invalid_limits: unknown resource limit', 'a missing limit is refused');
    is(refusal(sub { $limits->intersect({}) }), 'invalid_limits: limits must be a Selecto::Limits', 'and so is a plain hash');
}

done_testing;
