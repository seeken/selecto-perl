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
use Selecto::Write ();

# ON CONFLICT ... DO UPDATE updates whichever row holds the conflicting key.
# Under a host scope predicate that does not bound the conflict target, it
# took over or overwrote another tenant's row: such an upsert is refused
# (unsupported_scope_predicate), as MySQL and MariaDB refuse scoped upserts.
# A scope on conflict-target columns, and the engine tenant with the tenant
# in the conflict target, keep working.
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

sub document {
    my (%options) = @_;
    return {schema_version => 1, name => 'Upserts',
        source => {source_table => 'selecto_up_rows', primary_key => 'id', fields => [qw(id org_key code note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, code => {type => 'string'}, note => {type => 'string'}},
            associations => {}, ($options{tenant} ? (tenant_field => 'org_key') : ())},
        schemas => {}, joins => {},
        writes => {operations => {upsert => {enabled => 1, conflict_targets => [['code'], [qw(org_key code)]]}},
            fields => {map { ($_ => {insertable => 1, updatable => 1}) } qw(id org_key code note)}}};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $reset = sub {
        $dbh->do('DROP TABLE IF EXISTS selecto_up_rows');
        $dbh->do('CREATE TABLE selecto_up_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16) NOT NULL, code VARCHAR(16) NOT NULL,'
            . ' note VARCHAR(16), UNIQUE (code), UNIQUE (org_key, code))');
        $dbh->do(q{INSERT INTO selecto_up_rows VALUES (1, 't1', 'a', 'n'), (2, 't2', 'b', 'n')});
    };
    my $rows = sub { join ' ', map { join('/', @$_) } @{$dbh->selectall_arrayref('SELECT id, org_key, code, note FROM selecto_up_rows ORDER BY id')} };
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my $upsert = sub {
        my ($engine, $assignments, $target, $updates, %extra) = @_;
        my $command = Selecto::Write::Command->new(operation => 'upsert', relation => 'selecto_up_rows', assignments => $assignments,
            metadata => {conflict_target => $target, upsert_update_fields => $updates}, %extra);
        return eval { $engine->execute_write($command); 'applied' } // (blessed($@) ? $@->code : "died: $@");
    };
    my $plain = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document()));
    my @scope = (scope_predicate => $x->eq(q(org_key), q(t1)));
    for my $updates (['org_key', 'note'], ['note']) {
        $reset->();
        is($upsert->($plain, {id => 3, code => 'b', org_key => 't1', note => 'UP'}, ['code'], $updates, @scope),
            'unsupported_scope_predicate', "$name: a host-scoped upsert on code (updating @$updates) is refused");
        is($rows->(), '1/t1/a/n 2/t2/b/n', "$name: the other tenant's row is untouched (@$updates)");
    }
    $reset->();
    is($upsert->($plain, {id => 3, org_key => 't1', code => 'a', note => 'UP'}, [qw(org_key code)], ['note'], @scope),
        'applied', "$name: a host scope on a conflict-target column keeps working");
    is($rows->(), '1/t1/a/UP 2/t2/b/n', "$name: and updates the in-scope row only");
    $reset->();
    is($upsert->($plain, {id => 3, org_key => 't1', code => 'c', note => 'new'}, [qw(org_key code)], ['note'], @scope),
        'applied', "$name: and inserts a new in-scope row");
    is($rows->(), '1/t1/a/n 2/t2/b/n 3/t1/c/new', "$name: as written");
    my $tenant = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document(tenant => 1)), scope => {tenant => 't1'});
    $reset->();
    is($upsert->($tenant, {id => 3, org_key => 't1', code => 'a', note => 'UP'}, [qw(org_key code)], ['note']),
        'applied', "$name: an engine-tenant upsert with the tenant in its conflict target applies");
    is($rows->(), '1/t1/a/UP 2/t2/b/n', "$name: to the tenant's own row");
    $reset->();
    isnt($upsert->($tenant, {id => 3, org_key => 't1', code => 'b', note => 'UP'}, ['code'], ['note']), 'applied',
        "$name: an engine-tenant upsert without the tenant in its conflict target is refused");
    is($rows->(), '1/t1/a/n 2/t2/b/n', "$name: and changes nothing");
    $dbh->do('DROP TABLE IF EXISTS selecto_up_rows');
}

