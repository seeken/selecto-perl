use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;
BEGIN { eval {require DBI; require DBD::SQLite; 1} or plan skip_all => 'DBD::SQLite required' }
sub contract {
    return {name => 'Items', source => {source_table => 'items', primary_key => 'id', fields => [qw(id quantity reference)],
        columns => {id => {type => 'integer'}, quantity => {type => 'integer'}, reference => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}, update => {enabled => 1}}, fields => {quantity => {insertable => 1, updatable => 1}, reference => {insertable => 1, updatable => 1}}},
        rules => {schema => 'selecto.data_rules.v1', definitions => {positive => {version => 1, test => {op => 'number.gt', bound => 0}}}, normalizers => {},
            bindings => {positive => {subject => {scope => 'candidate', path => ['quantity']}, rule => {id => 'positive', version => 1}}}}};
}
for my $kind (qw(generated automatic_update ordinary)) {
    subtest $kind => sub {
        my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0});
        $db->do('PRAGMA foreign_keys=ON');
        $db->do('CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER,reference TEXT UNIQUE'
            . ($kind eq 'generated' ? ',derived INTEGER GENERATED ALWAYS AS (quantity*2) VIRTUAL' : '') . ')');
        $db->do("INSERT INTO items(id,quantity,reference) VALUES(1,2,'ab')");
        if ($kind eq 'automatic_update') {
            $db->do('CREATE TABLE child(id INTEGER PRIMARY KEY,owner TEXT REFERENCES items(reference) ON UPDATE CASCADE)');
            $db->do("INSERT INTO child VALUES(1,'ab')");
        }
        my $raw = contract();
        if ($kind ne 'generated') {
            $raw->{rules}{definitions}{reference} = {version => 1, test => {op => 'value.eq', value => 'AB'}};
            $raw->{rules}{normalizers}{upper} = {version => 1, steps => [{op => 'text.uppercase', profile => 'ascii_v1'}]};
            $raw->{rules}{bindings}{reference} = {subject => {scope => 'candidate', path => ['reference']},
                rule => {id => 'reference', version => 1}, normalizer => {id => 'upper', version => 1}};
        }
        my $mutations = 0;
        $db->sqlite_trace(sub {$mutations++ if $_[0] =~ /\A\s*(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+["`\[]?(?:items|child)\b/i});
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => Selecto::SQLite->new(dbh => $db));
        my $ok = eval {$engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'items',
            assignments => {quantity => 3}, predicate => Selecto::Expression->eq('id', 1))); 1};
        if ($kind eq 'ordinary') {
            ok $ok, 'ordinary stored normalizer candidate admits' or diag $@;
            is_deeply $db->selectrow_arrayref('SELECT quantity,reference FROM items'), [3,'AB'], 'actual normalizer mutation stores';
        } else {
            is ref($@) && $@->can('code') ? $@->code : "$@", 'required_data_rule_pending', 'physical transformations require complete prospective authority';
            is $mutations, 0, 'refusal precedes every business mutation';
            is_deeply $db->selectrow_arrayref('SELECT quantity,reference FROM items'), [2,'ab'], 'stored source retained';
            is $db->selectrow_array('SELECT owner FROM child'), 'ab', 'unselected physical child retained' if $kind eq 'automatic_update';
        }
        is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}], [], 'SQLite is memory only';
        $db->disconnect;
    };
}
done_testing;
