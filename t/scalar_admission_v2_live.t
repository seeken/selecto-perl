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
use Selecto::QueryEnforcement ();
use Selecto::Write ();

# query_enforced_scalar v2 (specification 2.37), live: every governed insert
# under a trusted host predicate, query enforcement or IN list is admitted
# only when PostgreSQL would store a row that satisfies it. The required
# checks of the harness's v2 migration note, through the public insert path
# (Engine::execute_write), explicit tooling with declared field types
# (execute_write_unsafe, deferred to the verified-storage check) and untyped
# tooling (refused: nothing decides it). A refused insert writes no row.
# The process locale is irrelevant: text compares by bytes.
local $ENV{LANG} = 'en_US.UTF-8';
my $x = 'Selecto::Expression';
my @backends;
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no live PostgreSQL, MySQL or MariaDB is configured' unless @backends;

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

# [label, PostgreSQL column DDL, MySQL column DDL, declared type, host
#  predicate (or ['qe', predicate]), candidate (undef: omitted), expected]
my @cases;
my $text = ['TEXT', 'VARCHAR(16)', 'string'];
for my $v ('1e1', '010', ' 10', '+10', '10.0', '10') {
  my $e = $v eq '10' ? 'apply' : 'refuse';
  push @cases, ["1 pin eq '$v'", @$text, $x->eq('org_key', '10'), $v, $e];
  push @cases, ["1 pin IN '$v'", @$text, $x->in('org_key', ['10']), $v, $e];
  push @cases, ["1 pin QE '$v'", @$text, ['qe', $x->eq('org_key', '10')], $v, $e];
}
push @cases, ["2 zwsp", @$text, $x->eq('org_key', 't1'), "t1\x{200B}", 'refuse'], ["2 shy", @$text, $x->eq('org_key', 't1'), "t1\x{AD}", 'refuse'],
  ["2 case", @$text, $x->eq('org_key', 't1'), 'T1', 'refuse'], ["2 own", @$text, $x->eq('org_key', 't1'), 't1', 'apply'];
push @cases, ["3 varchar(2) <>", 'VARCHAR(2)', 'VARCHAR(2)', 'string', $x->ne('org_key', 't1'), 't1 ', 'refuse'],
  ["3 varchar(2) NOT IN", 'VARCHAR(2)', 'VARCHAR(2)', 'string', $x->not($x->in('org_key', ['t1'])), 't1 ', 'refuse'],
  ["3 varchar(2) = own", 'VARCHAR(2)', 'VARCHAR(2)', 'string', $x->eq('org_key', 't1'), 't1', 'apply'];
push @cases, ["4 numeric(10,2) > 0", 'NUMERIC(10,2)', 'DECIMAL(10,2)', 'decimal', $x->gt('org_key', 0), '0.004', 'refuse'],
  ["4 numeric(20,3) <> 1", 'NUMERIC(20,3)', 'DECIMAL(20,3)', 'decimal', $x->ne('org_key', 1), '1.0004', 'refuse'],
  ["4 numeric(20,3) > 1", 'NUMERIC(20,3)', 'DECIMAL(20,3)', 'decimal', $x->gt('org_key', 1), '0.9996', 'refuse'],
  ["4 numeric(20,3) NOT IN 1", 'NUMERIC(20,3)', 'DECIMAL(20,3)', 'decimal', $x->not($x->in('org_key', [1])), '0.9996', 'refuse'],
  ["4 numeric(10,2) 0.01 > 0", 'NUMERIC(10,2)', 'DECIMAL(10,2)', 'decimal', $x->gt('org_key', 0), '0.01', 'apply'];
push @cases, ["5 ci <> t1", 'TEXT COLLATE ci', 'VARCHAR(16) COLLATE utf8mb4_general_ci', 'string', $x->ne('org_key', 't1'), 'T1', 'refuse_pg'],
  ["5 ci = own", 'TEXT COLLATE ci', 'VARCHAR(16) COLLATE utf8mb4_general_ci', 'string', $x->eq('org_key', 't1'), 't1', 'apply'];
