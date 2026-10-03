use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use lib 't/lib';
use TestSelecto;
use Selecto;

sub error (&) { my ($f) = @_; return eval { $f->(); 1 } ? undef : $@; }
sub command {
    my ($table, $id, $field, $value) = @_;
    return Selecto::Write::Command->new(operation => 'insert', relation => $table,
        assignments => {id => $id, $field => $value});
}
sub engine {
    my ($dbh, $adapter, $table, $field, $type, $predicate) = @_;
    return Selecto::Engine->new(adapter => Selecto->adapter($adapter => (dbh => $dbh)),
        domain => TestSelecto::writable_domain(name => 'Synthetic typed admission', table => $table,
            fields => {id => 'integer', $field => $type}, required_predicate => $predicate));
}

subtest 'SQLite typed prospective rows match real storage' => sub {
    plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE admission_numeric(id INTEGER PRIMARY KEY, total DECIMAL)');
    my $engine = engine($dbh, 'sqlite', 'admission_numeric', 'total', 'decimal', Selecto::Expression->lt('total', 16));
    for my $value ('0x10', 'NaN', 'Inf', '01', '1e9999') {
        my $error = error { $engine->execute_write(command('admission_numeric', 1, 'total', $value)) };
        isa_ok $error, 'Selecto::Error', "$value rejected";
        is $error->code, 'query_rule_not_evaluable', 'malformed or unrepresentable numeric refused';
        is $dbh->selectrow_array('SELECT COUNT(*) FROM admission_numeric'), 0, 'no row persisted';
    }
    is $engine->execute_write(command('admission_numeric', 1, 'total', '10.5'))->{affected_rows}, 1,
        'canonical decimal below the guard is admitted';
    is $dbh->selectrow_array('SELECT COUNT(*) FROM admission_numeric WHERE total < 16'), 1,
        'stored candidate meets the actual SQL predicate';
    my $above = error { $engine->execute_write(command('admission_numeric', 2, 'total', '16')) };
    is $above->code, 'query_rule_violation', 'false typed predicate rejected';

    $dbh->do('CREATE TABLE admission_text(id INTEGER PRIMARY KEY, status TEXT)');
    my $text = engine($dbh, 'sqlite', 'admission_text', 'status', 'string', Selecto::Expression->lt('status', '10'));
    my $error = error { $text->execute_write(command('admission_text', 1, 'status', '2')) };
    is $error->code, 'query_rule_violation', 'numeric-looking text retains TEXT ordering';
    is $dbh->selectrow_array('SELECT COUNT(*) FROM admission_text'), 0, 'text policy rejection precedes INSERT';
    is $text->execute_write(command('admission_text', 1, 'status', '09'))->{affected_rows}, 1,
        'valid lexical TEXT ordering remains available';

    $dbh->do('CREATE TABLE admission_collation(id INTEGER PRIMARY KEY, status TEXT COLLATE NOCASE)');
    my $collated = engine($dbh, 'sqlite', 'admission_collation', 'status', 'string', Selecto::Expression->eq('status', 'active'));
    is $collated->execute_write(command('admission_collation', 1, 'status', 'ACTIVE'))->{affected_rows}, 1,
        'actual NOCASE collation governs admission';
    is $dbh->selectrow_array(q{SELECT count(*) FROM admission_collation WHERE status = 'active'}), 1,
        'stored row agrees with collated predicate';

    my $mismatch = engine($dbh, 'sqlite', 'admission_numeric', 'total', 'string', Selecto::Expression->lt('total', '2'));
    $error = error { $mismatch->execute_write(command('admission_numeric', 3, 'total', '10')) };
    is $error->code, 'query_rule_not_evaluable', 'domain/actual storage mismatch refuses';
    $dbh->do(q{CREATE TRIGGER admission_change AFTER INSERT ON admission_numeric BEGIN UPDATE admission_numeric SET total=100 WHERE id=NEW.id; END});
    $error = error { $engine->execute_write(command('admission_numeric', 4, 'total', '10.5')) };
    is $error->code, 'query_rule_not_evaluable', 'transforming trigger table refuses before DML';
    is $dbh->selectrow_array('SELECT count(*) FROM admission_numeric'), 1, 'trigger never ran for rejected row';

    my $literal = Selecto::Write::Expression->literal('0x10');
    $error = error { $engine->execute_write(command('admission_numeric', 5, 'total', $literal)) };
    is $error->code, 'query_rule_not_evaluable', 'literal expression cannot evade typed validation';
    $error = error { $text->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'admission_text',assignments=>{id=>9})) };
    is $error->code, 'query_rule_not_evaluable', 'missing guarded default cannot be guessed';
};

