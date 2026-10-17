use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::MySQLFamily;

# The null-safe rewrite of the shared keyset-cursor predicate must keep its
# parentheses: "(a IS DISTINCT FROM ? OR (...))" negates only the comparison.
my $rewrite = \&Selecto::MySQLFamily::_null_safe_cursor_sql;
is($rewrite->('(`s0`.`id` IS DISTINCT FROM ? OR ((`c`.`seq` > ? OR `c`.`seq` IS NULL)))'),
    '((NOT (`s0`.`id` <=> ?)) OR ((`c`.`seq` > ? OR `c`.`seq` IS NULL)))',
    'the negation covers only the parent comparison, not the whole disjunction');
is($rewrite->('(`c`.`label` IS NOT DISTINCT FROM ? AND `c`.`seq` IS NULL)'),
    '((`c`.`label` <=> ?) AND `c`.`seq` IS NULL)', 'IS NOT DISTINCT FROM becomes <=> inside its parentheses');
is($rewrite->('(`we``ird`.`na``me` IS DISTINCT FROM ?)'), '((NOT (`we``ird`.`na``me` <=> ?)))',
    'a quoted qualified identifier with escaped backticks is matched whole');

package VersionedDBH {
    our @ISA = ('TestSelecto::DBH');
    sub selectrow_array { return $_[0]->{version} if $_[1] =~ /SELECT VERSION\(\)\z/; return; }
}

my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->new(
    name => 'Orders', table => 'orders', fields => {id => 'integer'},
    associations => {items => {table => 'items', target_primary_key => 'id',
        fields => {id => 'integer', order_id => 'integer', seq => 'integer'},
        owner_key => 'id', related_key => 'order_id', cardinality => 'many', join_type => 'left'}},
);
for my $name (qw(mysql mariadb)) {
    my $dbh = bless TestSelecto::DBH->new, 'VersionedDBH';
    $dbh->{version} = $name eq 'mysql' ? '8.4.11' : '11.4.13-MariaDB';
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
    my $statement = $engine->compile($engine->query->select('id', $x->related_collection('items', ['id', 'seq'],
        order_by => [['seq', 'asc']], limit => 2, after => {parent_key => 1, values => [3, 9]})->as('c')));
    like($statement->sql, qr/\(\(NOT \(`s0`\.`id` <=> \?\)\) OR \(/, "$name compiles the cursor with a scoped negation");
    unlike($statement->sql, qr/NOT \(\(/, "$name never negates the whole disjunction");
    unlike($statement->sql, qr/DISTINCT FROM/, "$name has no PostgreSQL-only comparison left");
}

done_testing;
