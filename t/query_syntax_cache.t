use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::SQL;
use DBI;

my $x = 'Selecto::Expression';
my $field = $x->field('name');
for my $name ('name', 'id', 'place.name', 'name') {
    $field->{arguments}[0] = $name;
    is(Selecto::SQL::_expression_key($field), Selecto::SQL::_value_key($field), 'key follows leaf mutation');
}
$field->{kind} = 'literal';
is(Selecto::SQL::_expression_key($field), Selecto::SQL::_value_key($field), 'kind mutation falls back');
$field->{kind} = 'field';
$field->{arguments} = [12];
is(Selecto::SQL::_expression_key($field), Selecto::SQL::_value_key($field), 'numeric mutation falls back');
$field->{arguments} = ['name', 'id'];
is(Selecto::SQL::_expression_key($field), Selecto::SQL::_value_key($field), 'malformed leaf falls back');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1,PrintError=>0});
$dbh->do('CREATE TABLE people (id INTEGER, name TEXT, score NUMERIC, place_id INTEGER)');
$dbh->do(q{INSERT INTO people VALUES (1,'Ada',10,NULL),(2,'Grace',20,NULL)});
my $engine=Selecto::Engine->new(domain=>TestSelecto::people_domain(),adapter=>Selecto::SQLite->new(dbh=>$dbh));
my $query=$engine->query->select('name')->where($x->eq('id',1));
is_deeply($engine->all($query)->{rows}, [['Ada']], 'warm syntax memo through public API');
$query->{selections}[0]{arguments}[0]='score';
is_deeply($engine->all($query)->{rows}, [[10]], 'direct selection mutation is compiled');
$query->{predicate}=$x->eq('id',2);
is_deeply($engine->all($query)->{rows}, [[20]], 'parameter mutation is compiled');
$query=$query->select('id')->limit(0);
is_deeply($engine->all($query)->{rows}, [], 'builder mutations are compiled');
my $required=$engine->domain->with_required_predicate($x->eq('id',1));
my $scoped=Selecto::Engine->new(domain=>$required,adapter=>$engine->adapter);
is_deeply($scoped->all($scoped->query->select('name'))->{rows}, [['Ada']], 'required predicate remains live');
my $changed=$required->with_required_predicate($x->eq('id',2));
my $other=Selecto::Engine->new(domain=>$changed,adapter=>$engine->adapter);
is_deeply($other->all($other->query->select('name'))->{rows}, [['Grace']], 'new context cannot reuse authority');
$query=$engine->query->select('name');$engine->all($query);
$query->{selections}[0]{arguments}[0]='missing';
eval {$engine->all($query)};
like("$@",qr/unknown.field/i,'field resolution still runs after warm execution');
done_testing;
