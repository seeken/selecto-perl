use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::QueryEnforcement ();
use Selecto::Write ();

# An insert has no pre-image: its post-image must satisfy its full guard
# (query enforcement, required filters, host scope, engine tenant). A
# trigger that moves the new row out of its guard (org_key t1 -> t2) must
# never commit it: PostgreSQL re-reads the inserted row by (tableoid, ctid)
# under the full guard after the statement and rolls it back
# (query_rule_violation), so ordinary row triggers stay allowed (R13); the
# other backends refuse a guarded insert on a table with insert triggers
# before any DML.
my $x = 'Selecto::Expression';
my @backends = (['sqlite', sub {
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1})
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
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
my $document = {schema_version => 1, name => 'InsertGuard',
    source => {source_table => 'selecto_ins_guard', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {insert => {enabled => 1}},
        fields => {id => {insertable => 1}, name => {insertable => 1}, note => {insertable => 1}, org_key => {insertable => 1}}}};
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my ($pg, $lite) = ($name eq 'postgresql', $name eq 'sqlite');
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my $domain = Selecto::Domain->parse($document);
    my %guards = (
        'query enforcement' => sub { my $e = Selecto::Engine->new(adapter => $adapter, domain => $domain);
            ($e, query_enforcement => Selecto::QueryEnforcement->capture($domain, $e->query->where($x->eq('org_key', 't1')))) },
        'a required filter' => sub { (Selecto::Engine->new(adapter => $adapter, domain => $domain->with_required_predicate($x->eq('org_key', 't1')))) },
        'a host scope' => sub { (Selecto::Engine->new(adapter => $adapter, domain => $domain), scope_predicate => $x->eq('org_key', 't1')) },
        'the engine tenant' => sub { (Selecto::Engine->new(adapter => $adapter, scope => {tenant => 't1'},
            domain => Selecto::Domain->parse({%$document, source => {%{$document->{source}}, tenant_field => 'org_key'}}))) },
    );
    for my $guard (sort keys %guards) {
        $dbh->do('DROP TABLE IF EXISTS selecto_ins_guard');
        $dbh->do('CREATE TABLE selecto_ins_guard (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16))'
            . ($pg || $lite ? '' : ' ENGINE=InnoDB'));
        if ($pg) {
            $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_ins_move() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.org_key := 't2'; RETURN NEW; END $$});
            $dbh->do('CREATE TRIGGER selecto_ins_move BEFORE INSERT ON selecto_ins_guard FOR EACH ROW EXECUTE FUNCTION selecto_ins_move()');
        } elsif ($lite) {
            $dbh->do(q{CREATE TRIGGER selecto_ins_move AFTER INSERT ON selecto_ins_guard BEGIN UPDATE selecto_ins_guard SET org_key = 't2' WHERE id = NEW.id; END});
        } else {
            $dbh->do(q{CREATE TRIGGER selecto_ins_move BEFORE INSERT ON selecto_ins_guard FOR EACH ROW SET NEW.org_key = 't2'});
        }
        my ($engine, %extra) = $guards{$guard}->();
        my $code = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_ins_guard',
            assignments => {id => 3, org_key => 't1', name => 'y', note => 'i'}, %extra)); 'applied' } // (blessed($@) ? $@->code : "died: $@");
        is($code, $pg ? 'query_rule_violation' : 'query_rule_not_evaluable',
            "$name: an insert guarded by $guard on a trigger table is refused");
        is_deeply($dbh->selectall_arrayref('SELECT COUNT(*) FROM selecto_ins_guard'), [[0]], "$name: $guard, and nothing was inserted");
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_ins_guard');
    $dbh->do('DROP FUNCTION IF EXISTS selecto_ins_move()') if $pg;
}
done_testing;
