use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;

# Round-3 review R31 and the R5 note on MySQL and MariaDB:
# - R31: with lower_case_table_names = 0, `rv_v` and `rv_V` are different
#   relations; the TIMESTAMP root `rv_v` keeps its zone-independent scope
#   compare even when a DATETIME `rv_V` is looked up first;
# - R5: a TIMESTAMP scope compare (epoch form) returns exactly the rows the
#   server's own comparison returns, zero dates and pre-range literals
#   included, on each server and under NOT.
my $x = 'Selecto::Expression';
my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my ($lctn) = $dbh->selectrow_array('SELECT @@lower_case_table_names');

    SKIP: {
        skip "$name: lower_case_table_names is $lctn", 2 unless $lctn eq '0';
        $dbh->do($_) for 'DROP VIEW IF EXISTS rv_v', 'DROP TABLE IF EXISTS rv_V', 'DROP TABLE IF EXISTS rv_vb',
            'CREATE TABLE rv_vb (id INT PRIMARY KEY, ts TIMESTAMP NULL, oid INT) ENGINE=InnoDB',
            q{INSERT INTO rv_vb VALUES (1, '2023-12-31 22:00:00', 1), (2, '2024-01-01 03:00:00', 1)},
            'CREATE VIEW rv_v AS SELECT id, ts, oid FROM rv_vb',
            'CREATE TABLE rv_V (id INT PRIMARY KEY, ts DATETIME NULL) ENGINE=InnoDB', q{INSERT INTO rv_V VALUES (1, '2020-01-01 00:00:00')};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Cased',
            source => {source_table => 'rv_v', primary_key => 'id', fields => [qw(id ts oid)],
                columns => {id => {type => 'integer'}, ts => {type => 'naive_datetime'}, oid => {type => 'integer'}},
                associations => {o => {queryable => 'other', owner_key => 'oid', related_key => 'id'}}},
            schemas => {other => {source_table => 'rv_V', primary_key => 'id', fields => [qw(id ts)],
                columns => {id => {type => 'integer'}, ts => {type => 'naive_datetime'}}, associations => {}}},
            joins => {o => {type => 'left'}}})
            ->with_required_predicate($x->all($x->lt('o.ts', '2030-01-01 00:00:00'), $x->lt('ts', '2024-01-01 00:00:00')));
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
        like($engine->compile($engine->query->select('id'))->sql, qr/UNIX_TIMESTAMP\(`s0`\.`ts`\)/,
            "$name: the TIMESTAMP root keeps its epoch compare beside a case-variant DATETIME relation");
        unlike($engine->compile($engine->query->select('id'))->sql, qr/UNIX_TIMESTAMP\(`j_o`\.`ts`\)/,
            "$name: and the DATETIME relation compares natively");
        $dbh->do($_) for 'DROP VIEW IF EXISTS rv_v', 'DROP TABLE IF EXISTS rv_V', 'DROP TABLE IF EXISTS rv_vb';
    }

    $dbh->do('DROP TABLE IF EXISTS rv_zero');
    $dbh->do('CREATE TABLE rv_zero (id INT PRIMARY KEY, ts TIMESTAMP(6) NULL) ENGINE=InnoDB');
    {
        my $loose = $connect->();
        $loose->do(q{SET SESSION sql_mode = ''});
        $loose->do(q{INSERT INTO rv_zero VALUES (1, '1970-01-01 00:00:01'), (2, '2038-01-19 03:14:07'), (3, '2038-01-19 03:14:07.999999'),
            (4, '0000-00-00 00:00:00'), (5, NULL), (6, '2000-01-01 00:00:00.5'), (7, '1970-01-01 00:00:01.25')});
        $loose->disconnect;
    }
    my $base = Selecto::Domain->parse({schema_version => 1, name => 'Zero', source => {source_table => 'rv_zero', primary_key => 'id',
        fields => [qw(id ts)], columns => {id => {type => 'integer'}, ts => {type => 'naive_datetime'}}, associations => {}}, schemas => {}, joins => {}});
    my $ids = sub { my $r = eval { join ',', map { $_->[0] } @{$_[0]->()->{rows}} }; defined($r) ? $r : 'error' };
    my @differences;
    for my $literal ('1969-12-31 23:59:59', '1970-01-01 00:00:00', '1970-01-01 00:00:00.5', '1970-01-01 00:00:01', '1970-01-01 00:00:01.1',
        '2000-01-01 00:00:00.5', '2038-01-19 03:14:07', '2038-01-19 03:14:07.5', '2038-01-19 03:14:08', '2100-01-01 00:00:00', '1000-01-01 00:00:00') {
        for my $op (qw(lt lte gt gte eq ne)) {
            for my $negated (0, 1) {
                my $predicate = $x->$op('ts', $literal);
                $predicate = $x->not($predicate) if $negated;
                my $scoped = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $base->with_required_predicate($predicate));
                my $plain = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $base);
                my $scope = $ids->(sub { $scoped->all($scoped->query->select('id')->order_by('id')) });
                my $native = $ids->(sub { $plain->all($plain->query->select('id')->where($predicate)->order_by('id')) });
                push @differences, ($negated ? 'NOT ' : '') . "$op '$literal': scope [$scope], native [$native]" if $scope ne $native;
            }
        }
    }
    is_deeply(\@differences, [], "$name: TIMESTAMP scope compares agree with the server's own on every literal, operator and NOT");
    $dbh->do('DROP TABLE IF EXISTS rv_zero');
    $dbh->disconnect;
}
done_testing;
