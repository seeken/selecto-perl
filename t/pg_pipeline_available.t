use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto::PostgreSQL;

# Preserve the concrete handle identity required by the eligibility guard,
# without needing a database or an installed PostgreSQL driver. These hashes
# are not DBI handles, so they must never reach DBI's native destructor.
{
    no warnings qw(redefine once);
    local *DBI::db::DESTROY = sub {};
    local $SIG{__WARN__};
    for my $case (
        ['stock driver', {}, 0],
        ['pipeline without transaction status', {pg_pipeline => 1}, 0],
        ['old pipeline fork', {pg_pipeline => 1, pg_transaction_status => 1}, 1],
        ['optional fork capable', {pg_pipeline => 1, pg_transaction_status => 1, pg_can_pipeline => 1}, 1],
        ['optional fork unsupported', {pg_pipeline => 1, pg_transaction_status => 1, pg_can_pipeline => 0}, 0],
        ['optional fork opted out', {pg_pipeline => 1, pg_transaction_status => 1, pg_can_pipeline => 0}, 0],
    ) {
        my ($name,$methods,$expected)=@$case;
        subtest $name => sub {
            my $checks=0;
            local *DBI::db::can = sub {
                my ($self,$method)=@_;
                return exists($methods->{$method}) ? sub {} : undef;
            };
            local *DBI::db::pg_can_pipeline = sub {$checks++;return $methods->{pg_can_pipeline}};
            my $dbh=bless {},'DBI::db';
            my $adapter=Selecto::PostgreSQL->new(dbh=>$dbh);
            my $available=eval {$adapter->_pg_pipeline_available};
            is($@,'','selection does not raise');
            is(!!$available,!!$expected,$expected ? 'selects pipeline' : 'selects sequential execution');
            is($checks,exists($methods->{pg_can_pipeline}) ? 1 : 0,'only queries capability when advertised');
            if ($expected) {
                for my $hook ('Callbacks','HandleError','HandleSetErr') {
                    local $dbh->{$hook}=$hook eq 'Callbacks' ? {execute=>sub {}} : sub {};
                    ok(!$adapter->_pg_pipeline_available,"$hook still selects sequential execution");
                }
                local $SIG{__WARN__}=sub {};
                ok(!$adapter->_pg_pipeline_available,'warning handler still selects sequential execution');
            }
        };
    }
}
done_testing;
