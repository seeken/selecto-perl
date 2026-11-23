use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Mojo::URL ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::AsOf;
use Selecto::BoundedQuery;
use Selecto::API;
use Selecto::API::RemoteQuery;
use Selecto::API::EngineHandler;

my $x = 'Selecto::Expression';
my $date = '2026-03-15';
sub domain {
    return Selecto::Domain->parse({schema_version => 1, domain_version => '1',
        domain_fingerprint => 'sha256:as-of-test', name => 'As of events',
        source => {source_table => 'as_of_events', primary_key => 'id',
            fields => [qw(id day started ended age hours fallback)],
            columns => {id => {type => 'integer'}, day => {type => 'date'},
                started => {type => 'utc_datetime'}, ended => {type => 'utc_datetime'},
                map { my ($name, $unit, $end, $otherwise) = @$_;
                    $name => {type => $unit eq 'day' ? 'integer' : 'decimal', computed => {
                        kind => 'temporal_delta', from => 'started', to => $end, unit => $unit,
                        ($otherwise ? (otherwise => 'now') : ())}}
                } [age => 'day', 'now'], [hours => 'hour', 'now'], [fallback => 'hour', 'ended', 1]},
            associations => {}}, schemas => {}, joins => {}}, strict => 1);
}
sub engine {
    my ($backend, $dbh) = @_;
    return Selecto::Engine->new(domain => domain(), adapter => Selecto->adapter($backend =>
        dbh => $dbh, temporary_relations => 1));
}
sub error {
    my ($code) = @_;
    return eval { $code->(); 'ok' } || (ref($@) ? $@->code : die $@);
}

subtest 'ISO admission and immutable query state' => sub {
    my $engine = engine('sqlite', TestSelecto::DBH->new);
    my $q = $engine->query;
    for my $value ($date, '2024-02-29', '2026-03-15T14:30:00',
        '2026-03-15T14:30:00Z', '2026-03-15T14:30:00.123456789+05:30',
        '2026-03-15T14:30:00-07:00') {
        is $q->as_of($value)->select('id')->limit(1)->as_of, $value, "accepts and preserves $value";
        is(Selecto::Query->new(as_of => $value)->as_of, $value, 'constructor accepts it');
    }
    is $q->as_of, undef, 'original query is unchanged';
    for my $bad (undef, '', 'now', '2026-02-29', '2026-04-31', '0000-01-01',
        '2026-03-15 12:00:00', '2026-03-15T24:00:00', '2026-03-15T01:60:00',
        '2026-03-15T00:00:60', '2026-03-15T00:00:00+24:00',
        '2026-03-15T00:00:00+00:60', "$date\n", "$date'; DROP TABLE x;--", [], {}) {
        is error(sub { $q->as_of($bad) }), 'invalid_query', 'rejects invalid clock';
        like "$@", qr/as_of must be a valid ISO/, 'clear validation message' if $@;
    }
    is(Selecto::AsOf->timestamp($date), '2026-03-15 00:00:00+00:00', 'a date starts at midnight');
    is(Selecto::AsOf->timestamp($date, 'America/Denver'), '2026-03-15 06:00:00+00:00',
        'date starts in the explicit query zone');
    is(Selecto::AsOf->timestamp('2026-03-15T00:30:00.125+02:00'),
        '2026-03-14 22:30:00.125+00:00', 'offset normalized to UTC');
    is(Selecto::AsOf->date('2026-03-15T00:30:00Z', 'America/Denver'),
        '2026-03-14', 'timestamp day follows explicit query zone');
    is(Selecto::AsOf->date($date, 'America/Denver'), $date, 'date means its named calendar day');
};

