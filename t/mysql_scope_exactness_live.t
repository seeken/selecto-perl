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
use Selecto::API::EngineHandler ();

# Review findings on the MySQL family (round 3, R2 R3 R4 R5 R11 R12), with
# PostgreSQL's answers as the oracle:
# - a TEMPORARY table shadowing a through-association bridge, which the
#   generated SQL names inside a parenthesised join, is refused on reads;
# - host, trusted and required ranges, BETWEEN and prefix/substring/suffix
#   matches on a text scope column compare bytes ('t1' never matches 'T1',
#   'tı', and only a byte prefix matches 't1 '); caller filters keep the
#   server's collation;
# - a text match on a TIMESTAMP scope column is refused (it reads the text
#   in the session zone, which a function can switch mid-statement);
# - a zero date never satisfies a TIMESTAMP scope compare;
# - a stream on a mariadb_use_result handle works, and no row reaches the
#   caller before the session check that covers it;
# - caller write predicates on TIMESTAMP columns keep the server's semantics.
my $x = 'Selecto::Expression';
my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my (%extra) = @_;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1, %extra});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;

sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return 'ok ' . (ref($value) eq 'ARRAY' ? join(',', @$value) : $value // '') if !$@;
    return blessed($@) && $@->can('code') ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();

    # R2: the bridge of a through association.
    $dbh->do('DROP TABLE IF EXISTS ' . join(', ', qw(sse_items sse_link sse_acc)));
    $dbh->do('CREATE TABLE sse_items (id INT PRIMARY KEY, org_key VARCHAR(8)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO sse_items VALUES (1, 't1'), (2, 't2')});
    $dbh->do('CREATE TABLE sse_acc (id INT PRIMARY KEY, label VARCHAR(20)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO sse_acc VALUES (10, 't1-acc'), (20, 't2-SECRET')});
    $dbh->do('CREATE TABLE sse_link (item_id INT, acc_id INT) ENGINE=InnoDB');
    $dbh->do('INSERT INTO sse_link VALUES (1, 10), (2, 20)');
    my $bridge = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => Selecto::Domain->parse({
        schema_version => 1, name => 'Bridge',
        source => {source_table => 'sse_items', primary_key => 'id', tenant_field => 'org_key', fields => [qw(id org_key)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}},
            associations => {accs => {queryable => 'acc', owner_key => 'id', related_key => 'id', cardinality => 'many',
                through => {table => 'sse_link', owner_key => 'item_id', related_key => 'acc_id'}}}},
        schemas => {acc => {source_table => 'sse_acc', primary_key => 'id', fields => [qw(id label)],
            columns => {id => {type => 'integer'}, label => {type => 'string'}}, associations => {}}},
        joins => {accs => {type => 'left'}}}))->with_scope(tenant => 't1');
    my $labels = sub { [map { $_->[1] // 'null' } @{$bridge->all($bridge->query->select('id', 'accs.label')->order_by('id'))->{rows}}] };
    my $streamed = sub {
        my $s = $bridge->stream($bridge->query->select('id', 'accs.label')->order_by('id'));
        my @rows; while (my $r = $s->next) { push @rows, $r->[1] } \@rows;
    };
    is(outcome($labels), 'ok t1-acc', "$name: the bridged read sees its own rows");
    $dbh->do('CREATE TEMPORARY TABLE sse_link (item_id INT, acc_id INT)');
    $dbh->do('INSERT INTO sse_link VALUES (1, 10), (1, 20)');
    is(outcome($labels), 'query_rule_not_evaluable/temporary_shadow', "$name: a TEMPORARY bridge shadow is refused");
    is(outcome($streamed), 'query_rule_not_evaluable/temporary_shadow', "$name: and refused on a stream");
    $dbh->do('DROP TEMPORARY TABLE sse_link');
    is(outcome($labels), 'ok t1-acc', "$name: and reads again once it is gone");

    # R3, R4, R5: scope exactness.
    $dbh->do('DROP TABLE IF EXISTS sse_rows');
    $dbh->do('CREATE TABLE sse_rows (id INT PRIMARY KEY, org_key VARCHAR(8), ts TIMESTAMP NULL, note VARCHAR(10)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO sse_rows VALUES (1, 't1', '2024-06-01 00:00:00', 'n'), (2, 'T1', '2024-06-02 00:00:00', 'n'),
        (3, 't1 ', '2024-06-03 00:00:00', 'n'), (4, 'tı', '2024-06-04 00:00:00', 'n')});
    my $domain = sub {
        my ($required, @write) = @_;
        my $d = Selecto::Domain->parse({schema_version => 1, name => 'Rows',
            source => {source_table => 'sse_rows', primary_key => 'id', fields => [qw(id org_key ts note)],
                columns => {id => {type => 'integer'}, org_key => {type => 'string'}, ts => {type => 'utc_datetime'},
                    note => {type => 'string'}}, associations => {}},
            schemas => {}, joins => {}, @write});
        return defined($required) ? $d->with_required_predicate($required) : $d;
    };
    my $ids = sub {
        my ($required, $filter) = @_;
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain->($required));
        my $query = $engine->query->select('id')->order_by('id');
        $query = $query->where($filter) if $filter;
        return outcome(sub { [map { $_->[0] } @{$engine->all($query)->{rows}}] });
    };
    my %cases = (
        'between' => [$x->between('org_key', 't1', 't1'), '1'],
        'gte and lte' => [$x->all($x->gte('org_key', 't1'), $x->lte('org_key', 't1')), '1'],
        'starts_with' => [$x->starts_with('org_key', 't1'), '1,3'],
        'text_contains' => [$x->text_contains('org_key', 't1'), '1,3'],
        'ends_with' => [$x->ends_with('org_key', 't1'), '1'],
        'not starts_with' => [$x->not($x->starts_with('org_key', 't1')), '2,4'],
    );
    for my $label (sort keys %cases) {
        is($ids->($cases{$label}[0]), "ok $cases{$label}[1]", "$name required $label compares bytes");
    }
    is($ids->($x->starts_with_ci('org_key', 't1')), 'query_rule_not_evaluable/inexact_text',
        "$name: a case-insensitive scope match is refused");
    like($ids->(undef, $x->starts_with('org_key', 't1')), qr/\Aok 1,2,3/, "$name: a caller prefix keeps the server's collation");
    is($ids->($x->starts_with('ts', '2024-06-01')), 'query_rule_not_evaluable/timestamp_operator',
        "$name: a text match on a TIMESTAMP scope column is refused");
    is($ids->($x->text_contains('ts', '06-01')), 'query_rule_not_evaluable/timestamp_operator',
        "$name: so is a substring match");
    is($ids->(undef, $x->starts_with('ts', '2024-06-01')), 'ok 1', "$name: a caller text match on a TIMESTAMP keeps working");
    is($ids->($x->gte('ts', '2024-06-02')), 'ok 2,3,4', "$name: a TIMESTAMP scope range still compares by epoch");
    # R15: any other use of a TIMESTAMP scope column (a cast, a computed value
    # built on it) renders it in the session zone: refused; a NULL test works.
    {
        my $computed = Selecto::Domain->parse({schema_version => 1, name => 'Computed',
            source => {source_table => 'sse_rows', primary_key => 'id', fields => [qw(id ts as_text)],
                columns => {id => {type => 'integer'}, ts => {type => 'utc_datetime'},
                    as_text => {type => 'string', computed => {kind => 'expression', expression => ['cast', ['field', 'ts'], 'string']}}},
                associations => {}}, schemas => {}, joins => {}});
        my $read = sub {
            my ($domain) = @_;
            my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
            return outcome(sub { [map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}}] });
        };
        is($read->($computed->with_required_predicate($x->gte('as_text', '2024-06-02'))), 'query_rule_not_evaluable/timestamp_operator',
            "$name: a computed value over a TIMESTAMP scope column is refused");
        is($read->($computed->with_required_predicate($x->not_null('ts'))), 'ok 1,2,3,4', "$name: a NULL test on it still works");
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $computed);
        like(outcome(sub { [map { $_->[0] } @{$engine->all($engine->query->select('id')->where($x->gte('as_text', '2024-06-02'))->order_by('id'))->{rows}}] }),
            qr/\Aok /, "$name: a caller filter on it keeps working");
    }

    # R12: caller write predicates keep native semantics.
    my $writer = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain->(undef,
        writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}}, fields => {note => {updatable => 1}}}));
    my $update = sub { my ($predicate) = @_; outcome(sub { $writer->execute_write(Selecto::Write::Command->new(operation => 'update',
        relation => 'sse_rows', assignments => {note => 'u'}, predicate => $predicate))->affected_rows }) };
    is($update->($x->lt('ts', '2024-6-2')), 'ok 1', "$name: a caller write predicate takes the server's literal forms");
    unlike($update->($x->eq('ts', undef)), qr/timestamp_literal/, "$name: and its own NULL comparison");
    unlike($writer->adapter->preview_write(Selecto::Write::Command->new(operation => 'update', relation => 'sse_rows',
        assignments => {note => 'u'}, predicate => $x->lt('ts', '2024-06-02')))->{sql}, qr/UNIX_TIMESTAMP/,
        "$name: a caller write predicate compiles natively");
    like($writer->adapter->preview_write(Selecto::Write::Command->new(operation => 'update', relation => 'sse_rows',
        assignments => {note => 'u'}, predicate => $x->eq('id', 1), scope_predicate => $x->lt('ts', '2024-06-02')))->{sql},
        qr/NULLIF\(UNIX_TIMESTAMP\(`ts`\), 0\) < CAST/, "$name: a write's scope still compares by epoch");
    like($writer->adapter->preview_write(Selecto::Write::Command->new(operation => 'update', relation => 'sse_rows',
        assignments => {note => 'u'}, predicate => $x->eq('id', 1), scope_predicate => $x->starts_with('org_key', 't1')))->{sql},
        qr/CAST\(CONVERT\(`org_key` USING utf8mb4\) AS BINARY\) LIKE CAST/, "$name: a write's scope prefix compares bytes");

    # R5: zero dates.
    $dbh->do('DROP TABLE IF EXISTS sse_zero');
    $dbh->do('CREATE TABLE sse_zero (id INT PRIMARY KEY, ts TIMESTAMP NULL) ENGINE=InnoDB');
    {
        my $loose = $connect->();
        $loose->do(q{SET SESSION sql_mode = ''});
        $loose->do(q{INSERT INTO sse_zero VALUES (1, '0000-00-00 00:00:00'), (2, '2024-06-01 00:00:00')});
        $loose->disconnect;
    }
    my $zero_domain = Selecto::Domain->parse({
        schema_version => 1, name => 'Zero', source => {source_table => 'sse_zero', primary_key => 'id', fields => [qw(id ts)],
            columns => {id => {type => 'integer'}, ts => {type => 'utc_datetime'}}, associations => {}}, schemas => {}, joins => {}});
    my $zero = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $zero_domain);
    for my $case (['gt', '1960-01-01', '2'], ['lt', '2030-01-01', '2']) {
        my ($op, $value, $want) = @$case;
        my $engine = Selecto::Engine->new(adapter => $zero->adapter, domain => $zero_domain->with_required_predicate($x->$op('ts', $value)));
        is(outcome(sub { [map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}}] }), "ok $want",
            "$name: a zero date never satisfies the scope ts $op $value");
    }

    # R11: streaming on a use_result handle.
    my $unbuffered = $connect->(mariadb_use_result => 1);
    my $plain = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $unbuffered)), domain => $domain->(undef));
    is(outcome(sub { my $s = $plain->stream($plain->query->select('id')->order_by('id')); my @r; while (my $r = $s->next) { push @r, $r->[0] } \@r }),
        'ok 1,2,3,4', "$name: a use_result handle streams a plain table");
    $unbuffered->do('DROP VIEW IF EXISTS sse_view');
    $unbuffered->do('DROP FUNCTION IF EXISTS sse_fn');
    $unbuffered->do(q{CREATE FUNCTION sse_fn(i INT) RETURNS INT NOT DETERMINISTIC NO SQL
        BEGIN IF i = 3 THEN SET time_zone = '+14:00'; END IF; RETURN 1; END});
    $unbuffered->do('CREATE VIEW sse_view AS SELECT id, org_key, ts, note FROM sse_rows WHERE sse_fn(id) = 1');
    my $viewer = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $unbuffered)), domain => Selecto::Domain->parse({
        schema_version => 1, name => 'View', source => {source_table => 'sse_view', primary_key => 'id', fields => [qw(id ts)],
            columns => {id => {type => 'integer'}, ts => {type => 'utc_datetime'}}, associations => {}}, schemas => {}, joins => {}}));
    my @handed;
    # (MariaDB refuses the function's SET time_zone inside the statement
    # itself; MySQL runs it and the stream's check refuses.)
    like(outcome(sub { my $s = $viewer->stream($viewer->query->select('id')->order_by('id'));
            while (my $r = $s->next) { push @handed, $r->[0] } \@handed }),
        $name eq 'mysql' ? qr{\Aquery_rule_violation/session_state_changed\z} : qr{\A(?:query_rule_violation/session_state_changed|query_error/)\z},
        "$name: a session change during a use_result stream is refused");
    is(scalar(@handed), 0, "$name: before any row reaches the caller");
    $unbuffered->do(q{SET time_zone = '+00:00'});
    $unbuffered->do('DROP VIEW IF EXISTS sse_view');
    $unbuffered->do('DROP FUNCTION IF EXISTS sse_fn');
    $unbuffered->disconnect;

    $dbh->do('DROP TABLE IF EXISTS ' . join(', ', qw(sse_items sse_link sse_acc sse_rows sse_zero)));
    $dbh->disconnect;
}
done_testing;
