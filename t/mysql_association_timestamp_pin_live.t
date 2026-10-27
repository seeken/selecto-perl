use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;

# Item 62a: an association's or bridge's fixed `where` pin is domain-authored
# scope. A stored function can switch time_zone and back within one MySQL
# statement, so a pin on a TIMESTAMP column compared with a datetime literal
# would be evaluated under whatever zone is current for that row. Such pins
# compare UNIX_TIMESTAMP(col) with the literal's UTC epoch, like host
# comparisons; DATETIME pins compile as before.
my $x = 'Selecto::Expression';
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

my $json = JSON::PP->new->canonical;
sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => ref($columns{$_}) ? $columns{$_} : {type => $columns{$_}}) } keys %columns},
        associations => {}};
}
sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return defined($value) ? "ok $value" : blessed($@) ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}

my $pin = '2023-12-31 22:00:00';
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    for my $type (qw(TIMESTAMP DATETIME)) {
        my $dbh = $connect->();
        $dbh->do("DROP VIEW IF EXISTS $_") for qw(selecto_atp_acc);
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_atp_items selecto_atp_acc_base selecto_atp_bridge);
        $dbh->do('DROP FUNCTION IF EXISTS selecto_atp_fn');
        $dbh->do('CREATE TABLE selecto_atp_items (id INT PRIMARY KEY, acc_id INT) ENGINE=InnoDB');
        $dbh->do("CREATE TABLE selecto_atp_acc_base (id INT NOT NULL, item_id INT, at $type NULL, label VARCHAR(40)) ENGINE=InnoDB");
        $dbh->do("CREATE TABLE selecto_atp_bridge (item_id INT, acc_id INT, bat $type NULL) ENGINE=InnoDB");
        $dbh->do(q{INSERT INTO selecto_atp_items VALUES (1, 101)});
        # 22:00 UTC is the pinned instant; 03:00 UTC is what the pin's text
        # means under -05:00.
        my @rows = ([1, 'mine', $pin], [2, 'OUT', '2024-01-01 03:00:00'], [3, 'other', '2023-12-31 20:00:00']);
        for my $row (@rows) {
            my ($n, $label, $at) = @$row;
            $dbh->do('INSERT INTO selecto_atp_acc_base VALUES (?, ?, ?, ?)', undef, 101, 1, $at, $label);
            $dbh->do('INSERT INTO selecto_atp_acc_base VALUES (?, ?, ?, ?)', undef, 300 + $n, 9, $pin, "b-$label");
            $dbh->do('INSERT INTO selecto_atp_bridge VALUES (?, ?, ?)', undef, 1, 300 + $n, $at);
        }
        $dbh->do(q{CREATE FUNCTION selecto_atp_fn(l VARCHAR(40)) RETURNS VARCHAR(40) DETERMINISTIC NO SQL
            BEGIN IF @selecto_arm = 1 AND l IN ('mine', 'b-mine') THEN SET time_zone = '-05:00'; END IF;
            IF @selecto_arm = 1 AND l IN ('other', 'b-other') THEN SET time_zone = '+00:00'; END IF; RETURN l; END});
        $dbh->do('CREATE VIEW selecto_atp_acc AS SELECT id, item_id, at, selecto_atp_fn(label) AS label FROM selecto_atp_acc_base');
        my $source = relation('selecto_atp_items', id => 'integer', acc_id => 'integer',
            has_a => {type => 'boolean', computed => {kind => 'association_exists', association => 'c'}});
        $source->{associations} = {
            a => {queryable => 'acc', owner_key => 'acc_id', related_key => 'id', where => {at => $pin}},
            c => {queryable => 'acc', owner_key => 'id', related_key => 'item_id', cardinality => 'many', where => {at => $pin}},
            tb => {queryable => 'acc', owner_key => 'id', related_key => 'id', cardinality => 'many',
                through => {table => 'selecto_atp_bridge', owner_key => 'item_id', related_key => 'acc_id', where => {bat => $pin}}},
        };
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'TimestampPins', source => $source,
            schemas => {acc => relation('selecto_atp_acc', id => 'integer', item_id => 'integer', at => 'naive_datetime',
                label => 'string')},
            joins => {map { ($_ => {type => 'left'}) } qw(a c tb)}});
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
        my $q = $engine->query;
        my @cases = (
            ['join', $q->select('id', 'a.label'), 'mine'],
            ['to-many join', $q->select('id', 'c.label'), 'mine'],
            ['collection', $q->select('id', $x->related_collection('c', ['label'])), '[{"label":"mine"}]'],
            ['association_exists', $q->select('id', 'has_a'), 1],
            ['through bridge', $q->select('id', 'tb.label'), 'b-mine'],
            ['retarget in', $q->retarget('a', strategy => 'in')->select('id', 'label'), 'mine'],
            ['retarget exists', $q->retarget('c', strategy => 'exists')->select('id', 'label'), 'mine'],
            ['through bridge retarget', $q->retarget('tb', strategy => 'in')->select('id', 'label'), 'b-mine'],
        );
        for my $case (@cases) {
            my ($label, $query, $want) = @$case;
            my $sql = $engine->compile($query)->sql;
            my $column = $label =~ /bridge/ ? 'bat' : 'at';
            if ($type eq 'TIMESTAMP') {
                like($sql, qr/NULLIF\(UNIX_TIMESTAMP\(`[^`]+`\.`$column`\), 0\) = CAST\(\? AS DECIMAL\(24,6\)\)/,
                    "$name $type $label: the pin compares by epoch");
            } else {
                unlike($sql, qr/UNIX_TIMESTAMP/, "$name $type $label: a DATETIME pin compiles as before");
            }
            my $read = sub {
                return join ' ', sort map {
                    my $value = $_->[-1];
                    $value = $json->decode($value) if defined($value) && !ref($value) && $value =~ /\A\[/;
                    ref($value) ? $json->encode($value) : $value // 'null';
                } @{$engine->all($query)->{rows}};
            };
            $dbh->do('SET @selecto_arm = 0');
            is(outcome($read), "ok $want", "$name $type $label: the pin selects its own row");
            next unless $type eq 'TIMESTAMP';
            # Switched and switched back within the statement: whatever the
            # rows' evaluation order, the epoch compare cannot admit OUT.
            $dbh->do('SET @selecto_arm = 1');
            my $armed = outcome($read);
            $dbh->do('SET @selecto_arm = 0');
            unlike($armed, qr/OUT/, "$name $type $label: a zone switched mid-statement cannot widen the pin ($armed)");
            $dbh->do(q{SET time_zone = '+00:00'});
        }
        $dbh->do('DROP VIEW IF EXISTS selecto_atp_acc');
        $dbh->do('DROP FUNCTION IF EXISTS selecto_atp_fn');
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_atp_items selecto_atp_acc_base selecto_atp_bridge);
        $dbh->disconnect;
    }
}
done_testing;
