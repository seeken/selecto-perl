use 5.034;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::PostgreSQL;
use lib 't/lib';
use TestPostgreSQL;

plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless TestPostgreSQL->configured;
plan skip_all => 'DBD::Pg required' unless eval { require DBD::Pg; 1 };
sub statement {
    return Selecto::Statement->new(sql=>$_[0],params=>$_[1]//[],columns=>$_[2]//['n'],adapter_name=>'postgresql');
}
sub failure {
    my ($work)=@_;
    return undef if eval {$work->();1};
    my $error=$@;
    die 'expected typed Selecto error' unless blessed($error) && $error->isa('Selecto::Error');
    return $error;
}
sub trace {
    my ($dbh,$work)=@_;
    my ($fh,$path)=tempfile(UNLINK=>1);
    $dbh->pg_server_trace($fh);
    my $ok=eval {$work->();1};my $error=$@;
    $dbh->pg_server_untrace;close $fh;
    open my $read,'<',$path or die $!;
    my $text=do {local $/;<$read>};close $read;
    die $error unless $ok;
    return $text;
}

subtest 'local encoding refresh is current and preserves every driver mode' => sub {
    for my $mode (-1,0,1) {
        my $dbh=TestPostgreSQL->connect(pg_enable_utf8=>$mode);
        my $a=Selecto::PostgreSQL->new(dbh=>$dbh);
        my $protocol=trace($dbh,sub {$a->_pg_require_utf8});
        unlike($protocol,qr/\tF\t/,"mode $mode: UTF8 check sends nothing");
        is($dbh->{pg_enable_utf8},$mode,"mode $mode: mode preserved after acceptance");
        is($dbh->{pg_utf8_flag},$mode==0?0:1,"mode $mode: result-decoding flag preserved");
        $dbh->do(q{SET client_encoding='LATIN1'});
        $protocol=trace($dbh,sub {
            my $error=failure(sub {$a->_pg_require_utf8});
            is($error->details->{reason},'client_encoding',"mode $mode: change after acceptance is caught");
        });
        unlike($protocol,qr/\tF\t/,"mode $mode: refusal sends nothing");
        is($dbh->{pg_enable_utf8},$mode,"mode $mode: mode preserved after refusal");
        is($dbh->{pg_utf8_flag},$mode==1?1:0,"mode $mode: forced decoding is preserved, automatic decoding is refreshed");
        $dbh->do(q{SET client_encoding='UTF8'});
        ok(!failure(sub {$a->_pg_require_utf8}),"mode $mode: restored encoding works");
        $dbh->begin_work;
        $dbh->do(q{SET LOCAL client_encoding='LATIN1'});
        is(failure(sub {$a->_pg_require_utf8})->details->{reason},'client_encoding',"mode $mode: SET LOCAL is caught");
        $dbh->rollback;
        ok(!failure(sub {$a->_pg_require_utf8}),"mode $mode: rollback ParameterStatus is current");
        $dbh->disconnect;
        is(failure(sub {$a->_pg_require_utf8})->code,'transaction_state_unsafe',"mode $mode: disconnected handles refuse before touching libpq");
    }
};

my $dbh=TestPostgreSQL->connect;
my $observer=TestPostgreSQL->connect;
my $a=Selecto::PostgreSQL->new(dbh=>$dbh);
$dbh->do('DROP TABLE IF EXISTS selecto_rt_read_items');
$dbh->do('CREATE TABLE selecto_rt_read_items (id integer primary key, name text)');
$dbh->do(q{INSERT INTO selecto_rt_read_items VALUES (1,'baseline')});
END {eval {$observer->do('DROP TABLE IF EXISTS selecto_rt_read_items')} if $observer}
my $read=statement('SELECT id FROM selecto_rt_read_items ORDER BY id',[],['id']);
subtest 'ordinary reads use a read-only transaction and restore session state' => sub {
    my ($application)=$dbh->selectrow_array('SHOW application_name');
    my $result=$a->execute_query(statement(q{SELECT current_setting('transaction_read_only'), set_config('application_name','rt changed',false)},[],[qw(ro app)]));
    is($result->{rows}[0][0],'on','the read actually runs read-only');
    is($dbh->selectrow_array('SHOW application_name'),$application,'a statement session change is rolled back');
    ok($dbh->{AutoCommit},'driver AutoCommit is unchanged');
    is($dbh->pg_ping,1,'the server is idle');
    my $error=failure(sub {$a->execute_query(statement(q{WITH w AS (INSERT INTO selecto_rt_read_items VALUES(9,'bad') RETURNING id) SELECT id FROM w}))});
    is($error->details->{category},'read_only_transaction','a statement cannot write the table');
    is($observer->selectrow_array('SELECT count(*) FROM selecto_rt_read_items'),1,'the refused write is absent');
    is_deeply($a->execute_query($read)->{rows},[[1]],'a later read succeeds');
};
subtest 'raw host BEGIN is handled without ending or changing the host transaction' => sub {
    for my $begin ('BEGIN','BEGIN ISOLATION LEVEL REPEATABLE READ') {
        $dbh->do($begin);
        $dbh->do(q{INSERT INTO selecto_rt_read_items VALUES(2,'host')});
        my $result=$a->execute_query($read);
        is_deeply($result->{rows},[[1],[2]],"$begin: sees host writes");
        is($dbh->pg_ping,3,"$begin: host transaction remains open");
        is($observer->selectrow_array('SELECT count(*) FROM selecto_rt_read_items'),1,"$begin: host write stays uncommitted");
        $dbh->do(q{SET LOCAL client_encoding='LATIN1'});
        is(failure(sub {$a->execute_query($read)})->details->{reason},'client_encoding',"$begin: encoding change after the first read refuses");
        is($dbh->pg_ping,3,"$begin: encoding refusal leaves the host transaction healthy");
        $dbh->do('ROLLBACK');
        is_deeply($a->execute_query($read)->{rows},[[1]],"$begin: rollback restores encoding and removes host write");
    }
};
subtest 'a host encoding change between cursor fetches is caught' => sub {
    $dbh->begin_work;
    my $s=$a->stream_query(statement('SELECT n FROM generate_series(1,3) n'),bounded=>1,fetch_size=>1);
    is_deeply($s->next,[1],'first row reads');
    $dbh->do(q{SET LOCAL client_encoding='LATIN1'});
    is(failure(sub {$s->next})->details->{reason},'client_encoding','next fetch refuses changed encoding');
    is($dbh->pg_ping,3,'stream refusal leaves host transaction healthy');
    $dbh->rollback;
};
subtest 'statement timeout is preserved and failure cleanup leaves the connection usable' => sub {
    $dbh->do('SET statement_timeout=25');
    my $error=failure(sub {$a->execute_query(statement('SELECT pg_sleep(0.2)'))});
    is($error->details->{category},'query_canceled','host timeout remains in force');
    is($dbh->selectrow_array('SHOW statement_timeout'),'25ms','host timeout is restored after rollback');
    $dbh->do('SET statement_timeout=0');
    is_deeply($a->execute_query($read)->{rows},[[1]],'connection recovers after timeout');
};
subtest 'owned reads and cursors do not inherit deferrable snapshot waits' => sub {
    my $writer=TestPostgreSQL->connect;
    my $owned=TestPostgreSQL->connect;
    my $adapter=Selecto::PostgreSQL->new(dbh=>$owned);
    $writer->do('BEGIN ISOLATION LEVEL SERIALIZABLE');
    $writer->do(q{UPDATE selecto_rt_read_items SET name='pending' WHERE id=1});
    $owned->do(q{SET default_transaction_isolation='serializable'});
    $owned->do('SET default_transaction_deferrable=on');
    $owned->do('SET statement_timeout=1000');
    my $settings=statement(q{SELECT current_setting('transaction_read_only'),current_setting('transaction_deferrable')},[],[qw(ro def)]);
    is_deeply($adapter->execute_query($settings)->{rows},[['on','off']],'ordinary read answers with nondeferrable snapshot');
    my $stream=$adapter->stream_query($settings,bounded=>1,fetch_size=>1);
    is_deeply($stream->next,['on','off'],'cursor answers with nondeferrable snapshot');
    $stream->close;
    is($owned->selectrow_array('SHOW default_transaction_deferrable'),'on','host default is preserved');
    is($owned->selectrow_array('SHOW statement_timeout'),'1s','host timeout is preserved');
    $writer->do('ROLLBACK');
    $_->disconnect for $owned,$writer;
};
subtest 'failed rollback closes the ordinary read connection' => sub {
    my $owned=TestPostgreSQL->connect;
    my $adapter=Selecto::PostgreSQL->new(dbh=>$owned);
    my $do=DBD::Pg::db->can('do');
    {
        no warnings 'redefine';
        local *DBD::Pg::db::do=sub {die "refused rollback\n" if $_[1] eq 'ROLLBACK';goto &$do};
        ok(failure(sub {$adapter->execute_query($read)}),'cleanup failure is typed');
    }
    ok(!$owned->{Active},'an unended read connection is closed');
};
$dbh->disconnect;
$observer->do('DROP TABLE selecto_rt_read_items');
$observer->disconnect;
done_testing;
