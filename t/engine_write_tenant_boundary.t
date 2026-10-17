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

# Lesson 47: a trusted engine tenant limits every write of a domain that
# declares source.tenant_field, with or without writes.scope.tenant. Before,
# a tenant_field domain without writes.scope.tenant was written unbounded:
# under engine tenant 7 an update or delete with a required or host
# tenant_id = 8, a tenant_id IN (7, 8), or only a caller filter id = 2
# changed tenant 8's rows. Now every update, delete, upsert, batch member,
# graph root and child, owned-sync cleanup, action and query-enforced write
# is bound to tenant_id = 7: inserts carry it (filled when absent), another
# value, or a host, required or caller predicate excluding tenant 7, is
# refused with tenant_mismatch before any DML, and an IN list is intersected.

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
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}

sub lines_contract {
    my ($t) = @_;
    return {schema_version => 1, name => 'Lines',
        source => {%{relation($t->{lines}, id => 'integer', order_id => 'integer', tenant_id => 'integer', qty => 'integer')},
            tenant_field => 'tenant_id'},
        schemas => {}, joins => {},
        writes => {operations => {map { ($_ => {enabled => 1}) } qw(insert update delete)},
            fields => {id => {insertable => 1}, tenant_id => {insertable => 1, updatable => 1},
                qty => {insertable => 1, updatable => 1}}}};
}

