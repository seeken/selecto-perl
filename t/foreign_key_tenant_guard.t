use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Time::HiRes ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::API::EngineHandler ();

# TW-05: on a tenant-scoped write, a foreign key or the owner key of a to-one
# association may only reference a parent row of the trusted tenant. The
# guard is part of the write statement, and a refused write is
# indistinguishable from one naming a parent that does not exist.

my $E = 'Selecto::Expression';
my $W = 'Selecto::Write::Expression';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $e = $@;
    return blessed($e) && $e->isa('Selecto::Error') ? $e->code : "died: $e";
}

sub error_of {
    my ($code) = @_;
    return undef if eval { $code->(); 1 };
    return $@;
}

sub relation {
    my ($table, %cols) = @_;
    return {
        source_table => $table, primary_key => 'id', fields => [sort keys %cols],
        columns => {map { ($_ => {type => $cols{$_}}) } keys %cols},
        associations => {},
    };
}

# Orders reference customers (tenant data), countries (a shared lookup) and
# other orders. $o{customer} picks how the customer reference is declared:
#   association  - a to-one association whose target schema has tenant_field
#   scope_keys   - an association with source/target scope keys, target without tenant_field
#   constraint   - writes.constraints.foreign_keys, tenancy derived from the schema
#   explicit     - writes.constraints.foreign_keys with references.tenant_field
#   undeclared   - an association whose target declares no tenancy
sub contract {
    my ($tables, %o) = @_;
    my $customer = $o{customer} // 'association';
    my %customer_schema = (%{relation($tables->{customers}, id => 'integer', site_id => 'integer', name => 'string')},
        ($customer =~ /\A(?:association|constraint)\z/ ? (tenant_field => 'site_id') : ()));
    my %constraints = (
        country_id => {source => 'input',
            references => {relation => $tables->{countries}, field => 'id', tenant_field => JSON::PP::false}},
        parent_id => {source => 'input', references => {relation => $tables->{orders}, field => 'id'}},
        ($customer =~ /\A(?:constraint|explicit)\z/ ? (customer_id => {source => 'input', references => {
            relation => $tables->{customers}, field => 'id',
            ($customer eq 'explicit' ? (tenant_field => 'site_id') : ())}}) : ()),
    );
    my %associations = (
        country => {queryable => 'country', owner_key => 'country_id', related_key => 'id'},
        ($customer =~ /\A(?:association|scope_keys|undeclared)\z/ ? (customer => {
            queryable => 'customer', owner_key => 'customer_id', related_key => 'id',
            ($customer eq 'scope_keys' ? (source_scope_key => 'site_id', target_scope_key => 'site_id') : ())}) : ()),
    );
    return {
        schema_version => 1, name => 'Orders', domain_version => '1',
        source => {%{relation($tables->{orders}, id => 'integer', site_id => 'integer', code => 'string',
            title => 'string', customer_id => 'integer', country_id => 'integer', parent_id => 'integer')},
            tenant_field => 'site_id', associations => \%associations},
        schemas => {
            customer => \%customer_schema,
            country => relation($tables->{countries}, id => 'integer', name => 'string'),
        },
        joins => {},
        writes => {
            operations => {insert => {enabled => 1}, update => {enabled => 1, bulk => 1},
                upsert => {enabled => 1, conflict_targets => [[qw(site_id code)]]}},
            fields => {map { ($_ => {insertable => 1, updatable => 1}) }
                qw(id code title customer_id country_id parent_id site_id)},
            constraints => {foreign_keys => \%constraints},
            ($o{scoped} ? (scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}) : ()),
            relationships => {notes => {
                writable => 1, table => $tables->{notes}, parent_key => 'id', child_key => 'order_id',
                allowed_ops => ['insert'],
                domain => {
                    name => 'Notes',
                    source => {%{relation($tables->{notes}, id => 'integer', site_id => 'integer',
                        order_id => 'integer', customer_id => 'integer', body => 'string')},
                        tenant_field => 'site_id', associations => {
                            customer => {queryable => 'customer', owner_key => 'customer_id', related_key => 'id'},
                            order => {queryable => 'order', owner_key => 'order_id', related_key => 'id'},
                        }},
                    schemas => {
                        customer => {%{relation($tables->{customers}, id => 'integer', site_id => 'integer',
                            name => 'string')}, tenant_field => 'site_id'},
                        order => {%{relation($tables->{orders}, id => 'integer', site_id => 'integer')},
                            tenant_field => 'site_id'},
                    },
                    writes => {
                        operations => {insert => {enabled => 1}},
                        fields => {map { ($_ => {insertable => 1}) } qw(id body customer_id)},
                        scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}},
                    },
                },
            }},
        },
    };
}