push @cases, ["6 boolean <> true", 'BOOLEAN', 'BOOLEAN', 'boolean', $x->ne('org_key', 'true'), 't', 'refuse'],
  ["6 timestamp <>", 'TIMESTAMP', 'DATETIME', 'naive_datetime', $x->ne('org_key', '2024-01-01 10:00:00'), '2024-01-01T10:00:00', 'refuse'],
  ["6 timestamp(0) <>", 'TIMESTAMP(0)', 'DATETIME(0)', 'naive_datetime', $x->ne('org_key', '2024-01-01 10:00:00'), '2024-01-01 10:00:00.4', 'refuse'],
  ["6 date >", 'DATE', 'DATE', 'date', $x->gt('org_key', '2024-01-10'), '2024-1-5', 'refuse'];
push @cases, ["7 absent field", @$text, $x->eq('org_key', 't1'), undef, 'refuse'];
push @cases, ["8 column pair", @$text, $x->eq('org_key', $x->field('alias')), 't1', 'refuse'];
push @cases, ["9 ci_bin <> t1", 'TEXT COLLATE ci_bin', 'VARCHAR(16) COLLATE utf8mb4_general_ci', 'string', $x->ne('org_key', 't1'), 'T1', 'refuse'];
push @cases, ["10 decimal/DECIMAL(12,2) < 16", 'DECIMAL(12,2)', 'DECIMAL(12,2)', 'decimal', $x->lt('org_key', 16), '15.999', 'refuse'],
  ["10 string/varchar(2) <>", 'VARCHAR(2)', 'VARCHAR(2)', 'string', $x->ne('org_key', 't1'), 't1 ', 'refuse'],
  ["10 string/varchar(2) = own", 'VARCHAR(2)', 'VARCHAR(2)', 'string', $x->eq('org_key', 't1'), 't1', 'apply'];
push @cases, ["11 integer over text", 'TEXT', 'VARCHAR(16)', 'integer', $x->eq('org_key', '10'), '010', 'refuse'];
# Fixed-width CHAR(n) reads back with its trailing blanks stripped: no cast
# reproduces it, so storage admission refuses the column (PostgreSQL bpchar,
# MySQL-family CHAR/NCHAR) and nothing is admitted.
for my $ddl (['CHAR(4)', 'CHAR(4)'], ['CHAR(4) COLLATE "C"', 'CHAR(4) COLLATE utf8mb4_bin']) {
  push @cases, ["12 $ddl->[1] <> t1", @$ddl, 'string', $x->ne('org_key', 't1'), 't1 ', 'refuse'],
    ["12 $ddl->[1] NOT IN t1", @$ddl, 'string', $x->not($x->in('org_key', ['t1'])), 't1 ', 'refuse'],
    ["12 $ddl->[1] = 't1 '", @$ddl, 'string', $x->eq('org_key', 't1 '), 't1 ', 'refuse'];
}
# PostgreSQL domains (here over varchar(2) and numeric(10,0)) hide the
# typmod from the declared name: storage admission refuses them, so neither
# 't1 ' = 't1 ' (stored as 't1') nor 1.4 = 1.4 (stored as 1) is admitted.
push @cases, ["13 domain over varchar(2) = 't1 '", 'selecto_v2_org_domain', 'n/a', 'string', $x->eq('org_key', 't1 '), 't1 ', 'refuse'],
  ["13 domain over varchar(2) = own", 'selecto_v2_org_domain', 'n/a', 'string', $x->eq('org_key', 't1'), 't1', 'refuse'],
  ["13 domain over numeric(10,0) = 1.4", 'selecto_v2_amount_domain', 'n/a', 'decimal', $x->eq('org_key', '1.4'), '1.4', 'refuse'];
