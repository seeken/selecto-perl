use 5.034;
use strict;
use warnings;
use Test::More;
use Cpanel::JSON::XS ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Domain::SchemaV2;

# Domain schema 2 (certification specification 3.0): one tenant declaration,
# columns as the field list, implied action capabilities, and a computed
# RFC 8785 fingerprint. Version 1 still parses and reports its deprecation.
my $V2 = 'Selecto::Domain::SchemaV2';
my $json = Cpanel::JSON::XS->new->utf8;

my $v1 = $json->decode(q({
  "schema_version": 1, "name": "Orders",
  "source": {"source_table": "orders", "primary_key": "id", "tenant_field": "org_id",
    "fields": ["id", "org_id", "total"],
    "columns": {"id": {"type": "integer"}, "org_id": {"type": "integer"}, "total": {"type": "decimal"}},
    "associations": {}},
  "schemas": {}, "joins": {},
  "required_filters": [["org_id", 7], ["total", null]]
}));

subtest 'RFC 8785 serialization' => sub {
    my $rfc = $json->decode(<<'JSON');
{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"string":"\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/","literals":[null,true,false]}
JSON
    chomp(my $want = <<'TEXT');
{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"EURO$\u000f\nA'B\"\\\\\"/"}
TEXT
    $want =~ s/EURO/\x{20ac}/;
    is($V2->jcs($rfc), $want, 'the RFC 8785 example serializes exactly');
    my $keys = $json->decode(qq({"\\u20ac":1,"\\r":2,"\\ufb33":3,"1":4,"\\ud83d\\ude00":5,"\\u0080":6,"\\u00f6":7}));
    is_deeply([map { $_->[1] } sort { $a->[0] <=> $b->[0] } map { [index($V2->jcs($keys), ":$_"), $_] } 1 .. 7], [2, 4, 6, 7, 1, 5, 3],
        'keys sort by UTF-16 code units');
    is($V2->jcs($json->decode('[1e21,1e20,1e-7,1e-6,-0.0,100]')), '[1e+21,100000000000000000000,1e-7,0.000001,0,100]',
        'numbers follow ECMAScript formatting');
};

subtest 'migration and fingerprint' => sub {
    my $migrated = $V2->migrate($v1);
    my $doc = $migrated->{document};
    is($doc->{schema_version}, 2, 'version 2');
    ok(!exists($doc->{source}{fields}) && !exists($doc->{source}{tenant_field}), 'fields and tenant_field are gone');
    ok(!exists($doc->{source}{field_order}), 'sorted fields need no field_order');
    is_deeply($doc->{tenant}, {field => 'org_id', pins => [['org_id', 7]]}, 'the tenant pin moves to tenant.pins');
    is_deeply($doc->{required_filters}, [['total', undef]], 'other required filters stay');
    is_deeply([map { $_->{code} } @{$migrated->{diagnostics}}], ['domain_schema_deprecated'], 'deprecation reported');
    is_deeply($V2->validate($doc), [], 'the migrated document is valid version 2');
    like($V2->fingerprint($doc), qr/\A[0-9a-f]{64}\z/, 'the fingerprint is lower-case hex SHA-256');
    is_deeply($V2->migrate({%$v1, source => {%{$v1->{source}}, fields => ['id']}})->{refused},
        {code => 'domain_migration_ambiguous', path => ['source', 'fields']}, 'fields that are not the columns refuse');
};

