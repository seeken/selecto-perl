use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::BoundedQuery;
BEGIN { eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite required' }

my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
    {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
$db->do('PRAGMA temp_store=MEMORY');
my $adapter = Selecto->adapter(sqlite => dbh => $db);
plan skip_all => 'connected SQLite lacks FTS5' unless $adapter->supports('text_search');
$db->do(q{ATTACH DATABASE ':memory:' AS tenant_a});
for my $schema (qw(main tenant_a)) {
    $db->do("CREATE TABLE $schema.items(id INTEGER PRIMARY KEY, title TEXT, tenant INTEGER)");
    $db->do("CREATE VIRTUAL TABLE $schema.docs USING fts5(title)");
}
$db->do('INSERT INTO main.items VALUES(?,?,?)', undef, @$_) for [1,'Oak',10],[2,'Elm',10];
$db->do('INSERT INTO tenant_a.items VALUES(?,?,?)', undef, @$_) for [1,'Elm tenant',10],[2,'Oak tenant',10];
$db->do(q{CREATE VIRTUAL TABLE main.items_search USING fts5(title, content='items', content_rowid='id')});
$db->do(q{INSERT INTO main.items_search(items_search) VALUES('rebuild')});
$db->do(q{INSERT INTO main.docs VALUES('Oak')});
$db->do(q{INSERT INTO tenant_a.docs VALUES('Elm tenant')});
my $raw = {name => 'Items', source => {source_table => 'items', primary_key => 'id',
    fields => [qw(id title tenant)], columns => {id=>{type=>'integer'},title=>{type=>'string'},tenant=>{type=>'integer'}},
    associations => {}, fts5_index => {table=>'items_search',key=>'id'}}, schemas=>{},joins=>{}, required_filters=>[['tenant',10]]};
my $base = Selecto::Engine->new(domain=>Selecto::Domain->parse($raw), adapter=>$adapter);
my $q = $base->query->select('id','title')->order_by('id');
my $search = Selecto::Expression->text_search(['title'],'Oak');
is_deeply($base->all($q->where($search))->{rows}, [[1,'Oak']], 'ordinary main external-index search remains native');
my $prefixed = $base->with_tenant({prefix=>'tenant_a'});
is_deeply($prefixed->all($q)->{rows}, [[1,'Elm tenant'],[2,'Oak tenant']],
    'ordinary attached-schema read preserves its own opposite search text and shared rowids');
my $main = $base->with_tenant({prefix=>'MAIN'});
is_deeply($main->all($q->where($search))->{rows}, [[1,'Oak']], 'explicit ASCII main identity remains supported');

# A fresh adapter has not cached its FTS capability. Refusal must precede even
# that catalog lookup, rather than merely avoiding the final business SELECT.
my $fresh = Selecto->adapter(sqlite=>dbh=>$db);
my $target = Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>$fresh)
    ->with_tenant({prefix=>'tenant_a'});
my $legacy = Selecto::Engine->new(domain=>Selecto::Domain->new(name=>'Docs',table=>'docs',fields=>{title=>'fts5'}),adapter=>$fresh);
my $legacy_target = $legacy->with_tenant({prefix=>'tenant_a'});
is_deeply($legacy_target->all($legacy_target->query->select('title'))->{rows}, [['Elm tenant']],
    'ordinary prefixed reads also preserve the attached virtual relation');
my $events = 0;
$db->sqlite_set_authorizer(sub { ++$events; return 0 });
sub refuses {
    my ($label,$run) = @_;
    $events = 0;
    my ($value,$error);my $ok=eval{$value=$run->();1};$error=$@;
    diag('unrefused native result: '.JSON::PP->new->canonical->allow_blessed->encode($value)) if $ok;
    is(!$ok && ref($error) && UNIVERSAL::isa($error,'Selecto::Error') ? $error->code : 'none',
        'unsupported_feature',$label);
    is($events,0,"$label prepares no native SQL, including capability catalog reads");
}
refuses('attached ordinary root cannot borrow main-index matches by rowid',sub{$target->all($q->where($search))});
refuses('attached ordinary root cannot borrow main-index rank',sub{
    $target->all($target->query->select('id',Selecto::Expression->text_rank(['title'],'Oak')->as('rank')))
});
refuses('bounded preparation keeps the same main-only index authority',sub{
    Selecto::BoundedQuery->prepare($target,$q->where($search))
});
refuses('attached legacy root cannot borrow the main FTS catalog proof',sub{
    $legacy_target->all($legacy_target->query->select('title')->where(Selecto::Expression->text_search(['title'],'Oak')))
});
refuses('attached legacy rank cannot borrow the main FTS catalog proof',sub{
    $legacy_target->all($legacy_target->query->select(Selecto::Expression->text_rank(['title'],'Oak')->as('rank')))
});
$db->sqlite_set_authorizer(undef);
is_deeply($db->selectall_arrayref('SELECT * FROM main.items ORDER BY id'),[[1,'Oak',10],[2,'Elm',10]],'all main physical values remain unchanged');
is_deeply($db->selectall_arrayref('SELECT * FROM tenant_a.items ORDER BY id'),[[1,'Elm tenant',10],[2,'Oak tenant',10]],'all attached physical values remain unchanged');
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP remains in memory');
my $databases=$db->selectall_arrayref('PRAGMA database_list');
ok(@$databases>=2 && !(grep{length($_->[2])}@$databases),'main and attached databases remain in memory');
$db->disconnect;
done_testing;
