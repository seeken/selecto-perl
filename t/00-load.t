use 5.034;
use strict;
use warnings;
use Test::More;

use_ok('Selecto');
use_ok('Selecto::Adapter');
use_ok('Selecto::Adapter::Registry');
use_ok('Selecto::Domain');
use_ok('Selecto::Engine');
use_ok('Selecto::Error');
use_ok('Selecto::Expression');
use_ok('Selecto::PostgreSQL');
use_ok('Selecto::Query');
use_ok('Selecto::Statement');
use_ok('Selecto::Write');

done_testing;
