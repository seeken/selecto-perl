use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();

# Tenant identity on MySQL/MariaDB compares exactly, as on PostgreSQL. The
# tenant columns below keep the server's default collation (or a named
# case-insensitive NO PAD or PAD SPACE one), where 't1' equals 'T1' and, on
# PAD SPACE collations, 't1 '. Under tenant 't1' every read, join, write,
# RETURNING re-read, guarded insert, reference guard and graph child must
# touch only the exact 't1' rows.

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

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

sub contract {
    my (%t) = @_;
    my $line = {%{relation($t{lines}, id => 'integer', order_id => 'integer', tenant_id => 'string', qty => 'integer')},
        tenant_field => 'tenant_id'};
    my $customer = {%{relation($t{customers}, id => 'integer', tenant_id => 'string', name => 'string')},
        tenant_field => 'tenant_id'};
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation($t{orders}, id => 'integer', tenant_id => 'string', code => 'string', total => 'integer',
            customer_id => 'integer')}, tenant_field => 'tenant_id', associations => {
                lines => {queryable => 'line', owner_key => 'id', related_key => 'order_id', cardinality => 'many'},
                customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id'},
            }},
        schemas => {line => $line, customer => $customer},
        joins => {},
        writes => {
            operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1, expected_cardinality => 'many'},
                delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {map { ($_ => {insertable => 1, updatable => 1}) } qw(id tenant_id code total customer_id)},
            relationships => {lines => {writable => 1, parent_key => 'id', child_key => 'order_id',
                allowed_ops => [qw(insert update delete)],
                domain => {schema_version => 1, name => 'Lines', source => $line, schemas => {}, joins => {},
                    writes => {operations => {map { ($_ => {enabled => 1}) } qw(insert update delete)},
                        fields => {id => {insertable => 1}, tenant_id => {insertable => 1}, qty => {insertable => 1, updatable => 1}}}}}},
        },
    };
}

my %COLLATIONS = (
    mysql => [['server default', 'utf8mb4', ''], ['case-insensitive NO PAD', 'utf8mb4', 'utf8mb4_0900_ai_ci'],
        ['PAD SPACE', 'utf8mb4', 'utf8mb4_general_ci'], ['utf16 PAD SPACE', 'utf16', 'utf16_general_ci'],
        ['latin1 PAD SPACE', 'latin1', 'latin1_swedish_ci']],
    mariadb => [['server default', 'utf8mb4', ''], ['case-insensitive NO PAD', 'utf8mb4', 'utf8mb4_uca1400_nopad_ai_ci'],
        ['PAD SPACE', 'utf8mb4', 'utf8mb4_general_ci'], ['utf16 PAD SPACE', 'utf16', 'utf16_general_ci'],
        ['latin1 PAD SPACE', 'latin1', 'latin1_swedish_ci']],
);

