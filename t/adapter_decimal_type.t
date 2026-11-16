use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::SQL;

# Third-party adapters use this public helper as a values-column callback.
my $adapter = bless {}, 'Selecto::SQL';
is($adapter->values_decimal_type(['000001.234500', undef, '-' . '1' . ('0' x 33) . '.1']),
    'DECIMAL(38,4)', 'column type preserves the widest integer and fractional portions');
my $ok = eval { $adapter->values_decimal_type(['10000000000000000000000000000000000000', '0.01']); 1 };
ok(!$ok, 'combined column precision overflows before SQL execution');
is($@->code, 'unsupported_precision', 'overflow is a portable precision refusal');
done_testing;
