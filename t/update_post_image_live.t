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

# TW-09 (bound tenant-like scope): a governed update's engine tenant and
# host scope predicate hold for the rows it leaves behind, not only for the
# rows it found; assigning the scoped column, or a trigger rewriting it, must
# not move a row out of them. A plain required predicate and query
# enforcement bound the pre-image only: an update may leave them. Single
# writes, batches, graphs and RETURNING; a primary key and a plain KEY(id).
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

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

my $document = {schema_version => 1, name => 'PostImage',
    source => relation('selecto_post_rows', id => 'integer', org_key => 'string', name => 'string', note => 'string'),
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
        fields => {org_key => {updatable => 1}, note => {updatable => 1}}}};

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $my = $name eq 'mysql' || $name eq 'mariadb';
    my $reset = sub {
        my (%options) = @_;
        $dbh->do('DROP TABLE IF EXISTS selecto_post_rows');
        $dbh->do('CREATE TABLE selecto_post_rows (id INT NOT NULL' . ($options{plain_key} ? '' : ' PRIMARY KEY')
            . ', org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16), stamp VARCHAR(16) NULL)' . ($my ? ' ENGINE=InnoDB' : ''));
        $dbh->do('CREATE INDEX selecto_post_rows_id ON selecto_post_rows (id)') if $options{plain_key};
        $dbh->do(q{INSERT INTO selecto_post_rows (id, org_key, name, note) VALUES (1, 't1', 'x', 'n'), (2, 't2', 'x', 'n')});
    };
    my $state = sub { join ' ', map { "$_->[0]:$_->[1]:$_->[2]" }
        @{$dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_post_rows ORDER BY id')} };
    my $domain = Selecto::Domain->parse($document);
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my %modes = (
        'required predicate' => sub {
            return (Selecto::Engine->new(adapter => $adapter, domain => $domain->with_required_predicate($x->eq('org_key', 't1'))), {});
        },
        'query enforcement' => sub {
            my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain);
            return ($engine, {query_enforcement => Selecto::QueryEnforcement->capture($domain,
                $engine->query->where($x->eq('org_key', 't1')))});
        },
        'host scope predicate' => sub {
            return (Selecto::Engine->new(adapter => $adapter, domain => $domain), {scope_predicate => $x->eq('org_key', 't1')});
        },
    );
    my $run = sub {
        my ($mode, $path, $assignments, %options) = @_;
        my ($engine, $extra) = $modes{$mode}->();
        my $command = Selecto::Write::Command->new(operation => 'update', relation => 'selecto_post_rows',
            assignments => $assignments, predicate => $x->eq('name', 'x'), %$extra,
            ($options{returning} ? (metadata => {returning => ['id']}) : ()));
        my $error = eval {
            $path eq 'batch' ? $engine->execute_batch(Selecto::Write::Batch->new($command))
                : $path eq 'graph' ? $engine->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'root', command => $command}]))
                : $engine->execute_write($command);
            1;
        } ? undef : $@;
        return blessed($error) ? $error->code : defined($error) ? "died: $error" : 'applied';
    };
    for my $mode (sort keys %modes) {
        for my $path (qw(single batch graph returning)) {
            next if $path eq 'returning' && $name eq 'sqlite' && !eval { $dbh->{sqlite_version} ge '3.35' };
            my %options = (returning => $path eq 'returning');
            my $label = "$name $mode ($path)";
            my $bound = $mode eq 'host scope predicate';
            for my $plain_key (0, 1) {
                my $table = $plain_key ? 'KEY(id)' : 'primary key';
                $reset->(plain_key => $plain_key);
                if ($bound) {
                    # Without an enforced unique key the rows cannot be named
                    # for a re-read by key: the update is refused before it
                    # runs. PostgreSQL re-reads by row id and needs no key.
                    is($run->($mode, $path, {org_key => 'T1'}, %options),
                        $plain_key && $name ne 'postgresql' ? 'query_rule_not_evaluable' : 'query_rule_violation',
                        "$label, $table: assigning the scoped column out of scope is refused");
                    is($state->(), '1:t1:n 2:t2:n', "$label, $table: and nothing changed");
                } else {
                    is($run->($mode, $path, {org_key => 'T1'}, %options), 'applied',
                        "$label, $table: the update may leave its pre-image predicate");
                    is($state->(), '1:T1:n 2:t2:n', "$label, $table: to the found row only");
                }
            }
            $reset->();
            is($run->($mode, $path, {org_key => 'zz'}, %options), $bound ? 'query_rule_violation' : 'applied',
                "$label: another scope value " . ($bound ? 'is refused' : 'applies'));
            $reset->();
            is($run->($mode, $path, {note => 'changed'}, %options), 'applied', "$label: an ordinary update applies");
            is($state->(), '1:t1:changed 2:t2:n', "$label: to the scoped row only");
            $reset->();
            is($run->($mode, $path, {org_key => 't1', note => 'same'}, %options), 'applied',
                "$label: assigning the scoped column its own value applies");
            is($state->(), '1:t1:same 2:t2:n', "$label: as written");
        }
    }

    # A bound-scope update needs an enforced unique key and may not assign
    # it: with only an index on id, a decoy sharing the old key would stand
    # in for the row the update moved out of scope.
    {
        my $host = 'host scope predicate';
        my $key_domain = Selecto::Domain->parse({%$document, writes => {%{$document->{writes}},
            fields => {%{$document->{writes}{fields}}, id => {updatable => 1}}}});
        my $key_run = sub {
            my ($assignments) = @_;
            my $command = Selecto::Write::Command->new(operation => 'update', relation => 'selecto_post_rows',
                assignments => $assignments, predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 'T1'));
            return eval { Selecto::Engine->new(adapter => $adapter, domain => $key_domain)->execute_write($command); 'applied' }
                // (blessed($@) ? $@->code : "died: $@");
        };
        for my $plain_key (1, 0) {
            $dbh->do('DROP TABLE IF EXISTS selecto_post_rows');
            $dbh->do('CREATE TABLE selecto_post_rows (id INT NOT NULL' . ($plain_key ? '' : ' PRIMARY KEY')
                . ', org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16), stamp VARCHAR(16) NULL)' . ($my ? ' ENGINE=InnoDB' : ''));
            $dbh->do('CREATE INDEX selecto_post_rows_id ON selecto_post_rows (id)') if $plain_key;
            $dbh->do($plain_key ? q{INSERT INTO selecto_post_rows (id, org_key, name, note) VALUES (1, 'T1', 'x', 'n'), (1, 'T1', 'y', 'n')}
                : q{INSERT INTO selecto_post_rows (id, org_key, name, note) VALUES (1, 'T1', 'x', 'n'), (3, 'T1', 'y', 'n')});
            my $table = $plain_key ? 'a non-unique key with a decoy' : 'a primary key';
            if ($name eq 'postgresql') {
                # PostgreSQL re-reads the written rows by (tableoid, ctid)
                # (R9): a key reassigned, or not unique, cannot let a decoy
                # stand in, so only leaving the scope is refused.
                is($key_run->({id => 2, org_key => 'T2'}), 'query_rule_violation', "$name $table: reassigning the key out of scope is refused");
                is($key_run->({id => 2}), 'applied', "$name $table: reassigning the key in scope applies");
                is($key_run->({note => 'changed'}), 'applied', "$name $table: an ordinary update applies");
                is_deeply($dbh->selectall_arrayref('SELECT id, org_key, name FROM selecto_post_rows ORDER BY name'),
                    [[2, 'T1', 'x'], [$plain_key ? 1 : 3, 'T1', 'y']], "$name $table: no row left its scope");
                next;
            }
            is($key_run->({id => 2, org_key => 'T2'}), 'query_rule_not_evaluable', "$name $table: reassigning the key out of scope is refused");
            is($key_run->({id => 2}), 'query_rule_not_evaluable', "$name $table: reassigning the key in scope is refused too");
            is($key_run->({note => 'changed'}), $plain_key ? 'query_rule_not_evaluable' : 'applied',
                "$name $table: an ordinary update " . ($plain_key ? 'is refused without a unique key' : 'applies'));
            is_deeply($dbh->selectall_arrayref('SELECT id, org_key, name FROM selecto_post_rows ORDER BY name'),
                [[1, 'T1', 'x'], [$plain_key ? 1 : 3, 'T1', 'y']], "$name $table: no row left its scope");
        }
        # A required-only update keeps its pre-image semantics (TW-09).
        $reset->(plain_key => 1);
        is($run->('required predicate', 'single', {org_key => 'T1'}), 'applied',
            "$name: a required-only update on a non-unique key still applies");
    }

    # A trigger that rewrites the scoped column after a governed update of
    # another column moves the row out of scope: the re-read refuses it.
    my $trigger = $name eq 'postgresql' ? sub {
        $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_post_upper() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN NEW.org_key := upper(NEW.org_key); RETURN NEW; END $$});
        $dbh->do('CREATE TRIGGER selecto_post_upper BEFORE UPDATE ON selecto_post_rows FOR EACH ROW EXECUTE FUNCTION selecto_post_upper()');
    } : $name eq 'sqlite' ? sub {
        $dbh->do(q{CREATE TRIGGER selecto_post_upper AFTER UPDATE OF note ON selecto_post_rows
            BEGIN UPDATE selecto_post_rows SET org_key = upper(org_key) WHERE id = NEW.id; END});
    } : sub {
        $dbh->do('CREATE TRIGGER selecto_post_upper BEFORE UPDATE ON selecto_post_rows FOR EACH ROW SET NEW.org_key = UPPER(NEW.org_key)');
    };
    for my $mode (sort keys %modes) {
        $reset->();
        $trigger->();
        if ($mode eq 'host scope predicate') {
            # SQLite already refuses governed writes on tables with triggers.
            is($run->($mode, 'single', {note => 'changed'}), $name eq 'sqlite' ? 'required_data_rule_pending' : 'query_rule_violation',
                "$name $mode: a trigger moving the row out of scope is refused");
            is($state->(), '1:t1:n 2:t2:n', "$name $mode: and nothing changed");
        } elsif ($name ne 'sqlite') {
            is($run->($mode, 'single', {note => 'changed'}), 'applied', "$name $mode: a trigger may leave the pre-image predicate");
        }
    }
    # Under an engine tenant (an immutable tenant field) a trigger rewriting
    # the tenant column is refused too.
    $reset->();
    $trigger->();
    my $tenant_domain = Selecto::Domain->parse({%$document, source => {%{$document->{source}}, tenant_field => 'org_key'},
        writes => {%{$document->{writes}}, fields => {note => {updatable => 1}}}});
    my $tenant_engine = Selecto::Engine->new(adapter => $adapter, domain => $tenant_domain, scope => {tenant => 't1'});
    my $tenant_error = eval { $tenant_engine->execute_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'selecto_post_rows', assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'))); 1 } ? undef : $@;
    is(blessed($tenant_error) ? $tenant_error->code : 'applied', $name eq 'sqlite' ? 'required_data_rule_pending' : 'query_rule_violation',
        "$name engine tenant: a trigger rewriting the tenant column is refused");
    is($state->(), '1:t1:n 2:t2:n', "$name engine tenant: and nothing changed");
    $dbh->do('DROP TRIGGER IF EXISTS selecto_post_upper' . ($name eq 'postgresql' ? ' ON selecto_post_rows' : ''));
    $reset->();
    is(eval { $tenant_engine->execute_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'selecto_post_rows', assignments => {note => 'changed'}, predicate => $x->eq('name', 'x'))); 'applied' }
        // (blessed($@) ? $@->code : "died: $@"), 'applied', "$name engine tenant: an ordinary update applies");
    is($state->(), '1:t1:changed 2:t2:n', "$name engine tenant: to the tenant's row only");

    # Ordinary triggers keep working under a host scope: the re-read runs
    # after the statement and their effects stay in scope (SQLite refuses
    # governed writes on tables with triggers, as before).
    if ($name ne 'sqlite') {
        my $host = 'host scope predicate';
        $reset->();
        $dbh->do('DROP TABLE IF EXISTS selecto_post_audit');
        $dbh->do('CREATE TABLE selecto_post_audit (row_id INT)');
        if ($name eq 'postgresql') {
            $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_post_stamp() RETURNS trigger LANGUAGE plpgsql AS
                $$ BEGIN NEW.stamp := NEW.note; RETURN NEW; END $$});
            $dbh->do('CREATE TRIGGER selecto_post_stamp BEFORE UPDATE ON selecto_post_rows FOR EACH ROW EXECUTE FUNCTION selecto_post_stamp()');
            $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_post_audit() RETURNS trigger LANGUAGE plpgsql AS
                $$ BEGIN INSERT INTO selecto_post_audit VALUES (NEW.id); RETURN NULL; END $$});
            $dbh->do('CREATE TRIGGER selecto_post_audit AFTER UPDATE ON selecto_post_rows FOR EACH ROW EXECUTE FUNCTION selecto_post_audit()');
        } else {
            $dbh->do(q{CREATE TRIGGER selecto_post_stamp BEFORE UPDATE ON selecto_post_rows FOR EACH ROW SET NEW.stamp = NEW.note});
            $dbh->do('CREATE TRIGGER selecto_post_audit AFTER UPDATE ON selecto_post_rows FOR EACH ROW INSERT INTO selecto_post_audit VALUES (NEW.id)');
        }
        for my $path (qw(single batch graph returning)) {
            $dbh->do('DELETE FROM selecto_post_audit');
            $dbh->do(q{UPDATE selecto_post_rows SET note = 'n'});
            $dbh->do('DELETE FROM selecto_post_audit');
            is($run->($host, $path, {note => 'changed'}, returning => $path eq 'returning'), 'applied',
                "$name $path: an update with an updated_at-style and an audit trigger applies");
            is_deeply($dbh->selectall_arrayref('SELECT id, note, stamp FROM selecto_post_rows ORDER BY id'),
                [[1, 'changed', 'changed'], [2, 'n', 'n']], "$name $path: the BEFORE trigger's change is kept");
            is_deeply($dbh->selectall_arrayref('SELECT row_id FROM selecto_post_audit'), [[1]], "$name $path: and the AFTER trigger ran");
        }
        $dbh->do('DROP TABLE IF EXISTS selecto_post_audit');
        if ($name eq 'postgresql') {
            # An AFTER trigger (row or statement level) that rewrites the
            # scoped column runs before the re-read and is caught.
            for my $level ('ROW', 'STATEMENT') {
                $reset->();
                $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_post_after() RETURNS trigger LANGUAGE plpgsql AS
                    $$ BEGIN UPDATE selecto_post_rows SET org_key = upper(org_key) WHERE org_key <> upper(org_key); RETURN NULL; END $$});
                $dbh->do("CREATE TRIGGER selecto_post_after AFTER UPDATE OF note ON selecto_post_rows FOR EACH $level EXECUTE FUNCTION selecto_post_after()");
                # A statement-level trigger is refused before the update: it
                # can write rows the re-read does not name.
                is($run->($host, 'single', {note => 'changed'}), $level eq 'ROW' ? 'query_rule_violation' : 'write_capability_missing',
                    "$name: an AFTER $level trigger moving the row out of scope is refused");
                is($state->(), '1:t1:n 2:t2:n', "$name: AFTER $level, and nothing changed");
            }
            # A deferrable constraint trigger fires at commit, after any
            # re-read: the update is refused before it runs.
            $reset->();
            $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_post_noop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$});
            $dbh->do('CREATE CONSTRAINT TRIGGER selecto_post_deferred AFTER UPDATE ON selecto_post_rows DEFERRABLE INITIALLY DEFERRED'
                . ' FOR EACH ROW EXECUTE FUNCTION selecto_post_noop()');
            is($run->($host, 'single', {note => 'changed'}), 'query_rule_not_evaluable', "$name: a deferrable constraint trigger is refused");
            is($state->(), '1:t1:n 2:t2:n', "$name: deferrable, and nothing changed");
        }
        # A guarded update through a view cannot be verified.
        $reset->();
        $dbh->do('DROP VIEW IF EXISTS selecto_post_view');
        $dbh->do('CREATE VIEW selecto_post_view AS SELECT id, org_key, name, note, stamp FROM selecto_post_rows');
        my $view_domain = Selecto::Domain->parse({%$document, source => {%{$document->{source}}, source_table => 'selecto_post_view'}});
        my $view_error = eval { Selecto::Engine->new(adapter => $adapter, domain => $view_domain)->execute_write(
            Selecto::Write::Command->new(operation => 'update', relation => 'selecto_post_view', assignments => {note => 'changed'},
                predicate => $x->eq('name', 'x'), scope_predicate => $x->eq('org_key', 't1'))); 1 } ? undef : $@;
        is(blessed($view_error) ? $view_error->code : 'applied', 'query_rule_not_evaluable', "$name: a guarded update through a view is refused");
        is($state->(), '1:t1:n 2:t2:n', "$name: view, and nothing changed");
        $dbh->do('DROP VIEW IF EXISTS selecto_post_view');
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_post_rows');
    $dbh->do("DROP FUNCTION IF EXISTS $_()") for $name eq 'postgresql'
        ? qw(selecto_post_upper selecto_post_stamp selecto_post_audit selecto_post_after selecto_post_noop) : ();
}

done_testing;
