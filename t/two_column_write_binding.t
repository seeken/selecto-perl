use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();

# Lesson 47a: on a two-column domain (source.tenant_field tenant_id,
# writes.scope.tenant site_id) the engine tenant means tenant_id on writes
# too, as on reads (41c). Before, writes bound site_id to the engine value:
# with colliding values (tenant 7 at sites 70 and 71, tenant 8 at site 7) an
# engine tenant 7 update, delete, API write or graph root reached tenant 8's
# site 7 row and missed tenant 7's own rows, and a graph child tenanted on
# site_id was bound site_id = 7. Now every write binds tenant_id = 7 and
# site_id is never bound to the engine value: it is pinned only by a host
# trusted-scope or required predicate.

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

my $E = 'Selecto::Expression';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}
sub relation {
    my ($table, @fields) = @_;
    return {source_table => $table, primary_key => 'id', fields => [@fields],
        columns => {map { ($_ => {type => $_ eq 'code' ? 'string' : 'integer'}) } @fields}, associations => {}};
}
sub watch_dml {
    my ($dbh, $dml) = @_;
    $dbh->{Callbacks} = {
        do => sub { push @$dml, $_[1] if $_[1] =~ /\A\s*(?:INSERT|UPDATE|DELETE|MERGE)\b/i; return },
        ChildCallbacks => {execute => sub {
            push @$dml, $_[0]->{Statement} if $_[0]->{Statement} =~ /\A\s*(?:INSERT|UPDATE|DELETE|MERGE)\b/i; return }},
    };
}

