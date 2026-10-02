use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Limits;
use Selecto::API::EngineHandler;
use Selecto::CoDomain;

my $url=$ENV{SELECTO_PERL_TEST_POSTGRES_URL};
plan skip_all=>'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && length($url);
plan skip_all=>'DBD::Pg is not installed' unless eval {require DBI;require DBD::Pg;1};
my ($user,$password,$host,$port,$database)=$url =~ m{\Apostgres(?:ql)?://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/]*)(?::(\d+))?/([^?]+)}
    or plan skip_all=>'PostgreSQL test URL is invalid';
my $dbh=DBI->connect("dbi:Pg:dbname=$database".(length($host)?";host=$host":'').(defined($port)?";port=$port":''),$user,$password,
    {RaiseError=>1,PrintError=>0,AutoCommit=>1});
$dbh->do('CREATE TEMP TABLE security_boundary_parents (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, label TEXT, secret TEXT)');
$dbh->do('CREATE TEMP TABLE security_boundary_children (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL, name TEXT)');
$dbh->do(q{INSERT INTO security_boundary_parents VALUES (1,1,'Public one','secret-one'),(2,2,'Public two','secret-two')});
$dbh->do(q{INSERT INTO security_boundary_children VALUES (13,1,'three'),(11,1,'one'),(12,1,'two'),(22,2,'second'),(21,2,'first')});
my $domain=Selecto::Domain->parse({schema_version=>1,name=>'Live bounded collections',
    source=>{source_table=>'security_boundary_parents',primary_key=>'id',fields=>[qw(id tenant_id label secret)],
        columns=>{id=>{type=>'integer'},tenant_id=>{type=>'integer',internal=>1},label=>{type=>'string'},secret=>{type=>'string',internal=>1}},
        associations=>{children=>{queryable=>'children',owner_key=>'id',related_key=>'parent_id',cardinality=>'many'}}},
    schemas=>{children=>{source_table=>'security_boundary_children',primary_key=>'id',fields=>[qw(id parent_id name)],columns=>{id=>{type=>'integer'},parent_id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}}},
    joins=>{children=>{type=>'left'}},query_library=>{projections=>{public=>{fields=>[qw(id label)]},hidden=>{fields=>[qw(id secret)]}}},
},strict=>1);
{
    package LiveBoundaryAdapter;
    use Mojo::Base 'Selecto::PostgreSQL';
    sub execute_query { my ($self,@args)=@_;++$self->{executions};$self->{last_sql}=$args[0]->sql;return $self->SUPER::execute_query(@args); }
}
my $adapter=LiveBoundaryAdapter->new(dbh=>$dbh);
my $engine=Selecto::Engine->new(domain=>$domain,adapter=>$adapter);
sub code {my ($run)=@_;my $ok=eval {$run->();1};return $ok?'ok':ref($@)&&$@->can('code')?$@->code:"$@";}
my $handler=Selecto::API::EngineHandler->new(default_limit=>2,limits=>Selecto::Limits->new(max_collection_rows=>2,max_total_collection_rows=>4));
is(code(sub {$handler->query($engine,{select=>['id',['children.name']]})}),'related_collection_limit_exceeded','live excess child set is refused');
like($adapter->{last_sql},qr/ORDER BY "c_children"\."id" ASC LIMIT 3/,'live statement limits within child subquery');
$handler=Selecto::API::EngineHandler->new(default_limit=>2,limits=>Selecto::Limits->new(max_collection_rows=>3,max_total_collection_rows=>6));
my $result=$handler->query($engine,{select=>['id',['children.name']],order_by=>[{field=>'id'}]});
is_deeply($result->{rows},[[1,[['one'],['two'],['three']]],[2,[['first'],['second']]]],'each parent collection has independent stable order');
ok($result->{subtables}{children}{complete},'successful live collection reports completeness');
my $scoped=Selecto::Engine->new(domain=>$domain->with_required_predicate(Selecto::Expression->eq('tenant_id',1)),adapter=>$adapter);
$result=$handler->query($scoped,{select=>['id',['children.name']]});
is_deeply([map {$_->[0]} @{$result->{rows}}],[1],'required tenant predicate survives child limiting');
sub source {
    my ($hidden)=@_;
    return Selecto::Domain->parse({schema_version=>1,name=>'Live lookup source',source=>{source_table=>'lookup_source',primary_key=>'id',fields=>['id'],columns=>{id=>{type=>'integer'}},associations=>{}},schemas=>{},joins=>{},co_domains=>{lookup=>{domain=>'parents',projection=>$hidden?'hidden':'public',search=>{fields=>['label'],mode=>'prefix',rank=>1},result=>{value_field=>'id',label_field=>$hidden?'secret':'label'}}}},strict=>1);
}
my $before=$adapter->{executions};
is(code(sub {Selecto::CoDomain->lookup(source_domain=>source(1),engine=>$scoped,co_domain=>'lookup',query=>'Public')}),'invalid_co_domain','live hidden lookup refused');
is($adapter->{executions},$before,'hidden lookup refusal precedes database execution');
my $lookup=Selecto::CoDomain->lookup(source_domain=>source(0),engine=>$scoped,co_domain=>'lookup',query=>'Public');
is_deeply($lookup->{results},[{value=>'1',label=>'Public one'}],'live public lookup keeps tenant scope');
$dbh->disconnect;
done_testing;
