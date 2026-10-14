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

done_testing;
