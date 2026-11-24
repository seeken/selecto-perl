use strict;
use warnings;
use Test::More;
use DBI ();
use Mojo::URL ();
use Selecto;

# Month buckets count calendar months back from the database's current month.
# SQLite runs in memory; PostgreSQL runs when SELECTO_PERL_TEST_POSTGRES_URL is set.
my $table = 'selecto_month_buckets_' . $$;
my @now = gmtime;
my ($year, $month) = ($now[5] + 1900, $now[4] + 1);
# The 15th of the month $ago months back, safely inside it in any time zone.
sub month_ago {
    my ($ago) = @_;
    my $index = $year * 12 + ($month - 1) - $ago;
    return sprintf '%04d-%02d-15', int($index / 12), $index % 12 + 1;
}

my %connect = (
    sqlite => sub {
        return undef unless eval { require DBD::SQLite; 1 };
        return DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
    postgresql => sub {
        my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
        return undef unless defined($url) && length($url) && eval { require DBD::Pg; 1 };
        my $parsed = Mojo::URL->new($url);
        return DBI->connect('dbi:Pg:dbname=' . substr($parsed->path, 1) . ';host=' . ($parsed->host // 'localhost')
            . ';port=' . ($parsed->port // 5432), $parsed->username, $parsed->password,
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    },
);
my @cleanup;
END { eval { $_->do("DROP TABLE IF EXISTS $table") } for @cleanup }

my $x = 'Selecto::Expression';
my $ran = 0;
for my $backend (qw(sqlite postgresql)) {
    my $dbh = $connect{$backend}->() or next;
    $ran++;
    subtest $backend => sub {
        $dbh->do("CREATE TABLE $table (id integer primary key, received_on date)");
        push @cleanup, $dbh if $backend eq 'postgresql';
        my @ages = (0, 1, 2, 4, 6, 12, 13);
        $dbh->do("INSERT INTO $table VALUES (?, ?)", undef, $_ + 1, month_ago($ages[$_])) for 0 .. $#ages;
        $dbh->do("INSERT INTO $table VALUES (?, NULL)", undef, scalar(@ages) + 1);
        my $domain = Selecto::Domain->new(name => 'Orders', table => $table,
            fields => {id => 'integer', received_on => 'date'});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)));
        my $bucket = $x->bucket('received_on', {kind => 'month_ranges', ranges => [
            {minimum => 6, maximum => 12, label => 'half year'},
            {minimum => 3, maximum => 5, label => 'quarter'},
            {minimum => 2, maximum => 2, label => 'two'},
            {minimum => 1, maximum => 1, label => 'last'},
            {minimum => 0, maximum => 0, label => 'this'},
        ]});
        my $rows = $engine->all($engine->query->select('id', $bucket->as('band'))->order_by('id'))->{rows};
        is_deeply [map { $_->[1] } @$rows], [qw(this last two quarter), 'half year', 'half year', 'Other', 'Other'],
            'calendar months ago: inclusive bounds, older and missing values are Other';
        my $open = $x->bucket('received_on', {kind => 'month_ranges', ranges => [
            {minimum => 13, label => 'older'}, {maximum => 1, label => 'recent'},
        ]});
        is_deeply [map { $_->[1] } @{$engine->all($engine->query->select('id', $open->as('band'))->order_by('id'))->{rows}}],
            [qw(recent recent Other Other Other Other older Other)], 'open-ended ranges';
    };
}

plan skip_all => 'no database driver is available' unless $ran;
done_testing;
