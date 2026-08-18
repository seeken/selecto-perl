use 5.034;
use strict;
use warnings;
use Test::More;

use_ok('Selecto');
use_ok('Selecto::Action');
use_ok('Selecto::Action::Capability');
use_ok('Selecto::Action::Plan');
use_ok('Selecto::Action::Planner');
use_ok('Selecto::API');
use_ok('Selecto::Adapter');
use_ok('Selecto::Adapter::Registry');
use_ok('Selecto::Domain');
use_ok('Selecto::Engine');
use_ok('Selecto::Error');
use_ok('Selecto::Expression');
use_ok('Selecto::PostgreSQL');
use_ok('Selecto::Query');
use_ok('Selecto::SQL');
use_ok('Selecto::SQLite');
use_ok('Selecto::Statement');
use_ok('Selecto::Write');

done_testing;
