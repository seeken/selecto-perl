use 5.034;
use utf8;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::PostgreSQL;
use lib 't/lib';
use TestPostgreSQL;
plan skip_all => 'PostgreSQL not configured' unless TestPostgreSQL->configured;
plan skip_all => 'DBD::Pg unavailable' unless eval {require DBD::Pg;1};

# PQtrace's text format changed in libpq 14. Accept the protocol message in
# either format so the sequential fallback is also checked with older libpq.
my $query_message=qr/(?:\tQuery\t|^To backend> Msg Q$)/m;
my $parse_message=qr/(?:\tParse\t|^To backend> Msg P$)/m;
my $frontend_message=qr/(?:\tF\t|^To backend> Msg [A-Z]$)/m;

# Model a handle whose driver predates both methods, with the same patched
# driver underneath so both paths exercise identical binding/conversion code.
{
    package Local::LegacyDB;
    our @ISA = ('DBI::db');
    sub can {
        return undef if $_[1] eq 'pg_pipeline' || $_[1] eq 'pg_transaction_status';
        return shift->SUPER::can(@_);
    }
}
sub statement {
    return Selecto::Statement->new(sql=>$_[0],params=>$_[1]//[],columns=>$_[2]//['n'],adapter_name=>'postgresql');
}
sub trace {
    my ($dbh,$work)=@_;
    my ($fh,$path)=tempfile(UNLINK=>1);
    $dbh->pg_server_trace($fh);
    my $result=$work->();
    $dbh->pg_server_untrace;close $fh;
    open my $in,'<',$path or die $!;
    my $text=do {local $/;<$in>};
    return ($text,$result);
}
sub error {
    my ($work)=@_;
    return undef if eval {$work->();1};
    my $e=$@;
    die $e unless blessed($e) && $e->isa('Selecto::Error');
    return $e;
}
subtest 'host execution hooks retain their dispatch' => sub {
    my $dbh=TestPostgreSQL->connect;
    my $a=Selecto::PostgreSQL->new(dbh=>$dbh);
    my $executions=0;
    $dbh->{Callbacks}={ChildCallbacks=>{execute=>sub {$executions++;return;}}};
    ok(!$a->_pg_pipeline_available,'DBI callbacks select fallback');
    is_deeply($a->execute_query(statement('SELECT ?::integer',[17]))->{rows},[[17]],'fallback returns bound result');
    is($executions,1,'real DBI execute callback is dispatched once');
    $dbh->{Callbacks}={};
    {
        local $dbh->{HandleError}=sub {return 0};
        ok(!$a->_pg_pipeline_available,'host error handler selects fallback');
    }
    {
        local $SIG{__WARN__}=sub {};
        ok(!$a->_pg_pipeline_available,'host warning handler selects fallback');
    }
    $dbh->disconnect;
};

for my $legacy (0,1) {
    subtest $legacy ? 'legacy feature fallback' : 'local status and pipeline' => sub {
        my $dbh=TestPostgreSQL->connect;
        bless $dbh,'Local::LegacyDB' if $legacy;
        my $a=Selecto::PostgreSQL->new(dbh=>$dbh);
        my ($wire,$r)=trace($dbh,sub {
            $a->execute_query(statement(q{SELECT ?::int, current_setting('transaction_read_only'), 'héllo'::text},[42],[qw(n ro text)]));
        });
        is_deeply($r->{rows}[0],[42,'on','héllo'],'bound read and read-only guard');
        is($a->_read_guard_scope,'own','read leaves idle');
        if ($a->_pg_pipeline_available) {
            like($wire,$parse_message, 'pipeline uses extended protocol');
            unlike($wire,$query_message, 'status and framing have no simple-protocol query');
            my ($local)=trace($dbh,sub {$a->_pg_transaction_status});
            unlike($local,$frontend_message,'status has no wire traffic');
        } else {
            like($wire,$query_message, 'fallback keeps sequential commands');
        }
        is(error(sub {$a->execute_query(statement('SELECT 1/0'))})->details->{sqlstate},'22012','original error SQLSTATE retained');
        is($a->_read_guard_scope,'own','read error cleanup leaves idle');
        $dbh->do('BEGIN');
        ($wire,$r)=trace($dbh,sub {$a->execute_query(statement(q{SELECT current_setting('transaction_read_only')}))});
        is($r->{rows}[0][0],'off','host transaction unchanged');
        unlike($wire,qr/(?:BEGIN|ROLLBACK)/,'no transaction control in host transaction');
        is($a->_read_guard_scope,'host','raw host BEGIN remains open');
        $dbh->do('ROLLBACK');
        $dbh->begin_work;
        $a->execute_query(statement('SELECT 1'));
        ok(!$dbh->{AutoCommit},'deferred host begin_work preserved');
        $dbh->rollback;
        $dbh->do(q{SET client_encoding='LATIN1'});
        is(error(sub {$a->execute_query(statement('SELECT 1'))})->details->{reason},'client_encoding','UTF8 refusal retained');
        $dbh->do(q{SET client_encoding='UTF8'});
        # An actual failed rollback in either transport leaves no live handle.
        my $do=DBD::Pg::db->can('do');
        my $pipeline=DBD::Pg::db->can('pg_pipeline');
        {
            no warnings 'redefine';
            local *DBD::Pg::db::do=sub {die "rollback failed\n" if $_[1] eq 'ROLLBACK';goto &$do};
            local *DBD::Pg::db::pg_pipeline=sub {
                return $pipeline->($_[0],[map {+{%$_,sql=>$_->{sql} eq 'ROLLBACK'?'SELECT 1/0':$_->{sql}}} @{$_[1]}]);
            } if $pipeline;
            ok(error(sub {$a->execute_query(statement('SELECT 1'))}),'rollback failure refuses answer');
        }
        ok(!$dbh->{Active},'rollback failure disconnects');
    };
}
subtest 'driver opt-out keeps materialized reads sequential' => sub {
    my $dbh=TestPostgreSQL->connect;
    plan skip_all => 'driver has no pipeline capability selection' unless $dbh->can('pg_can_pipeline');
    $dbh->{pg_pipeline}=0;
    my $a=Selecto::PostgreSQL->new(dbh=>$dbh);
    ok(!$a->_pg_pipeline_available,'disabled handle selects fallback');
    my ($wire,$r)=trace($dbh,sub {$a->execute_query(statement('SELECT ?::integer',[42]))});
    is_deeply($r->{rows},[[42]],'disabled pipeline read succeeds without error');
    like($wire,$query_message, 'disabled pipeline uses sequential commands');
    is($a->_read_guard_scope,'own','sequential cleanup leaves idle');
    $dbh->disconnect;
};
done_testing;