push @cases, ["N integer = 10 '010'", 'INTEGER', 'INT', 'integer', $x->eq('org_key', 10), '010', 'apply'],
  ["N numeric = 10 '10.0'", 'NUMERIC', 'DECIMAL(10,2)', 'decimal', $x->eq('org_key', 10), '10.0', 'apply'],
  ["R text range >= t", @$text, $x->gte('org_key', 't'), 'tz', 'refuse_or_defer'];

my %public = map { ($_ => 1) } qw(query_rule_violation query_rule_not_evaluable query_rule_unsupported_predicate);
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $pg = $name eq 'postgresql';
    subtest "$name inserts under host predicates follow the declared column type" => sub {
        my $dbh = $connect->();
        if ($pg) {
            $dbh->do("CREATE COLLATION IF NOT EXISTS $_ (provider = icu, locale = 'und-u-ks-level2', deterministic = false)")
                for qw(selecto_v2_ci ci_bin);
            $dbh->do('DROP TABLE IF EXISTS selecto_v2_rows');
            $dbh->do('DROP DOMAIN IF EXISTS selecto_v2_org_domain');
            $dbh->do('DROP DOMAIN IF EXISTS selecto_v2_amount_domain');
            $dbh->do('CREATE DOMAIN selecto_v2_org_domain AS varchar(2)');
            $dbh->do('CREATE DOMAIN selecto_v2_amount_domain AS numeric(10,0)');
        }
        for my $case (@cases) {
            my ($label, $pg_ddl, $my_ddl, $declared, $predicate, $value, $expect) = @$case;
            next if !$pg && $label =~ /\A(?:9|13) /;
            (my $ddl = $pg ? $pg_ddl : $my_ddl) =~ s/\bCOLLATE ci\b/COLLATE selecto_v2_ci/;
            my $qe = ref($predicate) eq 'ARRAY' ? $predicate->[1] : undef;
            for my $path (qw(engine typed_tooling untyped_tooling)) {
                $dbh->do('DROP TABLE IF EXISTS selecto_v2_rows');
                $dbh->do("CREATE TABLE selecto_v2_rows (id INT PRIMARY KEY, org_key $ddl"
                    . ($label =~ /\A7 / ? ' NOT NULL' : ' NULL') . ', alias VARCHAR(16))');
                my $domain = Selecto::Domain->parse({schema_version => 1, name => 'V2',
                    source => relation('selecto_v2_rows', id => 'integer', org_key => $declared, alias => 'string'),
                    schemas => {}, joins => {},
                    writes => {operations => {insert => {enabled => 1}},
                        fields => {map { ($_ => {insertable => 1}) } qw(id org_key alias)}}});
                my $adapter = Selecto->adapter($name => (dbh => $dbh));
                my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain);
                my $command = Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_v2_rows',
                    assignments => {id => 1, alias => 't1', defined($value) ? (org_key => $value) : ()},
                    ($path eq 'typed_tooling'
                        ? (metadata => {field_types => {id => 'integer', org_key => $declared, alias => 'string'}}) : ()),
                    ($qe ? (query_enforcement => Selecto::QueryEnforcement->capture($domain, $engine->query->where($qe)))
                        : (scope_predicate => $predicate)));
                my $error = eval { $path eq 'engine' ? $engine->execute_write($command) : $adapter->execute_write_unsafe($command); 1 }
                    ? undef : $@;
                my ($rows) = $dbh->selectrow_array('SELECT COUNT(*) FROM selecto_v2_rows');
                # Selecto compares MySQL-family text host-exactly
                # (tenant_key_collation): there 'T1' <> 't1' holds under a
                # case-insensitive collation, as in its SQL.
                my $want = $expect eq 'refuse_pg' ? ($pg ? 'refuse' : 'apply') : $expect;
                $want = 'refuse' if $path eq 'untyped_tooling';
                if ($want eq 'refuse_or_defer') {
                    ok(!$error || (blessed($error) && $public{$error->code}), "$label ($path): decided by SQL or refused");
                    next;
                }
                is($rows ? 'apply' : 'refuse', $want, "$label ($path)");
                ok(blessed($error) && $public{$error->code}, "$label ($path): refused with a public rule error")
                    or diag(blessed($error) ? $error->code : $error) if $want eq 'refuse';
            }
        }
        $dbh->do('DROP TABLE IF EXISTS selecto_v2_rows');
        $dbh->do("DROP COLLATION IF EXISTS $_") for $pg ? qw(selecto_v2_ci ci_bin) : ();
        $dbh->do("DROP DOMAIN IF EXISTS $_") for $pg ? qw(selecto_v2_org_domain selecto_v2_amount_domain) : ();
    };
}

