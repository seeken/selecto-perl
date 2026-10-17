use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto;
use lib 't/lib';
use TestSelecto;

sub code {
    my ($run) = @_;
    my $ok = eval { $run->(); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@";
}
sub statement {
    my ($sql, $params, $columns) = @_;
    return Selecto::Statement->new(sql=>$sql,params=>$params//[],columns=>$columns//['value'],adapter_name=>'postgresql');
}

my $fake=TestSelecto::DBH->new;
my $fake_adapter=Selecto->adapter(postgresql=>(dbh=>$fake));
ok(!$fake_adapter->bounded_stream_supported,'test handles cannot claim bounded driver streaming');
is(code(sub {$fake_adapter->stream_query(statement('SELECT 1'),bounded=>1)}),'unsupported_feature','unsupported handles refuse before preparation');
is(scalar @{$fake->prepared},0,'no query prepared after capability refusal');

subtest 'PostgreSQL server cursor lifecycle' => sub {
    my $database=$ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all=>'disposable PostgreSQL unavailable' unless $database && eval {require DBI;require DBD::Pg;1};
    my $dbh=DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    my $adapter=Selecto->adapter(postgresql=>(dbh=>$dbh));
    ok($adapter->bounded_stream_supported,'real Pg handle supports bounded streaming');
    is(code(sub {$adapter->stream_query(statement('SELECT 1'),bounded=>1,fetch_size=>0)}),'invalid_stream','fetch size remains validated');
    my $stream=$adapter->stream_query(statement('SELECT n::int, $1::numeric FROM generate_series(1,3) n',[2.50],['id','amount']),bounded=>1,fetch_size=>500);
    isa_ok($stream,'Selecto::Stream');
    is_deeply($stream->columns,['id','amount'],'cursor keeps statement columns');
    ok(!$dbh->{AutoCommit},'idle handle enters owned transaction');
    is(($dbh->selectrow_array('SHOW transaction_read_only'))[0],'on','owned transaction is read only');
    is(($dbh->selectrow_array(q{SELECT COUNT(*) FROM pg_cursors WHERE name LIKE 'selecto_stream_%'}))[0],1,'cursor exists while stream open');
    is_deeply($stream->next,[1,'2.5'],'bound parameters and native decoding survive cursor transport');
    is(code(sub {$adapter->stream_query(statement('SELECT 1'),bounded=>1)}),'stream_busy','overlapping stream on same handle refused');
    $stream->close;
    $stream->close;
    ok($stream->closed,'explicit early close is idempotent');
    is($stream->next,undef,'closed stream remains exhausted');
    ok($dbh->{AutoCommit},'early close restores idle handle');
    is(($dbh->selectrow_array(q{SELECT COUNT(*) FROM pg_cursors WHERE name LIKE 'selecto_stream_%'}))[0],0,'early close releases server cursor');
    $stream=$adapter->stream_query(statement('SELECT n FROM generate_series(1,2) n'),bounded=>1);
    is_deeply($stream->next,[1],'new stream after close works');
    is_deeply($stream->next,[2],'stream fetches final row');
    is($stream->next,undef,'exhaustion closes cursor');
    ok($dbh->{AutoCommit},'exhaustion restores idle handle');
    {
        my $abandoned=$adapter->stream_query(statement('SELECT 1'),bounded=>1);
        ok(!$abandoned->closed,'unconsumed cursor starts open');
    }
    ok($dbh->{AutoCommit},'destruction closes unconsumed cursor');
    is(code(sub {$adapter->stream_query(statement('SELECT missing_stream_column'),bounded=>1)}),'query_error','declaration error normalized');
    ok($dbh->{AutoCommit},'declaration failure restores idle handle');

    # Volatile calls are non-transactional evidence of actual evaluated rows.
    # Use a host transaction because nextval is forbidden in read-only ones.
    $dbh->do('CREATE TEMP SEQUENCE bounded_stream_probe');
    $dbh->do('CREATE TEMP TABLE bounded_stream_host (id INTEGER PRIMARY KEY)');
    for my $raw_begin (0,1) {
        $raw_begin ? $dbh->do('BEGIN') : $dbh->begin_work;
        $dbh->do('INSERT INTO bounded_stream_host VALUES (1)');
        $dbh->do('ALTER SEQUENCE bounded_stream_probe RESTART WITH 1');
        $stream=$adapter->stream_query(statement(q{SELECT nextval('bounded_stream_probe') FROM generate_series(1,1000)}),bounded=>1);
        is(($dbh->selectrow_array('SELECT is_called FROM bounded_stream_probe'))[0],0,'cursor declaration evaluates no result rows');
        is_deeply($stream->next,[1],'first fetch evaluates first result row');
        is(($dbh->selectrow_array('SELECT last_value FROM bounded_stream_probe'))[0],1,'driver does not eagerly execute remaining rows');
        $stream->close;
        is(($dbh->selectrow_array('SELECT last_value FROM bounded_stream_probe'))[0],1,'early close executes no remaining rows');
        is(($dbh->selectrow_array('SELECT COUNT(*) FROM bounded_stream_host'))[0],1,'pre-stream host work survives close');
        ok($adapter->_transaction_open,'host transaction remains open after close');
        $raw_begin ? $dbh->do('ROLLBACK') : $dbh->rollback;
        is(($dbh->selectrow_array('SELECT COUNT(*) FROM bounded_stream_host'))[0],0,'host work was never committed by stream');
    }

    # fetch_size rows per FETCH: each round trip evaluates exactly one batch.
    $dbh->begin_work;
    $dbh->do('ALTER SEQUENCE bounded_stream_probe RESTART WITH 1');
    $stream=$adapter->stream_query(statement(q{SELECT nextval('bounded_stream_probe') FROM generate_series(1,1000)}),bounded=>1,fetch_size=>3);
    is_deeply($stream->next,[1],'first batch yields its first row');
    is(($dbh->selectrow_array('SELECT last_value FROM bounded_stream_probe'))[0],3,'one FETCH evaluates fetch_size rows');
    is_deeply([map {$stream->next} 1..2],[[2],[3]],'buffered rows come from the same batch');
    is(($dbh->selectrow_array('SELECT last_value FROM bounded_stream_probe'))[0],3,'buffered rows need no further FETCH');
    is_deeply($stream->next,[4],'next batch continues in order');
    is(($dbh->selectrow_array('SELECT last_value FROM bounded_stream_probe'))[0],6,'second FETCH evaluates the next batch only');
    $stream->close;
    is($stream->next,undef,'close discards buffered rows');
    is(($dbh->selectrow_array('SELECT last_value FROM bounded_stream_probe'))[0],6,'early close executes no remaining rows');
    $dbh->rollback;

    my $batched=statement(q{SELECT n::int, (n::numeric / 4)::numeric(10,4), n % 2 = 0, TIMESTAMP '2025-03-01 10:00:00' + n * INTERVAL '1 second' FROM generate_series(1,7) n},
        [],['id','quarter','even','at']);
    my $expected=$adapter->execute_query($batched)->{rows};
    for my $size (1,3,7,50) {
        $stream=$adapter->stream_query($batched,bounded=>1,fetch_size=>$size);
        my @rows;
        while (my $row=$stream->next) { push @rows,$row; }
        is_deeply(\@rows,$expected,"fetch_size $size yields every row in order, decoded as execute_query does");
        ok($stream->closed && $dbh->{AutoCommit},"fetch_size $size exhaustion restores idle handle");
    }

    for my $host_transaction (0,1) {
        $dbh->begin_work if $host_transaction;
        $dbh->do('INSERT INTO bounded_stream_host VALUES (1)') if $host_transaction;
        $dbh->do(q{SET statement_timeout='2s'});
        my $guard=$adapter->begin_query_budget(timeout_ms=>40);
        $stream=$adapter->stream_query(statement('SELECT pg_sleep(0.2)'),bounded=>1);
        is(code(sub {$stream->next}),'query_error','server timeout during FETCH is normalized');
        ok($stream->closed,'timed-out fetch closes stream');
        $guard->close;
        is(($dbh->selectrow_array(q{SHOW statement_timeout}))[0],'2s','timeout restored after cursor transaction recovery');
        is(($dbh->selectrow_array(q{SELECT COUNT(*) FROM pg_cursors WHERE name LIKE 'selecto_stream_%'}))[0],0,'timed-out cursor released');
        if ($host_transaction) {
            is(($dbh->selectrow_array('SELECT COUNT(*) FROM bounded_stream_host'))[0],1,'timeout preserves earlier host write');
            $dbh->do('INSERT INTO bounded_stream_host VALUES (2)');
            ok($adapter->_transaction_open,'host can continue transaction after timeout');
            $dbh->rollback;
            is(($dbh->selectrow_array('SELECT COUNT(*) FROM bounded_stream_host'))[0],0,'host rollback still owns previous work');
        } else {
            ok($dbh->{AutoCommit},'timeout restores owned transaction state');
        }
    }
    {
        package Local::BoundedDecodeFailure;
        use Mojo::Base 'Selecto::PostgreSQL';
        sub _decode { die 'sensitive decoder diagnostic'; }
    }
    $dbh->begin_work;
    $dbh->do('INSERT INTO bounded_stream_host VALUES (1)');
    my $failing=Local::BoundedDecodeFailure->new(dbh=>$dbh);
    $stream=$failing->stream_query(statement('SELECT 1'),bounded=>1,canonical_values=>1);
    my $ok=eval {$stream->next;1};
    my $error=$@;
    ok(!$ok && $error->code eq 'query_error','decoder failure normalized');
    unlike("$error",qr/sensitive/,'decoder diagnostic remains private');
    ok($stream->closed,'decoder failure closes cursor');
    is(($dbh->selectrow_array('SELECT COUNT(*) FROM bounded_stream_host'))[0],1,'decoder failure preserves earlier host work');
    $dbh->rollback;

    # DBI can report errors through false returns instead of exceptions.
    $dbh->{RaiseError}=0;
    $dbh->do(q{SET statement_timeout='20ms'});
    $stream=$adapter->stream_query(statement('SELECT pg_sleep(0.1)'),bounded=>1);
    is(code(sub {$stream->next}),'query_error','nonthrowing driver failure is still normalized');
    ok($stream->closed && $dbh->{AutoCommit},'nonthrowing driver failure restores owned transaction');
    $dbh->do(q{SET statement_timeout='2s'});
    $dbh->{RaiseError}=1;
    $stream=$adapter->stream_query(statement('SELECT 1'),bounded=>1);
    $dbh->disconnect;
    is(code(sub {$stream->next}),'query_error','disconnect during stream normalized');
    ok($stream->closed,'disconnected stream releases local ownership');
};

done_testing;
