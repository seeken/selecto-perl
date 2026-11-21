use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;

# temporal_delta and bucket computed-column shorthand, against SQLite in
# memory and PostgreSQL when SELECTO_PERL_TEST_POSTGRES_URL is set.
my $x = 'Selecto::Expression';
my $suffix = $$;

my %connect = (
    sqlite => sub {
        return undef unless eval { require DBD::SQLite; 1 };
        return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    },
    postgresql => sub {
        my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
        return undef unless defined($url) && eval { require DBD::Pg; require Selecto::Certification; 1 };
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        return DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
);
my @cleanup;
END { for my $entry (@cleanup) { eval { $entry->[0]->do("DROP TABLE IF EXISTS $_") } for @{$entry->[1]} } }

sub code_of {
    my ($run) = @_;
    return eval { $run->(); 1 } ? 'ok' : ref($@) && $@->can('code') ? $@->code : die $@;
}

sub contract {
    my ($tickets, $events, %columns) = @_;
    return {
        name => 'Tickets',
        source => {
            source_table => $tickets, primary_key => 'id',
            fields => ['id', 'event_id', 'purchased_at', 'refunded_on', sort keys %columns],
            columns => {
                id => {type => 'integer'}, event_id => {type => 'integer'},
                purchased_at => {type => 'naive_datetime'}, refunded_on => {type => 'date'},
                %columns,
            },
            associations => {event => {queryable => 'event', field => 'event', owner_key => 'event_id', related_key => 'id'}},
        },
        schemas => {event => {
            source_table => $events, primary_key => 'id', fields => [qw(id name starts_on)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}, starts_on => {type => 'date'}},
            associations => {},
        }},
        joins => {event => {type => 'left'}},
    };
}

my %synthetic = (
    lead_days => {type => 'integer',
        computed => {kind => 'temporal_delta', from => 'purchased_at', to => 'event.starts_on'}},
    refund_days => {type => 'integer',
        computed => {kind => 'temporal_delta', from => 'purchased_at', to => 'refunded_on', unit => 'day'}},
    lead_bucket => {type => 'string',
        computed => {kind => 'bucket', field => 'lead_days', otherwise => 'Unknown', buckets => [
            {label => 'After the start', max => -1},
            {label => '0-6 days', min => 0, max => 6},
            {label => '7-29 days', min => 7, max => 29},
            {label => '30+ days', min => 30},
        ]}},
);

