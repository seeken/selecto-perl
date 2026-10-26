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

# MySQL/MariaDB: MEMORY, MyISAM and Aria apply each statement at once, so a
# write refused after its statement (a post-image violation, a cardinality
# mismatch, a later batch or graph command) could not be rolled back: the
# moved or changed rows stayed. Every write now requires an InnoDB table,
# checked after the table's metadata lock, on the single, batch, graph,
# delete and unsafe paths; a session TEMPORARY table shadowing the base
# table is refused too.
my @backends;
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
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;
my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Engines',
    source => {source_table => 'selecto_engine_rows', primary_key => 'id', fields => [qw(id name note org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
        associations => {}, tenant_field => 'org_key'},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}, delete => {enabled => 1, bulk => 1}},
        fields => {note => {updatable => 1}}}});
my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => 'selecto_engine_rows', assignments => {note => $_[1]},
    predicate => $x->eq('id', $_[0])) };
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain, scope => {tenant => 't1'});
    my %cases = (
        'an update moved out of its tenant by a trigger' => sub { $engine->execute_write($update->(1, 'evil')) },
        'a batch whose second update matches nothing' => sub { $engine->execute_batch(Selecto::Write::Batch->new($update->(1, 'b'), $update->(99, 'b'))) },
        'a graph whose second node matches nothing' => sub { $engine->execute_graph(Selecto::Write::Graph->new(nodes => [
            {id => 'a', command => $update->(1, 'g')}, {id => 'b', command => $update->(99, 'g')}])) },
        'an unsafe update expecting 1 that matches 2' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'update',
            relation => 'selecto_engine_rows', assignments => {note => 'u'}, predicate => $x->eq('org_key', 't1'), expected_count => 1)) },
        'a batch inserting, then updating nothing' => sub { $adapter->execute_batch_unsafe(Selecto::Write::Batch->new(
            Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_engine_rows', assignments => {id => 9, org_key => 't1', name => 'y', note => 'i'}),
            Selecto::Write::Command->new(operation => 'update', relation => 'selecto_engine_rows', assignments => {note => 'b'}, predicate => $x->eq('id', 99)))) },
        'an unsafe delete expecting 1 that matches 2' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'delete',
            relation => 'selecto_engine_rows', predicate => $x->eq('org_key', 't1'), expected_count => 1)) },
    );
    for my $storage ($name eq 'mariadb' ? qw(InnoDB MyISAM MEMORY Aria) : qw(InnoDB MyISAM MEMORY), 'temporary MEMORY shadow') {
        for my $case (sort keys %cases) {
            $dbh->do('DROP TEMPORARY TABLE IF EXISTS selecto_engine_rows');
            $dbh->do('DROP TABLE IF EXISTS selecto_engine_rows');
            my $engine_name = $storage =~ /shadow/ ? 'InnoDB' : $storage;
            $dbh->do("CREATE TABLE selecto_engine_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16)) ENGINE=$engine_name");
            if ($storage =~ /shadow/) {
                $dbh->do('CREATE TEMPORARY TABLE selecto_engine_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16)) ENGINE=MEMORY');
            }
            $dbh->do(q{INSERT INTO selecto_engine_rows VALUES (1, 't1', 'x', 'n'), (2, 't1', 'x', 'n'), (3, 't2', 'x', 'n')});
            $dbh->do(q{CREATE TRIGGER selecto_engine_tr BEFORE UPDATE ON selecto_engine_rows FOR EACH ROW
                BEGIN IF NEW.note = 'evil' THEN SET NEW.org_key = 't2'; END IF; END}) if $storage !~ /shadow/;
            my $code = eval { $cases{$case}->(); 'applied' } // (blessed($@) ? $@->code : "died: $@");
            my $state = join ' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, org_key, note FROM selecto_engine_rows ORDER BY id')};
            if ($storage eq 'InnoDB') {
                isnt($code, 'applied', "$name InnoDB: $case is refused after its statement ($code)");
            } else {
                like($code, $storage =~ /shadow/ ? qr/\A(?:write_capability_missing|query_rule_not_evaluable)\z/ : qr/\Awrite_capability_missing\z/,
                    "$name $storage: $case is refused before any DML");
            }
            is($state, '1:t1:n 2:t1:n 3:t2:n', "$name $storage: $case leaves every row unchanged");
        }
    }
    # Item 27: MySQL 8.4 does not list TEMPORARY tables in
    # information_schema, so a TEMPORARY MEMORY table shadowing an InnoDB
    # base table would pass a catalog-only engine check. Inserts and upserts
    # (guarded, RETURNING, upsert) are refused, or cannot leave a refused
    # row, against such a shadow too.
    my $tenant_engine = Selecto::Engine->new(adapter => $adapter, scope => {tenant => 't1'}, domain => Selecto::Domain->parse({
        schema_version => 1, name => 'EnginesInsert',
        source => {source_table => 'selecto_engine_rows', primary_key => 'id', fields => [qw(id name note org_key)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, name => {type => 'string'}, note => {type => 'string'}},
            associations => {}, tenant_field => 'org_key'},
        schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}, upsert => {enabled => 1, conflict_targets => [['org_key', 'id']]}},
            fields => {id => {insertable => 1}, name => {insertable => 1}, note => {insertable => 1, updatable => 1}, org_key => {insertable => 1}}}}));
    my %inserts = (
        'a guarded insert' => sub { $tenant_engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_engine_rows',
            assignments => {id => 9, org_key => 't1', name => 'y', note => 'i'})) },
        'a RETURNING insert' => sub { $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_engine_rows',
            assignments => {id => 9, org_key => 't1', name => 'y', note => 'i'},
            metadata => {returning => ['id'], __selecto_primary_key => 'id', __selecto_tenant_fields => []})) },
        'a guarded upsert' => sub { $tenant_engine->execute_write(Selecto::Write::Command->new(operation => 'upsert', relation => 'selecto_engine_rows',
            assignments => {id => 1, org_key => 't1', name => 'y', note => 'u'}, metadata => {conflict_target => ['org_key', 'id'], upsert_update_fields => ['note']})) },
    );
    for my $case (sort keys %inserts) {
        $dbh->do('DROP TEMPORARY TABLE IF EXISTS selecto_engine_rows');
        $dbh->do('DROP TABLE IF EXISTS selecto_engine_rows');
        $dbh->do('CREATE TABLE selecto_engine_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16), UNIQUE KEY (org_key, id)) ENGINE=InnoDB');
        $dbh->do('CREATE TEMPORARY TABLE selecto_engine_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), name VARCHAR(16), note VARCHAR(16), UNIQUE KEY (org_key, id)) ENGINE=MEMORY');
        $dbh->do(q{INSERT INTO selecto_engine_rows VALUES (1, 't1', 'x', 'n')});
        my $code = eval { $inserts{$case}->(); 'applied' } // (blessed($@) ? $@->code : "died: $@");
        isnt($code, 'applied', "$name temporary MEMORY shadow: $case is refused ($code)");
        is_deeply($dbh->selectall_arrayref('SELECT id, note FROM selecto_engine_rows ORDER BY id'), [[1, 'n']],
            "$name temporary MEMORY shadow: $case changes nothing");
    }
    # Item 32: lone inserts and upserts too. An insert expecting 2 rows, a
    # RETURNING insert with an unassigned non-AUTO_INCREMENT key, and an
    # AFTER INSERT trigger that SIGNALs all fail after the row is stored; on
    # MEMORY and MyISAM that row stayed. Every MySQL-family write now
    # requires InnoDB.
    my $plain = Selecto::Domain->parse({schema_version => 1, name => 'EnginesLone',
        source => {source_table => 'selecto_engine_lone', primary_key => 'id', fields => [qw(id note org_key)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}, upsert => {enabled => 1, conflict_targets => [['id']]}},
            fields => {id => {insertable => 1}, org_key => {insertable => 1}, note => {insertable => 1, updatable => 1}}}});
    my $lone_engine = Selecto::Engine->new(adapter => $adapter, domain => $plain);
    my %lone = (
        'an insert expecting 2 rows' => ['', sub { Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_engine_lone',
            assignments => {id => 3, org_key => 't1', note => 'i'}, expected_count => 2) }],
        'a RETURNING insert with an unassigned plain key' => ['DEFAULT 9 ', sub { Selecto::Write::Command->new(operation => 'insert',
            relation => 'selecto_engine_lone', assignments => {org_key => 't1', note => 'i'}, metadata => {returning => ['id']}) }],
        'an insert an AFTER INSERT trigger refuses' => ['trigger', sub { Selecto::Write::Command->new(operation => 'insert',
            relation => 'selecto_engine_lone', assignments => {id => 3, org_key => 't1', note => 'boom'}) }],
        'an upsert expecting 2 rows' => ['', sub { Selecto::Write::Command->new(operation => 'upsert', relation => 'selecto_engine_lone',
            assignments => {id => 4, org_key => 't1', note => 'up'}, expected_count => 2,
            metadata => {conflict_target => ['id'], upsert_update_fields => ['note']}) }],
    );
    for my $storage (qw(InnoDB MEMORY MyISAM)) {
        for my $case (sort keys %lone) {
            my ($flag, $command) = @{$lone{$case}};
            $dbh->do('DROP TABLE IF EXISTS selecto_engine_lone');
            $dbh->do('CREATE TABLE selecto_engine_lone (id INT NOT NULL ' . ($flag =~ /DEFAULT/ ? $flag : '')
                . "PRIMARY KEY, org_key VARCHAR(16), note VARCHAR(16)) ENGINE=$storage");
            $dbh->do(q{INSERT INTO selecto_engine_lone VALUES (1, 't1', 'n'), (2, 't2', 'n')});
            $dbh->do(q{CREATE TRIGGER selecto_engine_sig AFTER INSERT ON selecto_engine_lone FOR EACH ROW
                BEGIN IF NEW.note = 'boom' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'boom'; END IF; END}) if $flag eq 'trigger';
            my $code = eval { $lone_engine->execute_write($command->()); 'applied' } // (blessed($@) ? $@->code : "died: $@");
            if ($storage eq 'InnoDB') {
                isnt($code, 'applied', "$name InnoDB: $case is refused ($code)");
            } else {
                is($code, 'write_capability_missing', "$name $storage: $case is refused before any DML");
            }
            is_deeply($dbh->selectall_arrayref('SELECT id, note FROM selecto_engine_lone ORDER BY id'), [[1, 'n'], [2, 'n']],
                "$name $storage: $case leaves no row behind");
        }
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_engine_lone');
    $dbh->do('DROP TEMPORARY TABLE IF EXISTS selecto_engine_rows');
    $dbh->do('DROP TABLE IF EXISTS selecto_engine_rows');
}
done_testing;
