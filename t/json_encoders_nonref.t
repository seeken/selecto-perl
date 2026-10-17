use strict;
use warnings;
use Test::More;
use File::Find;

# Cpanel::JSON::XS refuses a plain scalar unless allow_nonref is set, where the JSON::PP it
# replaced accepted one. Selecto compares and fingerprints plain values with these encoders
# (tenant ids, filter operands, context values), so an encoder without allow_nonref breaks
# those paths with "hash- or arrayref expected". Every encoder built in lib/ and bin/ must set it.
my @problems;
find({ wanted => sub {
    return unless -f && (/\.pm\z/ || $File::Find::name =~ m{^bin/});
    open my $fh, '<', $_ or die "$_: $!";
    local $/;
    my $source = <$fh>;
    my $name = $File::Find::name;
    while ($source =~ /Cpanel::JSON::XS->new((?:->\w+(?:\([^()]*\))?)*)(->encode\(|\s*;)/g) {
        my ($chain, $tail) = ($1, $2);
        next if $chain =~ /allow_nonref/;
        next if $tail =~ /;/ && $source !~ /\$\w+->encode\(/;    # a decoder held in a variable
        push @problems, "$name: Cpanel::JSON::XS->new$chain$tail";
    }
}, no_chdir => 1 }, 'lib', 'bin');
is_deeply(\@problems, [], 'every Cpanel::JSON::XS encoder allows plain scalars');

require Cpanel::JSON::XS;
my $plain = eval { Cpanel::JSON::XS->new->canonical->encode(7) };
ok(!defined $plain, 'the library default still refuses a plain scalar (why the setting matters)');
is(Cpanel::JSON::XS->new->canonical->allow_nonref(1)->encode(7), '7', 'allow_nonref encodes it');

# The failing path itself: the engine's context comparison encodes plain tenant ids.
require Selecto::Write::Context;
my $same = eval { Selecto::Write::Context::_same(7, 7) };
ok(!$@ && $same, "Write::Context::_same compares plain scalars: " . ($@ // ''));
ok(!Selecto::Write::Context::_same(7, 8), '...and tells different ones apart');

done_testing;