for my $backend (qw(postgresql sqlite duckdb mysql mariadb)) {
    subtest "$backend compilation" => sub {
        my $engine = engine($backend, TestSelecto::DBH->new);
        no warnings 'redefine';
        local *Selecto::MySQLFamily::_server_version = sub { [99, 0, 0] };
        my $q = $engine->query->select(qw(id age hours fallback))
            ->where($x->date_shortcut('day', 'today'));
        my $normal = $engine->compile($q);
        my $fixed = $engine->compile($q->as_of('2026-03-15T14:30:00Z'));
        unlike $fixed->sql, qr/CURRENT_DATE|CURRENT_TIMESTAMP|'now'|2026-03-15/, 'read clock is bound';
        ok scalar(grep { /^2026-03-15/ } @{$fixed->params}), 'parameters contain clock';
        is $engine->compile($q)->sql, $normal->sql, 'next ordinary read SQL is byte identical';
        if ($backend eq 'sqlite' || $backend eq 'mysql' || $backend eq 'mariadb') {
            is scalar(() = $fixed->sql =~ /\?/g), scalar(@{$fixed->params}), 'each anonymous occurrence has a bind';
        }
        if ($backend eq 'postgresql' || $backend eq 'duckdb') {
            like $normal->sql, qr/CURRENT_TIMESTAMP/, 'default temporal SQL retains backend clock';
            like $normal->sql, qr/CURRENT_DATE/, 'default shortcut SQL retains backend date';
        }
        # One setting owns nested reads, even when the inner query has none.
        my $child = $engine->query->select('id')->where($x->date_shortcut('day', 'today'));
        my $union = $engine->compile($child->union($child)->as_of($date));
        unlike $union->sql, qr/CURRENT_DATE|'now'|2026-03-15/, 'set operands inherit outer read clock';
        ok @{$union->params} >= 4, 'both operands bind their date bounds';
        my $write = $engine->adapter->preview_write(Selecto::Write::Command->new(
            operation => 'update', relation => 'as_of_events', assignments => {
                started => Selecto::Write::Expression->current_timestamp},
            predicate => $x->eq('id', 1)));
        like $write->{sql}, qr/CURRENT_TIMESTAMP/, 'write keeps the real clock after an as_of read';
        is_deeply $write->{params}, [1], 'write never binds the read clock';
    };
}

