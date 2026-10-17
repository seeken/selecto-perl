use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();

# Lesson 35: under a tenant-bounded root, a graph child that stores no tenant
# column is reachable only through its bound parent. An UPDATE or DELETE
# child always carries "binding key = the bound parent's key" in its WHERE
# and never assigns the binding key, so tenant 10 cannot reach, change,
# delete or re-parent tenant 20's line by naming its id.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub domain {
    my ($t) = @_;
    my $lines = {
        schema_version => 1, name => 'Lines',
        source => {source_table => $t->{lines}, primary_key => 'id', fields => [qw(id order_id note)],
            columns => {id => {type => 'integer'}, order_id => {type => 'integer'}, note => {type => 'string'}},
            associations => {}},
        schemas => {}, joins => {},
        writes => {
            operations => {map { ($_ => {enabled => 1}) } qw(insert update delete)},
            fields => {order_id => {insertable => 1}, note => {insertable => 1, updatable => 1}},
        },
    };
    return Selecto::Domain->parse({
        schema_version => 1, name => 'Orders',
        source => {source_table => $t->{orders}, primary_key => 'id', fields => [qw(id tenant_id title)],
            columns => {id => {type => 'integer'}, tenant_id => {type => 'integer'}, title => {type => 'string'}},
            tenant_field => 'tenant_id', associations => {}},
        schemas => {}, joins => {},
        writes => {
            operations => {update => {enabled => 1}},
            fields => {title => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']}},
            relationships => {lines => {writable => 1, table => $t->{lines}, parent_key => 'id',
                child_key => 'order_id', allowed_ops => [qw(insert update delete)], domain => $lines}},
        },
    });
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "graph children stay under their bound parent on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_gc_${_}_$suffix") } qw(orders lines);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer not null, title text)");
        $dbh->do("CREATE TABLE $t{lines} (id integer primary key, order_id integer not null, note text)");
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 10, 'mine'), (2, 20, 'theirs')");
        $dbh->do("INSERT INTO $t{lines} VALUES (101, 1, 'my line'), (9001, 2, 'their line')");
        my $engine = Selecto::Engine->new(domain => domain(\%t),
            adapter => Selecto->adapter($name => (dbh => $dbh)), scope => {tenant => 10});
        my $lines = sub { $dbh->selectall_arrayref("SELECT id, order_id, note FROM $t{lines} ORDER BY id") };
        my $orders = sub { $dbh->selectall_arrayref("SELECT id, tenant_id, title FROM $t{orders} ORDER BY id") };
        my $graph = sub {
            my ($child) = @_;
            return Selecto::Write::Graph->new(nodes => [
                {id => 'order', command => Selecto::Write::Command->new(operation => 'update', relation => $t{orders},
                    assignments => {title => 'touched'}, predicate => Selecto::Expression->eq('id', 1), expected_count => 1)},
                {id => 'line', command => $child,
                    bindings => [{field => 'order_id', from => 'order', key => 'id'}]},
            ]);
        };
        my @before = (lines => $lines->(), orders => $orders->());

        for my $attack (
            ['update' => Selecto::Write::Command->new(operation => 'update', relation => $t{lines},
                assignments => {note => 'pwned'}, predicate => Selecto::Expression->eq('id', 9001), expected_count => 1)],
            ['delete' => Selecto::Write::Command->new(operation => 'delete', relation => $t{lines},
                predicate => Selecto::Expression->eq('id', 9001), expected_count => 1)],
            ['uncounted update' => Selecto::Write::Command->new(operation => 'update', relation => $t{lines},
                assignments => {note => 'pwned'}, predicate => Selecto::Expression->eq('id', 9001))],
            ['uncounted delete' => Selecto::Write::Command->new(operation => 'delete', relation => $t{lines},
                predicate => Selecto::Expression->eq('id', 9001))],
            ['re-parenting update' => Selecto::Write::Command->new(operation => 'update', relation => $t{lines},
                assignments => {order_id => 1, note => 'moved'}, predicate => Selecto::Expression->eq('id', 9001))],
        ) {
            my ($label, $child) = @$attack;
            my $result;
            my $code = code_of(sub { $result = $engine->execute_graph($graph->($child)) });
            ok($code ne 'ok' || $result->nodes->{line}->affected_rows == 0,
                "$label of tenant 20's line is refused or affects no row ($code)");
            is_deeply($lines->(), {@before}->{lines}, "$label: tenant 20's line is unchanged and not re-parented")
                if $code ne 'ok';
            is_deeply([grep { $_->[0] == 9001 } @{$lines->()}], [[9001, 2, 'their line']],
                "$label: tenant 20's line keeps its parent and note");
            is_deeply([grep { $_->[0] == 2 } @{$orders->()}], [[2, 20, 'theirs']], "$label: tenant 20's order is untouched");
        }

        is(code_of(sub { $engine->execute_graph($graph->(Selecto::Write::Command->new(operation => 'update',
            relation => $t{lines}, assignments => {note => 'edited'}, predicate => Selecto::Expression->eq('id', 101),
            expected_count => 1))) }), 'ok', 'tenant 10 still edits its own line');
        is_deeply([grep { $_->[0] == 101 } @{$lines->()}], [[101, 1, 'edited']], 'and the edit lands under its own order');
        is(code_of(sub { $engine->execute_graph($graph->(Selecto::Write::Command->new(operation => 'delete',
            relation => $t{lines}, predicate => Selecto::Expression->eq('id', 101), expected_count => 1))) }), 'ok',
            'tenant 10 still deletes its own line');
        is_deeply($lines->(), [[9001, 2, 'their line']], 'only its own line is gone');
        $dbh->do("DROP TABLE $t{$_}") for qw(lines orders);
    };
}

done_testing;
