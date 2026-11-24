package TestDomainGuard;
use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Exporter 'import';
our @EXPORT_OK = qw(find_denied_tokens token_hash);

sub token_hash {
    return sha256_hex('selecto-denylist-v1:' . lc $_[0]);
}

sub find_denied_tokens {
    my ($text, $hashes) = @_;
    my @found;
    my $line = 0;
    for my $text_line (split /\n/, lc $text) {
        ++$line;
        my %seen;
        while ($text_line =~ /([a-z0-9_.:-]+)/g) {
            my $token = $1;
            $token =~ s/^[.:-]+|[.:-]+$//g;
            # Keep package separators intact; punctuation may wrap a name.
            for my $piece ($token, split /[.\-\/]/, $token) {
                next unless length $piece;
                my $hash = token_hash($piece);
                next unless $hashes->{$hash} && !$seen{$hash}++;
                push @found, {line => $line, hash => $hash};
            }
        }
    }
    return \@found;
}

1;
