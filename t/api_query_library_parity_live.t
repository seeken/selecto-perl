use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::API::EngineHandler ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();

my $database = $ENV{SELECTO_API_TEST_DATABASE};
plan skip_all => 'API PostgreSQL database is not configured' unless defined $database && length $database;
plan skip_all => 'DBD::Pg is not installed' unless eval { require DBI; require DBD::Pg; 1 };
my $dbh = DBI->connect("dbi:Pg:dbname=$database;host=/tmp", undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TEMP TABLE records(id INTEGER PRIMARY KEY,name TEXT,score INTEGER,tenant_id INTEGER)');
$dbh->do(q{INSERT INTO records VALUES(1,'Alpha',10,7),(2,'Other tenant',99,8),(3,'Gamma',30,7),(4,'Delta',20,7)});
my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', domain_fingerprint => 'sha256:query-library-parity', name => 'Records',
    source => {source_table => 'records', primary_key => 'id', fields => [qw(id name score tenant_id)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, score => {type => 'integer'}, tenant_id => {type => 'integer', internal => 1}}, associations => {}},
    schemas => {}, joins => {}, required_selected => ['id'],
    query_library => {
        projections => {identity => {fields => ['name']}, details => {projections => ['identity'], fields => ['score','name']}},
        segments => {
            minimum => {parameters => {min => {type => 'integer', default => 20}}, filters => [['gte','score',['param','min']]]},
            alpha => {filters => [['eq','name','Alpha']]},
            either => {segment_groups => [{operator => 'or', segments => ['minimum','alpha']}]},
            neither => {segment_groups => [{operator => 'nor', segments => ['minimum','alpha']}]},
            not_alpha => {segment_groups => [{operator => 'not', segments => ['alpha']}]},
            xor => {segment_groups => [{operator => 'xor', segments => ['minimum','alpha']}]},
            composed => {segments => ['minimum'], filters => [['lt','score',30]]},
            compare => {filters => [['gt','score',['field','id']]]},
        },
        orderings => {descending => {order_by => [['score','desc'],['id','asc']]}, ascending => {order_by => [['id','asc']]}},
        views => {directory => {projection => 'details', segments => ['minimum'], ordering => 'descending'}},
    },
})->with_required_predicate(Selecto::Expression->eq('tenant_id',7));
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto::PostgreSQL->new(dbh => $dbh));
my $handler = Selecto::API::EngineHandler->new;
for my $case (
    [{view => 'directory'}, [[3,'Gamma',30],[4,'Delta',20]]],
    [{projection => ['identity','details'], segments => ['minimum'], parameters => {min => '25'}}, [[3,'Gamma',30]]],
    [{view => 'directory', segments => ['composed'], parameters => {min => 15}}, [[4,'Delta',20]]],
    [{view => 'directory', order_by => [{field => 'id', direction => 'desc'}]}, [[4,'Delta',20],[3,'Gamma',30]]],
    [{select => ['id'], segments => ['either'], ordering => 'ascending'}, [[1],[3],[4]]],
    [{select => ['id'], segments => ['neither']}, []],
    [{select => ['id'], segments => ['not_alpha'], ordering => 'ascending'}, [[3],[4]]],
    [{select => ['id'], segments => ['xor'], ordering => 'ascending'}, [[1],[3],[4]]],
    [{select => ['id'], segments => ['compare'], ordering => 'ascending'}, [[1],[3],[4]]],
    [{view => 'directory', order_by => [{field => 'id'}]}, [[3,'Gamma',30],[4,'Delta',20]]],
    [{view => 'directory', order_by => [{field => 'id', direction => 'DESC'}]}, [[4,'Delta',20],[3,'Gamma',30]]],
    [{select => ['id'], filters => [{field => 'score', op => 'between', value => 15, end => 25}], order_by => [{field => 'id'}]}, [[4]]],
    [{select => ['id'], filters => [{field => 'name', op => 'not_null'}], order_by => [{field => 'id'}]}, [[1],[3],[4]]],
    [{select => ['id'], filters => [{field => 'name', op => 'IS_NULL'}], order_by => [{field => 'id'}]}, []],
    [{select => ['id'], filters => [{field => 'score', op => 'GTE', value => 20}], order_by => [{field => 'id'}]}, [[3],[4]]],
    [{select => ['name'], order_by => [{field => 'id'}]}, [[1,'Alpha'],[3,'Gamma'],[4,'Delta']]],
    [{view => 'directory', limit => 0}, []],
    [{select => [{field => 'id'},'name'], ordering => 'ascending'}, [[1,'Alpha'],[3,'Gamma'],[4,'Delta']]],
    [{select => ['name',{field => 'id', alias => 'id'}], ordering => 'ascending'}, [[1,'Alpha'],[3,'Gamma'],[4,'Delta']]],
) {
    is_deeply $handler->query($engine,$case->[0])->{rows}, $case->[1], 'native Perl named query baseline';
}
is_deeply $handler->query($engine,{view => 'directory'})->{query_library},
    {segments => ['minimum'], projections => ['identity','details'], projection => 'details', ordering => 'descending', views => ['directory']},
    'applied query-library metadata includes composed definitions';
ok !eval { $handler->query($engine,{view => 'directory', parameters => {unknown => 1}}); 1 }, 'unknown parameters rejected';
ok !eval { $handler->query($engine,{view => 'directory', parameters => {min => 'bad'}}); 1 }, 'invalid typed parameters rejected';
my $hidden = $domain->contract;
$hidden->{query_library}{projections}{hidden} = {fields => ['tenant_id']};
my $hidden_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($hidden), adapter => $engine->adapter);
ok !eval { $handler->query($hidden_engine,{projection => 'hidden'}); 1 }, 'named projection cannot expose internal fields';
$dbh->disconnect;
done_testing;
