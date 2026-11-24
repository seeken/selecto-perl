use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Storable qw(dclone);
use Time::Local qw(timegm);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::ValueExpression;

my $x = 'Selecto::Expression';
sub delta {
    my ($from, $to, %options) = @_;
    return {type => ($options{unit} // 'day') eq 'day' ? 'integer' : 'decimal',
        computed => {kind => 'temporal_delta', from => $from, to => $to, %options}};
}
sub contract {
    my ($table, $status, %extra) = @_;
    return {name => 'Durations', source => {
        source_table => $table, primary_key => 'id',
        fields => [qw(id status_id started ended epoch dated), sort keys %extra],
        columns => {id => {type => 'integer'}, status_id => {type => 'integer'},
            started => {type => 'utc_datetime'}, ended => {type => 'utc_datetime'},
            epoch => {type => 'epoch_datetime'}, dated => {type => 'date'}, %extra},
        associations => {status => {queryable => 'status', field => 'status',
            owner_key => 'status_id', related_key => 'id', cardinality => 'one'}}},
        schemas => {status => {source_table => $status, primary_key => 'id',
            fields => [qw(id stamp epoch)], columns => {id => {type => 'integer'},
                stamp => {type => 'utc_datetime'}, epoch => {type => 'epoch_datetime'}}, associations => {}}},
        joins => {status => {type => 'left'}}};
}
sub error_code {
    my ($run) = @_;
    return eval { $run->(); 'ok' } || (ref($@) ? $@->code : die $@);
}
sub epoch {
    my ($stamp) = @_;
    my @parts = $stamp =~ /^(\d{4})-(\d\d)-(\d\d)(?:[ T](\d\d):(\d\d):(\d\d))?/;
    return timegm($parts[5] // 0, $parts[4] // 0, $parts[3] // 0, $parts[2], $parts[1] - 1, $parts[0]);
}
sub close_to {
    my ($got, $expected, $label, $tolerance) = @_;
    ok(defined($got) && abs($got - $expected) < ($tolerance // 0.00001), $label)
        or diag('got ' . ($got // 'NULL') . "; expected $expected");
}

subtest 'validation, metadata and legacy identities' => sub {
    my $raw = contract('orders', 'order_states', days => delta('started', 'ended'));
    my $domain = Selecto::Domain->parse($raw);
    my $legacy = dclone($raw);
    $legacy->{source}{columns}{days}{computed} = {kind => 'expression',
        expression => ['days_between', ['field', 'started'], ['field', 'ended']]};
    my $old = Selecto::Domain->parse($legacy);
    is($domain->fingerprint, $old->fingerprint, 'legacy normalized fingerprint is unchanged');
    for my $backend (qw(postgresql sqlite duckdb)) {
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => TestSelecto::DBH->new)));
        my $other = Selecto::Engine->new(domain => $old, adapter => Selecto->adapter($backend => (dbh => TestSelecto::DBH->new)));
        is($engine->compile($engine->query->select('days'))->sql,
            $other->compile($other->query->select('days'))->sql, "$backend legacy SQL unchanged");
    }
    is_deeply($domain->field_unit('days'), {kind => 'duration', code => 'day'}, 'derived day unit');
    for my $unit (qw(day hour fractional_day)) {
        my $with = Selecto::Domain->parse(contract('orders', 'order_states',
            days => delta('started', 'ended', unit => $unit, minimum => 0, otherwise => 'now')));
        isnt($with->fingerprint, $domain->fingerprint, "$unit options enter fingerprint");
        is($with->resolve('days')->{type}, $unit eq 'day' ? 'integer' : 'decimal', "$unit type");
        is_deeply($with->field_unit('days'), {kind => 'duration', code => $unit eq 'hour' ? 'hour' : 'day'}, "$unit metadata");
        is(Selecto::Domain->parse($with->as_contract)->fingerprint, $with->fingerprint, "$unit expanded contract round trip");
    }
    my $host = delta('started', 'ended', unit => 'hour');
    $host->{unit} = {kind => 'scalar'};
    is_deeply(Selecto::Domain->parse(contract('orders', 'order_states', hours => $host))->field_unit('hours'),
        {kind => 'scalar'}, 'host unit wins');
    for my $options ({unit => 'minute'}, {otherwise => 'today'}, {otherwise => undef},
        {minimum => -1}, {minimum => 1}, {minimum => []}, {from => []}, {to => undef}) {
        is(error_code(sub { Selecto::Domain->parse(contract('orders', 'order_states',
            bad => delta('started', 'ended', %$options))) }), 'invalid_domain', 'invalid option refuses');
    }
    is(error_code(sub { Selecto::Domain->parse(contract('orders', 'order_states',
        bad => {type => 'integer', computed => {kind => 'temporal_delta', from => 'started', to => 'ended', unit => 'hour'}})) }),
        'invalid_domain', 'elapsed result requires decimal declaration');
};

for my $backend (qw(sqlite postgresql duckdb mysql mariadb)) {
    subtest $backend => sub {
        my $driver = {sqlite => 'SQLite', postgresql => 'Pg', duckdb => 'DuckDB', mysql => 'MariaDB', mariadb => 'MariaDB'}->{$backend};
        eval "require DBD::$driver; 1" or plan skip_all => "$driver driver unavailable";
        my $url = $backend =~ /^(sqlite|duckdb)$/ ? ':memory:' : $ENV{'SELECTO_PERL_TEST_' . uc($backend eq 'postgresql' ? 'postgres' : $backend) . '_URL'};
        plan skip_all => 'disposable database URL not configured' unless $url;
        my ($dsn, $user, $password);
        if ($url eq ':memory:') {
            $dsn = "dbi:$driver:dbname=:memory:";
        } else {
            # Server URLs are parsed by the certification checkout, which is not on CPAN.
            eval { require Selecto::Certification; 1 }
                or plan skip_all => 'Selecto::Certification unavailable';
            ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url, $backend);
        }
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        my $fixed = '2026-07-02 12:00:00';
        no warnings 'redefine';
        local *Selecto::SQL::_server_timestamp = sub { $fixed };
        $dbh->do("SET TIME ZONE 'UTC'") if $backend eq 'postgresql' || $backend eq 'duckdb';
        if ($backend eq 'mysql' || $backend eq 'mariadb') {
            $dbh->do("SET time_zone = '+00:00'");
            $dbh->do('SET timestamp = ' . epoch($fixed));
        }
        $dbh->begin_work if $backend eq 'postgresql' || $backend eq 'duckdb';
        my ($now) = $backend eq 'sqlite' ? ($fixed)
            : $dbh->selectrow_array($backend eq 'duckdb' ? 'SELECT CAST(CURRENT_TIMESTAMP AS VARCHAR)' : 'SELECT CURRENT_TIMESTAMP');
        my $now_epoch = epoch("$now");
        my $table = 'selecto_duration_' . $$;
        my $status = $table . '_status';
        my $stamp = $backend eq 'postgresql' || $backend eq 'duckdb' ? 'TIMESTAMPTZ' : 'DATETIME';
        $dbh->do("CREATE TEMPORARY TABLE $status (id INTEGER PRIMARY KEY, stamp $stamp, epoch BIGINT)");
        $dbh->do("CREATE TEMPORARY TABLE $table (id INTEGER PRIMARY KEY, status_id INTEGER, started $stamp, ended $stamp, epoch BIGINT, dated DATE)");
        $dbh->do("INSERT INTO $status VALUES (1, '2026-06-30 08:30:00', ?)", undef, epoch('2026-06-30 08:30:00'));
        $dbh->do("INSERT INTO $table VALUES (1, 1, '2026-06-30 00:00:00', '2026-06-30 08:30:00', ?, '2026-06-30')", undef, epoch('2026-06-30 08:30:00'));
        $dbh->do("INSERT INTO $table VALUES (2, 1, '2026-07-01 00:00:00', '2026-06-30 08:30:00', ?, '2026-07-01')", undef, epoch('2026-06-30 08:30:00'));
        $dbh->do("INSERT INTO $table VALUES (3, 1, '2026-06-30 00:00:00', NULL, NULL, '2026-06-30')");
        $dbh->do("INSERT INTO $table VALUES (4, NULL, NULL, NULL, NULL, NULL)");
        my %columns;
        for my $unit (qw(day hour fractional_day)) {
            $columns{"closed_$unit"} = delta('started', 'ended', unit => $unit);
            $columns{"clamped_$unit"} = delta('started', 'ended', unit => $unit, minimum => 0);
            $columns{"now_$unit"} = delta('started', 'now', unit => $unit);
            $columns{"reverse_$unit"} = delta('now', 'started', unit => $unit);
            $columns{"fallback_$unit"} = delta('started', 'ended', unit => $unit, otherwise => 'now');
            $columns{"epoch_$unit"} = delta('started', 'epoch', unit => $unit, otherwise => 'now');
            $columns{"assoc_$unit"} = delta('dated', 'status.epoch', unit => $unit, otherwise => 'now');
            $columns{"assoc_stamp_$unit"} = delta('started', 'status.stamp', unit => $unit);
            $columns{"epoch_start_$unit"} = delta('epoch', 'ended', unit => $unit);
            $columns{"epoch_date_$unit"} = delta('epoch', 'dated', unit => $unit);
            $columns{"same_$unit"} = delta('now', 'now', unit => $unit, minimum => 0);
        }
        my $domain = Selecto::Domain->parse(contract($table, $status, %columns));
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)));
        my @fields = sort keys %columns;
        my $rows = $engine->all($engine->query->select('id', @fields)->order_by('id'))->{rows};
        my @records = map { my %row; @row{'id', @fields} = @$_; \%row } @$rows;
        for my $unit (qw(day hour fractional_day)) {
            my $divisor = $unit eq 'hour' ? 3600 : 86400;
            my $closed = $unit eq 'day' ? 0 : 30600 / $divisor;
            my $negative = $unit eq 'day' ? -1 : -55800 / $divisor;
            my $open = ($now_epoch - epoch('2026-06-30')) / $divisor;
            $open = int($now_epoch / 86400) - int(epoch('2026-06-30') / 86400) if $unit eq 'day';
            close_to($records[0]{"closed_$unit"}, $closed, "$unit closed");
            close_to($records[1]{"closed_$unit"}, $negative, "$unit negative");
            close_to($records[1]{"clamped_$unit"}, 0, "$unit minimum clamps negative");
            is($records[2]{"clamped_$unit"}, undef, "$unit minimum preserves NULL");
            close_to($records[0]{"now_$unit"}, $open, "$unit to now uses adapter clock", 0.001);
            close_to($records[0]{"reverse_$unit"}, -$open, "$unit from now", 0.001);
            close_to($records[0]{"fallback_$unit"}, $closed, "$unit fallback preserves non-NULL end");
            close_to($records[2]{"fallback_$unit"}, $open, "$unit fallback fills NULL end", 0.001);
            is($records[3]{"fallback_$unit"}, undef, "$unit fallback does not fill NULL start");
            close_to($records[0]{"epoch_$unit"}, $closed, "$unit epoch end");
            close_to($records[2]{"epoch_$unit"}, $open, "$unit epoch NULL fallback", 0.001);
            close_to($records[0]{"assoc_$unit"}, $closed, "$unit associated epoch and date");
            close_to($records[0]{"assoc_stamp_$unit"}, $closed, "$unit associated datetime");
            close_to($records[0]{"epoch_start_$unit"}, 0, "$unit epoch start and datetime end");
            close_to($records[0]{"epoch_date_$unit"}, -$closed, "$unit epoch start and date end");
            close_to($records[0]{"same_$unit"}, 0, "$unit shared clock");
        }
        # Numeric bucket groups and summary measures use the public API.
        for my $kind ($backend =~ /^(?:sqlite|postgresql)$/ ? ('numeric_ranges') : ()) {
            my $bucket = $x->bucket('clamped_hour', {kind => $kind, ranges => [
                {minimum => 0, maximum => 8, label => '0-8'},
                {minimum => 9, maximum => 16, label => '9-16'},
                {minimum => 17, maximum => 24, label => '17-24'},
                {minimum => 25, label => '25+'}]});
            my $query = $engine->query->select($bucket->as('band'),
                $x->avg('clamped_hour')->as('average'), $x->sum('clamped_hour')->as('total'))
                ->group_by($bucket)->order_by($bucket);
            my $summary = $engine->all($query)->{rows};
            is_deeply([map { $_->[0] } @$summary], ['0-8', 'Other'], "$kind duration groups");
            close_to($summary->[0][1], 0, 'average of clamped hours in first band');
            close_to($summary->[0][2], 0, 'sum of clamped hours in first band');
            close_to($summary->[1][1], 8.5, 'average ignores NULL durations');
            close_to($summary->[1][2], 8.5, 'sum ignores NULL durations');
            my $counts = $engine->all($engine->query->select(
                $x->count_bucket('clamped_hour', 0, 8)->as('early'),
                $x->count_bucket('clamped_hour', 9, 16)->as('later')))->{rows}[0];
            is_deeply([map { 0 + $_ } @$counts], [1, 0], 'numeric bucket counts on duration');
        }
        if ($backend eq 'sqlite') {
            my $query = $engine->query->select('now_hour')->where($x->eq('id', 1));
            my $statement = $engine->compile($query);
            ok(scalar(grep { $_ eq $fixed } @{$statement->params}), 'server time is bound');
            my $before = $engine->all($query)->{rows}[0][0];
            $fixed = '2026-07-03 12:00:00';
            close_to($engine->all($query)->{rows}[0][0] - $before, 24,
                'repeated query evaluates fresh clock after a day');
        }
        if ($backend eq 'postgresql' || $backend eq 'duckdb') {
            # Spring-forward: two local midnights span 23 elapsed hours.
            $dbh->do("UPDATE $table SET started = '2026-03-08 05:00:00+00', ended = '2026-03-09 04:00:00+00', dated = '2026-03-08' WHERE id = 1");
            my $dst_domain = Selecto::Domain->parse(contract($table, $status,
                hours => delta('started', 'ended', unit => 'hour'),
                days => delta('started', 'ended'),
                date_hours => delta('dated', 'ended', unit => 'hour')));
            my $dst_engine = Selecto::Engine->new(domain => $dst_domain, adapter => $engine->adapter);
            my $dst = $dst_engine->all($dst_engine->query->select(qw(hours days date_hours))->where($x->eq('id', 1))
                ->use_timezone('America/New_York'))->{rows}[0];
            close_to($dst->[0], 23, 'elapsed hours survive query timezone and DST');
            is(0 + $dst->[1], 1, 'calendar day uses query timezone');
            close_to($dst->[2], 23, 'date means midnight in query timezone');
        }
        $dbh->do("DROP TABLE $table");
        $dbh->do("DROP TABLE $status");
        $dbh->commit if !$dbh->{AutoCommit};
        $dbh->do('SET timestamp = 0') if $backend eq 'mysql' || $backend eq 'mariadb';
        $dbh->disconnect;
    };
}
done_testing;
