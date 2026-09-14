use 5.034;
use strict;
use warnings;
use Test::More;
use File::Find qw(find);

open my $file, '<', 'MANIFEST' or die 'cannot read package manifest';
my %manifest = map { chomp; (split /\s+/, $_)[0] => 1 } <$file>;
close $file;
my @missing;
find({no_chdir=>1,wanted=>sub {
    push @missing, $File::Find::name if -f $_ && /\.pm\z/ && !$manifest{$File::Find::name};
}}, 'lib');
is_deeply [sort @missing], [], 'every native library module is present in the distribution manifest';
is_deeply [sort grep {!$manifest{$_}} glob('t/*.t')], [], 'every root test is present in the distribution manifest';
done_testing;