for my $specification (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($backend, $environment) = @$specification;
    subtest "$backend tenant identity" => sub {
        plan skip_all => "$environment is not configured"
            unless defined($ENV{$environment}) && $ENV{$environment} ne '';
        my $dbh = open_db($backend, $ENV{$environment});
        for my $variant (@{$COLLATIONS{$backend}}) {
            my ($label, $charset, $collation) = @$variant;
            subtest $label => sub {
                my %t = map { ($_ => "selecto_tc_$_") } qw(orders lines customers);
                my $tenant = "tenant_id varchar(16) CHARACTER SET $charset" . (length($collation) ? " COLLATE $collation" : '') . ' NOT NULL';
                # latin1 has no dotless i; an accented i stands in for it.
                my $other = $charset eq 'latin1' ? 'tí' : 'tı';
                my $reset = sub {
                    $dbh->do("DROP TABLE IF EXISTS $t{$_}") for qw(lines orders customers);
                    $dbh->do("CREATE TABLE $t{customers} (id int primary key, $tenant, name varchar(20), KEY (tenant_id)) ENGINE=InnoDB");
                    $dbh->do("CREATE TABLE $t{orders} (id int primary key, $tenant, code varchar(20), total int, customer_id int, KEY (tenant_id)) ENGINE=InnoDB");
                    $dbh->do("CREATE TABLE $t{lines} (id int primary key, order_id int, $tenant, qty int, KEY (tenant_id)) ENGINE=InnoDB");
                    $dbh->do("INSERT INTO $t{customers} VALUES (1, 't1', 'mine'), (2, 'T1', 'upper'), (3, 't1 ', 'padded'), (4, '$other', 'dotless')");
                    $dbh->do("INSERT INTO $t{orders} VALUES (1, 't1', 'a', 1, 1), (2, 'T1', 'a', 2, 2), (3, 't1 ', 'a', 3, 3), (4, '$other', 'a', 4, 4), (5, 't1', 'b', 5, 1)");
                    # Line 11 is a 'T1' row under tenant 't1's order 1.
                    $dbh->do("INSERT INTO $t{lines} VALUES (10, 1, 't1', 1), (11, 1, 'T1', 2), (12, 2, 'T1', 3), (13, 3, 't1 ', 4), (14, 4, '$other', 5)");
                };
                my $rows = sub {
                    my ($table) = @_;
                    return $dbh->selectall_arrayref("SELECT id, CAST(CONVERT(tenant_id USING utf8mb4) AS BINARY), "
                        . ($table eq 'lines' ? 'qty' : $table eq 'orders' ? 'total' : 'name') . " FROM $t{$table} ORDER BY id");
                };
                $reset->();
                my $original_orders = $rows->('orders');
                my $original_lines = $rows->('lines');
                my $domain = Selecto::Domain->parse(contract(%t));
                my $adapter = Selecto->adapter($backend => (dbh => $dbh));
                my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 't1'});
                my $ids = sub { [map { $_->[0] } @{$_[0]{rows}}] };

                is_deeply($ids->($engine->all($engine->query->select('id')->order_by('id'))), [1, 5],
                    'a read returns only the exact tenant rows');
                is_deeply($engine->all($engine->query->select('id', 'lines.id')->where($x->eq('id', 1))->order_by('lines.id'))->{rows},
                    [[1, 10]], 'a join through a tenant-declaring relation pairs tenants exactly');
                is_deeply($engine->all($engine->query->select('id', 'customer.name')->order_by('id'))->{rows},
                    [[1, 'mine'], [5, 'mine']], 'a to-one join reads only the exact tenant\'s parent');
                is_deeply($ids->($engine->all($engine->query->select('id')->where($x->in('tenant_id', ['t1', 'T1']))->order_by('id'))),
                    [1, 5], 'a caller IN on the tenant column compares exactly');

                my $update = Selecto::Write::Command->new(operation => 'update', relation => $t{orders},
                    assignments => {total => 99}, predicate => $x->eq('code', 'a'));
                is(code_of(sub { $engine->execute_write($update) }), 'ok', 'an update runs');
                is_deeply($rows->('orders'), [[1, 't1', 99], @{$original_orders}[1 .. 4]], 'the update changed only the exact tenant\'s row');

                $reset->();
                my $returning = Selecto::Write::Command->new(operation => 'update', relation => $t{orders},
                    assignments => {total => 77}, predicate => $x->eq('code', 'a'), metadata => {returning => ['id', 'total']});
                my $result;
                is(code_of(sub { $result = $engine->execute_write($returning) }), 'ok', 'a RETURNING update runs');
                is($result && $result->affected_rows, 1, 'the RETURNING update affected one row');
                is_deeply($result && $result->values, {id => 1, total => 77}, 'it returns the exact tenant\'s row');
                is_deeply($rows->('orders'), [[1, 't1', 77], @{$original_orders}[1 .. 4]], 'no other tenant\'s row changed');

                $reset->();
                my $delete = Selecto::Write::Command->new(operation => 'delete', relation => $t{orders},
                    predicate => $x->eq('code', 'a'), metadata => {returning => ['id']});
                is(code_of(sub { $result = $engine->execute_write($delete) }), 'ok', 'a RETURNING delete runs');
                is_deeply($result && $result->values, {id => 1}, 'the delete returns the exact tenant\'s row');
                is_deeply($rows->('orders'), [@{$original_orders}[1 .. 4]], 'the delete removed only that row');

                $reset->();
                my $insert = Selecto::Write::Command->new(operation => 'insert', relation => $t{orders},
                    assignments => {id => 6, code => 'c', total => 6}, metadata => {returning => ['id', 'tenant_id']});
                is(code_of(sub { $result = $engine->execute_write($insert) }), 'ok', 'a RETURNING insert runs');
                is_deeply($result && $result->values, {id => 6, tenant_id => 't1'}, 'its re-read returns the stored row');

                $reset->();
                my $guarded = Selecto::Engine->new(domain => $domain->with_required_predicate($x->eq('tenant_id', 't1')),
                    adapter => $adapter);
                my $foreign = Selecto::Write::Command->new(operation => 'insert', relation => $t{orders},
                    assignments => {id => 7, tenant_id => 'T1', code => 'x', total => 7});
                is(code_of(sub { $guarded->execute_write($foreign) }), 'query_rule_violation',
                    'a guarded insert of another tenant\'s value is refused');
                is_deeply($rows->('orders'), $original_orders, 'nothing was inserted');

                my $reference = Selecto::Write::Command->new(operation => 'insert', relation => $t{orders},
                    assignments => {id => 8, code => 'r', total => 8, customer_id => 2});
                isnt(code_of(sub { $engine->execute_write($reference) }), 'ok',
                    'a reference to another tenant\'s parent is refused');
                is_deeply($rows->('orders'), $original_orders, 'nothing was inserted');

                my $graph = Selecto::Write::Graph->new(nodes => [
                    {id => 'root', command => Selecto::Write::Command->new(operation => 'update', relation => $t{orders},
                        assignments => {total => 50}, predicate => $x->eq('id', 1), expected_count => 1)},
                    {id => 'child', command => Selecto::Write::Command->new(operation => 'update', relation => $t{lines},
                        assignments => {qty => 50}, predicate => $x->eq('id', 11), expected_count => 1),
                        bindings => [{from => 'root', key => 'id', field => 'order_id'}]},
                ]);
                isnt(code_of(sub { $engine->execute_graph($graph) }), 'ok',
                    'a graph child update of another tenant\'s row under the root is refused');
                is_deeply($rows->('lines'), $original_lines, 'no line changed');
                is_deeply($rows->('orders'), $original_orders, 'the graph rolled back');

                $dbh->do("DROP TABLE IF EXISTS $t{$_}") for qw(lines orders customers);
            };
        }

        # A reference guard compares the referenced parent's tenant column by
        # the parent's own declared type: an integer tenant on the written
        # table says nothing about a text tenant on the parent, which under a
        # PAD SPACE or case-insensitive collation would admit '7 ' for '7'.
        subtest 'a reference guard compares a text parent tenant exactly under an integer child tenant' => sub {
            $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_tc_mix_orders selecto_tc_mix_customers);
            $dbh->do('CREATE TABLE selecto_tc_mix_customers (id int primary key, tenant_id varchar(16) NOT NULL, name varchar(20)) ENGINE=InnoDB');
            $dbh->do('CREATE TABLE selecto_tc_mix_orders (id int primary key, tenant_id int NOT NULL, code varchar(20), customer_id int) ENGINE=InnoDB');
            my @spellings = ('7', '07', '7 ', ' 7');
            $dbh->do('INSERT INTO selecto_tc_mix_customers VALUES (?, ?, ?)', undef, $_ + 1, $spellings[$_], "c$_") for 0 .. $#spellings;
            my $domain = Selecto::Domain->parse({
                schema_version => 1, name => 'MixedOrders', domain_version => '1',
                source => {%{relation('selecto_tc_mix_orders', id => 'integer', tenant_id => 'integer', code => 'string',
                    customer_id => 'integer')}, tenant_field => 'tenant_id', associations => {
                        customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id'}}},
                schemas => {customer => {%{relation('selecto_tc_mix_customers', id => 'integer', tenant_id => 'string',
                    name => 'string')}, tenant_field => 'tenant_id'}},
                joins => {},
                writes => {operations => {insert => {enabled => 1}},
                    fields => {map { ($_ => {insertable => 1}) } qw(id tenant_id code customer_id)}},
            });
            my $id = 100;
            for my $case (['the number 7', 7], ['the text 7', '7']) {
                my ($label, $tenant) = @$case;
                my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($backend => (dbh => $dbh)),
                    scope => {tenant => $tenant});
                my @accepted;
                for my $customer (1 .. @spellings) {
                    my $insert = Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_tc_mix_orders',
                        assignments => {id => ++$id, code => 'x', customer_id => $customer});
                    push @accepted, $spellings[$customer - 1] if code_of(sub { $engine->execute_write($insert) }) eq 'ok';
                }
                is_deeply(\@accepted, ['7'], "tenant $label references only the parent whose tenant is exactly '7'");
            }
            is($dbh->selectrow_array('SELECT COUNT(*) FROM selecto_tc_mix_orders WHERE customer_id <> 1'), 0,
                'no order references another tenant\'s parent');
            $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_tc_mix_orders selecto_tc_mix_customers);
        };

        # Host-trusted scope on a domain without tenant_field: the required
        # predicate, a command's scope predicate and query-enforcement
        # evidence compare their text eq/IN columns exactly.
        subtest 'host-trusted scope on a text column compares exactly without tenant_field' => sub {
            my $reset = sub {
                $dbh->do('DROP TABLE IF EXISTS selecto_tc_host');
                $dbh->do('CREATE TABLE selecto_tc_host (id int primary key, org_key varchar(16) NOT NULL, name varchar(20)) ENGINE=InnoDB');
                $dbh->do(q{INSERT INTO selecto_tc_host VALUES (1, 't1', 'a'), (2, 'T1', 'a'), (3, 't1 ', 'a'), (4, 't2', 'a')});
            };
            my $changed = sub { [map { $_->[0] } @{$dbh->selectall_arrayref(q{SELECT id FROM selecto_tc_host WHERE name = 'x' ORDER BY id})}] };
            my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Host',
                source => relation('selecto_tc_host', id => 'integer', org_key => 'string', name => 'string'),
                schemas => {}, joins => {},
                writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
                    fields => {name => {updatable => 1}}}});
            my $adapter = Selecto->adapter($backend => (dbh => $dbh));
            my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_tc_host',
                assignments => {name => 'x'}, predicate => $x->in('id', [1, 2, 3, 4]), @_) };
            $reset->();
            my $required = Selecto::Engine->new(adapter => $adapter,
                domain => $domain->with_required_predicate($x->in('org_key', ['t1'])));
            is_deeply([map { $_->[0] } @{$required->all($required->query->select('id')->order_by('id'))->{rows}}], [1],
                'a required IN reads only the exact rows');
            is(code_of(sub { $required->execute_write($update->()) }), 'ok', 'a required-scope update runs');
            is_deeply($changed->(), [1], 'it changes only the exact row');
            my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain);
            $reset->();
            is(code_of(sub { $engine->execute_write($update->(scope_predicate => $x->eq('org_key', 't1'))) }), 'ok',
                'a scope-predicate update runs');
            is_deeply($changed->(), [1], 'a host scope predicate changes only the exact row');
            $reset->();
            is(code_of(sub { $engine->execute_write($engine->enforce_query($update->(),
                $engine->query->where($x->eq('org_key', 't1')))) }), 'ok', 'a query-enforced update runs');
            is_deeply($changed->(), [1], 'query-enforcement evidence changes only the exact row');
            # Every =, <>, IN comparison at any depth of a host predicate is
            # exact: through OR, AND and NOT, and next to non-identity terms.
            for my $case (
                ['eq OR eq', $x->any($x->eq('org_key', 't1'), $x->eq('org_key', 'zz'))],
                ['AND(x, OR(eq, eq))', $x->all($x->gte('id', 0), $x->any($x->eq('org_key', 't1'), $x->eq('org_key', 'zz')))],
                ['eq OR non-identity', $x->any($x->eq('org_key', 't1'), $x->lt('id', 0))],
                ['NOT(<>)', $x->not($x->ne('org_key', 't1'))],
                ['NOT IN', $x->not($x->not($x->in('org_key', ['t1'])))],
            ) {
                my ($label, $predicate) = @$case;
                $reset->();
                my $hosted = Selecto::Engine->new(adapter => $adapter, domain => $domain->with_required_predicate($predicate));
                is_deeply([map { $_->[0] } @{$hosted->all($hosted->query->select('id')->order_by('id'))->{rows}}], [1],
                    "a required $label reads only the exact row");
                is(code_of(sub { $hosted->execute_write($update->()) }), 'ok', "a required $label update runs");
                is_deeply($changed->(), [1], "a required $label changes only the exact row");
                $reset->();
                is(code_of(sub { $engine->execute_write($update->(scope_predicate => $predicate)) }), 'ok',
                    "a $label scope-predicate update runs");
                is_deeply($changed->(), [1], "a $label scope predicate changes only the exact row");
            }
            $dbh->do('DROP TABLE selecto_tc_host');
        };
        $dbh->disconnect;
    };
}

done_testing;
