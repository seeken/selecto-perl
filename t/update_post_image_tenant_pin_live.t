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

# TW-09 tenant-pin rule: a required filter that pins the domain's declared
# tenant field (source.tenant_field or writes.scope.tenant.field) is
# tenant-like, so it bounds the post-image of an update; a BEFORE UPDATE
# trigger that moves the row to another tenant is refused and rolled back.
# The pin is recognised by provenance (it comes from the host's required
# predicate: contract required_filters, write_context required_filters or
# with_required_predicate), never by comparing it with other conjuncts.
# Every other required filter still bounds the pre-image only: an update
# from status 'open' to 'closed' applies.
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

sub document {
    my (%o) = @_;
    return {schema_version => 1, name => 'TenantPin',
        source => {%{relation('selecto_pin_rows', id => 'integer', org_key => 'string', status => 'string', title => 'string')},
            ($o{tenant_field} ? (tenant_field => 'org_key') : ())},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {status => {updatable => 1}, title => {updatable => 1}},
            ($o{scope} ? (scope => {tenant => {field => 'org_key', satisfied_by => ['trusted_context']}}) : ())},
        ($o{required} ? (required_filters => $o{required}) : ())};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $pg = $name eq 'postgresql';
    my $lite = $name eq 'sqlite';
    my $reset = sub {
        my ($trigger) = @_;
        $dbh->do('DROP TABLE IF EXISTS selecto_pin_rows');
        $dbh->do('CREATE TABLE selecto_pin_rows (id INT NOT NULL PRIMARY KEY, org_key VARCHAR(16), status VARCHAR(16), title VARCHAR(16))'
            . ($pg || $lite ? '' : ' ENGINE=InnoDB'));
        $dbh->do(q{INSERT INTO selecto_pin_rows VALUES (1, 't1', 'open', 'a'), (2, 't2', 'open', 'a')});
        return unless $trigger;
        if ($pg) {
            $dbh->do(q{CREATE OR REPLACE FUNCTION selecto_pin_move() RETURNS trigger LANGUAGE plpgsql AS
                $$ BEGIN IF NEW.title = 'evil' THEN NEW.org_key := 't2'; END IF; RETURN NEW; END $$});
            $dbh->do('CREATE TRIGGER selecto_pin_move BEFORE UPDATE ON selecto_pin_rows FOR EACH ROW EXECUTE FUNCTION selecto_pin_move()');
        } else {
            $dbh->do(q{CREATE TRIGGER selecto_pin_move BEFORE UPDATE ON selecto_pin_rows FOR EACH ROW
                BEGIN IF NEW.title = 'evil' THEN SET NEW.org_key = 't2'; END IF; END});
        }
    };
    my $state = sub { join ' ', map { join ':', @$_ }
        @{$dbh->selectall_arrayref('SELECT id, org_key, status, title FROM selecto_pin_rows ORDER BY id')} };
    my $adapter = Selecto->adapter($name => (dbh => $dbh));
    my %pins = (
        'contract required_filters' => sub {
            Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document(@_, required => [['org_key', 't1']])))
        },
        'write_context required_filters' => sub {
            Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document(@_)),
                write_context => {required_filters => [['org_key', 't1']]})
        },
        'with_required_predicate' => sub {
            Selecto::Engine->new(adapter => $adapter,
                domain => Selecto::Domain->parse(document(@_))->with_required_predicate($x->eq('org_key', 't1')))
        },
    );
    my $run = sub {
        my ($engine, $path, $assignments, %options) = @_;
        my $command = Selecto::Write::Command->new(operation => 'update', relation => 'selecto_pin_rows',
            assignments => $assignments, predicate => $x->eq('id', 1),
            ($options{returning} ? (metadata => {returning => ['id']}) : ()));
        my $error = eval {
            $path eq 'batch' ? $engine->execute_batch(Selecto::Write::Batch->new($command))
                : $path eq 'graph' ? $engine->execute_graph(Selecto::Write::Graph->new(nodes => [{id => 'root', command => $command}]))
                : $engine->execute_write($command);
            1;
        } ? undef : $@;
        return blessed($error) ? $error->code : defined($error) ? "died: $error" : 'applied';
    };
    for my $source (sort keys %pins) {
        for my $path (qw(single batch graph returning)) {
            next if $path eq 'returning' && $lite;
            my $label = "$name $source ($path)";
            my %options = (returning => $path eq 'returning');
            unless ($lite) {
                # SQLite refuses governed writes on tables with triggers.
                $reset->(1);
                is($run->($pins{$source}->(tenant_field => 1), $path, {title => 'evil'}, %options), 'query_rule_violation',
                    "$label: a trigger moving the row off the tenant pin is refused");
                is($state->(), '1:t1:open:a 2:t2:open:a', "$label: and nothing changed");
                # Without a declared tenant field the pin is a plain required
                # filter: it bounds the pre-image only.
                is($run->($pins{$source}->(), $path, {title => 'evil'}, %options), 'applied',
                    "$label: without a declared tenant field the pin bounds the pre-image only");
                is($state->(), '1:t2:open:evil 2:t2:open:a', "$label: so the trigger's change stands");
            }
            $reset->(0);
            is($run->($pins{$source}->(tenant_field => 1), $path, {title => 'ok'}, %options), 'applied',
                "$label: an ordinary update under the tenant pin applies");
            is($state->(), '1:t1:open:ok 2:t2:open:a', "$label: to the pinned row only");
        }
    }

    # Detection fails closed: every spelling of a required conjunct that
    # reads the tenant column joins the post-image scope.
    unless ($lite) {
        my %spellings = (
            'an OR with one arm' => $x->any($x->eq('org_key', 't1')),
            'NOT(<>)' => $x->not($x->ne('org_key', 't1')),
            '>= AND <=' => $x->all($x->gte('org_key', 't1'), $x->lte('org_key', 't1')),
            'IN with one value' => $x->in('org_key', ['t1']),
            'nested ANDs' => $x->all($x->all($x->eq('status', 'open'), $x->all($x->eq('org_key', 't1')))),
            'an OR mixing columns' => $x->any($x->eq('org_key', 't1'), $x->eq('status', 'never')),
        );
        for my $spelling (sort keys %spellings) {
            for my $path (qw(single batch graph returning)) {
                $reset->(1);
                my $engine = Selecto::Engine->new(adapter => $adapter,
                    domain => Selecto::Domain->parse(document(tenant_field => 1))->with_required_predicate($spellings{$spelling}));
                is($run->($engine, $path, {title => 'evil'}, returning => $path eq 'returning'), 'query_rule_violation',
                    "$name tenant pin spelled as $spelling ($path): a trigger moving the row is refused");
                is($state->(), '1:t1:open:a 2:t2:open:a', "$name tenant pin spelled as $spelling ($path): and nothing changed");
            }
        }
        # The same spellings on a non-tenant column stay pre-image only.
        for my $filter ($x->not($x->ne('status', 'open')), $x->any($x->eq('status', 'open')), $x->in('status', ['open'])) {
            $reset->(0);
            my $engine = Selecto::Engine->new(adapter => $adapter,
                domain => Selecto::Domain->parse(document(tenant_field => 1))->with_required_predicate(
                    $x->all($x->eq('org_key', 't1'), $filter)));
            is($run->($engine, 'single', {status => 'closed'}), 'applied', "$name a " . $filter->kind . " status filter: open -> closed applies");
            is($state->(), '1:t1:closed:a 2:t2:open:a', "$name a " . $filter->kind . " status filter: as written");
        }
    }

    # A required filter on another column stays pre-image only, alone or
    # beside the tenant pin: status 'open' -> 'closed' applies.
    for my $case (
        ['a status filter', [['status', 'open']]],
        ['a status filter beside the tenant pin', [['org_key', 't1'], ['status', 'open']]],
    ) {
        my ($label, $required) = @$case;
        for my $path (qw(single batch graph)) {
            $reset->(0);
            my $engine = Selecto::Engine->new(adapter => $adapter,
                domain => Selecto::Domain->parse(document(tenant_field => 1, required => $required)));
            is($run->($engine, $path, {status => 'closed'}), 'applied', "$name $label ($path): open -> closed applies");
            is($state->(), '1:t1:closed:a 2:t2:open:a', "$name $label ($path): as written");
        }
        $reset->(0);
        my $engine = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse(document(required => $required)),
            write_context => {required_filters => [['status', 'open']]});
        is($run->($engine, 'single', {status => 'closed'}), 'applied', "$name $label + write_context status filter: applies");
    }

    # writes.scope.tenant on the pinned column, under the engine tenant.
    unless ($lite) {
        $reset->(1);
        my $engine = Selecto::Engine->new(adapter => $adapter, scope => {tenant => 't1'},
            domain => Selecto::Domain->parse(document(scope => 1, required => [['org_key', 't1']])));
        is($run->($engine, 'single', {title => 'evil'}), 'query_rule_violation',
            "$name writes.scope.tenant + required pin: a trigger moving the row is refused");
        is($state->(), '1:t1:open:a 2:t2:open:a', "$name writes.scope.tenant + required pin: and nothing changed");
    }

    # A nested graph child whose own domain declares the tenant field and
    # pins it through required_filters.
    unless ($lite) {
        $reset->(1);
        $dbh->do('DROP TABLE IF EXISTS selecto_pin_parent');
        $dbh->do('CREATE TABLE selecto_pin_parent (id INT NOT NULL PRIMARY KEY, title VARCHAR(16))' . ($pg ? '' : ' ENGINE=InnoDB'));
        $dbh->do(q{INSERT INTO selecto_pin_parent VALUES (1, 'p')});
        $dbh->do('ALTER TABLE selecto_pin_rows ADD COLUMN parent_id INT');
        $dbh->do('UPDATE selecto_pin_rows SET parent_id = 1');
        my $child = document(tenant_field => 1, required => [['org_key', 't1']]);
        push @{$child->{source}{fields}}, 'parent_id';
        $child->{source}{columns}{parent_id} = {type => 'integer'};
        my $parent = Selecto::Domain->parse({schema_version => 1, name => 'PinParent',
            source => relation('selecto_pin_parent', id => 'integer', title => 'string'), schemas => {}, joins => {},
            writes => {operations => {update => {enabled => 1}}, fields => {title => {updatable => 1}},
                relationships => {rows => {writable => 1, table => 'selecto_pin_rows', parent_key => 'id', child_key => 'parent_id',
                    allowed_ops => ['update'], domain => $child}}}});
        my $engine = Selecto::Engine->new(adapter => $adapter, domain => $parent);
        my $graph = sub {
            my ($title) = @_;
            Selecto::Write::Graph->new(nodes => [
                {id => 'parent', command => Selecto::Write::Command->new(operation => 'update', relation => 'selecto_pin_parent',
                    assignments => {title => 'q'}, predicate => $x->eq('id', 1))},
                {id => 'row', command => Selecto::Write::Command->new(operation => 'update', relation => 'selecto_pin_rows',
                    assignments => {title => $title}, predicate => $x->eq('id', 1)),
                    bindings => [{field => 'parent_id', from => 'parent', key => 'id'}]},
            ]);
        };
        my $code = eval { $engine->execute_graph($graph->('evil')); 'applied' } // (blessed($@) ? $@->code : "died: $@");
        is($code, 'query_rule_violation', "$name nested graph child: a trigger moving the child off its tenant pin is refused");
        is($state->(), '1:t1:open:a 2:t2:open:a', "$name nested graph child: and nothing changed");
        is_deeply($dbh->selectall_arrayref('SELECT title FROM selecto_pin_parent'), [['p']], "$name nested graph child: the parent rolled back");
        $code = eval { $engine->execute_graph($graph->('ok')); 'applied' } // (blessed($@) ? $@->code : "died: $@");
        is($code, 'applied', "$name nested graph child: an ordinary child update applies");
        is($state->(), '1:t1:open:ok 2:t2:open:a', "$name nested graph child: to the pinned row");
        $dbh->do('DROP TABLE IF EXISTS selecto_pin_parent');
    }
    $dbh->do('DROP TABLE IF EXISTS selecto_pin_rows');
    $dbh->do('DROP FUNCTION IF EXISTS selecto_pin_move()') if $pg;
}

done_testing;
