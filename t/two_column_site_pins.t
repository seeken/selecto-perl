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

# Lesson 47b: on a two-column domain (source.tenant_field tenant_id,
# writes.scope.tenant site_id) under an engine tenant, a write that sets
# site_id (insert, update, upsert, batch member, graph root or child, owned
# sync, API write, action) is refused with missing_tenant_scope unless a host
# trusted-scope or required predicate pins the allowed sites with a
# positive top-level eq/IN; host and required pins count alike and are
# intersected. The value must be inside the pin (tenant_mismatch); an
# insert omitting site_id is filled only when exactly one site is pinned.
# Writes that do not set site_id are unaffected. Without this, once writes
# bind tenant_id only (47a), tenant 7 could relabel its own row to tenant
# 8's site 7 and then read tenant 8's site 7 rows through by-name site
# pairing (41c). A graph child tenanted on site_id is checked against the
# root's pin and is never given site_id = engine value. Previews refuse
# exactly what execution refuses.

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
        columns => {map { ($_ => {type => $_ =~ /\A(?:code|name)\z/ ? 'string' : 'integer'}) } @fields}, associations => {}};
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
    return {schema_version => 1, name => 'Orders', domain_version => '1', domain_fingerprint => 'sha256:l47b-orders',
        source => {%{relation($t->{orders}, qw(id tenant_id site_id account_id code total))}, tenant_field => 'tenant_id',
            associations => {account => {queryable => 'account', owner_key => 'account_id', related_key => 'id'}}},
        schemas => {account => {%{relation($t->{accounts}, qw(id site_id name))}, tenant_field => 'site_id'}},
        joins => {account => {type => 'left'}},
        writes => {
            operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
                delete => {enabled => 1}, upsert => {enabled => 1, conflict_targets => [[qw(tenant_id code)]]}},
            fields => {id => {insertable => 1}, site_id => {insertable => 1, updatable => 1}, code => {insertable => 1},
                total => {insertable => 1, updatable => 1}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
            relationships => {lines => {writable => 1, parent_key => 'id', child_key => 'order_id',
                allowed_ops => [qw(insert update delete)], domain => $lines,
                ($o{owned} ? (ownership => 'owned', strategy => 'sync', identity_fields => ['id'], delete_missing => 1) : ())}},
        },
        actions => {
            create => {type => 'create', label => 'Create',
                execution => {kind => 'updato', operation => 'insert', set => {id => 60, code => 'act', total => 1}}},
        }};
}

