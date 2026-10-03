use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Selecto;
use Selecto::BoundedQuery;
use Selecto::Limits;

sub scalar_domain {
    Selecto::Domain->new(name=>'Bounded rows',table=>'bounded_rows',primary_key=>'id',
        fields=>{id=>'integer',label=>'string'});
}
sub engine { Selecto::Engine->new(domain=>$_[1],adapter=>Selecto->adapter($_[0]=>dbh=>$_[2])) }
sub assert_rejected {
    my ($callback,$label)=@_;
    my $ok=eval {$callback->();1};my $error=$@;
    ok !$ok,$label;
    isa_ok $error,'Selecto::Error';
    return $error;
}

subtest 'SQLite transfer guard and cumulative consumption' => sub {
    plan skip_all=>'DBD::SQLite unavailable' unless eval {require DBD::SQLite;1};
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $dbh->do('CREATE TABLE bounded_rows (id integer primary key,label text)');
    $dbh->do('INSERT INTO bounded_rows VALUES (?,?)',undef,1,'abcd');
    $dbh->do('INSERT INTO bounded_rows VALUES (?,?)',undef,2,'abcde');
    my $engine=engine('sqlite',scalar_domain(),$dbh);
    my $limits=Selecto::Limits->new(max_result_cell_bytes=>4,max_response_bytes=>100);
    my $one=$engine->query->select('label')->where(Selecto::Expression->eq('id',1));
    is_deeply(Selecto::BoundedQuery->all($engine,$one,limits=>$limits)->{rows},[['abcd']],'exact raw cell byte boundary succeeds');
    assert_rejected(sub{Selecto::BoundedQuery->all($engine,$engine->query->select('label'),limits=>$limits)},'oversized cell rejected');
    # Spy on native decode: the oversized payload never crosses the SQL guard.
    my @decoded;
    {
        no warnings 'redefine';
        local *Selecto::SQLite::_decode=sub{push @decoded,$_[1];return $_[1]};
        eval {Selecto::BoundedQuery->all($engine,$engine->query->select('label'),limits=>$limits)};
    }
    ok !(grep {defined($_)&&$_ eq 'abcde'} @decoded),'oversized bytes are suppressed before native decode';
    assert_rejected(sub{Selecto::BoundedQuery->all($engine,$engine->query->select('label'),max_rows=>1)},'row cap plus one is detected, not silently truncated');
    assert_rejected(sub{Selecto::BoundedQuery->all($engine,$engine->query->select('label'),
        limits=>Selecto::Limits->new(max_result_cell_bytes=>8,max_response_bytes=>8))},'cumulative cell bytes exceed whole result');
    is_deeply(Selecto::BoundedQuery->all($engine,$one)->{rows},[['abcd']],'database reusable after rejected transfer');
    my $calls=0;
    $dbh->sqlite_create_function('bounded_volatile',0,sub{++$calls == 1 ? 'abcd' : 'x'x100});
    my $volatile=Selecto::Statement->new(sql=>'SELECT bounded_volatile() AS label',
        columns=>['label'],params=>[],adapter_name=>'sqlite');
    is_deeply(Selecto::BoundedQuery->execute($engine,$volatile,limits=>$limits)->{rows},[['abcd']],
        'volatile value fenced before transfer guard');
    is $calls,1,'size guard and emitted cell share one evaluation';
    assert_rejected(sub{Selecto::BoundedQuery->all($engine,$engine->query->limit(1))},
        'empty selection has no implicit unbounded projection');
    my $cycle=[];push @$cycle,$cycle;
    assert_rejected(sub{Selecto::BoundedQuery->validate_result({columns=>['x'],rows=>[[$cycle]]},Selecto::Limits->new)},'cyclic cached result refused before serialization');
    assert_rejected(sub{Selecto::BoundedQuery->validate_result(
        {columns=>['children'],rows=>[[[{a=>1,b=>2}]]]},Selecto::Limits->new(max_total_cells=>3))},
        'child field cells count against total cell ceiling');
    $dbh->disconnect;
};