subtest 'parse' => sub {
    my $domain = Selecto::Domain->parse($v1);
    is($domain->schema_version, 1, 'version 1 parses');
    is($domain->schema_diagnostics->[0]{code}, 'domain_schema_deprecated', 'and reports its deprecation');
    my $doc = $domain->schema_diagnostics->[0]{document};
    my $v2 = Selecto::Domain->parse($doc);
    is($v2->schema_version, 2, 'its version 2 document parses');
    is($v2->fingerprint, $V2->fingerprint($doc), 'with the computed fingerprint');
    is_deeply($v2->schema_diagnostics, [], 'and no deprecation');
    is($v2->tenant_field, 'org_id', 'the tenant field reaches the engine');
    $doc->{domain_fingerprint} = $V2->fingerprint($doc);
    ok(eval { Selecto::Domain->parse($doc); 1 }, 'a matching declared fingerprint parses');
    $doc->{domain_fingerprint} = 'orders-v1';
    my $error = eval { Selecto::Domain->parse($doc); 1 } ? undef : $@;
    is(blessed($error) && $error->details->{reason}, 'domain_fingerprint_mismatch', 'a stale one refuses');
    delete $doc->{domain_fingerprint};
    $error = eval { Selecto::Domain->parse({%$doc, source => {%{$doc->{source}}, fields => ['id']}}); 1 } ? undef : $@;
    is(blessed($error) && $error->details->{reason}, 'fields_removed', 'version 2 has no fields');

    ok(!$V2->is_version_2('2'), 'the string "2" is not schema 2');
    ok(!$V2->is_version_2($json->decode('["2"]')->[0]), 'nor is a decoded JSON string "2"');
    my $printed = 2;
    my $text = "$printed";
    ok($V2->is_version_2($printed), 'the number 2 is, even after it has been printed');
    ok($V2->is_version_2($json->decode('[2]')->[0]), 'and so is a decoded JSON number');
    $error = eval { Selecto::Domain->parse({%$doc, schema_version => '2'}); 1 } ? undef : $@;
    ok(blessed($error), 'a domain whose schema_version is the string "2" does not load as schema 2');
};

subtest 'a version 2 domain reads and writes like its version 1 form' => sub {
    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE orders (id INTEGER PRIMARY KEY, org_id INTEGER, total NUMERIC)');
    my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
    my $sql = sub {
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($_[0]), adapter => $adapter, scope => {tenant => 7});
        my $statement = $engine->compile($engine->query->select('id'));
        return [$statement->sql, $statement->params];
    };
    is_deeply($sql->($V2->migrate($v1)->{document}), $sql->($v1), 'the same SQL and parameters');
};

subtest 'a version 2 tenant is the public write authority' => sub {
    my $v2 = {
        schema_version => 2, name => 'Orders', tenant => {field => 'org_id'},
        source => {source_table => 'orders', primary_key => 'id', associations => {},
            columns => {id => {type => 'integer'}, org_id => {type => 'integer'}, total => {type => 'integer'}}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1}}, fields => {total => {updatable => 1}}},
    };
    is_deeply($V2->to_version_1($v2)->{writes}{scope}{tenant}, {required => JSON::PP::true, field => 'org_id'},
        'a plain tenant maps to writes.scope.tenant');

    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
    require Selecto::API::EngineHandler;
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE orders (id INTEGER PRIMARY KEY, org_id INTEGER, total INTEGER)');
    $dbh->do('INSERT INTO orders VALUES (1, 7, 1), (2, 8, 1)');
    my $adapter = Selecto->adapter(sqlite => dbh => $dbh);
    my $handler = Selecto::API::EngineHandler->new;
    my $update = sub {
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($_[0]), adapter => $adapter, scope => {tenant => 7});
        my $ok = eval { $handler->write($engine, {operation => 'update', assignments => {total => 9},
            filters => [{field => 'id', op => 'in', value => [1, 2]}]}); 1 };
        return $ok ? 'ok' : (blessed($@) && $@->isa('Selecto::Error') ? $@->code : "died: $@");
    };
    my $v1_form = $V2->to_version_1($v2);
    delete $v1_form->{writes}{scope};
    is($update->($v1_form), 'missing_tenant_scope', 'version 1 without writes.scope.tenant: the engine tenant alone does not authorize');
    is($update->($v2), 'ok', 'version 2: the engine tenant authorizes a public write');
    is_deeply($dbh->selectall_arrayref('SELECT id, org_id, total FROM orders ORDER BY id'), [[1, 7, 9], [2, 8, 1]],
        'bounded to that tenant');
};

subtest 'the computed fingerprint is a version 2 domain\'s identity' => sub {
    require Selecto::API;
    my $doc = {%{$V2->migrate($v1)->{document}}, domain_version => '1'};
    my $domain = Selecto::Domain->parse($doc);
    my $computed = $V2->fingerprint($doc);
    is($domain->contract->{domain_fingerprint}, $computed, 'the version 1 form carries it as domain_fingerprint');
    my $api = Selecto::API->new(domain => $domain, base_path => '/api/v1/orders');
    is($api->manifest->{domain}{fingerprint}, $computed, 'the canonical API hosts it and reports it');
};

done_testing;
