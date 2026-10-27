use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();

# DuckDB identity (brief items 37, 38, 41, 45, 46, 48, 49, 49a, 50, 53, 55).
# A column deciding tenant, trusted or host-scope identity must be an
# integer, VARCHAR, UUID or BOOLEAN column, read from the statement itself;
# VARCHAR compares by bytes under every operator (no NOCASE column or
# default_collation), an integer column only with a canonical integer
# literal ('1.4', '1e0' and '1.0' are refused, never rounded), and any other
# type is refused (identity_column_type). Ordinary caller filters on other
# columns keep DuckDB's own collation, for = and ranges alike.
plan skip_all => 'DBD::DuckDB is not installed' unless eval { require DBD::DuckDB; 1 };
my $x = 'Selecto::Expression';
my $connect = sub { DBI->connect('dbi:DuckDB:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1}) };
my $outcome = sub {
    my ($code) = @_;
    my $value = eval { $code->() };
    return $value if defined $value;
    my $error = $@;
    return blessed($error) ? $error->code . (($error->details // {})->{reason} ? '/' . $error->details->{reason} : '') : "died: $error";
};
my $rows = sub { my ($result) = @_; ref($result) eq 'HASH'
    ? join(';', map { join(',', map { $_ // 'NULL' } @$_) } @{$result->{rows}}) : $result };

sub flat {
    my (%o) = @_;
    return Selecto::Domain->parse({schema_version => 1, name => 'Flat', schemas => {}, joins => {},
        source => {source_table => 'selecto_duck_ident', primary_key => 'id', fields => [qw(id note org_key)],
            columns => {id => {type => 'integer'}, note => {type => 'string'}, org_key => {type => $o{decl} // 'string'}},
            associations => {}, tenant_field => 'org_key'},
        writes => {operations => {delete => {enabled => 1}}, fields => {}}});
}
my $table = sub {
    my ($dbh, $type, @values) = @_;
    $dbh->do("CREATE OR REPLACE TABLE selecto_duck_ident (id INTEGER PRIMARY KEY, org_key $type, note VARCHAR COLLATE NOCASE)");
    my $id = 0;
    $dbh->do('INSERT INTO selecto_duck_ident VALUES (' . ++$id . ", $_, 'n$id')") for @values;
};

subtest 'engine tenant reads by catalog type' => sub {
    for my $case (
        ['VARCHAR COLLATE NOCASE', ["'t1'", "'T1'"], 't1', '1', 'a NOCASE tenant column compares bytes'],
        ['VARCHAR', ["'1'", "'01'", "' 1'"], '1', '1', 'an integer-looking tenant never matches 01 or space-1'],
        ['INTEGER', ['1', '2'], '1.4', 'query_rule_not_evaluable/inexact_number', 'a fractional tenant is refused, not rounded'],
        ['INTEGER', ['1', '2'], '1e0', 'query_rule_not_evaluable/inexact_number', 'an exponent tenant is refused'],
        ['INTEGER', ['1', '2'], '1.0', 'query_rule_not_evaluable/inexact_number', 'a 1.0 tenant is refused'],
        ['INTEGER', ['1', '2'], '01', '1', 'a leading-zero integer is read as PostgreSQL reads it'],
        ['BIGINT', ['9223372036854775807', '9223372036854775806'], '9223372036854775807', '1', 'BIGINT compares exactly'],
        ['DECIMAL(18,2)', ['1.01', '1.00'], '1', 'query_rule_not_evaluable/identity_column_type', 'a DECIMAL tenant column is refused'],
        ['DOUBLE', ['0.1', '1'], '0.10000000000000001', 'query_rule_not_evaluable/identity_column_type', 'a DOUBLE tenant column is refused'],
        ['DATE', ["DATE '2020-01-01'"], '2020-01-01', 'query_rule_not_evaluable/identity_column_type', 'a DATE tenant column is refused'],
        ['UUID', ["'00000000-0000-0000-0000-000000000001'", "'00000000-0000-0000-0000-000000000002'"],
            '00000000-0000-0000-0000-000000000001', '1', 'a UUID tenant column compares by value'],
    ) {
        my ($type, $values, $tenant, $want, $label) = @$case;
        my $dbh = $connect->();
        $table->($dbh, $type, @$values);
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => flat(), scope => {tenant => $tenant});
        is($rows->($outcome->(sub { $engine->all($engine->query->select('id')) })), $want, "$type tenant $tenant: $label");
    }
    my $dbh = $connect->();
    $dbh->do(q{SET default_collation = 'nocase'});
    $table->($dbh, 'VARCHAR', "'t1'", "'T1'");
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => flat(), scope => {tenant => 't1'});
    is($rows->($outcome->(sub { $engine->all($engine->query->select('id')) })), '1', 'default_collation nocase: tenant t1 reads only t1');
};

subtest 'a tenant range pin and BOOLEAN trusted scope' => sub {
    my $dbh = $connect->();
    $table->($dbh, 'VARCHAR COLLATE NOCASE', "'t1'", "'T1'");
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)),
        domain => flat()->with_required_predicate($x->all($x->gte('org_key', 't1'), $x->lte('org_key', 't1'))));
    is($rows->($outcome->(sub { $engine->all($engine->query->select('id')) })), '1', 'a NOCASE range pin compares bytes');
    $dbh->do('CREATE TABLE selecto_duck_flags (id INTEGER PRIMARY KEY, active BOOLEAN)');
    $dbh->do('INSERT INTO selecto_duck_flags VALUES (1, true), (2, false)');
    my $flags = Selecto::Domain->parse({schema_version => 1, name => 'Flags', schemas => {}, joins => {},
        source => {source_table => 'selecto_duck_flags', primary_key => 'id', fields => [qw(active id)],
            columns => {id => {type => 'integer'}, active => {type => 'boolean'}}, associations => {}}});
    # A plain required filter (R3 clarification) compares a non-text column
    # natively: 'maybe' is no boolean, so the statement fails as it does on
    # PostgreSQL rather than being refused as an identity column.
    for my $case ([JSON::PP::true, '1'], ['false', '2'], ['maybe', 'query_error']) {
        my $scoped = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)),
            domain => $flags->with_required_predicate($x->eq('active', $case->[0])));
        is($rows->($outcome->(sub { $scoped->all($scoped->query->select('id')) })), $case->[1], "BOOLEAN scope active = $case->[0]");
    }
};

sub people {
    my (%o) = @_;
    my $source = {source_table => $o{table} // 'selecto_duck_people', primary_key => 'id', fields => [qw(account_id id note tenant_id)],
        columns => {id => {type => 'integer'}, tenant_id => {type => $o{rtype} // 'string'}, account_id => {type => 'integer'},
            note => {type => 'string'}},
        associations => {account => {queryable => 'account', owner_key => 'account_id', related_key => 'id', cardinality => 'one',
            ($o{where} ? (where => $o{where}) : ())}}};
    $source->{tenant_field} = 'tenant_id' if $o{root_tenant} // 1;
    return Selecto::Domain->parse({schema_version => 1, name => 'People', source => $source,
        schemas => {account => {source_table => 'selecto_duck_accounts', primary_key => 'id', tenant_field => 'tenant_id',
            fields => [qw(id name tenant_id)],
            columns => {id => {type => 'integer'}, tenant_id => {type => $o{atype} // 'string'}, name => {type => 'string'}},
            associations => {}}},
        joins => {account => {type => 'left'}}});
}

subtest 'joined relations, where pins and relation resolution' => sub {
    my $dbh = $connect->();
    my $read = sub {
        my ($field, %o) = @_;
        my $tenant = delete $o{tenant};
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => people(%o),
            (defined($tenant) ? (scope => {tenant => $tenant}) : ()));
        return $rows->($outcome->(sub { $engine->all($engine->query->select('id', $field)) }));
    };
    $dbh->do($_) for 'CREATE TABLE selecto_duck_people (id INTEGER PRIMARY KEY, tenant_id VARCHAR, account_id INTEGER, note VARCHAR)',
        'CREATE TABLE selecto_duck_accounts (id INTEGER PRIMARY KEY, tenant_id VARCHAR, name VARCHAR COLLATE NOCASE)',
        q{INSERT INTO selecto_duck_people VALUES (1, 't1', 10, 'own')}, q{INSERT INTO selecto_duck_accounts VALUES (10, 't1', 'Acme')};
    is($read->('account.name', tenant => 't1'), '1,Acme', 'a NOCASE column outside the scope is not refused');
    $dbh->do($_) for 'CREATE SCHEMA other', 'CREATE TABLE other.selecto_duck_accounts (x INTEGER)', q{ATTACH ':memory:' AS att},
        'CREATE TABLE att.selecto_duck_people (id INTEGER, tenant_id DECIMAL(10,2), account_id INTEGER, note VARCHAR)';
    is($read->('account.name', tenant => 't1'), '1,Acme', 'namesakes in another schema or ATTACHed database are not refused');
    $dbh->do($_) for 'DROP TABLE selecto_duck_accounts',
        'CREATE TABLE selecto_duck_accounts (id INTEGER PRIMARY KEY, tenant_id INTEGER, name VARCHAR)',
        q{UPDATE selecto_duck_people SET tenant_id = '1.4'}, q{INSERT INTO selecto_duck_accounts VALUES (10, 1, 'SECRET-1')};
    is($read->('account.name', tenant => '1.4', atype => 'integer'), '1,NULL', 'a text 1.4 tenant pair never matches INTEGER 1');
    $dbh->do('UPDATE selecto_duck_people SET tenant_id = NULL');
    is($read->('account.name', tenant => '1.4', root_tenant => 0, atype => 'integer'), 'query_rule_not_evaluable/inexact_number',
        'a joined INTEGER tenant pinned to 1.4 is refused');
    is($read->('account.name', tenant => '1', root_tenant => 0, atype => 'integer'), '1,SECRET-1', 'a canonical pin still joins');
    is($read->('account.name', root_tenant => 0, atype => 'integer', where => {tenant_id => '1.4'}),
        'query_rule_not_evaluable/inexact_number', 'an association where pin of 1.4 on INTEGER is refused');
    $dbh->do($_) for 'DROP TABLE selecto_duck_accounts',
        'CREATE TABLE selecto_duck_accounts (id INTEGER PRIMARY KEY, tenant_id VARCHAR COLLATE NOCASE, name VARCHAR)',
        q{INSERT INTO selecto_duck_accounts VALUES (10, 'T1', 'SECRET-T1')};
    is($read->('account.name', tenant => 't1', root_tenant => 0), '1,NULL', 'a joined NOCASE tenant compares bytes');
    $dbh->do($_) for 'DROP TABLE selecto_duck_accounts',
        'CREATE TABLE selecto_duck_accounts (id INTEGER PRIMARY KEY, tenant_id DECIMAL(18,2), name VARCHAR)',
        q{INSERT INTO selecto_duck_accounts VALUES (10, 1, 'SECRET-dec')};
    is($read->('account.name', tenant => 1, root_tenant => 0, atype => 'decimal'), 'query_rule_not_evaluable/identity_column_type',
        'a joined DECIMAL tenant column is refused');
    # The relation the statement binds decides: a temp shadow or a search
    # path schema with another tenant type is refused, not looked past.
    $dbh->do($_) for q{UPDATE selecto_duck_people SET tenant_id = '1'},
        'CREATE TEMP TABLE selecto_duck_people (id INTEGER, tenant_id DOUBLE, account_id INTEGER, note VARCHAR)',
        q{INSERT INTO temp.selecto_duck_people VALUES (5, 1, 10, 'temp-secret')};
    is($read->('note', tenant => '1', rtype => 'integer'), 'query_rule_not_evaluable/identity_column_type', 'a temp shadow is checked as bound');
    $dbh->do($_) for 'DROP TABLE temp.selecto_duck_people', q{SET search_path = 'other,main'},
        'CREATE TABLE other.selecto_duck_people (id INTEGER, tenant_id DECIMAL(5,1), account_id INTEGER, note VARCHAR)',
        q{INSERT INTO other.selecto_duck_people VALUES (6, 1.0, 10, 'path-secret')};
    is($read->('note', tenant => '1', rtype => 'integer'), 'query_rule_not_evaluable/identity_column_type',
        'a search_path relation is checked as bound');
    $dbh->do(q{SET search_path = ''});
    $dbh->do($_) for q{CREATE TABLE "PEOPLE2" (id INTEGER PRIMARY KEY, "TENANT_ID" INTEGER, account_id INTEGER, note VARCHAR)},
        q{INSERT INTO "PEOPLE2" VALUES (1, 1, 10, 'secret-1')};
    is($read->('note', table => 'people2', tenant => '1.4', rtype => 'integer'), 'query_rule_not_evaluable/inexact_number',
        'a case-folded relation and column are checked as bound');
};

subtest 'writes: engine tenant and host scope' => sub {
    for my $tenant (qw(1.4 1e0)) {
        my $dbh = $connect->();
        $table->($dbh, 'INTEGER', '1');
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => flat(), scope => {tenant => $tenant});
        is($outcome->(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_duck_ident',
            predicate => $x->eq('id', 1))); 'deleted' }), 'query_rule_not_evaluable/inexact_number', "tenant $tenant delete is refused");
        is($dbh->selectrow_array('SELECT count(*) FROM selecto_duck_ident'), 1, "tenant $tenant: tenant 1's row is kept");
    }
    for my $case (
        ['VARCHAR COLLATE NOCASE', ["'a'", "'B'", "'c'"], $x->eq('org_key', 'b'), 'ok', '1,2,3', 'a NOCASE eq scope compares bytes'],
        ['VARCHAR COLLATE NOCASE', ["'a'", "'B'", "'c'"], $x->gte('org_key', 'b'), 'ok', '1,2', 'a NOCASE range scope compares bytes'],
        ['INTEGER', ['1', '2', '3'], $x->lte('org_key', '0.5'), 'ok', '1,2,3', 'an integer range is exact, never rounded'],
        ['INTEGER', ['1', '2', '3'], $x->ne('org_key', '1.0'), 'query_rule_not_evaluable/inexact_number', '1,2,3',
            'a negated inexact integer is refused, not turned into an exclusion'],
        ['INTEGER', ['1', '2', '3'], $x->not($x->in('org_key', [1])), 'ok', '1', 'NOT IN excludes exactly'],
        ['DECIMAL(18,2)', ['1.00', '1.01', '2.00'], $x->ne('org_key', 1), 'query_rule_not_evaluable/identity_column_type', '1,2,3',
            'a DECIMAL scope column is refused'],
        ['DOUBLE', ['0.5', '1', '2'], $x->lte('org_key', '1'), 'query_rule_not_evaluable/inexact_text', '1,2,3',
            'a text range on a DOUBLE scope column is refused'],
    ) {
        my ($type, $values, $scope, $want, $left, $label) = @$case;
        my $dbh = $connect->();
        $table->($dbh, $type, @$values);
        my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));
        is($outcome->(sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'delete',
            relation => 'selecto_duck_ident', predicate => $x->not_null('id'), expected_count => undef, scope_predicate => $scope)); 'ok' }),
            $want, "$type: $label");
        is(join(',', map { $_->[0] } @{$dbh->selectall_arrayref('SELECT id FROM selecto_duck_ident ORDER BY id')}), $left,
            "$type: $label (rows left)");
    }
};

subtest 'ordinary caller filters keep DuckDB semantics' => sub {
    my $dbh = $connect->();
    $table->($dbh, 'VARCHAR', "'t1'", "'t1'", "'t1'");
    $dbh->do(q{UPDATE selecto_duck_ident SET note = CASE id WHEN 1 THEN 'a' WHEN 2 THEN 'B' ELSE 'c' END});
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(duckdb => (dbh => $dbh)), domain => flat(), scope => {tenant => 't1'});
    my $ids = sub { my ($filter) = @_; $rows->($outcome->(sub { $engine->all($engine->query->select(q{id})->where($filter)) })) };
    is($ids->($x->eq('note', 'b')), '2', 'caller = on a NOCASE column follows its collation');
    is($ids->($x->gte('note', 'b')), '2;3', 'caller >= on a NOCASE column follows its collation too');
};

done_testing;
