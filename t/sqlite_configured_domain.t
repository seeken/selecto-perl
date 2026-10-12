use 5.034;
use strict;
use warnings;
use Test::More;
$Selecto::Engine::VERIFY_DOMAIN_IDENTITY = 1;  # tamper detection is opt-in (Selecto::Engine); these tests check it
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
sub refused {
 my($label,$edit,$run)=@_;my$e=engine();$edit->($e);$events=0;
 my$error=caught(sub { $run->($e) });
 is(ref($error)?$error->code:'none','domain_modified_after_configuration',$label);
 is_deeply(ref($error)?$error->details->{path}:undef,[],"$label has canonical path");
 is($events,0,"$label rejects before native preparation or execution");
}
for my $route (qw(compile all stream bounded prepare)) {
 refused("table change at $route",sub { $_[0]->domain->{table}='other_records' },sub {
  my($e)=@_;my$q=$e->query->select('id');
  return $e->compile($q) if $route eq 'compile';return $e->all($q) if $route eq 'all';return $e->stream($q) if $route eq 'stream';
  return Selecto::BoundedQuery->all($e,$q) if $route eq 'bounded';return Selecto::BoundedQuery->prepare($e,$q);
 });
}
refused('cached fingerprint cannot mask changed table',sub { my$d=$_[0]->domain;my$f=$d->fingerprint;$d->{table}='other_records';$d->{fingerprint}=$f },sub { $_[0]->all($_[0]->query->select('id')) });
refused('contract-only relation mutation',sub { $_[0]->domain->{contract}{source}{source_table}='other_records' },sub { $_[0]->compile($_[0]->query->select('id')) });
refused('required predicate mutation',sub { $_[0]->domain->{required_predicate}=Selecto::Expression->eq('tenant_id',8) },sub { $_[0]->all($_[0]->query->select('id')) });
refused('association metadata mutation',sub { $_[0]->domain->{canonical_joins}{extra}={} },sub { $_[0]->compile($_[0]->query->select('id')) });
refused('trusted scope hash mutation',sub { $_[0]{scope}{tenant}=8 },sub { $_[0]->all($_[0]->query->select('id')) });
refused('forged read cache before first read',sub { $_[0]{_read_domain}=Selecto::Domain->new(name=>'Other',table=>'other_records',fields=>{id=>'integer'}) },sub { $_[0]->all($_[0]->query->select('id')) });
refused('deleting prepared read cache',sub { $_[0]->read_domain; delete $_[0]{_read_domain} },sub { $_[0]->all($_[0]->query->select('id')) });
refused('forged public seal cannot authorize changed domain',sub { $_[0]{domain}{table}='other_records'; $_[0]{_domain_seal}='forged' },sub { $_[0]->all($_[0]->query->select('id')) });
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
$scoped->read_domain->{required_predicate}=Selecto::Expression->eq('tenant_id',8);$events=0;
$error=caught(sub{$scoped->all($q)});is($error->code,'domain_modified_after_configuration','cached scoped domain cannot remove trusted tenant');is($events,0,'cached tenant tamper performs no native work');
my $prepared=Selecto::BoundedQuery->prepare($e,$q);$e->{domain}{table}='other_records';$events=0;
$error=caught(sub{Selecto::BoundedQuery->execute($e,$prepared)});is($error->code,'domain_modified_after_configuration','prepared bounded statement revalidates current domain before execute');is($events,0,'prepared stale statement performs no native work');
$e=engine();my $hidden=$e->without_action_prerequisites('finish');
ok(!exists($hidden->domain->fields->{can_finish}),'approved prerequisite removal changes the derived domain');
is_deeply($hidden->all($hidden->query->select('id'))->{rows},[[1],[2]],'approved prerequisite copy remains executable');
ok(exists($e->domain->fields->{can_finish}),'approved prerequisite copy leaves source domain usable');
is_deeply($e->all($e->query->select('can_finish'))-> {rows},[[1],[0]],'original computed prerequisite executes after derived copy');
refused('transition cannot launder a changed domain',sub { $_[0]->domain->{table}='other_records' },sub { $_[0]->with_scope(tenant=>7) });
refused('budget transition cannot launder a changed domain',sub { $_[0]->domain->{table}='other_records' },sub { $_[0]->with_limits(Selecto::Limits->new) });
refused('prerequisite transition cannot launder a changed domain',sub { $_[0]->domain->{table}='other_records' },sub { $_[0]->without_action_prerequisites('finish') });
my $calls=0;
{package SealEvil; use overload '""'=>sub{$calls++;'evil'},'bool'=>sub{$calls++;1},fallback=>1; sub isa{$calls++;1} sub STORABLE_freeze{$calls++;die 'callback'} }
my $evil=bless {},'SealEvil';
refused('overloaded unknown metadata',sub { $_[0]->domain->{components}{extra}=$evil },sub { $_[0]->compile($_[0]->query->select('id')) });
refused('executable callback metadata',sub { $_[0]->domain->{components}{extra}=sub{$calls++} },sub { $_[0]->compile($_[0]->query->select('id')) });
refused('excessively deep structural metadata',sub { my$v={};$v={next=>$v} for 1..66;$_[0]->domain->{components}{extra}=$v },sub { $_[0]->compile($_[0]->query->select('id')) });
refused('cyclic structural metadata',sub { my$d=$_[0]->domain; $d->{components}{extra}=$d },sub { $_[0]->compile($_[0]->query->select('id')) });
is($calls,0,'seal admission invokes no metadata callbacks, overloads, isa or serialization hooks');
{package SealTied;sub TIEHASH {bless{},shift}sub FIRSTKEY {$calls++;die 'callback'}sub FETCH {$calls++;die 'callback'} }
my %tied;tie %tied,'SealTied';
refused('tied structural metadata',sub { $_[0]->domain->{components}{extra}=\%tied },sub { $_[0]->compile($_[0]->query->select('id')) });
is($calls,0,'tied container is refused without traversal callbacks');
for my $route (qw(preview_write execute_write execute_batch)) {
 refused("domain mutation at $route",sub { $_[0]->domain->{table}='other_records' },sub {
  my($e)=@_;my$c=Selecto::Write::Command->new(operation=>'insert',relation=>'records',assignments=>{name=>'New',state=>'open',tenant_id=>7});
  return $e->$route($c) unless $route eq 'execute_batch';return $e->execute_batch(Selecto::Write::Batch->new($c));
 });
}
{package DerivedDomain;use parent 'Selecto::Domain';sub STORABLE_freeze{$calls++;die 'serialization hook'} }
my $derived=DerivedDomain->new(name=>'Derived',table=>'records',fields=>{id=>'integer'});
my $derived_engine=Selecto::Engine->new(domain=>$derived,adapter=>$adapter);
is_deeply($derived_engine->all($derived_engine->query->select('id'))->{rows},[[1],[2]],'constructed domain subclass retains ordinary native execution');
is($calls,0,'domain subclass seal does not invoke serialization hooks');
{package OverloadedDomain;use parent 'Selecto::Domain';use overload '%{}'=>sub{$calls++;die 'dereference overload'},fallback=>1;sub isa{$calls++;die 'isa hook'} }
my $raw=bless {table=>'records'},'OverloadedDomain';
ok(Selecto::ConfiguredDomain->digest($raw,{}) =~ /\A[0-9a-f]{64}\z/,'raw structural snapshot admits a native domain subclass with overloading disabled');
is($calls,0,'structural snapshot uses no overloaded dereference or custom inheritance hook');
ok(!$e->can('_seal_domain'),'engine exposes no method to reseal arbitrary changed domain');
my $direct=$adapter->compile(Selecto::Domain->new(name=>'Other',table=>'other_records',fields=>{id=>'integer'}),Selecto::Query->new->select('id'));
is_deeply($adapter->execute_query($direct)->{rows},[[900]],'trusted raw adapter remains an independent execution surface');
$db->sqlite_set_authorizer(undef);
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP is memory');is($db->selectall_arrayref('PRAGMA database_list')->[0][2],'','main database is memory');
$db->disconnect;
done_testing;
