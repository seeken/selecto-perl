use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use lib 't/lib';
use TestSelecto;
use TestPostgreSQL;
use Selecto;
use Selecto::API;
use Selecto::API::RemoteQuery;
use Selecto::API::EngineHandler;
use Selecto::DateShortcut;
use Selecto::AsOf;
use Selecto::MySQLFamily;
my $x = 'Selecto::Expression';
my $zone = 'America/Denver';
sub domain {
    my %columns = (id => {type => 'integer'}, instant => {type => 'utc_datetime'},
        epoch => {type => 'epoch_datetime'}, wall => {type => 'naive_datetime'},
        legacy => {type => 'datetime'}, day => {type => 'date'},
        naive_utc => {type => 'utc_datetime', storage => 'naive_utc'},
        computed => {type => 'utc_datetime', computed => {kind => 'expression', expression => ['field', 'instant']}});
    return Selecto::Domain->parse({schema_version => 1, domain_version => '1', domain_fingerprint => 'sha256:period-on-tests', name => 'Periods',
        source => {source_table => 'period_events', primary_key => 'id',
            fields => [sort keys %columns], columns => \%columns, associations => {}}, schemas => {}, joins => {}});
}
sub engine {
    my ($backend, $dbh) = @_;
    return Selecto::Engine->new(domain => domain(), adapter => Selecto->adapter($backend => dbh => $dbh, temporary_relations => 1));
}
sub code {
    my ($run) = @_;
    return 'ok' if eval { $run->(); 1 };
    return ref($@) ? $@->code : die $@;
}
my @cases = (
    ['2026', '2026-01-01 07:00:00', '2027-01-01 07:00:00'],
    ['2026-01', '2026-01-01 07:00:00', '2026-02-01 07:00:00'],
    ['2026-01-15', '2026-01-15 07:00:00', '2026-01-16 07:00:00'],
    ['2026-01-15T10', '2026-01-15 17:00:00', '2026-01-15 18:00:00'],
    ['2026-01-15T10:30', '2026-01-15 17:30:00', '2026-01-15 17:31:00'],
    ['2026-01-15 10:30', '2026-01-15 17:30:00', '2026-01-15 17:31:00'],
    ['2026-03-08', '2026-03-08 07:00:00', '2026-03-09 06:00:00'],
    ['2026-11-01', '2026-11-01 06:00:00', '2026-11-02 07:00:00'],
    ['2026-11-01T01', '2026-11-01 07:00:00', '2026-11-01 09:00:00'],
    ['2026-03-08T01', '2026-03-08 08:00:00', '2026-03-08 09:00:00'],
    ['2026-03-08T03', '2026-03-08 09:00:00', '2026-03-08 10:00:00'],
);
sub epoch { my ($text) = @_; $text =~ s/ /T/; return (Selecto::AsOf->_parse($text))[0]->epoch }
sub stamp { DateTime->from_epoch(epoch => $_[0])->strftime('%Y-%m-%d %H:%M:%S') }
subtest 'admission' => sub {
    my $engine = engine('sqlite', TestSelecto::DBH->new);
    for my $bad (undef, '', 2026, 2026.5, [], {}, JSON::PP::true, '0000',
        '2026-13', '2026-02-30', '2026-02-29', '2026-01-15T24',
        '2026-01-15T10:60', '2026-01-15T10:30:00', '2026-01-15T10:30+02:00',
        '2026-01-15T10:30.1', "2026\n", '2026-1') {
        is code(sub { $x->on('instant', $bad) }), 'invalid_query', 'invalid/non-string period refused';
    }
    for my $good ('0001', '0099-02', '2024-02-29', '9999', '2026-12-31T23:59') {
        is code(sub {$x->on('instant', $good)}), 'ok', "accept $good";
    }
    is code(sub {$engine->compile($engine->query->select('id')->where($x->on('id', '2026')))}), 'invalid_query', 'non-temporal refused';
    for my $value ('2026-01-15T10', '2026-01-15T10:30') {
        is code(sub {$engine->compile($engine->query->select('id')->where($x->on('day', $value)))}), 'invalid_query', 'date refuses subday';
    }
    is code(sub {$x->from_filter_ast(['on', 'instant'])}), 'invalid_query', 'AST arity';
};
for my $backend (qw(postgresql mysql mariadb duckdb sqlite)) {
    subtest "$backend SQL shape" => sub {
        no warnings 'redefine';
        local *Selecto::MySQLFamily::_server_version = sub { [99,0,0] };
        my $engine = engine($backend, TestSelecto::DBH->new);
        for my $field (qw(instant epoch wall legacy day naive_utc computed)) {
            my $statement = $engine->compile($engine->query->select('id')->use_timezone($zone)->as_of('1999-01-01')->where($x->on($field, '2026-01-15')));
            like $statement->sql, qr/>=.+ AND .+ </, "$field half-open";
            unlike $statement->sql, qr/BETWEEN|AT TIME ZONE|CONVERT_TZ|DATE_TRUNC|TO_TIMESTAMP|FROM_UNIXTIME/i, "$field no column transformation";
            my @expected = $field eq 'epoch' ? (epoch('2026-01-15 07:00:00'), epoch('2026-01-16 07:00:00'))
                : $field eq 'day' ? ('2026-01-15', '2026-01-16')
                : $field eq 'wall' || $field eq 'legacy' ? ('2026-01-15 00:00:00', '2026-01-16 00:00:00')
                : ('2026-01-15 07:00:00', '2026-01-16 07:00:00');
            @expected = map { $_ . '+00:00' } @expected if ($field eq 'instant' || $field eq 'computed') && ($backend eq 'postgresql' || $backend eq 'duckdb');
            is_deeply $statement->params, \@expected, "$field correct bounds independent of as_of";
        }
        for my $field (qw(instant epoch wall legacy day naive_utc computed)) {
            my $statement = $engine->compile($engine->query->select('id')->where($x->on($field, '2026-01-15')));
            my $session = $backend eq 'postgresql' && $field =~ /^(?:instant|epoch|naive_utc|computed)$/;
            my @expected = $field eq 'day' ? ('2026-01-15', '2026-01-16')
                : $field eq 'epoch' && !$session ? (epoch('2026-01-15 00:00:00'), epoch('2026-01-16 00:00:00'))
                : ('2026-01-15 00:00:00', '2026-01-16 00:00:00');
            @expected = map { $_ . '+00:00' } @expected
                if $backend eq 'duckdb' && ($field eq 'instant' || $field eq 'computed');
            is_deeply $statement->params, \@expected, "$field default bounds";
            like $statement->sql, qr/>=.+ AND .+ </, "$field default half-open";
            if ($session) {
                like $statement->sql, qr/CAST\(\$1 AS TIMESTAMPTZ\)/, "$field session-interpreted bound";
                like $statement->sql, qr/EXTRACT\(EPOCH FROM CAST\(\$1 AS TIMESTAMPTZ\)\)/,
                    'epoch conversion stays in SQL' if $field eq 'epoch';
                like $statement->sql, qr/CAST\(\$1 AS TIMESTAMPTZ\) AT TIME ZONE 'UTC'/,
                    'UTC wall-time storage converts only bound' if $field eq 'naive_utc';
            }
            unlike $statement->sql, qr/(?:EXTRACT|CAST|TO_TIMESTAMP)\("s0"\./,
                "$field default leaves column unwrapped";
        }
    };
}
for my $backend (qw(sqlite duckdb postgresql)) {
    subtest "$backend live memory" => sub {
        my $dbh;
        if ($backend eq 'postgresql') {
            plan skip_all => 'RAM PostgreSQL not configured' unless TestPostgreSQL->configured;
            $dbh = TestPostgreSQL->connect;
        } else {
            my $driver = $backend eq 'sqlite' ? 'SQLite' : 'DuckDB';
            plan skip_all => "$driver unavailable" unless eval "require DBD::$driver; 1";
            $dbh = DBI->connect("dbi:$driver:dbname=:memory:", '', '', {RaiseError => 1, PrintError => 0});
        }
        $dbh->do("SET TIME ZONE 'Pacific/Honolulu'") if $backend eq 'postgresql' || $backend eq 'duckdb';
        my $instant = $backend eq 'sqlite' ? 'TEXT' : 'TIMESTAMPTZ';
        $dbh->do("CREATE TEMP TABLE period_events(id INTEGER PRIMARY KEY, instant $instant, epoch BIGINT, wall TIMESTAMP, legacy TIMESTAMP, day DATE, naive_utc TIMESTAMP)");
        my $engine = engine($backend, $dbh);
        my $rows = sub {
            my ($expr, $tz) = @_;
            return $engine->all($engine->query->select('id')->order_by('id')->use_timezone($tz // $zone)->as_of('2000-01-01')->where($expr))->{rows};
        };
        my $seed = sub {
            $dbh->do('DELETE FROM period_events');
            my $id = 0;
            for my $epoch (@_) {
                my $utc = stamp($epoch);
                $dbh->do('INSERT INTO period_events VALUES(?,?,?,?,?,?,?)', undef, ++$id,
                    $backend eq 'sqlite' ? $utc : "$utc+00:00", $epoch, $utc, $utc, substr($utc,0,10), $utc);
            }
        };
        for my $case (@cases) {
            my ($value, $lo, $hi) = @$case;
            my ($start, $next) = (epoch($lo), epoch($hi));
            $seed->($start-1, $start, $next-1, $next);
            for my $field (qw(instant epoch naive_utc computed)) {
                is_deeply $rows->($x->on($field, $value)), [[2],[3]], "$field $value boundaries";
            }
            is_deeply $rows->($x->from_filter_ast(['not', ['on', 'instant', $value]])), [[1],[4]], "$value generic NOT";
        }
        for my $case (['2026','2026-01-01','2027-01-01'], ['2026-01','2026-01-01','2026-02-01'], ['2026-01-15','2026-01-15','2026-01-16']) {
            my ($period,$lo,$hi) = @$case;
            $seed->(epoch("$lo 00:00:00")-86400,epoch("$lo 00:00:00"),epoch("$hi 00:00:00")-86400,epoch("$hi 00:00:00"));
            is_deeply $rows->($x->on('day',$period)), [[2],[3]], "date $period";
        }
        $seed->(map {epoch($_)} ('2026-01-14 23:59:59','2026-01-15 00:00:00','2026-01-15 23:59:59','2026-01-16 00:00:00'));
        for my $field (qw(wall legacy)) { is_deeply $rows->($x->on($field,'2026-01-15')), [[2],[3]], "$field wall day" }
        if ($backend ne 'postgresql') {
            for my $field (qw(instant epoch naive_utc computed)) {
                is_deeply $engine->all($engine->query->select('id')->order_by('id')
                    ->where($x->on($field, '2026-01-15')))->{rows}, [[2],[3]], "$field retains UTC default";
            }
        }
        $seed->(map {epoch($_)} ('2026-03-08 08:59:59','2026-03-08 09:00:00'));
        is_deeply $rows->($x->on('instant','2026-03-08T02')), [], 'missing hour';
        is_deeply $rows->($x->on('instant','2026-03-08T02:30')), [], 'missing minute';
        is_deeply $rows->($x->not($x->on('instant','2026-03-08T02'))), [[1],[2]], 'NOT missing hour';
        $seed->(map {epoch($_)} ('2026-11-01 07:29:59','2026-11-01 07:30:00','2026-11-01 07:30:59','2026-11-01 07:31:00',
            '2026-11-01 08:29:59','2026-11-01 08:30:00','2026-11-01 08:30:59','2026-11-01 08:31:00'));
        is_deeply $rows->($x->on('instant','2026-11-01T01:30')), [[2],[3],[6],[7]], 'both fold minutes only';
        $seed->(map {epoch($_)} ('2026-10-03 15:29:59','2026-10-03 15:30:00','2026-10-03 15:59:59','2026-10-03 16:00:00'));
        is_deeply $rows->($x->on('instant','2026-10-04T02'),'Australia/Lord_Howe'), [[2],[3]], 'partial skipped hour';
        $seed->(map {epoch($_)} ('2026-01-15 06:59:59','2026-01-15 07:00:00','2026-01-16 06:59:59','2026-01-16 07:00:00'));
        my $handler = Selecto::API::EngineHandler->new;
        for my $field (qw(instant epoch computed)) {
            is_deeply $handler->query($engine,{select=>['id'],timezone=>$zone,filters=>[{field=>$field,op=>'on',value=>'2026-01-15'}],order_by=>[{field=>'id'}]})->{rows}, [[2],[3]], "EngineHandler $field";
        }
        is_deeply(Selecto::API::EngineHandler->new(explorer_timezone=>$zone)->query($engine,{select=>['id'],filters=>[{field=>'instant',op=>'on',value=>'2026-01-15'}],order_by=>[{field=>'id'}]})->{rows}, [[2],[3]], 'trusted zone fallback');
        my $schema = $handler->describe_openapi(Selecto::API->new(domain=>$engine->domain,base_path=>'/api2'))->openapi_document->{components}{schemas}{SelectoFilter};
        ok grep({$_ eq 'on'} @{$schema->{properties}{op}{enum}}), 'OpenAPI enum';
        like $schema->{allOf}[0]{then}{properties}{value}{pattern}, qr/\[T \]/, 'OpenAPI pattern';
        my $host = Selecto::API::RemoteQuery->new(base_path=>'/api2',default_limit=>10);
        my $request = sub {
            my ($field,$value) = @_;
            return $host->request($engine,{method=>'POST',path=>'/api2/query',content_type=>'application/json',body=>{
                format=>'selecto.remote-query',format_version=>1,domain=>{fingerprint=>$engine->domain->fingerprint},
                query=>{select=>['id'],timezone=>$zone,filters=>[{field=>$field,op=>'on',value=>$value}],limit=>10}}});
        };
        for my $field (qw(instant epoch computed)) {
            my $response=$request->($field,'2026-01-15');
            is $response->{status},$backend eq 'duckdb' ? 501 : 200,"RemoteQuery $field status (DuckDB bounded API unsupported)";
            next if $backend eq 'duckdb';
            is_deeply(JSON::PP->new->decode($response->{body})->{data}{rows},[[2],[3]],"RemoteQuery $field rows");
        }
        for my $case (['id','2026'],['day','2026-01-15T10'],['instant','2026-02-30'],['instant',2026]) {
            my $error=code(sub {$handler->query($engine,{select=>['id'],filters=>[{field=>$case->[0],op=>'on',value=>$case->[1]}]})});
            like $error,qr/^invalid_(?:api_)?query$/, 'handler validation';
            my $response=$request->(@$case);
            if ($backend eq 'duckdb' && $case->[0] eq 'day') {
                is $response->{status},501,'DuckDB bounded API refuses before compilation';
                next;
            }
            is $response->{status},422,'remote validation status';
            is(JSON::PP->new->decode($response->{body})->{error}{code},'invalid_query','remote validation code');
        }
        $seed->(epoch('2026-03-08 02:00:00'), epoch('2026-03-08 02:59:59'), epoch('2026-03-08 03:00:00'));
        is_deeply $rows->($x->on('wall', '2026-03-08T02')), [[1],[2]], 'wall clock gap hour stays literal';
        $dbh->do('INSERT INTO period_events(id) VALUES(4)');
        is_deeply $rows->($x->not($x->on('instant', '2026-03-08T02'))), [[1],[2],[3]], 'empty range NOT excludes NULL';
        if ($backend eq 'sqlite' || $backend eq 'postgresql') {
            $dbh->do('CREATE INDEX period_instant_idx ON period_events(instant)');
            $dbh->do('SET enable_seqscan=off') if $backend eq 'postgresql';
            my $statement = $engine->compile($engine->query->select('id')->use_timezone($zone)->where($x->on('instant', '2026-01-15')));
            my $explain = $backend eq 'sqlite' ? 'EXPLAIN QUERY PLAN ' : 'EXPLAIN ';
            my $plan = $dbh->selectall_arrayref($explain . $statement->sql, undef, @{$statement->params});
            like join(' ', map {@$_} @$plan), qr/period_instant_idx/, 'database can use the raw column index';
        }
        $dbh->disconnect;
    };
}
subtest 'PostgreSQL session zone without query timezone' => sub {
    plan skip_all => 'RAM PostgreSQL not configured' unless TestPostgreSQL->configured;
    my $dbh = TestPostgreSQL->connect;
    $dbh->do("SET TIME ZONE 'America/Chicago'");
    $dbh->do('CREATE TEMP TABLE period_events(id INTEGER PRIMARY KEY, instant TIMESTAMPTZ, epoch BIGINT, wall TIMESTAMP, legacy TIMESTAMP, day DATE, naive_utc TIMESTAMP)');
    my $engine = engine('postgresql', $dbh);
    my $rows = sub {
        my ($field, $period) = @_;
        return $engine->all($engine->query->select('id')->order_by('id')->where($x->on($field, $period)))->{rows};
    };
    my $seed = sub {
        $dbh->do('DELETE FROM period_events');
        my $id = 0;
        for my $epoch (@_) {
            my $utc = stamp($epoch);
            $dbh->do('INSERT INTO period_events VALUES(?,?,?,?,?,?,?)', undef, ++$id,
                "$utc+00:00", $epoch, $utc, $utc, substr($utc, 0, 10), $utc);
        }
    };
    my @fields = qw(instant epoch naive_utc computed);
    for my $case (
        ['2026', '2026-01-01 06:00:00', '2027-01-01 06:00:00'],
        ['2026-01-15', '2026-01-15 06:00:00', '2026-01-16 06:00:00'],
        ['2026-03', '2026-03-01 06:00:00', '2026-04-01 05:00:00'],
        ['2026-03-08', '2026-03-08 06:00:00', '2026-03-09 05:00:00'],
        ['2026-11-01', '2026-11-01 05:00:00', '2026-11-02 06:00:00'],
        ['2026-01-15T10', '2026-01-15 16:00:00', '2026-01-15 17:00:00'],
        ['2026-01-15T10:30', '2026-01-15 16:30:00', '2026-01-15 16:31:00'],
    ) {
        my ($period, $lo, $hi) = @$case;
        my ($start, $next) = (epoch($lo), epoch($hi));
        $seed->($start - 1, $start, $next - 1, $next);
        for my $field (@fields) {
            is_deeply $rows->($field, $period), [[2],[3]], "$field $period Chicago boundaries";
        }
    }
    $seed->(epoch('2026-01-15 05:30:00'), epoch('2026-01-16 05:30:00'));
    for my $field (@fields) {
        is_deeply $rows->($field, '2026-01-15'), [[2]], "$field includes late Jan 15, excludes late Jan 14";
    }
    my $handler = Selecto::API::EngineHandler->new;
    for my $field (qw(instant epoch computed)) {
        is_deeply $handler->query($engine, {select => ['id'], filters => [
            {field => $field, op => 'on', value => '2026-01-15'}]})->{rows}, [[2]], "API $field uses session";
    }
    my $host = Selecto::API::RemoteQuery->new(base_path => '/api2', default_limit => 10);
    my $response = $host->request($engine, {method => 'POST', path => '/api2/query',
        content_type => 'application/json', body => {
            format => 'selecto.remote-query', format_version => 1,
            domain => {fingerprint => $engine->domain->fingerprint},
            query => {select => ['id'], filters => [{field => 'instant', op => 'on', value => '2026-01-15'}], limit => 10}}});
    is $response->{status}, 200, 'RemoteQuery without timezone status';
    is_deeply(JSON::PP->new->decode($response->{body})->{data}{rows}, [[2]], 'RemoteQuery uses session');

    # A request's own timezone parameter always wins: over the session zone
    # and over the host's trusted fallback. Row 1 is Jan 15 00:30 in New York
    # (Jan 14 in Chicago and Honolulu); row 2 is Jan 15 in Chicago/Honolulu.
    for my $field (qw(instant epoch computed)) {
        is_deeply $handler->query($engine, {select => ['id'], timezone => 'America/New_York', filters => [
            {field => $field, op => 'on', value => '2026-01-15'}]})->{rows}, [[1]],
            "API $field request timezone beats session";
    }
    my $fallback = Selecto::API::EngineHandler->new(explorer_timezone => 'Pacific/Honolulu');
    is_deeply $fallback->query($engine, {select => ['id'], filters => [
        {field => 'instant', op => 'on', value => '2026-01-15'}]})->{rows}, [[2]], 'API host fallback zone without request timezone';
    is_deeply $fallback->query($engine, {select => ['id'], timezone => 'America/New_York', filters => [
        {field => 'instant', op => 'on', value => '2026-01-15'}]})->{rows}, [[1]], 'API request timezone beats host fallback';
    my $zoned = $host->request($engine, {method => 'POST', path => '/api2/query',
        content_type => 'application/json', body => {
            format => 'selecto.remote-query', format_version => 1,
            domain => {fingerprint => $engine->domain->fingerprint},
            query => {select => ['id'], timezone => 'America/New_York',
                filters => [{field => 'instant', op => 'on', value => '2026-01-15'}], limit => 10}}});
    is $zoned->{status}, 200, 'RemoteQuery with timezone status';
    is_deeply(JSON::PP->new->decode($zoned->{body})->{data}{rows}, [[1]], 'RemoteQuery request timezone beats session');

    # Reusing the same engine/period must defer zone resolution until execution.
    my $statement = $engine->compile($engine->query->select('id')->where($x->on('instant', '2026-01-15')));
    $dbh->do("SET TIME ZONE 'UTC'");
    is_deeply $dbh->selectall_arrayref($statement->sql, undef, @{$statement->params}), [[1]], 'compiled bound follows changed session';
    $dbh->do("SET TIME ZONE 'America/Chicago'");

    # PostgreSQL resolves ambiguous timestamps to standard time; gap minutes
    # shift forward. Test this separately from the explicit-zone union logic.
    $seed->(map {epoch($_)} ('2026-11-01 06:30:00', '2026-11-01 07:30:00', '2026-11-01 07:30:59', '2026-11-01 08:00:00'));
    for my $field (@fields) {
        is_deeply $rows->($field, '2026-11-01T01'), [[2],[3]], "$field session fold hour";
        is_deeply $rows->($field, '2026-11-01T01:30'), [[2],[3]], "$field session fold minute";
    }
    $seed->(map {epoch($_)} ('2026-03-08 08:29:59', '2026-03-08 08:30:00', '2026-03-08 08:30:59', '2026-03-08 08:31:00'));
    for my $field (@fields) {
        is_deeply $rows->($field, '2026-03-08T02'), [], "$field session gap hour";
        is_deeply $rows->($field, '2026-03-08T02:30'), [[2],[3]], "$field session gap minute shifts forward";
    }

    my ($today, $start, $next) = $dbh->selectrow_array(q{SELECT CURRENT_DATE::text,
        EXTRACT(EPOCH FROM CURRENT_DATE::timestamptz)::bigint,
        EXTRACT(EPOCH FROM (CURRENT_DATE + 1)::timestamptz)::bigint});
    $seed->($start - 1800, $start, $next - 1800, $next);
    for my $field (@fields) {
        my $shortcut = $engine->all($engine->query->select('id')->order_by('id')
            ->where($x->date_shortcut($field, 'today')))->{rows};
        is_deeply $shortcut, [[2],[3]], "$field today uses Chicago day";
        is_deeply $rows->($field, $today), $shortcut, "$field on and date_shortcut agree";
    }
    $seed->(map {epoch($_)} ('2026-01-14 23:59:59', '2026-01-15 00:00:00', '2026-01-15 23:59:59', '2026-01-16 00:00:00'));
    for my $field (qw(day wall legacy)) {
        is_deeply $rows->($field, '2026-01-15'), [[2],[3]], "$field remains literal without timezone";
    }
    $dbh->do('SET enable_seqscan=off');
    for my $field (qw(instant epoch naive_utc)) {
        $dbh->do("CREATE INDEX period_${field}_session_idx ON period_events($field)");
        my $bound = $engine->compile($engine->query->select('id')->where($x->on($field, '2026-01-15')));
        my $plan = $dbh->selectall_arrayref('EXPLAIN ' . $bound->sql, undef, @{$bound->params});
        like join(' ', map {@$_} @$plan), qr/Index Cond:.*>=.*</, "$field session bounds are index conditions";
    }
    $dbh->disconnect;
};
done_testing;
