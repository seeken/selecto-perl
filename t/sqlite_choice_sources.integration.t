use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Domain::Choices;
BEGIN {eval{require DBI;require DBD::SQLite;1}or plan skip_all=>'DBD::SQLite required'}
my$d=do{open my$f,'<:raw','t/fixtures/choice_sources.json'or die$!;local$/;JSON::PP->new->utf8->decode(<$f>)->{D045}{governed_domain}};
my$api='Selecto::Domain::Choices';
my$db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
$db->do('PRAGMA temp_store=MEMORY');
$db->do('CREATE TABLE users(id INTEGER PRIMARY KEY,name TEXT,tenant_id INTEGER,active INTEGER)');
$db->do(q{INSERT INTO users VALUES(42,'Ada',7,1),(43,'Bo',8,1),(44,'Cara',7,0)});
my$events=0;$db->sqlite_set_authorizer(sub{$events++;0});
my$r=$api->validate_choice($d,'owner_id',42,{tenant=>7,context=>{tenant_id=>7}});
is_deeply([$r->status,$r->reason_code],[qw(unknown resolver_required)],'actual stored row does not imply membership without host provider');
my$o=$api->list_options($d,'owner_id',{tenant=>7,search=>'Ada'});
is($o->status,'unknown','actual stored rows do not imply automatic options provider');
is($events,0,'missing providers execute no SQL or catalog read');
my$calls=0;
my$host=sub{
 my($request)=@_;$calls++;
 # This is deliberately supplied host policy, not metadata converted to SQL.
 my$present=$db->selectrow_array('SELECT count(*) FROM users WHERE id=? AND tenant_id=? AND active=1',undef,$request->{value},$request->{context}{tenant_id});
 return$present?$api->valid('certified_member'):$api->invalid('outside_domain');
};
for my$case([42,7,'valid'],[43,7,'invalid'],[44,7,'invalid'],[99,7,'invalid'],[43,8,'valid']){
 my($value,$tenant,$status)=@$case;
 $r=$api->validate_choice($d,'owner_id',$value,{tenant=>$tenant,context=>{tenant_id=>$tenant}},$host);
 is($r->status,$status,"explicit host provider uses actual active tenant-scoped row for $value/$tenant");
 is_deeply([$r->request->{value},$r->request->{context}{tenant_id}],[$value,$tenant],'provider result attaches actual input request');
}
is($calls,5,'only explicit providers are invoked');
ok($events>0,'explicit host provider really executes native SQL');
my$host_options=sub{
 my($request)=@_;
 my$rows=$db->selectall_arrayref('SELECT id AS value,name AS label FROM users WHERE tenant_id=? AND active=1 AND name LIKE ? ORDER BY name LIMIT ? OFFSET ?', {Slice=>{}},$request->{tenant},'%'.$request->{search}.'%',$request->{limit},$request->{offset});
 return$api->options_resolved($rows,{total_count=>scalar@$rows});
};
$o=$api->list_options($d,'owner_id',{tenant=>7,search=>'Ad',limit=>10,offset=>0},$host_options);
is_deeply($o->options,[{value=>42,label=>'Ada'}],'explicit options provider returns actual native rows');
my$before=$events;
my$bad=$api->list_options($d,'owner_id',{},sub{{status=>'resolved',options=>[{value=>99,label=>'Forged'}]}});
is($bad->reason_code,'invalid_resolver_result','serialized host return cannot impersonate a native options decision');
is($events,$before,'malformed provider result admission adds no SQL');
$db->sqlite_set_authorizer(undef);
is($db->selectrow_array('SELECT count(*) FROM users'),3,'provider reads preserve business rows');
is($db->selectrow_array('PRAGMA temp_store'),2,'TEMP remains in memory');
ok(!grep(length($_->[2]),@{$db->selectall_arrayref('PRAGMA database_list')}),'all native SQLite databases remain in memory');
$db->disconnect;
done_testing;