my $handler = Selecto::API::EngineHandler->new;

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "site pins bound every site_id a write sets on $name" => sub {
        my $dbh = $connect->();
        my $adapter;
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l47b_${_}_$suffix") } qw(orders accounts lines);
        my $original = [[1, 7, 70, 1, 'a', 10], [2, 8, 7, 1, 'b', 20], [3, 7, 71, 1, 'c', 30]];
        my $original_lines = [[10, 1, 70, 1], [11, 1, 7, 2]];
        my $reset = sub {
            %{$dbh->{CachedKids} // {}} = ();
            $adapter = Selecto->adapter($name => (dbh => $dbh));
            $dbh->do("DROP TABLE IF EXISTS $t{$_}") for qw(lines accounts orders);
            $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, account_id integer, code text, total integer)");
            $dbh->do("CREATE UNIQUE INDEX $t{orders}_tc ON $t{orders} (tenant_id, code)");
            $dbh->do("CREATE TABLE $t{accounts} (row_id integer primary key, id integer, site_id integer, name text)");
            $dbh->do("CREATE TABLE $t{lines} (id integer primary key, order_id integer, site_id integer, qty integer)");
            # Tenant 7 uses sites 70 and 71; tenant 8 site 7. Account 1
            # exists once per site; line 11 is a site 7 row under order 1.
            $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 70, 1, 'a', 10), (2, 8, 7, 1, 'b', 20), (3, 7, 71, 1, 'c', 30)");
            $dbh->do("INSERT INTO $t{accounts} VALUES (1, 1, 70, 'mine'), (2, 1, 71, 'mine too'), (3, 1, 7, 'secret of tenant 8')");
            $dbh->do("INSERT INTO $t{lines} VALUES (10, 1, 70, 1), (11, 1, 7, 2)");
        };
        my $orders = sub { $dbh->selectall_arrayref("SELECT id, tenant_id, site_id, account_id, code, total FROM $t{orders} ORDER BY id") };
        my $lines = sub { $dbh->selectall_arrayref("SELECT id, order_id, site_id, qty FROM $t{lines} ORDER BY id") };
        my $engine = sub {
            my (%o) = @_;
            my $domain = Selecto::Domain->parse(contract(\%t, %o));
            $domain = $domain->with_required_predicate($o{required}) if $o{required};
            return Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 7},
                ($o{host} ? (write_context => {required_filters => $o{host}}) : ()));
        };
        my %pin = (
            'no pin' => [],
            'host pin (70, 71)' => [host => [['site_id', 'in', [70, 71]]]],
            'required pin (70, 71)' => [required => $E->in('site_id', [70, 71])],
        );
        my %one = (
            'host pin 70' => [host => [['site_id', 70]]],
            'required pin 70' => [required => $E->eq('site_id', 70)],
            'host (70, 71) and required (70) pins' => [host => [['site_id', 'in', [70, 71]]], required => $E->eq('site_id', 70)],
        );
        my $command = sub { Selecto::Write::Command->new(relation => $t{orders}, @_) };
        my $set_site = sub { my ($id, $site) = @_; $command->(operation => 'update', assignments => {site_id => $site},
            predicate => $E->eq('id', $id), expected_count => 1) };
        my $insert = sub { $command->(operation => 'insert', assignments => {id => 4, code => 'x', total => 1, @_}) };
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
        my $graph = sub {
            my ($root, @children) = @_;
            my $owned = ref($children[-1]) eq 'HASH' ? pop(@children)->{owned} : 0;
            my @ids = map { "line$_" } 0 .. $#children;
            return Selecto::Write::Graph->new(nodes => [{id => 'root', command => $root},
                map { {id => $ids[$_], command => $children[$_], bindings => [{from => 'root', key => 'id', field => 'order_id'}]} }
                    0 .. $#children], ($owned ? (owned_sets => [{parent => 'root', relationship => 'lines', nodes => \@ids,
                    delete_missing => JSON::PP::true}]) : ()));
        };
        my $line = sub {
            my ($operation, $id, %assignments) = @_;
            return Selecto::Write::Command->new(operation => $operation, relation => $t{lines},
                ($operation eq 'delete' ? () : (assignments => \%assignments)),
                ($operation eq 'insert' ? () : (predicate => $E->eq('id', $id))), expected_count => 1);
        };
        my $total = sub { $command->(operation => 'update', assignments => {total => 5}, predicate => $E->eq('id', $_[0]), expected_count => 1) };
        my $account_names = sub {
            my ($e) = @_;
            return [sort map { $_->[1] // 'null' } @{$e->all($e->query->select('id', 'account.name'))->{rows}}];
        };
        my $refused = sub {
            my ($label, $expected, $run) = @_;
            $reset->();
            my @dml;
            watch_dml($dbh, \@dml);
            my $code = code_of($run);
            $dbh->{Callbacks} = undef;
            is($code, $expected, "$label is refused ($expected)");
            is_deeply(\@dml, [], "$label: no DML ran");
            is_deeply($orders->(), $original, "$label: no order changed");
            is_deeply($lines->(), $original_lines, "$label: no line changed");
        };
        my $accepted = sub {
            my ($label, $run, $expect, $expect_lines) = @_;
            $reset->();
            is(code_of($run), 'ok', "$label is accepted");
            is_deeply($orders->(), $expect, "$label: orders as expected") if $expect;
            is_deeply($lines->(), $expect_lines // $original_lines, "$label: lines as expected");
            ok(!grep({ $_->[0] != 2 && $_->[2] == 7 } @{$orders->()}), "$label: no order of tenant 7 sits at site 7");
            ok(!grep({ $_->[0] != 11 && $_->[2] == 7 } @{$lines->()}), "$label: no new line was given site 7");
        };

        for my $variant (sort keys %pin) {
            my @o = @{$pin{$variant}};
            my $expected = @o ? 'tenant_mismatch' : 'missing_tenant_scope';
            # Relabel, then read the site-paired relation: refused, and the
            # read still sees only tenant 7's own site rows.
            $refused->("$variant: relabelling order 1 to site 7", $expected, sub { $engine->(@o)->execute_write($set_site->(1, 7)) });
            is_deeply($account_names->($engine->(@o)), ['mine', 'mine too'], "$variant: the site-paired read stays inside tenant 7's sites");
            $refused->("$variant: a preview of the relabel", $expected, sub { $engine->(@o)->preview_write($set_site->(1, 7)) });
            $refused->("$variant: an API relabel", $expected, sub { $api_write->($engine->(@o),
                {operation => 'update', assignments => {site_id => 7}, filters => [{field => 'id', op => 'eq', value => 1}]}) });
            $refused->("$variant: a batch relabel", $expected, sub { $engine->(@o)->execute_batch(
                Selecto::Write::Batch->new($total->(3), $set_site->(1, 7))) });
            $refused->("$variant: a graph root relabel", $expected, sub { $engine->(@o)->execute_graph($graph->($set_site->(1, 7))) });
            $refused->("$variant: an action insert", 'missing_tenant_scope', sub { my $e = $engine->(@o);
                $e->execute_action($e->plan_action({action => 'create'}), resolver => sub { 'enabled' }) });
            $refused->("$variant: an insert at site 7", $expected, sub { $engine->(@o)->execute_write($insert->(site_id => 7)) });
            $refused->("$variant: an insert omitting site_id", 'missing_tenant_scope', sub { $engine->(@o)->execute_write($insert->()) });
            $refused->("$variant: an upsert", @o ? 'query_enforcement_unsupported_operation' : 'missing_tenant_scope', sub {
                $engine->(@o)->execute_write($command->(operation => 'upsert', assignments => {id => 4, code => 'a', total => 9},
                    metadata => {conflict_target => [qw(tenant_id code)], upsert_update_fields => ['total']})) });
            $refused->("$variant: a graph child at site 7", $expected, sub { $engine->(@o)->execute_graph($graph->(
                $total->(1), $line->('insert', undef, id => 12, site_id => 7, qty => 1))) });
            $refused->("$variant: a graph child omitting site_id", 'missing_tenant_scope', sub { $engine->(@o)->execute_graph($graph->(
                $total->(1), $line->('insert', undef, id => 12, qty => 1))) });
            $refused->("$variant: a graph child moved to site 7", $expected, sub { $engine->(@o)->execute_graph($graph->(
                $total->(1), $line->('update', 10, site_id => 7))) });
            # Writes that do not set site_id are unaffected.
            $accepted->("$variant: an update not touching site_id", sub { $engine->(@o)->execute_write($total->(1)) },
                [[1, 7, 70, 1, 'a', 5], @$original[1, 2]]);
        }
        $accepted->('no pin: a bulk update of totals across tenant 7\'s sites', sub {
            $engine->()->execute_write($command->(operation => 'update', assignments => {total => 0},
                predicate => $E->gt('total', 0), expected_count => undef)) },
            [[1, 7, 70, 1, 'a', 0], [2, 8, 7, 1, 'b', 20], [3, 7, 71, 1, 'c', 0]]);

        for my $variant (sort grep { /70, 71/ } keys %pin) {
            my @o = @{$pin{$variant}};
            $accepted->("$variant: moving order 1 to pinned site 71", sub { $engine->(@o)->execute_write($set_site->(1, 71)) },
                [[1, 7, 71, 1, 'a', 10], @$original[1, 2]]);
            $accepted->("$variant: an insert at pinned site 71", sub { $engine->(@o)->execute_write($insert->(site_id => 71)) },
                [@$original, [4, 7, 71, undef, 'x', 1]]);
            $refused->("$variant: an insert omitting site_id with two sites pinned", 'missing_tenant_scope', sub {
                $engine->(@o)->execute_write($insert->()) });
        }
        for my $variant (sort keys %one) {
            my @o = @{$one{$variant}};
            $accepted->("$variant: an insert omitting site_id is filled", sub { $engine->(@o)->execute_write($insert->()) },
                [@$original, [4, 7, 70, undef, 'x', 1]]);
            $accepted->("$variant: an API insert omitting site_id is filled", sub { $api_write->($engine->(@o),
                {operation => 'insert', assignments => {id => 4, code => 'x', total => 1}}) },
                [@$original, [4, 7, 70, undef, 'x', 1]]);
            $accepted->("$variant: an action insert is filled", sub { my $e = $engine->(@o);
                $e->execute_action($e->plan_action({action => 'create'}), resolver => sub { 'enabled' }) },
                [@$original, [60, 7, 70, undef, 'act', 1]]);
            $refused->("$variant: moving order 1 to site 71", 'tenant_mismatch', sub { $engine->(@o)->execute_write($set_site->(1, 71)) });
            $accepted->("$variant: a graph child omitting site_id gets the pinned site, never 7", sub {
                $engine->(@o)->execute_graph($graph->($total->(1), $line->('insert', undef, id => 12, qty => 3))) },
                [[1, 7, 70, 1, 'a', 5], @$original[1, 2]], [@$original_lines, [12, 1, 70, 3]]);
            $reset->();
            my $preview = $engine->(@o)->preview_write($insert->());
            ok(scalar(grep { defined($_) && $_ eq '70' } @{$preview->{params}}),
                "$variant: a preview inserts the pinned site, as execution does");
            unless (@o == 4) {
                # A pin excluding every value is a host error.
                $refused->("$variant: contradictory pins", 'tenant_mismatch', sub {
                    $engine->(@o, ($o[0] eq 'host' ? (required => $E->eq('site_id', 71)) : (host => [['site_id', 71]])))
                        ->execute_write($insert->()) });
            }
        }

        # Owned sync: a child set under a pinned site, and cleanup confined
        # to the pinned site (line 11 at site 7 is never deleted).
        $reset->();
        if ($engine->(owned => 1)->adapter->write_capabilities->{owned_set_sync}) {
            $accepted->('owned sync under a site pin', sub { $engine->(owned => 1, host => [['site_id', 70]])->execute_graph($graph->(
                $total->(1), $line->('insert', undef, id => 12, qty => 3), {owned => 1})) },
                [[1, 7, 70, 1, 'a', 5], @$original[1, 2]], [[11, 1, 7, 2], [12, 1, 70, 3]]);
            $refused->('owned sync inserting without a pin', 'missing_tenant_scope', sub { $engine->(owned => 1)->execute_graph($graph->(
                $total->(1), $line->('insert', undef, id => 12, qty => 3), {owned => 1})) });
        }

        $dbh->do("DROP TABLE $t{$_}") for qw(lines accounts orders);
    };
}

done_testing;
