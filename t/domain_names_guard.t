use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestDomainGuard qw(find_denied_tokens token_hash);

my $hash_path = 't/data/denylist.sha256';
open my $fh, '<', $hash_path or die "Cannot read hash file: $!";
chomp(my @hashes = <$fh>);
close $fh;
ok @hashes && !grep(!/\A[0-9a-f]{64}\z/, @hashes), 'hash file contains lowercase SHA-256 values';
my %hashes = map { $_ => 1 } @hashes;

subtest 'in-memory planted token' => sub {
    my $invented = 'synthetic_sentinel_42';
    my $hash = token_hash($invented);
    my %planted = (%hashes, $hash => 1);
    is_deeply find_denied_tokens("ordinary text\n$invented", \%planted),
        [{line => 2, hash => $hash}], 'checker catches the planted token and line';
    for my $text ("($invented)", "prefix.$invented-suffix", "path/$invented.pm") {
        is_deeply find_denied_tokens($text, \%planted),
            [{line => 1, hash => $hash}], 'punctuation, dotted names and paths are checked';
    }
    is_deeply find_denied_tokens(uc($invented), \%planted),
        [{line => 1, hash => $hash}], 'matching is case insensitive';
    is_deeply find_denied_tokens("${invented}::Base ${invented}_suffix", \%planted),
        [], 'package separators and longer identifiers stay intact';
    is_deeply find_denied_tokens(".:-$invented-:.", \%planted),
        [{line => 1, hash => $hash}], 'edge punctuation is stripped';
};

subtest 'CSS prefixes are checked in memory' => sub {
    my $prefix = 'syntheticbrand42';
    my $hash = token_hash($prefix);
    my %planted = (%hashes, $hash => 1);
    for my $css ("--$prefix-name", ".$prefix-name", "var(--$prefix-name)") {
        is_deeply find_denied_tokens($css, \%planted),
            [{line => 1, hash => $hash}], 'checker catches an embedded CSS prefix';
    }
};

SKIP: {
    # Release tarballs have no Git metadata. The self-tests above still run there.
    skip 'repository scan requires a Git checkout', 2 unless -e '.git';

    # Include new files too, so the guard works before changes are staged.
    open my $git, '-|', 'git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'
        or die "Cannot list repository files: $!";
    my @paths = do { local $/ = "\0"; map { chomp; $_ } <$git> };
    close $git or die "Cannot list repository files\n";
    ok @paths, 'repository files were enumerated';
    my @violations;
    for my $path (@paths) {
        next if $path eq $hash_path;
        push @violations, map { "$path:$_->{line}: $_->{hash} (path)" }
            @{find_denied_tokens($path, \%hashes)};
        next unless -f $path;
        open my $file, '<:raw', $path or die "Cannot read repository file: $!";
        my $text = do { local $/; <$file> } // '';
        close $file;
        next if $text =~ /\0/ || -B $path;
        push @violations, map { "$path:$_->{line}: $_->{hash}" }
            @{find_denied_tokens($text, \%hashes)};
    }
    is_deeply \@violations, [], 'repository paths and text contain no denied tokens';
}
done_testing;
