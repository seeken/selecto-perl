use 5.034;
use strict;
use warnings;
use Test::More;

# Author test: the Changes file must have an entry for the version being released.
eval 'use Test::CPAN::Changes 0.4; 1' or plan skip_all => 'Test::CPAN::Changes required';
changes_file_ok('Changes');
done_testing;
