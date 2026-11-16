use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use DBI ();
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Write ();
use Selecto::Expression;

my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    push @backends, [$spec->[0], $ENV{$spec->[1]}]
        if $ENV{$spec->[1]} && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;
for my $backend (@backends) {
    my ($name, $url) = @$backend;
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url, $name);
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('DROP TABLE IF EXISTS selecto_unique_rows');
    $dbh->do('CREATE TABLE selecto_unique_rows (id INT NOT NULL, stamp INT NOT NULL, tenant VARCHAR(8), note VARCHAR(8)) ENGINE=InnoDB');
    $dbh->do('CREATE UNIQUE INDEX selecto_unique_expr ON selecto_unique_rows (id, '
        . ($name eq 'mysql' ? '((stamp + 0))' : 'stamp') . ')');
    $dbh->do(q{INSERT INTO selecto_unique_rows VALUES (1, 0, 't1', 'old'), (1, 1, 't1', 'old')});
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'KeyMetadata',
        source => {source_table => 'selecto_unique_rows', primary_key => 'id', fields => [qw(id stamp tenant note)],
            columns => {id => {type => 'integer'}, stamp => {type => 'integer'}, tenant => {type => 'string'}, note => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {note => {updatable => 1}}}});
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
    my $ok = eval { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_unique_rows',
        assignments => {note => 'new'}, predicate => Selecto::Expression->eq('id', 1),
        scope_predicate => Selecto::Expression->eq('tenant', 't1'))); 1 };
    is($ok ? 'applied' : blessed($@) ? $@->code : 'untyped_error', 'query_rule_not_evaluable',
        "$name: a partial unique index never proves the declared key unique");
    is_deeply($dbh->selectall_arrayref('SELECT note FROM selecto_unique_rows ORDER BY stamp'), [['old'], ['old']],
        "$name: refusing an unproven readback key leaves every row intact");
    $dbh->do('DROP TABLE selecto_unique_rows');
    $dbh->disconnect;
}
done_testing;
