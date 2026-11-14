use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use Selecto;

# SQLite's LIKE folds ASCII case, so the plain starts_with, text_contains and
# ends_with operators compare exactly (INSTR/SUBSTR); only the _ci forms use
# LIKE. %, _ and the LIKE escape character stay literal in every form.
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
$dbh->do('CREATE TABLE text_rows (id INTEGER PRIMARY KEY, name TEXT)');
$dbh->do('INSERT INTO text_rows VALUES (?, ?)', undef, @$_)
    for [1, 'Widget'], [2, 'widget 50%'], [3, 'a_b!c'], [4, undef], [5, 'Gadget widget'], [6, 'ÉCLAIR'];
my $domain = Selecto::Domain->parse({name => 'Text rows', source => {source_table => 'text_rows', primary_key => 'id',
    fields => [qw(id name)], columns => {id => {type => 'integer'}, name => {type => 'string'}}}});
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
sub ids {
    my ($operator, $value) = @_;
    my $query = $engine->query->select('id')->where(Selecto::Expression->$operator('name', $value))->order_by('id');
    return [map { $_->[0] } @{$engine->all($query)->{rows}}];
}
is_deeply ids(starts_with => 'widget'), [2], 'starts_with is case-sensitive';
is_deeply ids(starts_with_ci => 'widget'), [1, 2], 'starts_with_ci folds case';
is_deeply ids(text_contains => 'widget'), [2, 5], 'text_contains is case-sensitive';
is_deeply ids(text_contains_ci => 'WIDGET'), [1, 2, 5], 'text_contains_ci folds case';
is_deeply ids(ends_with => 'Widget'), [1], 'ends_with is case-sensitive';
is_deeply ids(ends_with_ci => 'WIDGET'), [1, 5], 'ends_with_ci folds case';
is_deeply ids(text_contains => '%'), [2], '% is literal';
is_deeply ids(text_contains => '_'), [3], '_ is literal';
is_deeply ids(ends_with => '!c'), [3], 'the escape character is literal';
is_deeply ids(starts_with => ''), [1, 2, 3, 5, 6], 'an empty prefix matches every non-null value';
is_deeply ids(starts_with => 'ÉC'), [6], 'non-ASCII prefixes compare by character';
is_deeply ids(ends_with => 'AIR'), [6], 'non-ASCII suffixes compare by character';
done_testing;