sub contract {
    my ($t, %o) = @_;
    my $lines = {schema_version => 1, name => 'Lines',
        source => {%{relation($t->{lines}, qw(id order_id site_id qty))}, tenant_field => 'site_id'},
        schemas => {}, joins => {},
        writes => {operations => {map { ($_ => {enabled => 1}) } qw(insert update delete)},
            fields => {id => {insertable => 1}, site_id => {insertable => 1, updatable => 1}, qty => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}}};
    return {schema_version => 1, name => 'Orders', domain_version => '1', domain_fingerprint => 'sha256:l47a-orders',
        source => {%{relation($t->{orders}, qw(id tenant_id site_id code total))}, tenant_field => 'tenant_id'},
        schemas => {}, joins => {},
        writes => {
            operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
                delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {id => {insertable => 1}, tenant_id => {insertable => 1, updatable => 1},
                site_id => {insertable => 1, updatable => 1}, code => {insertable => 1}, total => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
            relationships => {lines => {writable => 1, parent_key => 'id', child_key => 'order_id',
                allowed_ops => [qw(insert update delete)], domain => $lines}},
        }};
}

my $handler = Selecto::API::EngineHandler->new;

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "two-column writes bind tenant_id, never site_id, on $name" => sub {
        my $dbh = $connect->();
        my $adapter;
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l47a_${_}_$suffix") } qw(orders lines);
        my $original = [[1, 7, 70, 'a', 10], [2, 8, 7, 'b', 20], [3, 7, 71, 'c', 30]];
        my $original_lines = [[10, 1, 70, 1], [11, 2, 7, 2]];
        my $reset = sub {
            %{$dbh->{CachedKids} // {}} = ();
            $adapter = Selecto->adapter($name => (dbh => $dbh));
            $dbh->do("DROP TABLE IF EXISTS $t{$_}") for qw(lines orders);
            $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, code text, total integer)");
            $dbh->do("CREATE TABLE $t{lines} (id integer primary key, order_id integer, site_id integer, qty integer)");
            # Colliding values: tenant 8's site is 7, the engine tenant.
            $dbh->do("INSERT INTO $t{orders} VALUES " . join(', ', map { '(' . join(', ', map { /\D/ ? "'$_'" : $_ } @$_) . ')' } @$original));
            $dbh->do("INSERT INTO $t{lines} VALUES (10, 1, 70, 1), (11, 2, 7, 2)");
        };
        my $orders = sub { $dbh->selectall_arrayref("SELECT id, tenant_id, site_id, code, total FROM $t{orders} ORDER BY id") };
        my $lines = sub { $dbh->selectall_arrayref("SELECT id, order_id, site_id, qty FROM $t{lines} ORDER BY id") };
        my $engine = sub {
            my (%o) = @_;
            my $domain = Selecto::Domain->parse(contract(\%t));
            $domain = $domain->with_required_predicate($o{required}) if $o{required};
            return Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7},
                ($o{host} ? (write_context => {required_filters => $o{host}}) : ()));
        };
        my $command = sub { Selecto::Write::Command->new(relation => $t{orders}, @_) };
        my $bulk_update = sub { $command->(operation => 'update', assignments => {total => 99},
            predicate => $E->gt('total', 0), expected_count => undef, @_) };
        my $bulk_delete = sub { $command->(operation => 'delete', predicate => $E->gt('total', 0), expected_count => undef) };
        my $api = Selecto::API->new(domain => Selecto::Domain->parse(contract(\%t)), base_path => '/api');
        my $api_write = sub {
            my ($e, $body) = @_;
            my $response = $api->request({method => 'POST', path => '/api/write', body => $body}, {
                write => sub { my ($intent) = @_; my $data = eval { $handler->write($e, $intent) };
                    return ['ok', $data] unless $@;
                    my $error = $@; die $error unless blessed($error) && $error->isa('Selecto::Error');
                    return ['error', {status => Selecto::API::error_status($error->code), code => $error->code,
                        message => $error->message, details => $error->details}] },
            });
            my $decoded = JSON::PP->new->decode($response->{body});
            Selecto::Error->throw($decoded->{error}{code}, 'API refusal') unless $decoded->{ok};
            return $decoded;
        };
        my $root_update = sub { $command->(operation => 'update', assignments => {total => 5},
            predicate => $E->eq('id', $_[0]), expected_count => 1) };
        my $graph = sub {
            my ($root, @children) = @_;
            return Selecto::Write::Graph->new(nodes => [{id => 'root', command => $root},
                map { {id => "line$_", command => $children[$_], bindings => [{from => 'root', key => 'id', field => 'order_id'}]} }
                    0 .. $#children]);
        };
        my $line = sub {
            my ($operation, $id, %assignments) = @_;
            return Selecto::Write::Command->new(operation => $operation, relation => $t{lines},
                ($operation eq 'delete' ? () : (assignments => \%assignments)),
                ($operation eq 'insert' ? () : (predicate => $E->eq('id', $id))), expected_count => 1);
        };
        my $refused = sub {
            my ($label, $expected, $run) = @_;
            $reset->();
            my @dml;
            watch_dml($dbh, \@dml);
            my $code = code_of($run);
            $dbh->{Callbacks} = undef;
            is($code, $expected, "$label is refused ($expected)");
            is_deeply(\@dml, [], "$label: no DML ran") if $expected =~ /tenant/;
            is_deeply($orders->(), $original, "$label: no order changed");
            is_deeply($lines->(), $original_lines, "$label: no line changed");
        };
        my $accepted = sub {
            my ($label, $run, $expect, $expect_lines) = @_;
            $reset->();
            is(code_of($run), 'ok', "$label is accepted");
            is_deeply($orders->(), $expect, "$label: orders as expected");
            is_deeply($lines->(), $expect_lines // $original_lines, "$label: lines as expected");
            is_deeply([grep { $_->[1] == 8 } @{$orders->()}], [[2, 8, 7, 'b', 20]], "$label: tenant 8's site 7 row is untouched");
        };
        my $updated = [[1, 7, 70, 'a', 99], [2, 8, 7, 'b', 20], [3, 7, 71, 'c', 99]];

        $accepted->('an update', sub { $engine->()->execute_write($bulk_update->()) }, $updated);
        $accepted->('a delete', sub { $engine->()->execute_write($bulk_delete->()) }, [[2, 8, 7, 'b', 20]]);
        $accepted->('an API update', sub { $api_write->($engine->(), {operation => 'update', assignments => {total => 99},
            filters => [{field => 'total', op => 'gt', value => 0}], expected_count => 2}) }, $updated);
        $accepted->('a graph root update of its own row', sub { $engine->()->execute_graph($graph->($root_update->(1))) },
            [[1, 7, 70, 'a', 5], @$original[1, 2]]);
        $refused->('an update of tenant 8\'s site 7 row', 'cardinality_mismatch', sub { $engine->()->execute_write($root_update->(2)) });
        $refused->('an API update of tenant 8\'s site 7 row', 'cardinality_mismatch', sub {
            $api_write->($engine->(), {operation => 'update', assignments => {total => 0}, filters => [{field => 'id', op => 'eq', value => 2}]}) });
        $refused->('a graph root update of tenant 8\'s site 7 row', 'cardinality_mismatch', sub {
            $engine->()->execute_graph($graph->($root_update->(2))) });
        $refused->('a required tenant_id = 8', 'tenant_mismatch', sub {
            $engine->(required => $E->eq('tenant_id', 8))->execute_write($bulk_update->()) });
        $refused->('a host tenant_id = 8', 'tenant_mismatch', sub {
            $engine->(host => [['tenant_id', 8]])->execute_write($bulk_update->()) });
        $accepted->('a required site_id = 7 pin', sub { $engine->(required => $E->eq('site_id', 7))->execute_write($bulk_update->()) },
            $original);
        $accepted->('a host site_id IN (70, 71) pin', sub { $engine->(host => [['site_id', 'in', [70, 71]]])->execute_write($bulk_update->()) },
            $updated);
        $accepted->('a caller site_id = 7 filter', sub { $engine->()->execute_write($bulk_update->(
            predicate => $E->eq('site_id', 7))) }, $original);

        $refused->('an insert for tenant 8', 'tenant_mismatch', sub { $engine->()->execute_write($command->(operation => 'insert',
            assignments => {id => 4, tenant_id => 8, site_id => 70, code => 'x', total => 1})) });
        $accepted->('an insert at a pinned site', sub { $engine->(host => [['site_id', 70]])->execute_write($command->(
            operation => 'insert', assignments => {id => 4, site_id => 70, code => 'x', total => 1})) },
            [@$original, [4, 7, 70, 'x', 1]]);

        # The SQL a preview shows binds tenant_id, never site_id, to 7.
        $reset->();
        my $preview = $engine->()->preview_write($root_update->(1));
        like($preview->{sql}, qr/tenant_id"? = (?:\?|\$\d)/, 'a preview binds tenant_id');
        unlike($preview->{sql}, qr/site_id/, 'and never site_id');

        # A graph child tenanted on site_id is never given site_id = 7.
        $accepted->('a site_id child at a pinned site', sub { $engine->(host => [['site_id', 70]])->execute_graph($graph->(
            $root_update->(1), $line->('insert', undef, id => 12, site_id => 70, qty => 3))) },
            [[1, 7, 70, 'a', 5], @$original[1, 2]], [@$original_lines, [12, 1, 70, 3]]);
        $refused->('a graph child under tenant 8\'s site 7 row', 'cardinality_mismatch', sub { $engine->()->execute_graph($graph->(
            $root_update->(2), $line->('update', 11, qty => 0))) });

        $dbh->do("DROP TABLE $t{$_}") for qw(lines orders);
    };
}

done_testing;
