use strict;
use warnings;
use Test::More;
use Selecto::API;

# A tenant-scoped upsert on MySQL/MariaDB is refused because ON DUPLICATE KEY UPDATE matches
# any unique key. The backend cannot do it: 501 in every runtime (spec decision D10), not a
# 422 request error.
is(Selecto::API::error_status('unsupported_scope_predicate'), 501, 'a refused scoped upsert is 501');
is(Selecto::API::error_status('unsupported_feature'), 422, 'other refusals are unchanged');
is(Selecto::API::error_status('missing_tenant_scope'), 403, 'tenant scope stays 403');
is(Selecto::API::error_status('resource_not_found'), 404, 'not found stays 404');
is(Selecto::API::error_status(undef), 422, 'no code stays 422');

done_testing;
