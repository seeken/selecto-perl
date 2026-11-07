use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::Query;
use Selecto::Statement;
use Selecto::Write ();

# Three settings cut an answer short with no error: sql_select_limit on either
# server, and on MariaDB the recursion limit and group_concat_max_len. A generated
# statement holds them off, is refused, or says it was cut: it never answers short.
# A hand-built read keeps the host's settings and the host's answer.

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';
plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };

my $CHAIN = 1500;
my $x = 'Selecto::Expression';

sub open_db {
    my ($backend, $url) = @_;
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url, $backend);
    return DBI->connect($dsn, $username, $password,
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
}

sub failure {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error')
        ? join('/', $error->code, map { $_ // '' } @{$error->details // {}}{qw(category reason)}) : "died: $error";
}

sub tree_query {
    my ($engine, $domain) = @_;
    return $engine->query->with_recursive_cte('tree', $domain,
        Selecto::Query->new->select(qw(id manager_id))->where($x->eq('id', 1)),
        Selecto::Query->new->select(qw(id manager_id)),
        columns => [qw(id manager_id)], join => {owner_key => 'id', related_key => 'id'},
        recursive_join => {owner_key => 'manager_id', related_key => 'id', type => 'inner'})
        ->select('id', 'tree.manager_id');
}

for my $specification (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($backend, $environment) = @$specification;
    subtest "$backend session limits" => sub {
        plan skip_all => "$environment is not configured"
            unless defined($ENV{$environment}) && $ENV{$environment} ne '';
        my $dbh = open_db($backend, $ENV{$environment});
        my $mariadb = $backend eq 'mariadb';
        $dbh->do("DROP TABLE IF EXISTS selecto_limit_$_") for qw(items orders rows ring);
        $dbh->do("CREATE TABLE selecto_limit_$_ (id int primary key, manager_id int, name varchar(20)) ENGINE=InnoDB") for qw(rows ring);
        # A chain: id 1 starts, and each step finds the row that names the last as its manager.
        $dbh->do('INSERT INTO selecto_limit_rows VALUES ' . join(',', map { "($_," . ($_ - 1) . ",'a')" } 1 .. $CHAIN));
        $dbh->do(q{INSERT INTO selecto_limit_ring VALUES (1, 2, 'a'), (2, 1, 'b')});
        $dbh->do('CREATE TABLE selecto_limit_orders (id int primary key) ENGINE=InnoDB');
        $dbh->do('CREATE TABLE selecto_limit_items (id int primary key, order_id int, label mediumtext) ENGINE=InnoDB');
        $dbh->do('INSERT INTO selecto_limit_orders VALUES (1), (2)');
        $dbh->do('INSERT INTO selecto_limit_items VALUES ' . join(',', map { "($_, 1, '" . ('x' x 100) . "')" } 1 .. 40));

        my $adapter = Selecto->adapter($backend => (dbh => $dbh));
        my $fields = {id => 'integer', manager_id => 'integer', name => 'string'};
        my $rows = TestSelecto::writable_domain(name => 'LimitRows', table => 'selecto_limit_rows', fields => $fields);
        my $engine = Selecto::Engine->new(adapter => $adapter, domain => $rows);
        my $ring = Selecto::Domain->new(name => 'Ring', table => 'selecto_limit_ring', fields => $fields);
        my $ring_engine = Selecto::Engine->new(adapter => $adapter, domain => $ring);
        my $chain = Selecto::Domain->new(name => 'Chain', table => 'selecto_limit_rows', fields => $fields);
        my $chain_engine = Selecto::Engine->new(adapter => $adapter, domain => $chain);
        my $orders = Selecto::Domain->new(name => 'LimitOrders', table => 'selecto_limit_orders', fields => {id => 'integer'},
            associations => {items => {table => 'selecto_limit_items', target_primary_key => 'id',
                fields => {id => 'integer', order_id => 'integer', label => 'string'},
                owner_key => 'id', related_key => 'order_id', cardinality => 'many', join_type => 'left'}});
        my $order_engine = Selecto::Engine->new(adapter => $adapter, domain => $orders);

        my $read = sub { scalar @{$engine->all($engine->query->select('id'))->{rows}} };
        my $stream = sub { my $s = $engine->stream($engine->query->select('id')); my $n = 0; $n++ while $s->next; $s->close; $n };
        my $update = sub {
            $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_limit_rows',
                assignments => {name => $_[0]}, predicate => $x->lte('id', 5), expected_count => 5));
        };
        my $hand = sub {
            scalar @{$adapter->execute_query(Selecto::Statement->new(sql => 'SELECT id FROM selecto_limit_rows',
                columns => ['id'], adapter_name => $backend))->{rows}};
        };
        my $collection = sub {
            my $result = $order_engine->all($order_engine->query->select('id', $x->related_collection('items', ['id', 'label'])->as('c'))
                ->where($x->eq('id', 1)));
            my $items = $result->{rows}[0][1];
            return scalar @{ref($items) ? $items : JSON::PP->new->decode($items)};
        };

        for my $limit (2, 0) {
            $dbh->do("SET SESSION sql_select_limit = $limit");
            if ($mariadb) {
                is $read->(), $CHAIN, "limit $limit: a generated read answers in full";
                is $stream->(), $CHAIN, "limit $limit: a generated stream answers in full";
                is failure(sub { $update->("w$limit") }), 'ok', "limit $limit: a write reads what it must";
                is $dbh->selectrow_array(q{SELECT COUNT(*) FROM selecto_limit_rows WHERE name = ? LIMIT 1}, undef, "w$limit"), 5,
                    "limit $limit: and wrote every row";
                is +($dbh->selectrow_array('SELECT @@SESSION.sql_select_limit LIMIT 1'))[0], $limit, "limit $limit: the host's setting stands";
            } else {
                is failure($_), 'invalid_connection//session_sql_select_limit', "limit $limit: refused, not short" for $read, $stream, sub { $update->('w') };
                is $dbh->selectrow_array(q{SELECT COUNT(*) FROM selecto_limit_rows WHERE name = 'w' LIMIT 1}), 0, "limit $limit: nothing was written";
            }
            is $hand->(), $limit, "limit $limit: a hand-built read has the host's answer";
            ok $dbh->{Active}, "limit $limit: and the connection stays open";
            $dbh->do('SET SESSION sql_select_limit = DEFAULT');
        }
        is $read->(), $CHAIN, 'a session without a limit reads in full';

        # A chain past the server's default.
        my $tree = sub { scalar @{$chain_engine->all(tree_query($chain_engine, $chain))->{rows}} };
        my $tree_stream = sub {
            my $s = $chain_engine->stream(tree_query($chain_engine, $chain)); my $n = 0; $n++ while $s->next; $s->close; $n };
        my $walk = 'WITH RECURSIVE c(id) AS (SELECT 1 UNION ALL SELECT r.id FROM selecto_limit_rows r JOIN c ON r.manager_id = c.id) SELECT id FROM c';
        my $hand_walk = sub {
            scalar @{$adapter->execute_query(Selecto::Statement->new(sql => $walk, columns => ['id'], adapter_name => $backend))->{rows}} };
        if ($mariadb) {
            is $tree->(), $CHAIN, 'a generated chain past the default answers in full';
            is $tree_stream->(), $CHAIN, 'and streams in full';
            $dbh->do('SET SESSION max_recursive_iterations = 2');
            is $tree->(), $CHAIN, 'a host limit does not cut a generated chain';
            is $hand_walk->(), 3, 'a hand-built one keeps the host limit';
            $dbh->do('SET SESSION max_recursive_iterations = DEFAULT');
            # A cycle must stop, and must not answer with the rows it had.
            my $started = time;
            is failure(sub { $ring_engine->all(tree_query($ring_engine, $ring)) }), 'query_error/result_incomplete/recursion_limit',
                'a generated cycle is stopped and refused';
            is failure(sub { my $s = $ring_engine->stream(tree_query($ring_engine, $ring)); 1 while $s->next; $s->close }),
                'query_error/result_incomplete/recursion_limit', 'and so is a streamed one';
            cmp_ok time - $started, '<', 30, 'a cycle does not hold the connection';
            is $read->(), $CHAIN, 'the connection reads on after the refusal';
        } else {
            like failure($tree), qr{\Aquery_error/}, 'past cte_max_recursion_depth MySQL refuses: never short';
        }

        $dbh->do('SET SESSION group_concat_max_len = 200');
        is $collection->(), 40, 'a host group_concat_max_len does not shorten a generated collection';
        if ($mariadb) {
            is +($dbh->selectrow_array('SELECT @@SESSION.group_concat_max_len LIMIT 1'))[0], 200, 'the host setting stands';
            my $sql = 'SELECT JSON_ARRAYAGG(label) FROM selecto_limit_items';
            my $answer = $adapter->execute_query(Selecto::Statement->new(sql => $sql, columns => ['j'], adapter_name => $backend))->{rows}[0][0];
            cmp_ok length($answer), '<=', 202, 'a hand-built aggregate keeps the host limit';
            # What no pin can reach: an aggregate past max_allowed_packet.
            my ($packet) = $dbh->selectrow_array('SELECT @@max_allowed_packet LIMIT 1');
            my $body = 'y' x 100_000;
            $dbh->do('INSERT INTO selecto_limit_items VALUES (?, 2, ?)', undef, 1000 + $_, $body) for 1 .. 1 + int($packet / length $body);
            is failure(sub { $order_engine->all($order_engine->query->select('id', $x->related_collection('items', ['id', 'label'])->as('c'))
                ->where($x->eq('id', 2))) }), 'query_error/result_incomplete/aggregate_length', 'an aggregate past the packet is refused';
        }
        $dbh->do('SET SESSION group_concat_max_len = DEFAULT');
        $dbh->do("DROP TABLE IF EXISTS selecto_limit_$_") for qw(items orders rows ring);
        $dbh->disconnect;
    };
}

done_testing;
