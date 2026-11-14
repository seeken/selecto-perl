use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use Selecto;
use Selecto::API::Explorer;

plan skip_all => 'DBD::SQLite is required' unless eval { require DBD::SQLite; 1 };

my $json = JSON::PP->new->utf8->canonical;
my ($t, $f) = (JSON::PP::true, JSON::PP::false);
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, sqlite_unicode => 1});
$dbh->do('CREATE TABLE ex_tasks (id INTEGER PRIMARY KEY, team_id INTEGER, owner_id INTEGER, title TEXT, state TEXT,
    hours NUMERIC, points INTEGER, done INTEGER, due_on TEXT, started_at TEXT, logged_at TEXT, note TEXT)');
$dbh->do('CREATE TABLE ex_owners (id INTEGER PRIMARY KEY, name TEXT)');
$dbh->do('CREATE TABLE ex_steps (id INTEGER PRIMARY KEY, task_id INTEGER, label TEXT)');
my @tasks = (
    [1, 3, 1, 'Alpha plan', 'open', '1.50', 2, 1, '2026-05-01', '2026-05-01 08:00:00', '2026-05-01T15:00:00Z', 'n1'],
    [2, 3, 1, 'beta 10%', 'open', '2.25', 5, 0, '2026-05-09', '2026-05-09 23:30:00', '2026-05-10T05:30:00Z', 'n2'],
    [3, 3, 2, 'Gamma_x', 'done', undef, 8, 1, '2026-04-20', '2026-04-20 12:00:00', '2026-04-20T18:00:00Z', 'n3'],
    [4, 3, undef, 'alpha review', 'done', '4.00', 1, undef, '2025-12-30', '2025-12-30 07:00:00', '2025-12-30T14:00:00Z', 'n4'],
    [5, 4, 1, 'other team', 'open', '9.00', 3, 1, '2026-05-09', '2026-05-09 10:00:00', '2026-05-09T16:00:00Z', 'n5'],
);
$dbh->do('INSERT INTO ex_tasks VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', undef, @$_) for @tasks;
$dbh->do('INSERT INTO ex_owners VALUES (?,?)', undef, @$_) for [1, 'Ada'], [2, 'Bo'];
$dbh->do('INSERT INTO ex_steps VALUES (?,?,?)', undef, @$_) for [1, 1, 's1'], [2, 1, 's2'], [3, 3, 's3'];

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', domain_fingerprint => 'sha256:explorer-test-v1',
    name => 'Explorer tasks',
    source => {source_table => 'ex_tasks', primary_key => 'id', tenant_field => 'team_id',
        fields => [qw(id team_id owner_id title state hours points done due_on started_at logged_at note)],
        columns => {id => {type => 'integer', nullable => $f}, team_id => {type => 'integer', internal => $t},
            owner_id => {type => 'integer', internal => $t}, title => {type => 'string', nullable => $f, groupable => $f},
            state => {type => 'string', nullable => $f}, hours => {type => 'decimal'}, points => {type => 'integer', nullable => $f},
            done => {type => 'boolean'}, due_on => {type => 'date', nullable => $f},
            started_at => {type => 'naive_datetime', nullable => $f}, logged_at => {type => 'utc_datetime', nullable => $f},
            note => {type => 'string', internal => $t}},
        associations => {owner => {queryable => 'owner', owner_key => 'owner_id', related_key => 'id', cardinality => 'one'},
            steps => {queryable => 'steps', owner_key => 'id', related_key => 'task_id', cardinality => 'many'}}},
    schemas => {owner => {source_table => 'ex_owners', primary_key => 'id', fields => [qw(id name)],
            columns => {id => {type => 'integer', nullable => $f}, name => {type => 'string', nullable => $f}}, associations => {}},
        steps => {source_table => 'ex_steps', primary_key => 'id', fields => [qw(id task_id label)],
            columns => {id => {type => 'integer', nullable => $f}, task_id => {type => 'integer', internal => $t},
                label => {type => 'string', nullable => $f}}, associations => {}}},
    joins => {owner => {type => 'left'}, steps => {type => 'left'}},
    query_library => {segments => {open => {filters => [['eq', 'state', 'open']]},
        noted => {parameters => {n => {type => 'string', required => $t}}, filters => [['eq', 'note', ['param', 'n']]]}}},
}, strict => 1);
my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));
my $engine = Selecto::Engine->new(domain => $domain->with_required_predicate(Selecto::Expression->eq('team_id', 3)),
    adapter => $adapter);
