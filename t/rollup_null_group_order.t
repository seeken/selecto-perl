use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use lib 't/lib';
use TestPostgreSQL ();
use TestSelecto;

# A rollup over two groups whose values include real NULLs. On PostgreSQL the
# rolled-up NULL of a subtotal or the grand total ties with a real NULL value
# under "NULLS FIRST", so a real-NULL row could land above the Total or a
# subtotal below its own rows. The marker over every group breaks the tie,
# as the emulated rollup (SQLite, MySQL, MariaDB) already does.
my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->new(name => 'Loads', table => 'selecto_rollup_null_loads',
    fields => {id => 'integer', origin => 'string', destination => 'string'});

sub query_for {
    my ($engine) = @_;
    return $engine->query->select('origin', 'destination', $x->count->as('n'),
        $x->grouping('origin', 'destination')->as('__selecto_rollup_grouping'))
        ->group_by_rollup('origin', 'destination')->order_by('origin')->order_by('destination');
}

my @rows = ([1, undef, undef], [2, undef, 'MI'], [3, 'MI', undef], [4, 'MI', 'OH'], [5, 'MI', 'OH'], [6, 'OH', 'MI']);
# Each subtotal comes right before its own rows, the grand total first.
my $expected = [
    [undef, undef, 6, 3],
    [undef, undef, 2, 1], [undef, undef, 1, 0], [undef, 'MI', 1, 0],
    ['MI', undef, 3, 1], ['MI', undef, 1, 0], ['MI', 'OH', 2, 0],
    ['OH', undef, 1, 1], ['OH', 'MI', 1, 0],
];

subtest 'the PostgreSQL ORDER BY ends with the marker' => sub {
    my $engine = Selecto::Engine->new(domain => $domain,
        adapter => Selecto->adapter(postgresql => (dbh => TestSelecto::DBH->new)));
    my $sql = $engine->compile(query_for($engine))->sql;
    like $sql, qr/ORDER BY 1 ASC NULLS FIRST, 2 ASC NULLS FIRST, 4 DESC\z/, 'groups, then the marker';
};

for my $backend (
    [sqlite => sub {
        return unless eval { require DBD::SQLite; 1 };
        DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    }],
    [postgresql => sub {
        return unless TestPostgreSQL->configured && eval { require DBD::Pg; 1 };
        TestPostgreSQL->connect;
    }],
) {
    my ($name, $connect) = @$backend;
    subtest "$name orders real NULL groups under their subtotals" => sub {
        my $dbh = $connect->() or plan skip_all => "no $name database";
        $dbh->do('DROP TABLE IF EXISTS selecto_rollup_null_loads');
        $dbh->do('CREATE TABLE selecto_rollup_null_loads (id integer primary key, origin text, destination text)');
        $dbh->do('INSERT INTO selecto_rollup_null_loads VALUES (?, ?, ?)', undef, @$_) for @rows;
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
        is_deeply [map { [$_->[0], $_->[1], 0 + $_->[2], 0 + $_->[3]] } @{$engine->all(query_for($engine))->{rows}}],
            $expected, 'Total, then each subtotal ahead of its rows';
        $dbh->do('DROP TABLE selecto_rollup_null_loads');
    };
}

done_testing;
