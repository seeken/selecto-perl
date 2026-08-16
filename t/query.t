use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;

my $dbh = TestSelecto::DBH->new;
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $engine = Selecto::Engine->new(domain => TestSelecto::people_domain(), adapter => $adapter);
my $base = $engine->query->select('id', 'name');
my $filtered = $base->where(Selecto::Expression->eq('name', q{O'Brien}));
ok(!defined($base->predicate), 'query builder leaves the original query unchanged');
my $statement = $engine->compile($filtered);
like($statement->sql, qr/"s0"\."name" = \$1/, 'predicate is compiled with a PostgreSQL placeholder');
unlike($statement->sql, qr/O'Brien/, 'value is not interpolated into SQL');
is_deeply($statement->params, [q{O'Brien}], 'value is carried separately');

my $join_engine = Selecto::Engine->new(domain => TestSelecto::orders_domain(), adapter => $adapter);
my $grouped = $join_engine->query->select(
    Selecto::Expression->field('person.name')->as('person_name'),
    Selecto::Expression->count->as('order_count'),
)->group_by('person.name')->order_by('person.name');
my $grouped_statement = $join_engine->compile($grouped);
like($grouped_statement->sql, qr/LEFT JOIN "people" AS "j_person"/, 'referenced association creates one join');
like($grouped_statement->sql, qr/COUNT\(\*\)/, 'aggregate is compiled');
like($grouped_statement->sql, qr/GROUP BY "j_person"\."name"/, 'joined group is validated and compiled');
is_deeply($grouped_statement->columns, ['person_name', 'order_count'], 'stable result columns use aliases');

my $values = ['open'];
my $membership = Selecto::Expression->in('name', $values);
push @$values, 'closed';
my $arguments = $membership->arguments;
push @{$arguments->[1]}, 'mutated-copy';
my $membership_statement = $engine->compile($engine->query->select('id')->where($membership));
is_deeply($membership_statement->params, ['open'], 'expression values are isolated from caller and accessor mutation');

eval { $engine->query->select('id')->order_by('id', 'sideways') };
is($@->code, 'invalid_query', 'invalid order direction fails closed');

done_testing;
