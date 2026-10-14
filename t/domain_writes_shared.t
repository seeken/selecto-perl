use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(refaddr);
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# writes() is a defensive copy; writes_shared() is the sealed contract itself, for the hot
# write path. Governed writes must treat it as read-only.
my $E = 'Selecto::Expression';
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, AutoCommit => 1});
$dbh->do('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, notes TEXT)');
my $raw = {schema_version => 1, name => 'Items',
    source => {source_table => 'items', primary_key => 'id', fields => [qw(id name notes)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, notes => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {update => {enabled => 1}, insert => {enabled => 1}},
        fields => {name => {updatable => 1, insertable => 1}, notes => {updatable => 1, insertable => 1}},
        constraints => {foreign_keys => {}}}};
my $domain = Selecto::Domain->parse($raw);

is(refaddr($domain->writes_shared), refaddr($domain->writes_shared), 'writes_shared is the same structure on every call');
isnt(refaddr($domain->writes), refaddr($domain->writes_shared), 'writes is a separate copy');
is_deeply($domain->writes, $domain->writes_shared, 'the copy equals the shared contract');

my $copy = $domain->writes;
$copy->{operations}{update}{enabled} = 0;
ok($domain->writes_shared->{operations}{update}{enabled}, 'changing a writes() copy leaves the shared contract alone');
ok($domain->writes->{operations}{update}{enabled}, '...and later copies');

sub flat {
    my ($v) = @_;
    return 'undef' unless defined $v;
    return ref($v) eq 'HASH' ? '{' . join(',', map { "$_=" . flat($v->{$_}) } sort keys %$v) . '}'
        : ref($v) eq 'ARRAY' ? '[' . join(',', map { flat($_) } @$v) . ']' : "S:$v";
}
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh)));
my $before = flat($domain->writes_shared);
$engine->governed_write(Selecto::Write::Command->new(relation => 'items', operation => 'update',
    assignments => {name => 'a', notes => 'b'}, predicate => $E->eq('id', 1)));
$engine->governed_write(Selecto::Write::Command->new(relation => 'items', operation => 'insert',
    assignments => {name => 'c', notes => 'd'}));
is(flat($domain->writes_shared), $before, 'governed writes leave the shared contract unchanged');

done_testing;
