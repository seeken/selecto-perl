use 5.034;
use strict;
use warnings;

use Test::More;
use Selecto::Analytics::Pipeline ();

my $currency = {kind => 'currency', code => 'USD'};

my $percent = Selecto::Analytics::Pipeline->apply(
    [10, 30, undef], ['percent_of_total'], $currency, 'flow',
);
is_deeply [map { $_->{value} } @{$percent->{points}}], [25, 75, undef],
    'percent of total retains gaps and returns percentages';
is_deeply $percent->{unit}, {kind => 'percentage', scale => 'whole'},
    'percent of total derives a percentage unit';
is_deeply [map { $_->{raw_value} } @{$percent->{points}}], [10, 30, undef],
    'transformed points preserve raw aggregate values';

my $change = Selecto::Analytics::Pipeline->apply(
    [10, 15, 0, 20], ['percent_change'], $currency, 'flow',
);
is_deeply [map { $_->{value} } @{$change->{points}}], [undef, 50, -100, undef],
    'percent change handles its first point and a zero denominator safely';

my $indexed = Selecto::Analytics::Pipeline->apply(
    [undef, 20, 30], ['index_to_first'], $currency, 'flow',
);
is_deeply [map { $_->{value} } @{$indexed->{points}}], [undef, 100, 150],
    'indexing uses the first defined non-zero baseline';

my $cumulative = Selecto::Analytics::Pipeline->apply(
    [2, undef, 3], ['cumulative'], $currency, 'flow',
);
is_deeply [map { $_->{value} } @{$cumulative->{points}}], [2, undef, 5],
    'cumulative values preserve missing points without losing the running total';

my $average = Selecto::Analytics::Pipeline->apply(
    [2, 4, 8, undef, 10], [{type => 'moving_average', parameters => {window => 3}}],
    $currency, 'flow',
);
is_deeply [map { $_->{value} } @{$average->{points}}], [2, 3, 14 / 3, undef, 9],
    'moving average uses bounded trailing partial windows and retains current gaps';
is_deeply $average->{unit}, $currency, 'moving average preserves its input unit';

my $error = eval {
    Selecto::Analytics::Pipeline->apply(
        [1, 2], [{type => 'moving_average', parameters => {window => 500}}],
        $currency, 'flow',
    );
    '';
};
$error = $@ unless length $error;
like "$error", qr/window must be an integer from 2 through 365/,
    'moving-average windows are server-side bounded';

done_testing;