sub connect_backend {
    my ($backend) = @_;
    my $driver = {sqlite => 'SQLite', postgresql => 'Pg', duckdb => 'DuckDB',
        mysql => 'MariaDB', mariadb => 'MariaDB'}->{$backend};
    return unless eval "require DBD::$driver; 1";
    return DBI->connect("dbi:$driver:dbname=:memory:", undef, undef,
        {RaiseError => 1, PrintError => 0}) if $backend eq 'sqlite' || $backend eq 'duckdb';
    my $url = $ENV{'SELECTO_PERL_TEST_' . uc($backend eq 'postgresql' ? 'postgres' : $backend) . '_URL'};
    return unless $url;
    my $parsed = Mojo::URL->new($url);
    return DBI->connect("dbi:$driver:dbname=" . substr($parsed->path, 1)
        . ';host=' . $parsed->host . ';port=' . $parsed->port,
        $parsed->username, $parsed->password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}

for my $backend (qw(sqlite postgresql duckdb mysql mariadb)) {
    subtest "$backend live read" => sub {
        my $dbh = connect_backend($backend) or plan skip_all => 'no configured in-memory backend/driver';
        $dbh->do("SET TIME ZONE 'UTC'") if $backend eq 'postgresql' || $backend eq 'duckdb';
        my $temporary = $backend eq 'sqlite' || $backend eq 'duckdb' ? '' : 'TEMPORARY ';
        my $stamp = $backend eq 'postgresql' || $backend eq 'duckdb' ? 'TIMESTAMPTZ' : 'DATETIME';
        $dbh->do("CREATE ${temporary}TABLE as_of_events (id INTEGER PRIMARY KEY, day DATE, started $stamp, ended $stamp)");
        my @days = qw(2026-03-15 2026-03-14 2026-03-09 2026-03-08 2026-03-01 2026-02-15 2025-03-15);
        $dbh->do('INSERT INTO as_of_events VALUES (?, ?, ?, NULL)', undef, $_ + 1, $days[$_], "$days[$_] 00:00:00") for 0 .. $#days;
        my $engine = engine($backend, $dbh);
        for my $case ([today => [1]], [yesterday => [2]], [last_7_days => [1,2,3]],
            [this_month => [1,2,3,4,5]], [this_year => [1,2,3,4,5,6]], [this_week => [1,2,3]],
            [this_quarter => [1,2,3,4,5,6]], [mtd_all_years => [1,2,3,4,5,7]]) {
            my ($shortcut, $expected) = @$case;
            next if $shortcut eq 'mtd_all_years' && ($backend eq 'mysql' || $backend eq 'mariadb');
            my $query = $engine->query->as_of($date)->select('id')->order_by('id')
                ->where($x->date_shortcut('day', $shortcut));
            is_deeply [map { $_->[0] } @{$engine->all($query)->{rows}}], $expected, "$shortcut measures from as_of";
        }
        my $q = $engine->query->as_of('2026-03-15T12:00:00+02:00')->select(qw(age hours fallback))
            ->where($x->eq('id', 2));
        my $bounded = $backend eq 'sqlite' || $backend eq 'postgresql';
        my $row = ($bounded ? Selecto::BoundedQuery->all($engine, $q) : $engine->all($q))->{rows}[0];
        is 0 + $row->[0], 1, 'calendar age from as_of';
        cmp_ok abs($row->[1] - 34), '<', 0.0001, 'elapsed hours use normalized timestamp';
        cmp_ok abs($row->[2] - 34), '<', 0.0001, 'NULL coalesce uses same timestamp';
        if ($backend eq 'postgresql') {
            my $zoned = $engine->all($q->as_of($date)->use_timezone('America/Denver'))->{rows}[0];
            cmp_ok abs($zoned->[1] - 30), '<', 0.0001, 'date clock starts at midnight in query timezone';
            is 0 + $zoned->[0], 2, 'calendar age uses that same zoned date';
        }
        my $midnight = $engine->all($q->as_of($date))->{rows}[0];
        cmp_ok abs($midnight->[1] - 24), '<', 0.0001, 'date means midnight for timestamp expressions';

        if ($backend eq 'sqlite' || $backend eq 'postgresql') {
            for my $case ([elapsed_days_ranges => 1, 1, [qw(Other match Other Other Other Other Other)]],
                [month_ranges => 1, 1, [qw(Other Other Other Other Other match Other)]],
                [date_relative_ranges => 'today', 'today', [qw(match Other Other Other Other Other Other)]],
                [date_relative_ranges => 'yesterday', 'yesterday', [qw(Other match Other Other Other Other Other)]],
                [date_relative_ranges => 1, 6, [qw(Other match match Other Other Other Other)]]) {
                my ($kind, $min, $max, $expected) = @$case;
                my $bucket = $x->bucket('day', {kind => $kind,
                    ranges => [{minimum => $min, maximum => $max, label => 'match'}]})->as('band');
                my $query = $engine->query->as_of($date)->select($bucket)->order_by('id');
                is_deeply [map { $_->[0] } @{$engine->all($query)->{rows}}], $expected, "$kind $min..$max uses as_of";
            }
            my $count = $x->count_bucket('day', 1, 6, 'elapsed_days')->as('n');
            is 0 + $engine->all($engine->query->as_of($date)->select($count))->{rows}[0][0], 2, 'elapsed-days count uses as_of';
        }

        my $handler = Selecto::API::EngineHandler->new(bounded_results => $bounded ? 1 : 0);
        my $body = {select => ['id'], filters => [{field => 'day', op => 'date_shortcut', value => 'today'}], as_of => $date};
        my $trusted = Selecto::API::EngineHandler->new(today => '2030-01-01');
        is_deeply $trusted->query($engine, $body)->{rows}, [[1]], 'as_of supersedes trusted today';
        is $trusted->today, '2030-01-01', 'handler default is unchanged';
        my $api = Selecto::API->new(domain => $engine->domain);
        my $call = sub { $api->request({method => 'POST', path => '/api/v1/selecto/query', body => $_[0]},
            {query => sub { ['ok', $handler->query($engine, $_[0])] }}) };
        my $response = $call->($body);
        is $response->{status}, 200, 'canonical query accepts as_of';
        my $data = JSON::PP->new->utf8->decode($response->{body})->{data};
        is_deeply $data->{rows}, [[1]], 'canonical rows relative to requested day';
        is $data->{meta}{as_of}, $date, 'canonical response echoes clock in metadata';
        is $call->({%$body, as_of => 'yesterday'})->{status}, 422, 'canonical invalid as_of returns validation error';

        if ($bounded) {
            my $remote = Selecto::API::RemoteQuery->new;
            my $request = {format => 'selecto.remote-query', format_version => 1,
                domain => {fingerprint => $engine->domain->fingerprint}, query => $body};
            my $wire = sub { $remote->request($engine, {method => 'POST', path => '/api/v1/selecto/query',
                content_type => 'application/json', body => $_[0]}) };
            $response = $wire->($request);
            is $response->{status}, 200, 'remote query accepts clock and shortcut';
            $data = JSON::PP->new->utf8->decode($response->{body});
            is_deeply $data->{data}{rows}, [[1]], 'remote query rows use clock';
            is $data->{meta}{as_of}, $date, 'remote metadata echoes clock without request_id';
            $request->{query}{as_of} = [];
            is $wire->($request)->{status}, 422, 'remote invalid clock is a validation error';
        }
        $dbh->do('DROP TABLE as_of_events');
        $dbh->disconnect;
    };
}

done_testing;
