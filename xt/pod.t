use 5.034;
use strict;
use warnings;
use Test::More;

# Author test: run with `prove -l xt` before a release.
eval 'use Test::Pod 1.52; 1' or plan skip_all => 'Test::Pod 1.52 required';
all_pod_files_ok(all_pod_files(grep { -d } qw(lib bin)));