subtest 'shorthand expands to an ordinary expression column' => sub {
    my $domain = Selecto::Domain->parse(contract('t', 'e', %synthetic));
    my $columns = $domain->as_contract->{source}{columns};
    is_deeply($columns->{lead_days}{computed},
        {kind => 'expression', expression => ['days_between', ['field', 'purchased_at'], ['field', 'event.starts_on']]},
        'temporal_delta');
    is($columns->{lead_bucket}{computed}{kind}, 'expression', 'bucket is an expression');
    is_deeply($columns->{lead_bucket}{computed}{expression}[2],
        [['and', ['gte', 'lead_days', 0], ['lte', 'lead_days', 6]], ['literal', '0-6 days', 'string']],
        'a two-sided bucket is an inclusive range');
    is_deeply($columns->{lead_bucket}{computed}{expression}[-1], ['else', ['literal', 'Unknown', 'string']], 'otherwise');
    is_deeply(Selecto::Domain->parse($domain->as_contract)->as_contract->{source}{columns}{lead_bucket},
        $columns->{lead_bucket}, 'the expanded form parses back unchanged');

    my %bad = (
        'unit other than day' => {kind => 'temporal_delta', from => 'purchased_at', to => 'refunded_on', unit => 'hour'},
        'missing to' => {kind => 'temporal_delta', from => 'purchased_at'},
        'unknown key' => {kind => 'temporal_delta', from => 'purchased_at', to => 'refunded_on', absolute => 1},
        'non-date operand' => {kind => 'temporal_delta', from => 'id', to => 'refunded_on'},
        'unknown field' => {kind => 'temporal_delta', from => 'nowhere', to => 'refunded_on'},
    );
    for my $label (sort keys %bad) {
        is(code_of(sub { Selecto::Domain->parse(contract('t', 'e', bad => {type => 'integer', computed => $bad{$label}})) }),
            'invalid_domain', "temporal_delta: $label");
    }
    my $bucket = sub { {kind => 'bucket', field => 'id', buckets => $_[0], @_[1 .. $#_]} };
    my %bad_bucket = (
        'no buckets' => $bucket->([]),
        'no bounds' => $bucket->([{label => 'a'}]),
        'min above max' => $bucket->([{label => 'a', min => 5, max => 1}]),
        'duplicate label' => $bucket->([{label => 'a', max => 1}, {label => 'a', min => 2}]),
        'overlap on a shared bound' => $bucket->([{label => 'a', min => 0, max => 5}, {label => 'b', min => 5, max => 9}]),
        'overlap with an open end' => $bucket->([{label => 'a', min => 3}, {label => 'b', min => 7, max => 9}]),
        'non-numeric bound' => $bucket->([{label => 'a', min => 'x'}]),
        'otherwise repeats a label' => $bucket->([{label => 'a', min => 0}], otherwise => 'a'),
        'string source' => {kind => 'bucket', field => 'event.name', buckets => [{label => 'a', min => 0}]},
    );
    for my $label (sort keys %bad_bucket) {
        is(code_of(sub { Selecto::Domain->parse(contract('t', 'e', bad => {type => 'string', computed => $bad_bucket{$label}})) }),
            'invalid_domain', "bucket: $label");
    }
    is(code_of(sub { Selecto::Domain->parse(contract('t', 'e', bad => {type => 'string', computed => $synthetic{lead_days}{computed}})) }),
        'invalid_domain', 'the declared type must be integer');
};

my $ran = 0;
for my $backend (qw(sqlite postgresql)) {
    my $dbh = $connect{$backend}->() or next;
    $ran++;
    subtest $backend => sub {
        my ($tickets, $events) = ("selecto_synthetic_tickets_$suffix", "selecto_synthetic_events_$suffix");
        my ($date, $stamp) = $backend eq 'sqlite' ? ('TEXT', 'TEXT') : ('DATE', 'TIMESTAMP');
        $dbh->do("CREATE TABLE $events(id INTEGER PRIMARY KEY, name VARCHAR(20), starts_on $date)");
        $dbh->do("CREATE TABLE $tickets(id INTEGER PRIMARY KEY, event_id INTEGER, purchased_at $stamp, refunded_on $date)");
        push @cleanup, [$dbh, [$tickets, $events]];
        $dbh->do("INSERT INTO $events VALUES (1,'Gala','2026-06-30'), (2,'Fair',NULL)");
        $dbh->do("INSERT INTO $tickets VALUES
            (1, 1, '2026-06-30 23:59:00', NULL),
            (2, 1, '2026-06-24 00:00:01', '2026-06-25'),
            (3, 1, '2026-06-01 12:00:00', NULL),
            (4, 1, '2026-01-01 08:00:00', NULL),
            (5, 1, '2026-07-02 09:00:00', '2026-07-01'),
            (6, 2, '2026-03-01 09:00:00', NULL),
            (7, 1, '2026-06-23 23:59:59', NULL)");
        my $engine = Selecto::Engine->new(
            adapter => Selecto->adapter($backend => (dbh => $dbh)),
            domain => Selecto::Domain->parse(contract($tickets, $events, %synthetic)));

        my $rows = $engine->all($engine->query->select(qw(id lead_days refund_days lead_bucket))->order_by('id'))->{rows};
        is_deeply([map { [map { defined($_) ? "$_" : undef } @$_] } @$rows], [
            [1, 0, undef, '0-6 days'],
            [2, 6, 1, '0-6 days'],
            [3, 29, undef, '7-29 days'],
            [4, 180, undef, '30+ days'],
            [5, -2, -1, 'After the start'],
            [6, undef, undef, 'Unknown'],
            [7, 7, undef, '7-29 days'],
        ], 'whole calendar days whatever the time, negative when reversed, NULL when either date is missing');

        my $grouped = $engine->all($engine->query->select('lead_bucket', $x->count->as('n'))
            ->group_by('lead_bucket')->order_by('lead_bucket'))->{rows};
        is_deeply([map { "$_->[0]=$_->[1]" } @$grouped],
            ['0-6 days=2', '30+ days=1', '7-29 days=2', 'After the start=1', 'Unknown=1'], 'group by a bucket');

        my $filtered = $engine->all($engine->query->select('id')->where($x->gte('lead_days', 7))->order_by('id'))->{rows};
        is_deeply([map { $_->[0] } @$filtered], [3, 4, 7], 'filter on a temporal delta');
        my $labelled = $engine->all($engine->query->select('id')->where($x->eq('lead_bucket', '0-6 days'))->order_by('id'))->{rows};
        is_deeply([map { $_->[0] } @$labelled], [1, 2], 'filter on a bucket label');
        my $statement = $engine->compile($engine->query->select('lead_bucket'));
        unlike($statement->sql, qr/days|Unknown/, 'labels are bound, not written into the SQL');
    };
}
plan skip_all => 'no database driver is available' unless $ran;
done_testing;