sub relation {
    my($table,$columns,%extra)=@_;
    return {source_table=>$table,primary_key=>'id',fields=>[sort keys %$columns],
        columns=>{map{$_=>{type=>$columns->{$_}}}keys %$columns},associations=>{},%extra};
}
sub child_domain {
    Selecto::Domain->parse({schema_version=>1,name=>'Bounded parents',
        source=>relation('bounded_parents',{id=>'integer',tenant=>'integer'},
            associations=>{children=>{queryable=>'child',owner_key=>'id',related_key=>'parent_id'}}),
        schemas=>{child=>relation('bounded_children',{id=>'integer',parent_id=>'integer',label=>'string'})},joins=>{}});
}
subtest 'PostgreSQL per-parent bounded aggregation and transfer' => sub {
    my $url=$ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all=>'SELECTO_PERL_TEST_POSTGRES_URL not configured' unless $url;
    plan skip_all=>'DBD::Pg unavailable' unless eval{require DBD::Pg;1};
    my($user,$host,$port,$db)=$url=~m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)};
    plan skip_all=>'simple disposable PostgreSQL URL required' unless $db;
    my $dbh=DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port",$user,'',{RaiseError=>1,PrintError=>0,pg_enable_utf8=>1});
    $dbh->do('CREATE TEMP TABLE bounded_parents(id integer primary key,tenant integer)');
    $dbh->do('CREATE TEMP TABLE bounded_children(id integer primary key,parent_id integer,label text)');
    $dbh->do('INSERT INTO bounded_parents VALUES (1,1),(2,2)');
    $dbh->do('INSERT INTO bounded_children VALUES (?,?,?)',undef,@$_)
        for [1,1,'Café'],[2,1,'second'],[3,2,'other tenant'];
    my $domain=child_domain()->with_required_predicate(Selecto::Expression->eq('tenant',1));
    my $engine=engine('postgresql',$domain,$dbh);
    my $query=$engine->query->select('id',Selecto::Expression->related_collection('children',['label'])->as('children'))->order_by('id');
    my $limits=Selecto::Limits->new(max_collection_rows=>2,max_total_collection_rows=>3);
    my $hidden=$engine->query->select(Selecto::Expression->window('count',[
        Selecto::Expression->related_collection('children',['label'])])->as('hidden'));
    my $hidden_error=assert_rejected(sub{Selecto::BoundedQuery->prepare($engine,$hidden)},
        'nested collection concealed inside another expression refuses bounded execution');
    is $hidden_error->code,'unsupported_feature','hidden collection profile refuses before compile or execution';
    my $prepared=Selecto::BoundedQuery->prepare($engine,$query,limits=>$limits);
    like $prepared->{statement}->sql,qr/LIMIT 3/,'cap plus one applied before JSON aggregation';
    my $ordered=$engine->query->select(Selecto::Expression->related_collection('children',['label'],
        order_by=>[['label','desc']])->as('children'));
    my $ordered_sql=Selecto::BoundedQuery->prepare($engine,$ordered,limits=>$limits)->{statement}->sql;
    like $ordered_sql,qr/ORDER BY [^;]*"label" DESC, [^;]*"id" ASC/,'authored child ordering gains stable primary key tie-breaker';

    my $rows=Selecto::BoundedQuery->execute($engine,$prepared)->{rows};
    is_deeply $rows,[[1,[{label=>'Café'},{label=>'second'}]]],'bounded children preserve order and required tenant predicate';
    $dbh->do('INSERT INTO bounded_children VALUES (4,1,?)',undef,'third');
    assert_rejected(sub{Selecto::BoundedQuery->all($engine,$query,limits=>$limits)},'extra child rejects complete response');
    $dbh->do('DELETE FROM bounded_children WHERE id=4');
    $dbh->do('UPDATE bounded_children SET label=? WHERE id=1',undef,'x'x100);
    assert_rejected(sub{Selecto::BoundedQuery->all($engine,$query,limits=>Selecto::Limits->new(max_result_cell_bytes=>64))},'large nested JSON suppressed before driver consumption');
    is $dbh->selectrow_array('SELECT 1'),1,'PG transaction usable after child/transfer failures';
    my $sqlite=engine('sqlite',child_domain(),DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0}));
    my $error=assert_rejected(sub{Selecto::BoundedQuery->prepare($sqlite,$query)},'unsupported bounded nested SQLite refuses before database prepare');
    is $error->code,'unsupported_feature','unsupported capability remains explicit';
    $dbh->disconnect;
};

done_testing;