sub contract {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Orders', domain_version => '1', domain_fingerprint => 'sha256:l47-orders',
        source => {%{relation($t->{orders}, id => 'integer', tenant_id => 'integer', code => 'string',
            total => 'integer', state => 'string')}, tenant_field => 'tenant_id'},
        schemas => {}, joins => {},
        writes => {
            operations => {
                insert => {enabled => 1},
                update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
                delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
                upsert => {enabled => 1, conflict_targets => [[qw(tenant_id code)], ['code']]},
            },
            fields => {id => {insertable => 1}, tenant_id => {insertable => 1, updatable => 1},
                code => {insertable => 1}, total => {insertable => 1, updatable => 1},
                state => {insertable => 1, updatable => 1}},
            transitions => {state => {open => ['closed']}},
            relationships => {lines => {writable => 1, parent_key => 'id', child_key => 'order_id',
                allowed_ops => [qw(insert update delete)], domain => lines_contract($t),
                ($o{owned} ? (ownership => 'owned', strategy => 'sync', identity_fields => ['id'], delete_missing => 1) : ())}},
            ($o{scoped} ? (scope => {tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']}}) : ()),
        },
        actions => {
            close => {type => 'transition', scope => 'row',
                transition => {field => 'state', from => 'open', to => 'closed'},
                execution => {kind => 'updato', operation => 'update', set => {state => 'closed'}}},
            create => {type => 'create', label => 'Create',
                execution => {kind => 'updato', operation => 'insert',
                    set => {id => 60, code => 'act', total => 1, state => 'open'}}},
            create_foreign => {type => 'create', label => 'Create foreign',
                execution => {kind => 'updato', operation => 'insert',
                    set => {id => 61, tenant_id => 8, code => 'act8', total => 1, state => 'open'}}},
        }};
}

# Records every INSERT, UPDATE, DELETE or MERGE the handle runs.
sub watch_dml {
    my ($dbh, $dml) = @_;
    my $is_dml = sub {
        my ($sql) = @_;
        return defined($sql) && ($sql =~ /\A\s*(?:INSERT|UPDATE|DELETE|MERGE)\b/i
            || $sql =~ /\A\s*WITH\b/i && $sql =~ /\b(?:INSERT\s+INTO|DELETE\s+FROM|UPDATE\s+\S+\s+SET)\b/i);
    };
    $dbh->{Callbacks} = {
        do => sub { push @$dml, $_[1] if $is_dml->($_[1]); return },
        ChildCallbacks => {execute => sub { push @$dml, $_[0]->{Statement} if $is_dml->($_[0]->{Statement}); return }},
    };
}

my $handler = Selecto::API::EngineHandler->new;

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "a trusted engine tenant bounds every write on $name" => sub {
        my $dbh = $connect->();
        my $adapter;
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l47_${_}_$suffix") } qw(orders lines);
        my $reset = sub {
            # A fresh adapter and statement cache, so a watched refusal
            # cannot reuse a statement handle prepared before the watch.
            %{$dbh->{CachedKids} // {}} = ();
            $adapter = Selecto->adapter($name => (dbh => $dbh));
            $dbh->do("DROP TABLE IF EXISTS $t{$_}") for qw(lines orders);
            $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, code text, total integer, state text)");
            $dbh->do("CREATE UNIQUE INDEX $t{orders}_tc ON $t{orders} (tenant_id, code)");
            $dbh->do("CREATE TABLE $t{lines} (id integer primary key, order_id integer, tenant_id integer, qty integer)");
            # Tenant 8 shares code 'a' with tenant 7; line 12 is a tenant 8 row
            # under tenant 7's order 1.
            $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 'a', 10, 'open'), (2, 8, 'b', 20, 'open'), (3, 7, 'c', 30, 'open'), (4, 8, 'a', 40, 'open')");
            $dbh->do("INSERT INTO $t{lines} VALUES (10, 1, 7, 1), (11, 2, 8, 2), (12, 1, 8, 3)");
        };
        my $orders = sub { $dbh->selectall_arrayref("SELECT id, tenant_id, code, total, state FROM $t{orders} ORDER BY id") };
        my $lines = sub { $dbh->selectall_arrayref("SELECT id, order_id, tenant_id, qty FROM $t{lines} ORDER BY id") };
        my $original_orders = [[1, 7, 'a', 10, 'open'], [2, 8, 'b', 20, 'open'], [3, 7, 'c', 30, 'open'], [4, 8, 'a', 40, 'open']];
        my $original_lines = [[10, 1, 7, 1], [11, 2, 8, 2], [12, 1, 8, 3]];
        my $tenant8 = sub { [grep { $_->[1] == 8 } @{$orders->()}] };
        my $engine = sub {
            my (%o) = @_;
            my $domain = Selecto::Domain->parse(contract(\%t, %o));
            $domain = $domain->with_required_predicate($o{required}) if $o{required};
            return Selecto::Engine->new(domain => $domain, adapter => $adapter,
                ($o{untenanted} ? () : (scope => {tenant => 7})),
                ($o{host} ? (write_context => {required_filters => $o{host}}) : ()));
        };
        my $command = sub { Selecto::Write::Command->new(relation => $t{orders}, @_) };
        my $bulk_update = sub { $command->(operation => 'update', assignments => {total => 99},
            predicate => $E->gt('total', 0), expected_count => undef, @_) };
        my $bulk_delete = sub { $command->(operation => 'delete', predicate => $E->gt('total', 0), expected_count => undef, @_) };
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
            return $decoded->{ok} ? 'ok' : $decoded->{error}{code};
        };
        my $resolver = sub { 'enabled' };
        my $graph = sub {
            my ($root, @children) = @_;
            my $owned = ref($children[-1]) eq 'HASH' ? pop(@children)->{owned} : 0;
            my @ids = map { "line$_" } 0 .. $#children;
            return Selecto::Write::Graph->new(nodes => [
                {id => 'root', command => $root},
                map { {id => $ids[$_], command => $children[$_],
                    bindings => [{from => 'root', key => 'id', field => 'order_id'}]} } 0 .. $#children,
            ], ($owned ? (owned_sets => [{parent => 'root', relationship => 'lines', nodes => \@ids,
                delete_missing => JSON::PP::true}]) : ()));
        };
        my $line = sub {
            my ($operation, $id, %assignments) = @_;
            return Selecto::Write::Command->new(operation => $operation, relation => $t{lines},
                ($operation eq 'delete' ? () : (assignments => \%assignments)),
                ($operation eq 'insert' ? () : (predicate => $E->eq('id', $id))), expected_count => 1);
        };
        my $root_update = sub { my ($id) = @_; $command->(operation => 'update', assignments => {total => 5},
            predicate => $E->eq('id', $id), expected_count => 1) };

        # Every refusal: the code, no DML at all for tenant_mismatch, and
        # both tables unchanged.
        my $refused = sub {
            my ($label, $expected, $run) = @_;
            $reset->();
            my @dml;
            watch_dml($dbh, \@dml);
            my $code = code_of($run);
            $dbh->{Callbacks} = undef;
            is($code, $expected, "$label is refused ($expected)");
            is_deeply(\@dml, [], "$label: no DML ran") if $expected =~ /\A(?:tenant_mismatch|missing_tenant_scope|tenant_scope_conflict_target)\z/;
            is_deeply($orders->(), $original_orders, "$label: no order changed");
            is_deeply($lines->(), $original_lines, "$label: no line changed");
        };
        # Every accepted write: tenant 8's rows are exactly as before.
        my $accepted = sub {
            my ($label, $run, $expect_orders, $expect_lines) = @_;
            $reset->();
            is(code_of($run), 'ok', "$label is accepted");
            is_deeply($orders->(), $expect_orders, "$label: only tenant 7's orders changed") if $expect_orders;
            is_deeply($lines->(), $expect_lines // $original_lines, "$label: lines as expected");
            is_deeply($tenant8->(), [[2, 8, 'b', 20, 'open'], [4, 8, 'a', 40, 'open']], "$label: tenant 8's orders are untouched");
        };
        my $updated7 = [[1, 7, 'a', 99, 'open'], [2, 8, 'b', 20, 'open'], [3, 7, 'c', 99, 'open'], [4, 8, 'a', 40, 'open']];
        my $deleted7 = [[2, 8, 'b', 20, 'open'], [4, 8, 'a', 40, 'open']];

        # The audit's cases, each of which changed tenant 8's rows before.
        for my $source (['required', sub { (required => $_[0]) }], ['host', sub { (host => $_[1]) }]) {
            my ($kind, $with) = @$source;
            my %eight = $with->($E->eq('tenant_id', 8), [['tenant_id', 8]]);
            my %both = $with->($E->in('tenant_id', [7, 8]), [['tenant_id', 'in', [7, 8]]]);
            $refused->("$kind tenant_id = 8: update", 'tenant_mismatch', sub { $engine->(%eight)->execute_write($bulk_update->()) });
            $refused->("$kind tenant_id = 8: delete", 'tenant_mismatch', sub { $engine->(%eight)->execute_write($bulk_delete->()) });
            $refused->("$kind tenant_id = 8: API update", 'tenant_mismatch', sub {
                my $code = $api_write->($engine->(%eight), {operation => 'update', assignments => {total => 99},
                    filters => [{field => 'total', op => 'gt', value => 0}], expected_count => 2});
                Selecto::Error->throw($code, $code) unless $code eq 'ok' });
            $refused->("$kind tenant_id = 8: graph", 'tenant_mismatch', sub { $engine->(%eight)->execute_graph($graph->($root_update->(1))) });
            $accepted->("$kind tenant_id IN (7, 8): update", sub { $engine->(%both)->execute_write($bulk_update->()) }, $updated7);
            $accepted->("$kind tenant_id IN (7, 8): delete", sub { $engine->(%both)->execute_write($bulk_delete->()) }, $deleted7);
            $accepted->("$kind tenant_id IN (7, 8): API update", sub {
                my $code = $api_write->($engine->(%both), {operation => 'update', assignments => {total => 99},
                    filters => [{field => 'total', op => 'gt', value => 0}], expected_count => 2});
                die "API: $code" unless $code eq 'ok' }, $updated7);
        }
        $accepted->('no predicate: update', sub { $engine->()->execute_write($bulk_update->()) }, $updated7);
        $accepted->('no predicate: delete', sub { $engine->()->execute_write($bulk_delete->()) }, $deleted7);
        $refused->('caller id = 2: update', 'cardinality_mismatch', sub {
            $engine->()->execute_write($command->(operation => 'update', assignments => {total => 0},
                predicate => $E->eq('id', 2), expected_count => 1)) });
        $refused->('caller id = 2: delete', 'cardinality_mismatch', sub {
            $engine->()->execute_write($command->(operation => 'delete', predicate => $E->eq('id', 2), expected_count => 1)) });
        $refused->('caller id = 2: API update', 'cardinality_mismatch', sub {
            my $code = $api_write->($engine->(), {operation => 'update', assignments => {total => 0},
                filters => [{field => 'id', op => 'eq', value => 2}]});
            Selecto::Error->throw($code, $code) unless $code eq 'ok' });
        $refused->('caller id = 2: graph root', 'cardinality_mismatch', sub { $engine->()->execute_graph($graph->($root_update->(2))) });
        $refused->('caller tenant_id = 8', 'tenant_mismatch', sub { $engine->()->execute_write($bulk_update->(
            predicate => $E->all($E->gt('total', 0), $E->eq('tenant_id', 8)))) });
        $accepted->('caller tenant_id IN (7, 8)', sub { $engine->()->execute_write($bulk_update->(
            predicate => $E->in('tenant_id', [7, 8]))) }, $updated7);

        # Inserts carry the tenant; upserts resolve conflicts inside it.
        $refused->('insert of a tenant 8 row', 'tenant_mismatch', sub { $engine->()->execute_write($command->(
            operation => 'insert', assignments => {id => 5, tenant_id => 8, code => 'x', total => 1, state => 'open'})) });
        $refused->('update re-tagging a row to tenant 8', 'tenant_mismatch', sub { $engine->()->execute_write($command->(
            operation => 'update', assignments => {tenant_id => 8}, predicate => $E->eq('id', 1), expected_count => 1)) });
        $accepted->('insert omitting the tenant', sub { $engine->()->execute_write($command->(
            operation => 'insert', assignments => {id => 5, code => 'x', total => 1, state => 'open'})) },
            [@$original_orders, [5, 7, 'x', 1, 'open']]);
        $accepted->('API insert omitting the tenant', sub {
            my $code = $api_write->($engine->(), {operation => 'insert', assignments => {id => 5, code => 'x', total => 1, state => 'open'}});
            die "API: $code" unless $code eq 'ok' }, [@$original_orders, [5, 7, 'x', 1, 'open']]);
        $accepted->('upsert on (tenant_id, code) colliding with tenant 8\'s code', sub { $engine->()->execute_write($command->(
            operation => 'upsert', assignments => {id => 9, code => 'a', total => 77, state => 'open'},
            metadata => {conflict_target => [qw(tenant_id code)], upsert_update_fields => ['total']})) },
            [[1, 7, 'a', 77, 'open'], @$original_orders[1 .. 3]]);
        $refused->('upsert resolving conflicts without the tenant column', 'tenant_scope_conflict_target', sub {
            $engine->()->execute_write($command->(operation => 'upsert', assignments => {id => 9, code => 'a', total => 77, state => 'open'},
                metadata => {conflict_target => ['code'], upsert_update_fields => ['total']})) });

        # Batches, query-enforced writes and actions.
        $refused->('a batch reaching tenant 8\'s row', 'cardinality_mismatch', sub { $engine->()->execute_batch(
            Selecto::Write::Batch->new($root_update->(1), $root_update->(2))) });
        $accepted->('a batch of bulk writes', sub { $engine->()->execute_batch(
            Selecto::Write::Batch->new($bulk_update->(), $bulk_delete->(predicate => $E->eq('code', 'zzz')))) }, $updated7);
        $refused->('a batch inserting a tenant 8 row', 'tenant_mismatch', sub { $engine->()->execute_batch(Selecto::Write::Batch->new(
            $command->(operation => 'insert', assignments => {id => 5, tenant_id => 8, code => 'x', total => 1, state => 'open'}))) });
        $accepted->('a query-enforced update', sub { my $e = $engine->();
            $e->execute_write($e->enforce_query($bulk_update->(), $e->query->where($E->gt('total', 0)))) }, $updated7);
        $refused->('a query-enforced update for tenant 8', 'tenant_mismatch', sub { my $e = $engine->();
            $e->execute_write($e->enforce_query($bulk_update->(), $e->query->where($E->eq('tenant_id', 8)))) });
        $refused->('an action on tenant 8\'s row', 'cardinality_mismatch', sub { my $e = $engine->();
            $e->execute_action($e->plan_action({action => 'close', target => 2}), resolver => $resolver) });
        $refused->('an action inserting a tenant 8 row', 'tenant_mismatch', sub { my $e = $engine->();
            $e->execute_action($e->plan_action({action => 'create_foreign'}), resolver => $resolver) });
        $accepted->('an action inserting without a tenant', sub { my $e = $engine->();
            $e->execute_action($e->plan_action({action => 'create'}), resolver => $resolver) },
            [@$original_orders, [60, 7, 'act', 1, 'open']]);

        # Graph children and owned-sync rows.
        $refused->('a graph child of tenant 8', 'tenant_mismatch', sub { $engine->()->execute_graph($graph->(
            $root_update->(1), $line->('insert', undef, id => 20, tenant_id => 8, qty => 1))) });
        $refused->('a graph child update of tenant 8\'s line', 'cardinality_mismatch', sub { $engine->()->execute_graph($graph->(
            $root_update->(1), $line->('update', 12, qty => 0))) });
        $accepted->('a graph child omitting its tenant', sub { $engine->()->execute_graph($graph->(
            $root_update->(1), $line->('insert', undef, id => 20, qty => 4))) },
            [[1, 7, 'a', 5, 'open'], @$original_orders[1 .. 3]], [@$original_lines, [20, 1, 7, 4]]);
        $reset->();
        if ($engine->(owned => 1)->adapter->write_capabilities->{owned_set_sync}) {
            $accepted->('owned sync cleanup', sub { $engine->(owned => 1)->execute_graph($graph->(
                $root_update->(1), $line->('update', 10, qty => 9), {owned => 1})) },
                [[1, 7, 'a', 5, 'open'], @$original_orders[1 .. 3]], [[10, 1, 7, 9], [11, 2, 8, 2], [12, 1, 8, 3]]);
        }

        # Control: the same domain with writes.scope.tenant on tenant_id.
        $refused->('writes.scope.tenant: required tenant_id = 8', 'tenant_mismatch', sub {
            $engine->(scoped => 1, required => $E->eq('tenant_id', 8))->execute_write($bulk_update->()) });
        $accepted->('writes.scope.tenant: no predicate', sub { $engine->(scoped => 1)->execute_write($bulk_update->()) }, $updated7);
        # A public write without any tenant boundary is still refused.
        $refused->('an API write without a tenant boundary', 'missing_tenant_scope', sub {
            my $code = $api_write->($engine->(untenanted => 1), {operation => 'update', assignments => {total => 0},
                filters => [{field => 'id', op => 'eq', value => 1}]});
            Selecto::Error->throw($code, $code) unless $code eq 'ok' });

        $dbh->do("DROP TABLE $t{$_}") for qw(lines orders);
    };
}

done_testing;
