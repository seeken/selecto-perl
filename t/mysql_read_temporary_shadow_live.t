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

# A session TEMPORARY table named like a relation a read uses (the root or
# a joined relation) shadows it for the statement while every catalog
# lookup describes the base table: reads refuse it, as writes do. A
# temporary table that is itself the domain relation, and unrelated
# temporary tables, keep working.
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

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}
my $source = relation('selecto_shadow_orders', id => 'integer', org_key => 'string', note => 'string');
$source->{associations} = {lines => {queryable => 'line', owner_key => 'id', related_key => 'order_id', cardinality => 'many'}};
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'ShadowOrders', source => $source, joins => {},
    schemas => {line => relation('selecto_shadow_lines', id => 'integer', order_id => 'integer', sku => 'string')}})
    ->with_required_predicate($x->eq('org_key', 't1'));
sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return defined($value) ? "ok $value" : blessed($@) ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
    my $drop = sub {
        $dbh->do("DROP TEMPORARY TABLE IF EXISTS $_") for qw(selecto_shadow_orders selecto_shadow_lines selecto_shadow_other);
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_shadow_lines selecto_shadow_orders);
    };
    $drop->();
    $dbh->do('CREATE TABLE selecto_shadow_orders (id INT PRIMARY KEY, org_key VARCHAR(8), note VARCHAR(16)) ENGINE=InnoDB');
    $dbh->do('CREATE TABLE selecto_shadow_lines (id INT PRIMARY KEY, order_id INT, sku VARCHAR(16)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO selecto_shadow_orders VALUES (1, 't1', 'base')});
    $dbh->do(q{INSERT INTO selecto_shadow_lines VALUES (10, 1, 'base-line')});
    my $root = $engine->query->select('id', 'note')->order_by('id');
    my $joined = $engine->query->select('id', 'lines.sku')->order_by('id');
    my %reads = (
        'read' => sub { join ',', map { join '/', @$_ } @{$engine->all($_[0])->{rows}} },
        'stream' => sub { my $s = $engine->stream($_[0]); my @o; while (my $r = $s->next) { push @o, join '/', @$r } join ',', @o },
    );
    $dbh->do('CREATE TEMPORARY TABLE selecto_shadow_other (id INT)');
    for my $kind (sort keys %reads) {
        is(outcome(sub { $reads{$kind}->($root) }), 'ok 1/base', "$name $kind: an unrelated temporary table changes nothing");
        is(outcome(sub { $reads{$kind}->($joined) }), 'ok 1/base-line', "$name $kind: joined read without a shadow");
    }
    $dbh->do('CREATE TEMPORARY TABLE selecto_shadow_lines (id INT PRIMARY KEY, order_id INT, sku VARCHAR(16))');
    $dbh->do(q{INSERT INTO selecto_shadow_lines VALUES (99, 1, 'TEMP-line')});
    for my $kind (sort keys %reads) {
        is(outcome(sub { $reads{$kind}->($joined) }), 'query_rule_not_evaluable/temporary_shadow',
            "$name $kind: a temporary table shadowing a joined relation is refused");
        is(outcome(sub { $reads{$kind}->($root) }), 'ok 1/base', "$name $kind: a read not using it still runs");
    }
    $dbh->do('CREATE TEMPORARY TABLE selecto_shadow_orders (id INT PRIMARY KEY, org_key VARCHAR(8), note VARCHAR(16))');
    $dbh->do(q{INSERT INTO selecto_shadow_orders VALUES (9, 't1', 'TEMP-root')});
    for my $kind (sort keys %reads) {
        is(outcome(sub { $reads{$kind}->($root) }), 'query_rule_not_evaluable/temporary_shadow',
            "$name $kind: a temporary table shadowing the root is refused");
    }
    # A temporary table that is the domain relation itself is the host's own.
    $drop->();
    $dbh->do('CREATE TEMPORARY TABLE selecto_shadow_orders (id INT PRIMARY KEY, org_key VARCHAR(8), note VARCHAR(16))');
    $dbh->do(q{INSERT INTO selecto_shadow_orders VALUES (5, 't1', 'own')});
    for my $kind (sort keys %reads) {
        is(outcome(sub { $reads{$kind}->($root) }), 'ok 5/own', "$name $kind: a temporary domain relation with no namesake is read");
    }
    $drop->();
}
done_testing;
