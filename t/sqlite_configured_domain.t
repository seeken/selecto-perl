use 5.034;
use strict;
use warnings;
use Test::More;
# A configured engine runs its domain; its checked transitions (with_limits,
# with_scope, without_action_prerequisites) keep it runnable. Changing a domain
# after configuring it is the host's business, as with any object it holds.
use JSON::PP ();
use DBI;
use Storable qw(dclone);
use Selecto;
use Selecto::BoundedQuery;
plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };
my $db = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError=>1,PrintError=>0});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE records(id INTEGER PRIMARY KEY, tenant_id INTEGER, name TEXT, state TEXT)');
$db->do('CREATE TABLE other_records(id INTEGER PRIMARY KEY, tenant_id INTEGER, name TEXT, state TEXT)');
$db->do(q{INSERT INTO records VALUES(1,7,'A','open'),(2,8,'B','done')});
$db->do(q{INSERT INTO other_records VALUES(900,7,'Other','open')});
my $adapter=Selecto->adapter(sqlite=>dbh=>$db);
my $base={schema_version=>1,name=>'Records',source=>{source_table=>'records',primary_key=>'id',tenant_field=>'tenant_id',fields=>[qw(id tenant_id name state)],columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer'},name=>{type=>'string'},state=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
 writes=>{operations=>{insert=>{enabled=>JSON::PP::true}},fields=>{name=>{insertable=>JSON::PP::true},state=>{insertable=>JSON::PP::true},tenant_id=>{insertable=>JSON::PP::true}}},
 actions=>{finish=>{type=>'transition',scope=>'row',transition=>{field=>'state',from=>'open',to=>'done'},execution=>{kind=>'updato',operation=>'update',set=>{state=>'done'}}}}};
sub engine { Selecto::Engine->new(domain=>Selecto::Domain->parse(dclone($base)),adapter=>$adapter) }
sub caught { my($run)=@_;my$ok=eval{$run->();1};return $ok?undef:$@ }
my $events=0;
$db->sqlite_set_authorizer(sub { $events++; return 0 });
my $original=engine();my $copy=bless {%$original},ref($original);$events=0;my $copyerror=caught(sub{$copy->all($copy->query->select('id'))});
is($copyerror->code,'domain_modified_after_configuration','raw engine copy has no private configuration authority');is($events,0,'unsealed raw copy performs no native work');
my $e=engine();my $q=$e->query->select('id')->order_by('id');
is_deeply($e->all($q)->{rows},[[1],[2]],'ordinary configured query executes actual source');
is_deeply($e->all($q)->{rows},[[1],[2]],'repeated compilation and statement use retains valid identity');
my $stream=$e->stream($q);is_deeply($stream->next,[1],'ordinary stream executes');$stream->close;
my $limited=$e->with_limits(Selecto::Limits->new(max_fields=>1));
is($limited->limits->get('max_fields'),1,'approved budget copy tightens native limits');
is_deeply($limited->all($q)->{rows},[[1],[2]],'approved budget copy preserves checked cached domain and executes');
my $looser=$limited->with_limits(Selecto::Limits->new(max_fields=>100));is($looser->limits->get('max_fields'),1,'approved budget transition cannot loosen an existing ceiling');
my $scoped=$e->with_scope(tenant=>7);
is_deeply($scoped->all($q)->{rows},[[1]],'approved scoped copy installs trusted tenant predicate');
is_deeply($e->all($q)->{rows},[[1],[2]],'approved scoped copy preserves original working engine');
my $error=caught(sub{$scoped->with_scope(tenant=>8)});is($error->code,'tenant_mismatch','approved transition still refuses another tenant');
$e=engine();my $hidden=$e->without_action_prerequisites('finish');
ok(!exists($hidden->domain->fields->{can_finish}),'approved prerequisite removal changes the derived domain');
is_deeply($hidden->all($hidden->query->select('id'))->{rows},[[1],[2]],'approved prerequisite copy remains executable');
ok(exists($e->domain->fields->{can_finish}),'approved prerequisite copy leaves source domain usable');
is_deeply($e->all($e->query->select('can_finish'))-> {rows},[[1],[0]],'original computed prerequisite executes after derived copy');
{package DerivedDomain;use parent -norequire, q{Selecto::Domain};}
my $derived=DerivedDomain->new(name=>'Derived',table=>'records',fields=>{id=>'integer'});
my $derived_engine=Selecto::Engine->new(domain=>$derived,adapter=>$adapter);
is_deeply($derived_engine->all($derived_engine->query->select('id'))->{rows},[[1],[2]],'constructed domain subclass retains ordinary native execution');
my $direct=$adapter->compile(Selecto::Domain->new(name=>'Other',table=>'other_records',fields=>{id=>'integer'}),Selecto::Query->new->select('id'));
is_deeply($adapter->execute_query($direct)->{rows},[[900]],'trusted raw adapter remains an independent execution surface');
$db->sqlite_set_authorizer(undef);
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP is memory');is($db->selectall_arrayref('PRAGMA database_list')->[0][2],'','main database is memory');
$db->disconnect;
done_testing;