# A fixed-width CHAR(n) tenant column (the usual uuid tenant, CHAR(36)) keeps
# governed inserts: their stored row is re-read under the enforced predicate,
# so the own tenant's row is applied under writes.scope.tenant, a required
# predicate or a host scope predicate, another tenant's (or a case variant of
# the own) is refused, and 't1 ' (stored 't1') is refused by that re-check
# (cases 12 above). Only commands without the re-check
# (*_unsafe tooling) refuse CHAR(n) outright.
for my $backend (grep { $_->[0] ne 'postgresql' } @backends) {
    my ($name, $connect) = @$backend;
    subtest "$name governed inserts on a CHAR(36) tenant column" => sub {
        my $dbh = $connect->();
        my $tenant = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
        my $base = {schema_version => 1, name => 'CharTenant',
            source => {%{relation('selecto_v2_char_rows', id => 'integer', tenant_id => 'string', label => 'string')},
                tenant_field => 'tenant_id'},
            schemas => {}, joins => {},
            writes => {operations => {insert => {enabled => 1}},
                fields => {map { ($_ => {insertable => 1}) } qw(id tenant_id label)}}};
        my %modes = (
            'writes.scope.tenant' => sub {
                my $document = {%$base, writes => {%{$base->{writes}},
                    scope => {tenant => {field => 'tenant_id', satisfied_by => ['trusted_context']}}}};
                return (Selecto::Engine->new(adapter => $_[0], domain => Selecto::Domain->parse($document),
                    scope => {tenant => $tenant}), {});
            },
            'required predicate' => sub {
                return (Selecto::Engine->new(adapter => $_[0], domain => Selecto::Domain->parse($base)
                    ->with_required_predicate($x->eq('tenant_id', $tenant))), {});
            },
            'host scope predicate' => sub {
                return (Selecto::Engine->new(adapter => $_[0], domain => Selecto::Domain->parse($base)),
                    {scope_predicate => $x->eq('tenant_id', $tenant)});
            },
        );
        for my $mode (sort keys %modes) {
            for my $case (['own tenant', $tenant, 'apply'], ['another tenant', 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'refuse'],
                ['the own tenant in upper case', uc($tenant), 'refuse']) {
                my ($label, $value, $expect) = @$case;
                $dbh->do('DROP TABLE IF EXISTS selecto_v2_char_rows');
                $dbh->do('CREATE TABLE selecto_v2_char_rows (id INT PRIMARY KEY, tenant_id CHAR(36) NOT NULL, label VARCHAR(16))');
                my ($engine, $extra) = $modes{$mode}->(Selecto->adapter($name => (dbh => $dbh)));
                my $error = eval {
                    $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_v2_char_rows',
                        assignments => {id => 1, tenant_id => $value, label => 'x'}, %$extra));
                    1;
                } ? undef : $@;
                my ($rows) = $dbh->selectrow_array('SELECT COUNT(*) FROM selecto_v2_char_rows');
                is($rows ? 'apply' : 'refuse', $expect, "$mode: $label")
                    or diag(blessed($error) ? $error->code : $error);
                ok(blessed($error) && $error->isa('Selecto::Error'), "$mode: $label refused with a typed error")
                    or diag($error) if $expect eq 'refuse';
            }
        }
        $dbh->do('DROP TABLE IF EXISTS selecto_v2_char_rows');
    };
}

done_testing;
