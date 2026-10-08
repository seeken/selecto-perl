use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Domain;
use Selecto::Engine;
use Selecto::SQLite;
use Selecto::Write;
use Selecto::Expression;
BEGIN {eval {require DBI;require DBD::SQLite;1} or plan skip_all => 'DBD::SQLite required'}
sub document {
    my (%args)=@_;
    my $rules={schema=>'selecto.data_rules.v1',definitions=>{null=>{version=>1,test=>{op=>'value.eq',value=>undef}},positive=>{version=>1,test=>{op=>'number.gt',bound=>0}}},normalizers=>{},bindings=>{}};
    if ($args{input}) {
        $rules->{normalizers}{empty}={version=>1,steps=>[{op=>'text.empty_to_null'}]};
        $rules->{bindings}{input}={subject=>{scope=>'input',path=>['id']},rule=>{id=>'null',version=>1},normalizer=>{id=>'empty',version=>1}};
    }
    $rules->{bindings}{stored}={subject=>{scope=>'candidate',path=>[$args{consume_id}?'id':'quantity']},rule=>{id=>$args{consume_id}?'null':'positive',version=>1},
        $args{advisory}?(enforcement=>'advisory',condition=>{op=>'presence.absent'}):()};
    return {name=>'Native projection',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id quantity active)],columns=>{id=>{type=>'integer'},quantity=>{type=>'integer'},active=>{type=>'boolean'}}},schemas=>{},
        writes=>{operations=>{insert=>{enabled=>1},update=>{enabled=>1}},fields=>{map {($_=>{insertable=>1,updatable=>1})} qw(id quantity active)}},rules=>$rules};
}
sub memory {
    my ($schema,$raw,$work)=@_;my $db=DBI->connect('dbi:SQLite:dbname=:memory:',undef,undef,{RaiseError=>1,PrintError=>0});
    $db->do('PRAGMA temp_store=MEMORY');$db->do($_) for @$schema;
    my $writer=Selecto::Engine->new(domain=>Selecto::Domain->parse($raw),adapter=>Selecto::SQLite->new(dbh=>$db));$work->($writer,$db);
    is_deeply [grep {length($_->[2])} @{$db->selectall_arrayref('PRAGMA database_list')}],[],'all native schemas are in memory';$db->disconnect;
}
sub positive {my($work)=@_;my $ok=eval {$work->();1};ok $ok,'native public operation admits' or diag $@;return $ok}
sub pending {
    my($db,$work,$code)=@_;my $before=$db->selectrow_array('SELECT total_changes()');my $ok=eval {$work->();1};my $error=$@;
    ok !$ok,'native public operation refuses';is ref($error)&&$error->can('code')?$error->code:"$error",$code//'required_data_rule_pending','exact finite refusal';
    is $db->selectrow_array('SELECT total_changes()'),$before,'no business DML';
}
for my $indexed (0,1) {
    subtest $indexed?'normalized INPUT becomes native indexed NULL':'normalized INPUT leaves unconsumed generated identity usable'=>sub {
        memory(['CREATE TABLE items(id INTEGER PRIMARY KEY'.($indexed?' DESC':'').',quantity INTEGER,active BOOLEAN)'],document(input=>1,consume_id=>$indexed),sub {
            my($writer,$db)=@_;my $write=Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>'',quantity=>2});
            positive(sub {$writer->preview_write($write)});positive(sub {$writer->execute_write($write)});
            is_deeply $db->selectall_arrayref('SELECT id,quantity FROM items'),[[$indexed?undef:1,2]],'actual stored identity follows SQLite';
        });
    };
}
subtest 'normalizing raw INPUT cannot fabricate a consumed generated NULL'=>sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER,active BOOLEAN)'],document(input=>1,consume_id=>1,advisory=>1),sub {
        my($writer,$db)=@_;my $write=Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>'',quantity=>2});
        pending($db,sub {$writer->preview_write($write)});pending($db,sub {$writer->execute_write($write)});
    });
};
subtest 'raw INPUT validation precedes prospective native conversion'=>sub {
    my $raw=document();$raw->{rules}{definitions}{number}={version=>1,test=>{op=>'type.is',type=>'integer'}};
    $raw->{rules}{bindings}{input}={subject=>{scope=>'input',path=>['id']},rule=>{id=>'number',version=>1}};
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY DESC,quantity INTEGER,active BOOLEAN)'],$raw,sub {
        my($writer,$db)=@_;pending($db,sub {$writer->execute_write(Selecto::Write::Command->new(operation=>'insert',relation=>'items',assignments=>{id=>'',quantity=>2}))},'data_rule_failed');
    });
};
subtest 'actual stored BOOLEAN text stays unknown until explicitly replaced'=>sub {
    my $raw=document();$raw->{rules}{definitions}{false}={version=>1,test=>{op=>'value.eq',value=>JSON::PP::false}};
    $raw->{rules}{bindings}{stored}={subject=>{scope=>'candidate',path=>['active']},rule=>{id=>'false',version=>1}};
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER,active BOOLEAN)',"INSERT INTO items VALUES(1,1,'false')"],$raw,sub {
        my($writer,$db)=@_;my $bad=Selecto::Write::Command->new(operation=>'update',relation=>'items',assignments=>{quantity=>2},predicate=>Selecto::Expression->eq('id',1),expected_count=>1);
        pending($db,sub {$writer->execute_write($bad)});is_deeply $db->selectrow_arrayref('SELECT active,typeof(active) FROM items'),['false','text'],'no presentation boolean is fabricated';
        my $good=$bad->with_assignments({quantity=>2,active=>JSON::PP::false});positive(sub {$writer->preview_write($good)});positive(sub {$writer->execute_write($good)});
        is_deeply $db->selectrow_arrayref('SELECT quantity,active,typeof(active) FROM items'),[2,0,'integer'],'explicit replacement stores actual canonical false';
    });
};
subtest 'actual noncanonical integer is repairable before candidate projection'=>sub {
    memory(['CREATE TABLE items(id INTEGER PRIMARY KEY,quantity INTEGER,active BOOLEAN)','INSERT INTO items VALUES(1,1.5,0)'],document(),sub {
        my($writer,$db)=@_;my $write=Selecto::Write::Command->new(operation=>'update',relation=>'items',assignments=>{quantity=>2},predicate=>Selecto::Expression->eq('id',1),expected_count=>1);
        positive(sub {$writer->preview_write($write)});positive(sub {$writer->execute_write($write)});is_deeply $db->selectrow_arrayref('SELECT quantity,typeof(quantity) FROM items'),[2,'integer'],'actual submitted integer repairs stored REAL';
    });
};
done_testing;
