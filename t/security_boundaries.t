use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Limits;
use Selecto::Importer;
use Selecto::FieldPolicy;
use Selecto::CoDomain;
use Selecto::Files;
use Selecto::API::EngineHandler;
use lib 't/lib';
use TestSelecto;

sub error_code {
    my ($run) = @_;
    my $ok = eval { $run->(); 1 };
    return $ok ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@";
}
sub domain {
    return Selecto::Domain->parse({schema_version=>1,name=>'Boundary fixtures',
        source=>{source_table=>'fixtures',primary_key=>'id',fields=>[qw(id status secret)],
            columns=>{id=>{type=>'integer'},status=>{type=>'string'},secret=>{type=>'string',internal=>1}},
            associations=>{children=>{queryable=>'children',owner_key=>'id',related_key=>'parent_id',cardinality=>'many'}}},
        schemas=>{children=>{source_table=>'children',primary_key=>'id',fields=>[qw(id parent_id name hidden)],
            columns=>{id=>{type=>'integer'},parent_id=>{type=>'integer'},name=>{type=>'string'},hidden=>{type=>'string',internal=>1}},associations=>{}}},
        joins=>{children=>{type=>'left'}},
        writes=>{operations=>{update=>{enabled=>1},delete=>{enabled=>1}},fields=>{status=>{updatable=>1}}},
        imports=>{contract_version=>1,enabled=>1,field_policy=>'declared_only',fields=>{status=>{sources=>['column']}},actions=>{},key_sets=>[{id=>'status',fields=>['status'],cardinality=>'zero_or_one',allowed_on_match=>['update'],allowed_on_missing=>['error'],default_on_match=>'update',default_on_missing=>'error'}]},
        query_library=>{
            segments=>{
                csv=>{parameters=>{codes=>{type=>'string'}},filters=>[['csv_in','status',['param','codes']]]},
                list=>{parameters=>{codes=>{type=>'application/list'}},filters=>[['in','status',['param','codes']]]},
                hidden=>{filters=>[['eq','secret','hidden']]},
            },
            projections=>{public=>{fields=>[qw(id status)]},hidden=>{fields=>[qw(id status secret)]},association=>{fields=>[qw(id status children.hidden)]}},
            orderings=>{hidden=>{order_by=>[['secret','asc']]},public=>{order_by=>[['status','asc']]}},
        },
    },strict=>1);
}
my $domain=domain();
my $limits=Selecto::Limits->new(max_filter_values=>2,max_parameter_bytes=>8,max_value_bytes=>3);
is($limits->check_bytes('max_value_bytes','é','bad'),'2','limits count UTF-8 bytes');
is(error_code(sub {$limits->check_bytes('max_value_bytes','éé','bad')}),'bad','Unicode bytes reject above threshold');
is(error_code(sub {Selecto::Limits->new(max_filter_values=>0)}),'invalid_limits','unbounded or zero policy override refused');
is(error_code(sub {Selecto::Limits->new(request_limit=>100)}),'invalid_limits','unknown policy setting refused');
sub segment { Selecto::QueryLibrary->apply_segment($domain,Selecto::Query->new,$_[0],{codes=>$_[1]},$_[2]//$limits) }
is(error_code(sub {segment('csv','a,b')}),'ok','csv membership boundary accepted');
is(error_code(sub {segment('csv','a,b,c')}),'invalid_query_library','csv membership above cap rejected');
is(error_code(sub {segment('csv','aaaa')}),'invalid_query_library','csv individual bytes bounded');
is(error_code(sub {segment('csv',',,,,,,,,,')}),'invalid_query_library','csv raw bytes checked before empty-item dropping');
is(error_code(sub {segment('csv',' é ,b')}),'ok','csv Unicode and trim within budgets');
is(error_code(sub {segment('list',['a','b'])}),'ok','regular IN within budget accepted');
is(error_code(sub {segment('list',['a','b','c'])}),'invalid_query_library','regular IN cannot bypass item ceiling');
is(error_code(sub {segment('list',[['nested']])}),'invalid_query_library','nested references refused before compilation');

subtest 'API conflict targets keep exact request identity' => sub {
    my $write_domain=TestSelecto::writable_domain(name=>'Targets',table=>'targets',fields=>{id=>'integer',status=>'string'});
    my $engine=Selecto::Engine->new(domain=>$write_domain,adapter=>Selecto->adapter(postgresql=>(dbh=>TestSelecto::DBH->new)));
    my $handler=Selecto::API::EngineHandler->new;
    is(error_code(sub {$handler->write_command($engine,{operation=>'upsert',assignments=>{id=>1,status=>'test'},
        conflict_target=>['id','id'],upsert_update_fields=>['status']})}),
        'conflict_target_not_declared','duplicate conflict fields refuse before de-duplication');
    is(error_code(sub {$handler->write_command($engine,{operation=>'upsert',assignments=>{id=>1,status=>'test'},
        conflict_target=>['id'],upsert_update_fields=>['status']})}),'ok','exact declared target still accepted');
};

subtest 'hidden descriptors are safe at resolve' => sub {
    my $policy=Selecto::FieldPolicy->new(domain=>$domain,authorize=>sub {{status=>'disabled'}});
    for my $profile ([{field=>'secret'}],[{field=>'status',mode=>'hidden'}],[{field=>'status',view_capability=>'view'}],[{field=>'children.hidden'}]) {
        my $resolved=$policy->resolve(profile=>$profile,snapshot=>{map {$_=>'secret-marker'} qw(secret status children.hidden)});
        is($resolved->[0]{state},'hidden','field hidden');
        ok(!exists($resolved->[0]{value}),'hidden descriptor omits value');
        unlike(JSON::PP->new->encode($resolved),qr/secret-marker/,'serialized descriptor contains no secret');
    }
    is($policy->resolve(profile=>[{field=>'status',mode=>'read_only'}],snapshot=>{status=>'public'})->[0]{value},'public','visible readonly retains allowed value');
};

subtest 'CSV aggregate budgets include headers' => sub {
    my $importer=Selecto::Importer->new(domain=>$domain,max_file_bytes=>8,max_total_decoded_bytes=>4,max_total_cells=>4);
    is($importer->inspect_csv("a,b\nx,y\n")->{row_count},1,'exact file/cell/decoded boundary accepted');
    is(error_code(sub {$importer->inspect_csv("a,b\nxx,y\n")}), 'import_file_limit_exceeded','input cap enforced before parsing');
    my $decoded=Selecto::Importer->new(domain=>$domain,max_total_decoded_bytes=>3);
    is(error_code(sub {$decoded->inspect_csv("a,b\nx,y\n")}), 'import_decoded_limit_exceeded','aggregate bytes exceed cap with small cells');
    my $cells=Selecto::Importer->new(domain=>$domain,max_total_cells=>3);
    is(error_code(sub {$cells->inspect_csv("a,b\nx,y\n")}), 'import_total_cell_limit_exceeded','aggregate cell count includes header');
    my $unicode=Selecto::Importer->new(domain=>$domain,max_total_decoded_bytes=>2);
    is(error_code(sub {$unicode->inspect_csv("h\né\n")}), 'import_decoded_limit_exceeded','decoded UTF-8 byte budget counts multibyte cells');
    my $quoted=Selecto::Importer->new(domain=>$domain);
    is($quoted->inspect_csv("h\n\"a\nb\"\n")->{rows}[0]{values}{c1},"a\nb",'single-pass rows preserve quoted multiline input');
    is($quoted->inspect_csv("a,b\n",header=>0)->{row_count},1,'headerless first row retained');
};

{
    package BoundaryDBH; sub ping {1}
    package BoundaryAdapter;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;
    sub execute_query ($self,$statement) {
        ++$self->{calls}; $self->{statement}=$statement;
        return {columns=>$statement->columns,rows=>[[map {$_ eq 'id'?1:$_ eq 'children'?($self->{payload}//'[{"children.name":"child"}]'):'public'} @{$statement->columns}]]};
    }
    package UnsupportedBoundaryAdapter;
    use Mojo::Base 'BoundaryAdapter';
    sub name {'sqlite'}
}
my $adapter=BoundaryAdapter->new(dbh=>bless({},'BoundaryDBH'));
my $engine=Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
subtest 'public collections are bounded before execution' => sub {
    my $policy=Selecto::Limits->new(max_collection_rows=>2,max_total_collection_rows=>4,max_response_bytes=>500);
    my $handler=Selecto::API::EngineHandler->new(limits=>$policy,default_limit=>2);
    my $result=$handler->query($engine,{select=>['id',['children.name']]});
    like($adapter->{statement}->sql,qr/ORDER BY "c_children"\."id" ASC LIMIT 3/,'child subquery carries cap plus one and stable order');
    is_deeply($result->{subtables}{children},{columns=>['children.name'],limit=>2,complete=>JSON::PP::true},'success explicitly complete under cap');
    local $adapter->{payload}='[{"children.name":"a"},{"children.name":"b"},{"children.name":"c"}]';
    is(error_code(sub {$handler->query($engine,{select=>['id',['children.name']]})}),'related_collection_limit_exceeded','excess children refused rather than silently truncated');
    my $before=$adapter->{calls};
    is(error_code(sub {$handler->query($engine,{select=>['id',['children.name']],limit=>3})}),'invalid_api_query','two-dimensional child budget checked');
    is($adapter->{calls},$before,'aggregate budget fails before database execution');
    my $unsupported=UnsupportedBoundaryAdapter->new(dbh=>bless({},'BoundaryDBH'));
    my $other=Selecto::Engine->new(domain=>$domain,adapter=>$unsupported);
    is(error_code(sub {$handler->query($other,{select=>['id',['children.name']]})}),'unsupported_feature','unsupported adapter fails closed');
    ok(!$unsupported->{calls},'unsupported collection never executes');
    local $adapter->{payload}='x'x501;
    is(error_code(sub {$handler->query($engine,{select=>['id',['children.name']]})}),'api_result_limit_exceeded','oversized malformed JSON refused before decoding');
    # An adapter may return already-decoded cells. Encoding must account for
    # quotes and control characters, not only their one-byte input length.
    local $adapter->{payload}=[{'children.name' => chr(1) x 70}];
    is(error_code(sub {$handler->query($engine,{select=>['id',['children.name']]})}),'api_result_limit_exceeded','encoded metadata and control escaping count toward response budget');
    local $adapter->{payload}=[{'children.name' => 'é' x 200}];
    is(error_code(sub {$handler->query($engine,{select=>['id',['children.name']]})}),'api_result_limit_exceeded','encoded Unicode and response metadata count toward budget');
};
subtest 'API and query library share trusted limits' => sub {
    my $handler=Selecto::API::EngineHandler->new(max_filter_values=>2,limits=>$limits);
    my $before=$adapter->{calls};
    for my $body ({select=>['id'],segments=>['csv'],parameters=>{codes=>'a,b,c'}},{select=>['id'],filters=>[{field=>'status',op=>'in',value=>['a','b','c']}]}) {
        isnt(error_code(sub {$handler->query($engine,$body)}),'ok','both membership producers refuse excess');
    }
    is($adapter->{calls},$before,'refusal occurs before adapter');
    my $tight_engine=Selecto::Engine->new(domain=>$domain,adapter=>$adapter,limits=>Selecto::Limits->new(max_filter_values=>1));
    isnt(error_code(sub {$handler->query($tight_engine,{select=>['id'],segments=>['csv'],parameters=>{codes=>'a,b'}})}),'ok','handler cannot widen engine membership ceiling');
    is(error_code(sub {$handler->write_command($engine,{operation=>'delete',filters=>[{field=>'status',op=>'eq',value=>'active'}]})}),'invalid_api_write','nonbulk broad predicate refused');
    is(error_code(sub {$handler->write_command($engine,{operation=>'delete',filters=>[{field=>'id',op=>'eq',value=>1}]})}),'ok','nonbulk primary-key target accepted');
};

sub lookup_source {
    my (%options)=@_;
    my $lookup={domain=>'fixtures',projection=>$options{projection}//'public',
        search=>{fields=>$options{search}//['status'],mode=>'prefix',rank=>1},
        result=>{value_field=>$options{value}//'id',label_field=>$options{label}//'status',description_fields=>$options{description}//[]}};
    $lookup->{ordering}=$options{ordering} if $options{ordering};
    $lookup->{segments}=$options{segments} if $options{segments};
    return Selecto::Domain->parse({schema_version=>1,name=>'Lookup source',source=>{source_table=>'sources',primary_key=>'id',fields=>['id'],columns=>{id=>{type=>'integer'}},associations=>{}},schemas=>{},joins=>{},co_domains=>{lookup=>$lookup}},strict=>1);
}
subtest 'co-domain validates all public field roles' => sub {
    for my $options ({value=>'secret',projection=>'hidden'},{label=>'secret',projection=>'hidden'},{description=>['secret'],projection=>'hidden'},{search=>['secret']},{ordering=>'hidden'},{projection=>'hidden'},{projection=>'association'},{segments=>['hidden']}) {
        my $before=$adapter->{calls};
        is(error_code(sub {Selecto::CoDomain->lookup(source_domain=>lookup_source(%$options),engine=>$engine,co_domain=>'lookup',query=>'public')}),'invalid_co_domain','nonpublic lookup role refused');
        is($adapter->{calls},$before,'invalid lookup never executes');
    }
    is(error_code(sub {Selecto::CoDomain->lookup(source_domain=>lookup_source(ordering=>'public'),engine=>$engine,co_domain=>'lookup',query=>'public')}),'ok','public lookup still works');
};

subtest 'hold release is authority-specific and audited before mutation' => sub {
    my (@requests,@audit); my ($admin,$audit_ok)=(0,1);
    my $service=Selecto::Files->new(secret=>'synthetic',descriptor=>{id=>'files',domain_fingerprint=>'fixture',roles=>{docs=>{max_files=>2,max_bytes=>32,media_types=>['text/plain']}}},
        authorize=>sub {push @requests,[@_];return $admin && $_[0] =~ /hold/ ? {allowed=>1,hold_admin=>1}:1},
        audit=>sub {push @audit,$_[0];return $audit_ok});
    my $owner={domain_fingerprint=>'fixture',key=>{id=>1}};
    my $alice=$service->bind(tenant=>'t',actor=>'alice')->for_record($owner);
    my $bob=$service->bind(tenant=>'t',actor=>'bob')->for_record($owner);
    my $file=$alice->upload(role=>'docs',bytes=>'fixture',name=>'fixture.txt',media_type=>'text/plain',idempotency_key=>'one');
    $alice->detach($file->{attachment_id},expected_revision=>$file->{revision});
    $alice->place_hold($file->{version_id},authority=>'legal');
    $alice->place_hold($file->{version_id},authority=>'records');
    is(error_code(sub {$bob->release_hold($file->{version_id},authority=>'legal')}),'not_found','boolean authorization cannot release another actor hold');
    is(error_code(sub {$bob->place_hold($file->{version_id},authority=>'legal')}),'not_found','another actor cannot overwrite hold ownership');
    is(error_code(sub {$alice->purge($file->{version_id})}),'conflict','denial preserves purge block');
    $audit_ok=0;
    is(error_code(sub {$alice->release_hold($file->{version_id},authority=>'legal')}),'audit_failed','failed audit prevents release');
    is(error_code(sub {$alice->purge($file->{version_id})}),'conflict','audit failure preserves hold');
    $audit_ok=1;$admin=1;
    is(error_code(sub {$bob->release_hold($file->{version_id},authority=>'legal')}),'ok','explicit admin releases another authority');
    is(error_code(sub {$alice->purge($file->{version_id})}),'conflict','second authority remains blocking');
    $alice->release_hold($file->{version_id},authority=>'records');
    is(error_code(sub {$alice->purge($file->{version_id})}),'ok','all legitimate releases permit purge');
    my @holds=grep {$_->[0]=~/hold/} @requests;
    is_deeply($holds[0][4],{operation=>'place_hold',version_id=>$file->{version_id},authority=>'legal'},'authorization receives normalized hold identity');
    is($audit[-1]{operation},'release_hold','release audit invoked');
};

done_testing;