my @backends = (['sqlite', sub {
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('PRAGMA foreign_keys = ON');
    return $dbh;
}, 1]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    require Selecto::Certification;
    push @backends, ['postgresql', sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }, 1] if eval { require DBD::Pg; 1 };
}
push @backends, ['duckdb', sub {
    DBI->connect('dbi:DuckDB:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}, 0] if eval { require DBD::DuckDB; 1 };

for my $backend (@backends) {
    my ($name, $connect, $foreign_keys) = @$backend;
    subtest "TW-05 on $name" => sub {
        my $dbh = $connect->();
        my $suffix = $$ . '_' . int(Time::HiRes::time() * 1000) % 1_000_000;
        my %tables = map { ($_ => "selecto_fk_${_}_$suffix") } qw(customers countries orders notes);
        my $fk = sub { $foreign_keys ? " REFERENCES $_[0](id)" : '' };
        $dbh->do("CREATE TABLE $tables{customers} (id integer primary key, site_id integer not null, name varchar(40) not null)");
        $dbh->do("CREATE TABLE $tables{countries} (id integer primary key, name varchar(40) not null)");
        $dbh->do("CREATE TABLE $tables{orders} (id integer primary key, site_id integer not null, code varchar(20) not null,
            title varchar(40), customer_id integer" . $fk->($tables{customers}) . ', country_id integer'
            . $fk->($tables{countries}) . ', parent_id integer' . $fk->($tables{orders}) . ', UNIQUE (site_id, code))');
        $dbh->do("CREATE TABLE $tables{notes} (id integer primary key, site_id integer not null,
            order_id integer not null" . $fk->($tables{orders}) . ', customer_id integer'
            . $fk->($tables{customers}) . ', body varchar(40) not null)');
        $dbh->do("INSERT INTO $tables{customers} VALUES (1, 10, 'Ours'), (2, 20, 'Theirs'), (3, 11, 'Sister')");
        $dbh->do("INSERT INTO $tables{countries} VALUES (1, 'NL')");
        $dbh->do("INSERT INTO $tables{orders} (id, site_id, code, title, customer_id) VALUES (1, 10, 'A', 'mine', 1), (2, 20, 'A', 'theirs', 2)");
        my $baseline = [[1, 10, 'A', 'mine', 1, undef, undef], [2, 20, 'A', 'theirs', 2, undef, undef]];
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $rows = sub { $dbh->selectall_arrayref("SELECT id, site_id, code, title, customer_id, country_id, parent_id
            FROM $tables{orders} ORDER BY id") };
        my $reset = sub {
            $dbh->do("DELETE FROM $tables{notes}");
            $dbh->do("DELETE FROM $tables{orders} WHERE id > 2");
            $dbh->do("UPDATE $tables{orders} SET title = CASE WHEN id = 1 THEN 'mine' ELSE 'theirs' END,
                customer_id = id, country_id = NULL, parent_id = NULL");
        };
        my $scoped = sub {
            my (%o) = @_;
            return Selecto::Engine->new(domain => Selecto::Domain->parse(contract(\%tables, %o, scoped => 1)),
                adapter => $adapter, scope => {tenant => 10});
        };
        my $insert = sub {
            my ($engine, %assignments) = @_;
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(
                operation => 'insert', relation => $tables{orders},
                assignments => {id => 3, code => 'B', title => 'new', %assignments})) });
        };
        my $update = sub {
            my ($engine, $id, %assignments) = @_;
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(
                operation => 'update', relation => $tables{orders}, assignments => \%assignments,
                predicate => $E->eq('id', $id))) });
        };

        for my $declared (qw(association scope_keys constraint explicit)) {
            my $engine = $scoped->(customer => $declared);
            is($insert->($engine, customer_id => 2), 'cardinality_mismatch',
                "$declared: an insert may not reference another tenant's customer");
            is($insert->($engine, customer_id => 99), 'cardinality_mismatch',
                "$declared: a missing customer is refused the same way");
            is($update->($engine, 1, customer_id => 2), 'cardinality_mismatch',
                "$declared: an update may not repoint a row at another tenant's customer");
            is_deeply($rows->(), $baseline, "$declared: no row changed");
            is($insert->($engine, customer_id => 1), 'ok', "$declared: the tenant's own customer is accepted");
            is($update->($engine, 1, customer_id => undef), 'ok', "$declared: a null reference needs no parent");
            $reset->();
        }

        my $engine = $scoped->();
        my $upsert = sub {
            my (%assignments) = @_;
            return code_of(sub { $engine->execute_write(Selecto::Write::Command->new(
                operation => 'upsert', relation => $tables{orders}, assignments => {title => 'up', %assignments},
                metadata => {conflict_target => [qw(site_id code)], upsert_update_fields => [qw(title customer_id)]})) });
        };
        is($upsert->(id => 3, code => 'B', customer_id => 2), 'cardinality_mismatch',
            "an upsert insert may not reference another tenant's customer");
        is($upsert->(id => 1, code => 'A', customer_id => 2), 'cardinality_mismatch',
            "an upsert update may not repoint a row at another tenant's customer");
        is_deeply($rows->(), $baseline, 'no upsert changed a row');
        is($upsert->(id => 1, code => 'A', customer_id => 1), 'ok', "an upsert naming the tenant's customer applies");
        $reset->();

        my $bulk = code_of(sub { $engine->execute_write(Selecto::Write::Command->new(
            operation => 'update', relation => $tables{orders}, assignments => {customer_id => 2},
            predicate => $E->eq('code', 'A'), expected_count => undef)) });
        is($bulk, $name eq 'duckdb' ? 'write_capability_missing' : 'cardinality_mismatch',
            'a broad guarded update is refused before mutation or by the foreign-key guard');
        is_deeply($rows->(), $baseline, 'the bulk update changed nothing');

        my $batch = sub {
            my (@parents) = @_;
            my $id = 4;
            return code_of(sub { $engine->execute_batch(Selecto::Write::Batch->new(
                Selecto::Write::Command->new(operation => 'insert', relation => $tables{orders},
                    assignments => {id => 3, code => 'B', title => 'parent'}),
                map { Selecto::Write::Command->new(operation => 'insert', relation => $tables{orders},
                    assignments => {id => $id, code => 'C' . $id++, title => 'child', parent_id => $_}) } @parents,
            )) });
        };
        is($batch->(3), 'ok', 'a batch child may reference a parent the batch created for the tenant');
        $reset->();
        is($batch->(3, 2), 'cardinality_mismatch', "a batch child may not reference another tenant's order");
        is_deeply($rows->(), $baseline, 'the refused batch inserted nothing');

        my $graph = sub {
            my ($customer) = @_;
            return code_of(sub { $engine->execute_graph(Selecto::Write::Graph->new(nodes => [
                {id => 'order', command => Selecto::Write::Command->new(operation => 'insert',
                    relation => $tables{orders}, assignments => {id => 3, code => 'G', title => 'graph'})},
                {id => 'note', command => Selecto::Write::Command->new(operation => 'insert',
                    relation => $tables{notes}, assignments => {id => 1, body => 'n', customer_id => $customer}),
                    bindings => [{field => 'order_id', from => 'order', key => 'id'}]},
            ])) });
        };
        is($graph->(2), 'cardinality_mismatch', "a graph child may not reference another tenant's customer");
        is_deeply($rows->(), $baseline, 'the refused graph inserted nothing');
        is($graph->(1), 'ok', 'a graph child binds to the order the graph created and names its own customer');
        is_deeply($dbh->selectall_arrayref("SELECT id, site_id, order_id, customer_id FROM $tables{notes}"),
            [[1, 10, 3, 1]], 'the child row belongs to the tenant and its new order');
        $reset->();

        is($insert->($engine, country_id => 1), 'ok', 'a shared lookup (tenant_field false) is not tenant-guarded');
        $reset->();
        my $missing_country = $insert->($engine, country_id => 77);
        if ($foreign_keys) {
            ok($missing_country ne 'ok' && $missing_country ne 'cardinality_mismatch',
                "a shared lookup is left to the database constraint ($missing_country)");
        } else {
            is($missing_country, 'ok', 'a shared lookup is not guarded');
        }
        $reset->();

        my $undeclared = $scoped->(customer => 'undeclared');
        my $error = error_of(sub { $undeclared->execute_write(Selecto::Write::Command->new(
            operation => 'insert', relation => $tables{orders},
            assignments => {id => 3, code => 'B', title => 'new', customer_id => 1})) });
        is($error && $error->code, 'invalid_domain', 'undeclared tenancy fails closed on a tenant-scoped write');
        is($error && $error->details->{code}, 'foreign_key_tenant_scope_undeclared', 'and says why');
        is($insert->($undeclared, title => 'no reference'), 'ok', 'a write that assigns no reference is unaffected');
        $reset->();
        my $unscoped = Selecto::Engine->new(adapter => $adapter,
            domain => do { my $c = contract(\%tables, customer => 'undeclared'); delete $c->{source}{tenant_field};
                Selecto::Domain->parse($c) });
        is($insert->($unscoped, customer_id => 1, site_id => 10), 'ok',
            'undeclared tenancy is not refused outside a tenant-scoped write');
        $reset->();

        my $guarded = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(contract(\%tables))
            ->with_required_predicate($E->eq('site_id', 10)));
        is($insert->($guarded, site_id => 10, customer_id => 2), 'cardinality_mismatch',
            "a required tenant predicate also guards references");
        is($update->($guarded, 1, customer_id => 2), 'cardinality_mismatch', 'and repointing updates');
        is($insert->($guarded, site_id => 10, customer_id => 1), 'ok', "and accepts the tenant's own customer");
        $reset->();
        my $listed = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(contract(\%tables))
            ->with_required_predicate($E->in('site_id', [10, 11])));
        is($update->($listed, 1, customer_id => 3), 'ok', 'a customer of a tenant the predicate lists is accepted');
        is($update->($listed, 1, customer_id => 2), 'cardinality_mismatch', 'one outside the list is refused');
        $reset->();

        is($update->($engine, 1, customer_id => $W->field('parent_id')), 'invalid_write',
            'a computed reference cannot be guarded and is refused');
        my $plain = Selecto::Engine->new(adapter => $adapter, domain => do {
            my $c = contract(\%tables, customer => 'constraint'); delete $c->{source}{tenant_field};
            Selecto::Domain->parse($c) });
        is($insert->($plain, customer_id => 1, site_id => 10), 'missing_tenant_scope',
            'a declared reference to tenant data needs a trusted tenant, as in the Elixir core');

        my $handler = Selecto::API::EngineHandler->new;
        is(code_of(sub { $handler->write($scoped->(), {operation => 'insert',
            assignments => {id => 3, code => 'B', title => 'x', customer_id => 2}}) }), 'cardinality_mismatch',
            'the API write handler is guarded');
        is_deeply($rows->(), $baseline, 'nothing changed');
        $dbh->do("DROP TABLE $tables{$_}") for qw(notes orders countries customers);
    };
}

