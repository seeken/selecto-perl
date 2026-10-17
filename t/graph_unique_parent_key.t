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

# Lesson 36: under a tenant-bounded root, a graph or sync relationship's
# parent_key must be the parent's primary key or exactly a single-column
# upsert conflict target. Here parts bind to their item by a code that tenant
# 7's and tenant 8's items share: through tenant 7's item, a two-hop graph
# would reach tenant 8's part. Such a domain is refused when the engine is
# built (invalid_domain, foreign_key_tenant_scope_undeclared). A parent
# naming its child's primary key binds one child, and is accepted when the
# child domain is tenant-bounded.

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

sub error_of {
    my ($code) = @_;
    return undef if eval { $code->(); 1 };
    return $@;
}
sub relation {
    my ($table, $types) = @_;
    my @fields = sort keys %$types;
    return {source_table => $table, primary_key => 'id', fields => \@fields,
        columns => {map { ($_ => {type => $types->{$_}}) } @fields}, associations => {}};
}

sub domain {
    my ($t, %o) = @_;
    my $parts = {schema_version => 1, name => 'Parts',
        source => {%{relation($t->{parts}, {id => 'integer', item_code => 'string', note => 'string',
            ($o{parts_tenant} ? (tenant_id => 'integer') : ())})},
            ($o{parts_tenant} ? (tenant_field => 'tenant_id') : ())},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {note => {updatable => 1}}}};
    my $items = {schema_version => 1, name => 'Items',
        source => relation($t->{items}, {id => 'integer', order_id => 'integer', code => 'string', status => 'string'}),
        schemas => {}, joins => {},
        writes => {
            operations => {update => {enabled => 1},
                (defined($o{conflict_targets}) ? (upsert => {enabled => 1, conflict_targets => $o{conflict_targets}}) : ())},
            fields => {status => {updatable => 1}},
            relationships => {parts => {writable => 1, table => $t->{parts}, parent_key => $o{parent_key} // 'code',
                child_key => $o{child_key} // 'item_code', allowed_ops => ['update'], domain => $parts}},
        }};
    return Selecto::Domain->parse({schema_version => 1, name => 'Orders',
        source => {%{relation($t->{orders}, {id => 'integer', tenant_id => 'integer', title => 'string'})},
            tenant_field => 'tenant_id'},
        schemas => {}, joins => {},
        writes => {
            operations => {update => {enabled => 1}},
            fields => {title => {updatable => 1}},
            scope => {tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']}},
            relationships => {items => {writable => 1, table => $t->{items}, parent_key => 'id',
                child_key => 'order_id', allowed_ops => ['update'], domain => $items}},
        }});
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "unique graph parent keys on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_upk_${_}_$suffix") } qw(orders items parts);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, title text)");
        $dbh->do("CREATE TABLE $t{items} (id integer primary key, order_id integer, tenant_id integer, code text, status text)");
        $dbh->do("CREATE TABLE $t{parts} (id integer primary key, item_code text, note text)");
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 'mine'), (2, 8, 'theirs')");
        $dbh->do("INSERT INTO $t{items} VALUES (11, 1, 7, 'X', 'new'), (21, 2, 8, 'X', 'new')");
        $dbh->do("INSERT INTO $t{parts} VALUES (90, 'X', 'their part')");
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $graph = Selecto::Write::Graph->new(nodes => [
            {id => 'order', command => Selecto::Write::Command->new(operation => 'update', relation => $t{orders},
                assignments => {title => 'touched'}, predicate => Selecto::Expression->eq('id', 1), expected_count => 1)},
            {id => 'item', command => Selecto::Write::Command->new(operation => 'update', relation => $t{items},
                assignments => {status => 'seen'}, predicate => Selecto::Expression->eq('id', 11), expected_count => 1,
                metadata => {returning => [qw(id code)]}),
                bindings => [{field => 'order_id', from => 'order', key => 'id'}]},
            {id => 'part', command => Selecto::Write::Command->new(operation => 'update', relation => $t{parts},
                assignments => {note => 'pwned'}, predicate => Selecto::Expression->eq('id', 90), expected_count => 1),
                bindings => [{field => 'item_code', from => 'item', key => 'code'}]},
        ]);
        my $part = sub { ($dbh->selectrow_array("SELECT note FROM $t{parts} WHERE id = 90"))[0] };

        for my $case (['a non-unique code', undef], ['a composite (order_id, code) conflict target', [[qw(order_id code)]]]) {
            my ($label, $targets) = @$case;
            my $error = error_of(sub {
                my $engine = Selecto::Engine->new(domain => domain(\%t, conflict_targets => $targets),
                    adapter => $adapter, scope => {tenant => 7});
                $engine->execute_graph($graph);
            });
            is($error && blessed($error) && $error->code, 'invalid_domain', "$label parent_key is refused");
            is($error && blessed($error) && $error->details->{code}, 'foreign_key_tenant_scope_undeclared',
                "$label: foreign_key_tenant_scope_undeclared");
            is($error && blessed($error) && $error->details->{parent_key}, 'code', "$label: names the parent_key");
            is($part->(), 'their part', "$label: tenant 8's part is untouched");
        }
        is(error_of(sub { Selecto::Engine->new(domain => domain(\%t, conflict_targets => [['code']]),
            adapter => $adapter, scope => {tenant => 7}) }), undef,
            'a single-column conflict target on the parent key is accepted');
        is(error_of(sub { Selecto::Engine->new(domain => domain(\%t, parent_key => 'id'),
            adapter => $adapter, scope => {tenant => 7}) }), undef, 'the parent primary key is accepted');
        # The parent holding its child's id (as a truck holds its trailer's) binds one child.
        is(error_of(sub { Selecto::Engine->new(domain => domain(\%t, child_key => 'id', parts_tenant => 1),
            adapter => $adapter, scope => {tenant => 7}) }), undef,
            "a reference to a tenant-bounded child's primary key is accepted");
        my $unbounded = error_of(sub { Selecto::Engine->new(domain => domain(\%t, child_key => 'id'),
            adapter => $adapter, scope => {tenant => 7}) });
        is($unbounded && blessed($unbounded) && $unbounded->details->{code}, 'foreign_key_tenant_scope_undeclared',
            'a reference to the primary key of a child without a tenant boundary is refused');
        $dbh->do("DROP TABLE $t{$_}") for qw(parts items orders);
    };
}

done_testing;