my $unscoped = Selecto::Engine->new(domain => $domain, adapter => $adapter);
my %host = (base_path => '/x/tasks', id => 'tasks', publication => 'pub-1', clock => '2026-05-10T02:00:00Z',
    default_limit => 3, count_exact => 1, collection_limit => 2,
    limits => {max_limit => 10, max_offset => 5, max_select => 6, max_filters => 4, max_filter_depth => 2,
        max_filter_values => 3, max_orders => 2, max_group_by => 2, max_aggregates => 4, max_groups => 8,
        max_result_cells => 12, max_buckets => 3, max_export_rows => 4, max_count_rows => 3});
my $explorer = Selecto::API::Explorer->new(%host);

my $features = $json->decode($explorer->request($engine, {method => 'GET', path => '/x/tasks/explorer-features'})->{body});
sub post {
    my ($query, %options) = @_;
    my $response = $explorer->request($options{engine} // $engine, {method => 'POST', path => '/x/tasks/explorer-query',
        content_type => $options{content_type} // 'application/json', accept => $options{accept},
        body => $options{body} // {format => 'selecto.explorer-query', format_version => 1,
            domain => {fingerprint => $features->{domain}{fingerprint}},
            features => {revision => $features->{revision}}, request_id => 'r1', query => $query}});
    my $body = ($response->{content_type} // '') =~ m{json} ? $json->decode($response->{body}) : $response->{body};
    return ($response->{status}, $body, $response);
}
sub rows { my ($status, $body) = post(@_); return $status == 200 ? $body->{data}{rows} : "$status $body->{error}{code}" }
sub refusal { my ($status, $body) = post(@_); return "$status " . ($body->{error}{code} // '') }

subtest 'features document' => sub {
    is $features->{format}, 'selecto.explorer-features';
    is $features->{domain}{fingerprint}, 'sha256:explorer-test-v1';
    is_deeply [map { $_->{id} } @{$features->{fields}}],
        [qw(done due_on hours id logged_at points started_at state title owner.id owner.name steps.id steps.label)],
        'public fields: root, to-one, then to-many; withheld fields absent';
    my %field = map { ($_->{id} => $_) } @{$features->{fields}};
    is_deeply $field{done}{aggregates}, [qw(count count_distinct true_count false_count true_percentage)];
    is_deeply $field{title}{buckets}, [], 'groupable: false disables buckets';
    is $field{title}{groupable}, $f;
    is $field{'owner.name'}{nullable}, $t, 'to-one fields are nullable';
    is $field{'steps.label'}{collection}, 'steps';
    is $field{'steps.label'}{sortable}, $f;
    is $features->{supports}{timezones}, 'utc', 'SQLite converts instants only to UTC';
    is_deeply $features->{collections}, [{id => 'steps', path => 'steps', label => 'steps', limit => 2}];
    is_deeply $features->{query_library}{segments}, [{name => 'noted', parameters => [{name => 'n', type => 'string', required => $t}]},
        {name => 'open', parameters => []}];
    like $features->{revision}, qr/\Asha256:[0-9a-f]{64}\z/;
    my $again = $json->decode($explorer->request($engine, {method => 'GET', path => '/x/tasks/explorer-features'})->{body});
    is $again->{revision}, $features->{revision}, 'revision is stable';
    my $restricted = Selecto::API::Explorer->new(%host, supports => {rollup => 0});
    isnt $json->decode($restricted->request($engine, {method => 'GET', path => '/x/tasks/explorer-features'})->{body})->{revision},
        $features->{revision}, 'revision changes with supports';
};

subtest 'manifest' => sub {
    my $manifest = $json->decode($explorer->request($engine, {method => 'GET', path => '/x/tasks'})->{body});
    is_deeply $manifest->{profiles}, ['remote_query.v1', 'remote_query.explorer.v1'];
    is_deeply [map { "$_->{method} $_->{path}" } grep { $_->{operation_id} =~ /Explorer/ } @{$manifest->{routes}}],
        ['GET /x/tasks/explorer-features', 'POST /x/tasks/explorer-query'];
};

subtest 'detail' => sub {
    my ($status, $body) = post({select => ['id', 'owner.name', ['steps.label']], order_by => [{field => 'id'}], limit => 2});
    is $status, 200;
    is_deeply $body->{data}{rows}, [[1, 'Ada', [['s1'], ['s2']]], [2, 'Ada', []]];
    is_deeply $body->{data}{page}, {limit => 2, offset => 0, has_more => $t};
    is_deeply $body->{data}{subtables}, {steps => {columns => ['steps.label'], limit => 2, complete => $t}};
    is $body->{meta}{request_id}, 'r1';
    is_deeply rows({select => ['id', {field => 'hours', alias => 'h'}], filters => [{field => 'hours', op => 'gte', value => '2'}],
        row_format => 'objects'}), [{id => 2, h => '2.25'}, {id => 4, h => '4'}], 'objects, decimal strings, team scope';
    is_deeply rows({select => ['id'], filters => [{any => [{field => 'state', op => 'eq', value => 'done'},
        {all => [{field => 'done', op => 'eq', value => $t}, {field => 'points', op => 'lt', value => 3}]}]}]}),
        [[1], [3], [4]], 'nested any/all';
    is_deeply rows({select => ['id'], filters => [{field => 'due_on', op => 'date_shortcut', value => 'today'}]}),
        [], 'today from the trusted clock (UTC)';
    is_deeply rows({select => ['id'], filters => [{field => 'due_on', op => 'date_shortcut', value => 'today'}],
        timezone => 'America/Denver'}), [[2]], 'today in the request zone';
    is_deeply rows({select => ['id'], segments => ['open']}), [[1], [2]], 'segment';
    is_deeply rows({select => ['id', {field => 'started_at', alias => 'd', format => 'day'}], filters => [{field => 'id', op => 'eq', value => 2}]}),
        [[2, '2026-05-09']], 'formatted selection';
    is refusal({select => ['id'], filters => [{field => 'logged_at', op => 'date_shortcut', value => 'today'}],
        timezone => 'America/Denver'}), '501 operation_unsupported', 'a UTC-only host refuses converting instants';
    is_deeply rows({select => ['id'], filters => [{field => 'logged_at', op => 'date_shortcut', value => 'today'}]}),
        [[2]], 'instant shortcuts in UTC';
    my ($count_status, $count) = post({select => ['id'], filters => [{field => 'state', op => 'eq', value => 'open'}], count => 'exact', limit => 1});
    is $count->{data}{total_count}, 2, 'bounded exact count';
    is refusal({select => ['id'], count => 'exact'}), '422 count_unavailable', 'count above max_count_rows';
};

subtest 'text operators' => sub {
    is_deeply rows({select => ['id'], filters => [{field => 'title', op => 'starts_with', value => 'alpha'}]}), [[4]],
        'starts_with is case-sensitive on SQLite';
    is_deeply rows({select => ['id'], filters => [{field => 'title', op => 'starts_with_ci', value => 'alpha'}]}), [[1], [4]];
    is_deeply rows({select => ['id'], filters => [{field => 'title', op => 'text_contains', value => '%'}]}), [[2]];
    is_deeply rows({select => ['id'], filters => [{field => 'title', op => 'text_contains', value => '_'}]}), [[3]];
    is_deeply rows({select => ['id'], filters => [{field => 'title', op => 'ends_with', value => 'Plan'}]}), [];
    is_deeply rows({select => ['id'], filters => [{field => 'title', op => 'ends_with_ci', value => 'PLAN'}]}), [[1]];
};

subtest 'aggregates and groups' => sub {
    is_deeply rows({select => [{aggregate => 'count', alias => 'n'}, {aggregate => 'sum', field => 'hours', alias => 's'},
        {aggregate => 'true_percentage', field => 'done', alias => 'p'}]}), [[4, '7.75', '66.6666666666667']], 'summary';
    is_deeply rows({group_by => ['state'], select => ['state', {aggregate => 'sum', field => 'hours', alias => 'h', ignore_nulls => 'auto'},
        {aggregate => 'true_count', field => 'done', alias => 'y'}]}), [['done', '4', 1], ['open', '3.75', 1]], 'grouped';
    is_deeply rows({group_by => [{field => 'due_on', alias => 'm', format => 'month'}], select => [{group => 'm'},
        {aggregate => 'count', alias => 'n'}], order_by => [{field => 'n', direction => 'desc'}]}),
        [['2026-05', 2], ['2025-12', 1], ['2026-04', 1]], 'formatted groups ordered by an aggregate, then the key';
    is_deeply rows({group_by => [{field => 'points', alias => 'b', buckets => {kind => 'numeric', ranges => [{max => 2, label => 'low'},
        {min => 5, label => 'high'}]}}], select => [{group => 'b'}, {aggregate => 'count', alias => 'n'}]}),
        [['low', 2], ['high', 2]], 'range buckets in range order';
    is_deeply rows({group_by => [{field => 'due_on', alias => 'b', buckets => {kind => 'elapsed_days', ranges => [{max => 0, label => 'today'},
        {min => 1, label => 'past'}]}}], select => [{group => 'b'}, {aggregate => 'count', alias => 'n'}], timezone => 'America/Denver'}),
        [['today', 1], ['past', 3]], 'elapsed days from the trusted clock';
    is_deeply rows({group_by => [{field => 'points', alias => 'b', buckets => {kind => 'numeric', step => 4}}],
        select => [{group => 'b'}, {aggregate => 'count', alias => 'n'}]}), [['0-3', 2], ['4-7', 1], ['8-11', 1]], 'steps';
    is_deeply rows({select => [{aggregate => 'bucket_count', field => 'points', alias => 'c',
        buckets => {kind => 'numeric', ranges => [{max => 4, label => 'a'}, {min => 2, label => 'b'}]}}]}), [[2, 3]], 'bucket_count';
    my ($status, $body) = post({group_by => ['state', 'done'], select => ['state', 'done', {aggregate => 'count', alias => 'n'}],
        rollup => $t, limit => 10});
    is_deeply $body->{data}{rows}, [['done', undef, 1], ['done', $t, 1], ['done', undef, 2], ['open', $f, 1], ['open', $t, 1],
        ['open', undef, 2], [undef, undef, 4]], 'rollup in group-path order';
    is_deeply [map { $_->{kind} } @{$body->{data}{row_meta}}], [qw(detail detail subtotal detail detail subtotal total)];
    is_deeply $body->{data}{row_meta}[0]{drilldown}, {column => 'done',
        filters => [{field => 'state', op => 'eq', value => 'done'}, {field => 'done', op => 'is_null'}]};
    is_deeply rows({select => ['id'], filters => $body->{data}{row_meta}[0]{drilldown}{filters}}), [[4]], 'drilldown';
    my ($grid_status, $grid) = post({group_by => ['state', 'done'], select => ['state', 'done', {aggregate => 'count', alias => 'n'}],
        complete => $t, limit => 4});
    is $grid->{data}{complete}, $t;
    is refusal({group_by => ['state', 'done'], select => ['state', 'done', {aggregate => 'count', alias => 'n'}], complete => $t, limit => 3}),
        '422 result_limit_exceeded', 'complete overflow';
};

subtest 'export' => sub {
    my (undef, $plain, $response) = post({select => ['id'], limit => 1}, accept => 'text/csv');
    is $response->{content_type}, 'application/json; charset=utf-8', 'Accept applies only to exports';
    is $plain->{data}{format}, 'selecto.explorer-query-result';
    my ($status, $body, $export) = post({select => ['id', 'title', 'done'], order_by => [{field => 'id'}],
        export => {all_rows => $t, shape => 'rows'}}, accept => 'text/csv');
    is $status, 200;
    is $export->{content_type}, 'text/csv; charset=utf-8';
    is $export->{body}, "id,title,done\r\n1,Alpha plan,true\r\n2,beta 10%,false\r\n3,Gamma_x,true\r\n4,alpha review,\r\n";
    my (undef, undef, $grid) = post({group_by => ['state', 'done'], select => ['state', 'done', {aggregate => 'count', alias => 'n'}],
        export => {all_rows => $t, shape => 'grid'}}, accept => 'application/json');
    is $grid->{body}, '{"data":{"columns":["state","","false","true"],"rows":[["done",1,null,1],["open",null,1,1]]},"ok":true}';
    is refusal({select => ['id'], export => {all_rows => $t}}, accept => 'application/pdf'), '406 response_format_not_acceptable';
};

subtest 'refusal order' => sub {
    is refusal({select => ['id']}, body => []), '400 malformed_request';
    is refusal({select => ['id']}, content_type => 'text/plain'), '415 unsupported_media_type';
    is refusal(undef, body => {format => 'selecto.explorer-query', format_version => 1, domain => {fingerprint => 'sha256:old'},
        query => {select => ['id']}}), '409 stale_domain_fingerprint';
    is refusal(undef, body => {format => 'selecto.explorer-query', format_version => 1,
        domain => {fingerprint => $features->{domain}{fingerprint}}, features => {revision => 'sha256:old'},
        query => {select => ['id']}}), '409 stale_explorer_features';
    is refusal({select => ['note']}, engine => $unscoped), '403 operation_forbidden', 'tenant scope before fields';
    is refusal({select => ['id', 'note', 'id'], limit => 99}), '403 hidden_field', 'withheld before shape';
    is refusal({select => ['id'], filters => [{any => [{field => 'state', op => 'eq', value => 'x'},
        {field => 'note', op => 'eq', value => 'n1'}]}]}), '403 hidden_field', 'withheld inside any';
    is refusal({select => ['id', ['steps.task_id']]}), '403 hidden_field', 'withheld child';
    is refusal({select => ['id', 'missing']}), '422 invalid_field';
    is refusal({group_by => ['title'], select => ['title']}), '422 invalid_field', 'groupable: false';
    is refusal({select => ['id'], segments => ['noted'], parameters => {n => 'n1'}}), '403 hidden_field',
        'segment parameter compared with a withheld field';
    is refusal({select => ['id', 'id']}), '422 invalid_query', 'duplicate column';
    is refusal({select => ['id'], limit => 11}), '422 invalid_query';
    is refusal({select => ['id'], having => []}), '422 invalid_query', 'closed query members';
    is refusal({select => ['state', {aggregate => 'count', alias => 'n'}]}), '422 invalid_query', 'ungrouped selection';
    is refusal({group_by => ['state'], select => ['state'], rollup => $t, order_by => [{field => 'state'}]}), '422 invalid_query';
    my $restricted = Selecto::API::Explorer->new(%host, count_exact => 0, supports => {buckets => 0});
    my $rfeatures = $json->decode($restricted->request($engine, {method => 'GET', path => '/x/tasks/explorer-features'})->{body});
    for my $query ({select => ['id'], count => 'exact'}, {group_by => [{field => 'points', alias => 'b',
        buckets => {kind => 'numeric', step => 2}}], select => [{group => 'b'}]}) {
        my $response = $restricted->request($engine, {method => 'POST', path => '/x/tasks/explorer-query',
            content_type => 'application/json', body => {format => 'selecto.explorer-query', format_version => 1,
                domain => {fingerprint => $rfeatures->{domain}{fingerprint}}, query => $query}});
        is $response->{status}, 501, 'unadvertised supports refuse with 501';
    }
    ok !exists $rfeatures->{limits}{max_count_rows}, 'max_count_rows only with count_exact';
};

subtest 'other routes reach remote_query.v1' => sub {
    my $response = $explorer->request($engine, {method => 'POST', path => '/x/tasks/query', content_type => 'application/json',
        body => {format => 'selecto.remote-query', format_version => 1, domain => {fingerprint => $engine->domain->fingerprint},
            query => {select => ['id'], limit => 1}}});
    is $response->{status}, 200;
    is $explorer->request($engine, {method => 'GET', path => '/x/tasks/nope'})->{status}, 404;
};

done_testing;