subtest 'TW-05 guard SQL shapes' => sub {
    my %tables = (customers => 'customers', countries => 'countries', orders => 'orders', notes => 'notes');
    my $domain = Selecto::Domain->parse(contract(\%tables, scoped => 1));
    my $shape = sub {
        my ($name, $command) = @_;
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => TestSelecto::DBH->new)),
            scope => {tenant => 10});
        return $engine->preview_write($command);
    };
    my $insert = Selecto::Write::Command->new(operation => 'insert', relation => 'orders',
        assignments => {id => 3, code => 'B', customer_id => 2});
    my $update = Selecto::Write::Command->new(operation => 'update', relation => 'orders',
        assignments => {customer_id => 2}, predicate => $E->eq('id', 1));
    my $upsert = Selecto::Write::Command->new(operation => 'upsert', relation => 'orders',
        assignments => {id => 3, code => 'B', customer_id => 2},
        metadata => {conflict_target => [qw(site_id code)], upsert_update_fields => ['customer_id']});

    my $pg = $shape->(postgresql => $insert);
    like($pg->{sql}, qr/\AINSERT INTO "orders" \(.*\) SELECT \$1, \$2, \$3, \$4 WHERE EXISTS \(SELECT 1 FROM "customers" AS "selecto_fk_parent" WHERE "selecto_fk_parent"\."id" = \$5 AND "selecto_fk_parent"\."site_id" = \$6\)\z/,
        'PostgreSQL inserts through a guarded SELECT');
    is_deeply([@{$pg->{params}}[4, 5]], [2, 10], 'the reference and the tenant are bound');
    like($shape->(postgresql => $update)->{sql}, qr/WHERE .* AND EXISTS \(SELECT 1 FROM "customers" AS "selecto_fk_parent"/,
        'PostgreSQL guards an update in its WHERE');
    like($shape->(postgresql => $upsert)->{sql}, qr/SELECT .* WHERE EXISTS \(.*\) ON CONFLICT \("site_id", "code"\) DO UPDATE/,
        'PostgreSQL guards the upsert source row');
    like($shape->(sqlite => $upsert)->{sql}, qr/SELECT .* WHERE EXISTS \(.*\) ON CONFLICT/, 'SQLite guards the upsert source row');
    for my $name (qw(mysql mariadb)) {
        like($shape->($name => $insert)->{sql}, qr/SELECT \?, \?, \?, \? FROM DUAL WHERE EXISTS \(SELECT 1 FROM \(SELECT 1 FROM `customers` AS `selecto_fk_parent` WHERE `selecto_fk_parent`\.`id` = \? AND `selecto_fk_parent`\.`site_id` = \? LIMIT 1\) AS `selecto_fk_check`\)\z/,
            "$name inserts through a guarded SELECT FROM DUAL");
        like($shape->($name => $update)->{sql}, qr/AND EXISTS \(SELECT 1 FROM \(SELECT 1 FROM `customers`/,
            "$name guards an update through a derived table");
    }
    my $mssql = $shape->(mssql => $upsert);
    like($mssql->{sql}, qr/WHEN MATCHED AND EXISTS \(SELECT 1 FROM \[customers\] AS \[selecto_fk_parent\].*WHEN NOT MATCHED AND EXISTS \(SELECT 1 FROM \[customers\]/s,
        'SQL Server guards both MERGE branches');
    is_deeply($mssql->{params}, ['B', 2, 3, 10, 2, 10, 2, 10], 'and binds the reference and tenant for each branch');
    like($shape->(mssql => $insert)->{sql}, qr/SELECT \?, \?, \?, \? WHERE EXISTS/, 'SQL Server inserts through a guarded SELECT');
    like($shape->(duckdb => $insert)->{sql}, qr/SELECT .* WHERE EXISTS \(SELECT 1 FROM "customers" AS "selecto_fk_parent"/,
        'DuckDB inserts through a guarded SELECT');
    my $stripped = Selecto::Write::Command->new(operation => 'update', relation => 'orders',
        assignments => {customer_id => 2}, predicate => $E->eq('id', 1), foreign_key_guards => []);
    like($shape->(postgresql => $stripped)->{sql}, qr/EXISTS/, 'a caller cannot strip the guards');
    my $injected = Selecto::Write::Command->new(operation => 'update', relation => 'orders',
        assignments => {title => 'x'}, predicate => $E->eq('id', 1),
        foreign_key_guards => [{field => 'title', relation => 'secrets', target_field => 'id',
            tenant_field => 'site_id', value => 1, tenants => [1]}]);
    unlike($shape->(postgresql => $injected)->{sql}, qr/secrets/, 'nor inject its own');
    my $listed = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => TestSelecto::DBH->new)),
        domain => Selecto::Domain->parse(contract(\%tables))->with_required_predicate($E->in('site_id', [10, 11])));
    like($listed->preview_write($update)->{sql}, qr/"selecto_fk_parent"\."site_id" IN \(\$\d+, \$\d+\)\)/,
        'a tenant set from the host predicate becomes IN');
};

done_testing;
