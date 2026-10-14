use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use JSON::PP ();
use POSIX ();
use Time::HiRes qw(time sleep);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';
plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };

my $x = 'Selecto::Expression';

sub open_db {
    my ($backend, $url) = @_;
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url, $backend);
    return DBI->connect($dsn, $username, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
}

# PostgreSQL order: NULLs last ascending, first descending; ties by id ascending.
sub expected_order {
    my ($rows, $column, $direction) = @_;
    my @sorted = sort {
        my ($l, $r) = ($a->{$column}, $b->{$column});
        my $by = !defined($l) && !defined($r) ? 0
            : !defined($l) ? ($direction eq 'asc' ? 1 : -1)
            : !defined($r) ? ($direction eq 'asc' ? -1 : 1)
            : ($column eq 'label' ? $l cmp $r : $l <=> $r) * ($direction eq 'asc' ? 1 : -1);
        $by || $a->{id} <=> $b->{id};
    } @$rows;
    return [map { $_->{id} } @sorted];
}

sub children {
    my ($value) = @_;
    $value = JSON::PP::decode_json($value) unless ref $value;
    return [map { 0 + $_->{id} } @$value];
}

for my $specification (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($backend, $environment) = @$specification;
    subtest "$backend live" => sub {
        plan skip_all => "$environment is not configured"
            unless defined($ENV{$environment}) && $ENV{$environment} ne '';
        my $url = $ENV{$environment};
        my $dbh = open_db($backend, $url);

        subtest 'related-collection keyset cursors page like PostgreSQL' => sub {
            $dbh->do('DROP TABLE IF EXISTS selecto_live_items');
            $dbh->do('DROP TABLE IF EXISTS selecto_live_orders');
            $dbh->do('CREATE TABLE selecto_live_orders (id int primary key) ENGINE=InnoDB');
            $dbh->do('CREATE TABLE selecto_live_items (id int primary key, order_id int, label varchar(20) COLLATE utf8mb4_bin, seq int) ENGINE=InnoDB');
            $dbh->do('INSERT INTO selecto_live_orders VALUES (1),(2),(3)');
            my @items = ([1, 1, 'a', undef], [2, 1, undef, 1], [3, 1, 'c', 2], [4, 1, 'd', undef], [5, 1, undef, undef],
                [6, 1, 'f', 3], [7, 2, 'g', 5], [8, 2, undef, undef], [9, 2, 'i', 4], [10, 3, 'j', 1]);
            $dbh->do('INSERT INTO selecto_live_items VALUES (?,?,?,?)', undef, @$_) for @items;
            my $domain = Selecto::Domain->new(name => 'Orders', table => 'selecto_live_orders', fields => {id => 'integer'},
                associations => {items => {table => 'selecto_live_items', target_primary_key => 'id',
                    fields => {id => 'integer', order_id => 'integer', label => 'string', seq => 'integer'},
                    owner_key => 'id', related_key => 'order_id', cardinality => 'many', join_type => 'left'}});
            my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)));
            my %by_order;
            push @{$by_order{$_->[1]}}, {id => $_->[0], label => $_->[2], seq => $_->[3]} for @items;
            for my $column (qw(seq label)) {
                for my $direction (qw(asc desc)) {
                    my %expected = map { ($_ => expected_order($by_order{$_}, $column, $direction)) } keys %by_order;
                    my (%after, @got1);
                    my $guard = 0;
                    while ($guard++ < 10) {
                        my $query = $engine->query->select('id', $x->related_collection('items', ['id', 'seq', 'label'],
                            order_by => [[$column, $direction]], limit => 2, (%after ? (after => {%after}) : ()))->as('c'))
                            ->order_by('id', 'asc');
                        my $result = $engine->all($query);
                        my %page = map { (0 + $_->[0] => children($_->[1])) } @{$result->{rows}};
                        # Parents the cursor does not name restart at their first page.
                        if (%after) {
                            is_deeply($page{2}, [@{$expected{2}}[0 .. 1]], "$column $direction: an uncursored parent returns its first page");
                            is_deeply($page{3}, [@{$expected{3}}[0 .. 0]], "$column $direction: another uncursored parent returns its first page");
                        }
                        last unless @{$page{1}};
                        push @got1, @{$page{1}};
                        my ($last) = grep { $_->{id} == $page{1}[-1] } @{$by_order{1}};
                        %after = (parent_key => 1, values => [$last->{$column}, $last->{id}]);
                    }
                    is_deeply(\@got1, $expected{1}, "$column $direction: paging parent 1 by cursor visits every row once, in PostgreSQL order")
                        or diag(explain(\@got1));
                }
            }
            $dbh->do('DROP TABLE selecto_live_items');
            $dbh->do('DROP TABLE selecto_live_orders');
        };

        subtest 'same-key upserts from two sessions never deadlock' => sub {
            $dbh->do('DROP TABLE IF EXISTS selecto_live_conc');
            $dbh->do('CREATE TABLE selecto_live_conc (id int primary key, code varchar(40) not null, hits int not null, unique key uc (code)) ENGINE=InnoDB');
            my $rounds = 100;
            my $start = time + 2;
            my @pids;
            for my $worker (1, 2) {
                my $pid = fork;
                die "fork failed\n" unless defined $pid;
                if (!$pid) {
                    my $connection = open_db($backend, $url);
                    my $domain = TestSelecto::writable_domain(
                        name => 'Conc', table => 'selecto_live_conc',
                        fields => {id => 'integer', code => 'string', hits => 'integer'},
                        conflict_targets => [['code']]);
                    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $connection)));
                    my %outcome;
                    for my $round (1 .. $rounds) {
                        my $at = $start + $round * 0.04;
                        my $wait = $at - time;
                        sleep($wait) if $wait > 0;
                        my $command = Selecto::Write::Command->new(operation => 'upsert', relation => 'selecto_live_conc',
                            assignments => {id => $worker * 1000 + $round, code => "k$round", hits => $worker},
                            metadata => {conflict_target => ['code'], upsert_update_fields => ['hits']});
                        my $ok = eval { $engine->execute_write($command); 1 };
                        $outcome{$ok ? 'ok' : (ref($@) && $@->can('code') ? $@->code : 'died')}++;
                    }
                    POSIX::_exit(($outcome{ok} // 0) == $rounds ? 0 : 1);
                }
                push @pids, $pid;
            }
            my @status = map { waitpid($_, 0); $? >> 8 } @pids;
            is_deeply(\@status, [0, 0], 'every upsert of both sessions succeeded (no deadlock, no unique violation)');
            my ($rows) = $dbh->selectrow_array('SELECT COUNT(*) FROM selecto_live_conc');
            is($rows, $rounds, 'exactly one row per key');
            my ($lost) = $dbh->selectrow_array('SELECT COUNT(*) FROM selecto_live_conc WHERE hits NOT IN (1, 2)');
            is($lost, 0, 'every row holds one session\'s update');
            $dbh->do('DROP TABLE selecto_live_conc');
        };

        subtest 'server errors are typed' => sub {
            $dbh->do('DROP TABLE IF EXISTS selecto_live_kid');
            $dbh->do('DROP TABLE IF EXISTS selecto_live_par');
            $dbh->do('CREATE TABLE selecto_live_par (id int primary key, code varchar(20) not null, unique key pc (code)) ENGINE=InnoDB');
            $dbh->do('CREATE TABLE selecto_live_kid (id int primary key, par int not null, FOREIGN KEY (par) REFERENCES selecto_live_par(id)) ENGINE=InnoDB');
            $dbh->do(q{INSERT INTO selecto_live_par VALUES (1, 'a')});
            my $adapter = Selecto->adapter($backend => (dbh => $dbh));
            my $run = sub {
                my ($sql) = @_;
                return eval { $dbh->do($sql); 1 } ? undef : $adapter->normalize_error($@);
            };
            is($run->(q{INSERT INTO selecto_live_par VALUES (2, 'a')})->code, 'database_unique_violation', 'duplicate key');
            is($run->(q{INSERT INTO selecto_live_kid VALUES (1, 99)})->code, 'database_foreign_key_violation', 'missing parent');
            is($run->(q{INSERT INTO selecto_live_par (id, code) VALUES (3, NULL)})->code, 'database_not_null_violation', 'null in a required column');
            $dbh->do('DROP TABLE selecto_live_kid');
            $dbh->do('DROP TABLE selecto_live_par');
        };
        $dbh->disconnect;
    };
}

done_testing;