# A PostgreSQL statement-level UPDATE trigger can write rows the post-image
# re-read does not name: a bound-scope update on such a table is refused.
SKIP: {
    my ($pg) = grep { $_->[0] eq 'postgresql' } @backends;
    skip 'SELECTO_PERL_TEST_POSTGRES_URL is not configured', 10 unless $pg;
    my $dbh = $pg->[1]->();
    $dbh->do('DROP TABLE IF EXISTS selecto_up_rows');
    $dbh->do('CREATE TABLE selecto_up_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16) NOT NULL, code VARCHAR(16) NOT NULL, note VARCHAR(16))');
    $dbh->do(q{INSERT INTO selecto_up_rows VALUES (1, 't1', 'a', 'n'), (2, 't2', 'b', 'n')});
    $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_up_other() RETURNS trigger LANGUAGE plpgsql AS
        $$ BEGIN IF pg_trigger_depth() = 1 THEN UPDATE selecto_up_rows SET note = 'other' WHERE org_key = 't2'; END IF;
        RETURN NULL; END $$});
    $dbh->do('CREATE TRIGGER selecto_up_other AFTER UPDATE ON selecto_up_rows FOR EACH STATEMENT EXECUTE FUNCTION selecto_up_other()');
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Statement',
        source => {source_table => 'selecto_up_rows', primary_key => 'id', fields => [qw(id org_key code note)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, code => {type => 'string'}, note => {type => 'string'}},
            associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}});
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)), domain => $domain);
    my $result = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_up_rows',
        assignments => {note => 'changed'}, predicate => $x->eq('code', 'a'), scope_predicate => $x->eq('org_key', 't1'))); 'applied' }
        // (blessed($@) ? $@->code : "died: $@");
    is($result, 'write_capability_missing', 'a statement-level trigger writing other rows is refused');
    is_deeply($dbh->selectall_arrayref('SELECT id, note FROM selecto_up_rows ORDER BY id'), [[1, 'n'], [2, 'n']], 'and nothing changed');
    my $required = Selecto::Engine->new(adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
        domain => $domain->with_required_predicate($x->eq('org_key', 't1')));
    is(eval { $required->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_up_rows',
        assignments => {note => 'changed'}, predicate => $x->eq('code', 'a'))); 'applied' } // (blessed($@) ? $@->code : "died: $@"),
        'applied', 'a required-only update (pre-image bound) is not affected');
    is_deeply($dbh->selectall_arrayref('SELECT id, note FROM selecto_up_rows ORDER BY id'), [[1, 'changed'], [2, 'other']],
        'its trigger ran as usual');

    # The same holds for a statement-level DELETE trigger under a bound scope
    # (engine tenant or host scope); a required-only delete is not bound.
    my $delete_domain = sub {
        my ($tenant) = @_;
        return Selecto::Domain->parse({schema_version => 1, name => 'StatementDelete',
            source => {source_table => 'selecto_up_rows', primary_key => 'id', fields => [qw(id org_key code note)],
                columns => {id => {type => 'integer'}, org_key => {type => 'string'}, code => {type => 'string'}, note => {type => 'string'}},
                associations => {}, ($tenant ? (tenant_field => 'org_key') : ())},
            schemas => {}, joins => {},
            writes => {operations => {delete => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}}});
    };
    my $reset = sub {
        $dbh->do('DROP TABLE IF EXISTS selecto_up_rows');
        $dbh->do('CREATE TABLE selecto_up_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16) NOT NULL, code VARCHAR(16) NOT NULL, note VARCHAR(16))');
        $dbh->do(q{INSERT INTO selecto_up_rows VALUES (5, 't1', 'a', 'n'), (6, 't2', 'b', 'n')});
        $dbh->do('CREATE TRIGGER selecto_up_other AFTER DELETE ON selecto_up_rows FOR EACH STATEMENT EXECUTE FUNCTION selecto_up_other()');
    };
    my $state = sub { $dbh->selectall_arrayref('SELECT id, note FROM selecto_up_rows ORDER BY id') };
    my $delete = sub {
        my ($engine, %extra) = @_;
        return eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'delete', relation => 'selecto_up_rows',
            predicate => $x->eq('id', 5), %extra)); 'applied' } // (blessed($@) ? $@->code : "died: $@");
    };
    my $pg_adapter = Selecto->adapter(postgresql => (dbh => $dbh));
    $reset->();
    is($delete->(Selecto::Engine->new(adapter => $pg_adapter, domain => $delete_domain->(1), scope => {tenant => 't1'})),
        'write_capability_missing', 'an engine-tenant delete on a table with a statement-level DELETE trigger is refused');
    is_deeply($state->(), [[5, 'n'], [6, 'n']], 'and nothing changed');
    $reset->();
    is($delete->(Selecto::Engine->new(adapter => $pg_adapter, domain => $delete_domain->(0)), scope_predicate => $x->eq('org_key', 't1')),
        'write_capability_missing', 'a host-scoped delete on such a table is refused');
    is_deeply($state->(), [[5, 'n'], [6, 'n']], 'and nothing changed');
    $reset->();
    is($delete->(Selecto::Engine->new(adapter => $pg_adapter, domain => $delete_domain->(0)->with_required_predicate($x->eq('org_key', 't1')))),
        'applied', 'a required-only delete is not bound and applies');
    is_deeply($state->(), [[6, 'other']], 'with its trigger');
    $dbh->do('DROP TABLE IF EXISTS selecto_up_rows');
    $dbh->do('DROP FUNCTION IF EXISTS selecto_up_other()');
}

done_testing;