subtest 'PostgreSQL actual type and precision govern prospective rows' => sub {
    plan skip_all => 'SELECTO_TEST_PG_DSN and DBD::Pg required'
        unless $ENV{SELECTO_TEST_PG_DSN} && eval { require DBD::Pg; 1 };
    my $dbh = DBI->connect($ENV{SELECTO_TEST_PG_DSN}, $ENV{PGUSER} // '', $ENV{PGPASSWORD} // '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('CREATE TEMP TABLE admission_pg_numeric(id INTEGER PRIMARY KEY, total NUMERIC(8,2))');
    my $engine = engine($dbh, 'postgresql', 'admission_pg_numeric', 'total', 'decimal', Selecto::Expression->lt('total', '16'));
    my $error = error { $engine->execute_write(command('admission_pg_numeric', 1, 'total', '0x10')) };
    is $error->code, 'query_rule_not_evaluable', 'malformed numeric rejected before PG INSERT';
    $error = error { $engine->execute_write(command('admission_pg_numeric', 1, 'total', '15.999')) };
    is $error->code, 'query_rule_violation', 'actual scale rounding to 16 is considered before INSERT';
    is $engine->execute_write(command('admission_pg_numeric', 1, 'total', '15.99'))->{affected_rows}, 1,
        'representable accepted value inserted';
    is $dbh->selectrow_array('SELECT COUNT(*) FROM admission_pg_numeric WHERE total < 16'), 1,
        'stored row meets real precision-aware SQL predicate';
    $dbh->do('CREATE TEMP TABLE admission_pg_text(id INTEGER PRIMARY KEY, status TEXT COLLATE "C")');
    my $text = engine($dbh, 'postgresql', 'admission_pg_text', 'status', 'string', Selecto::Expression->lt('status', '10'));
    $error = error { $text->execute_write(command('admission_pg_text', 1, 'status', '2')) };
    is $error->code, 'query_rule_violation', 'PG numeric-looking text remains text';
    is $dbh->selectrow_array('SELECT COUNT(*) FROM admission_pg_text'), 0, 'PG refusal precedes INSERT';
    $dbh->{pg_bool_tf} = 1;
    $error = error { $text->execute_write(command('admission_pg_text', 2, 'status', '2')) };
    is $error->code, 'query_rule_violation', 'driver string false cannot turn a failed policy into admission';
    $dbh->do('CREATE TEMP TABLE admission_pg_bool(id INTEGER PRIMARY KEY, active BOOLEAN)');
    my $boolean = engine($dbh, 'postgresql', 'admission_pg_bool', 'active', 'boolean', Selecto::Expression->eq('active', 1));
    is $boolean->execute_write(command('admission_pg_bool', 1, 'active', 1))->{affected_rows}, 1,
        'boolean policies support pg_bool_tf driver rendering';
    $dbh->disconnect;
};

subtest 'unsupported adapter storage proof fails closed' => sub {
    for my $backend (qw(mysql mariadb mssql duckdb)) {
        my $dbh = TestSelecto::DBH->new;
        my $engine = engine($dbh, $backend, 'records', 'tenant_id', 'integer', Selecto::Expression->eq('tenant_id', 7));
        my $error = error { $engine->execute_write(command('records', 1, 'tenant_id', 7)) };
        is $error->code, 'query_rule_not_evaluable', "$backend typed storage profile refused";
        is_deeply $dbh->prepared, [], "$backend prepares no DML";
    }
};

done_testing;
