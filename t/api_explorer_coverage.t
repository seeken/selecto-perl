use 5.034;
use strict;
use warnings;
use Test::More;
use DBI;
use JSON::PP ();
use Mojo::URL ();
use Selecto;
use Selecto::API::Explorer;

my $json = JSON::PP->new->canonical->utf8;
my ($true, $false) = (JSON::PP::true, JSON::PP::false);
my $native_available = eval {
    unshift @INC, '../selecto-perl-components/lib' if -d '../selecto-perl-components/lib';
    require Selecto::Components::Config;
    require Selecto::Components::Explorer;
    require Mojolicious;
    require Mojolicious::Controller;
    1;
};

sub relation {
    my ($table, $types, %extra) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %$types],
        columns => {map { ($_ => {type => $types->{$_}}) } keys %$types}, associations => {}, %extra};
}

sub exercise {
    my ($backend, $dbh) = @_;
    $dbh->do('CREATE TABLE cov_items (id INTEGER, tenant_id INTEGER, area TEXT, stage TEXT, points INTEGER, due_on DATE, secret TEXT, locked TEXT)');
    $dbh->do('CREATE TABLE cov_notes (id INTEGER, item_id INTEGER, tenant_id INTEGER, kind TEXT, weight INTEGER, secret TEXT)');
    my @items = (
        [1, 1, 'A', 'open', 2, '2026-05-10', 's1', 'x'],
        [2, 1, 'A', 'done', 5, '2026-05-10', 's2', 'x'],
        [3, 1, 'B', 'open', 7, '2026-05-11', 's3', 'x'],
        [4, 1, 'B', undef, 3, '2026-05-10', 's4', 'x'],
        [5, 1, 'A', 'open', 4, '2026-05-10', 's5', 'x'],
        [6, 1, undef, 'done', 6, '2026-05-10', 's6', 'x'],
        [1, 2, 'Z', 'secret-stage', 900, '2026-05-10', 's7', 'x'],
    );
    $dbh->do('INSERT INTO cov_items VALUES (?,?,?,?,?,?,?,?)', undef, @$_) for @items;
    $dbh->do('INSERT INTO cov_notes VALUES (?,?,?,?,?,?)', undef, @$_) for
        [10, 1, 1, 'memo', 2, 'h1'], [11, 1, 1, 'memo', 4, 'h2'], [12, 2, 1, 'mark', 7, 'h3'],
        [13, 3, 1, 'memo', 8, 'h4'], [10, 1, 2, 'private-kind', 900, 'h5'];
    my $document = {schema_version => 1, domain_version => '1', domain_fingerprint => 'sha256:coverage-items', name => 'Coverage items',
        source => relation('cov_items', {id => 'integer', tenant_id => 'integer', area => 'string', stage => 'string',
            points => 'integer', due_on => 'date', secret => 'string', locked => 'string'}, tenant_field => 'tenant_id',
            associations => {notes => {queryable => 'notes', owner_key => 'id', related_key => 'item_id', cardinality => 'many'}}),
        schemas => {notes => relation('cov_notes', {id => 'integer', item_id => 'integer', tenant_id => 'integer',
            kind => 'string', weight => 'integer', secret => 'string'}, tenant_field => 'tenant_id')},
        joins => {notes => {type => 'left'}}, redact_fields => ['secret', 'notes.secret'],
        retarget => {targets => {notes => {label => 'Notes'}}}};
    push @{$document->{source}{fields}}, 'age';
    $document->{source}{columns}{age} = {type => 'integer', computed => {
        kind => 'temporal_delta', from => 'due_on', to => 'now', unit => 'day'}};
    $document->{source}{columns}{locked}{groupable} = $false;
    $document->{source}{columns}{stage}{value_order} = ['open', 'done'];
    $document->{source}{columns}{points}{value_order} = ['7', '2', '3', '4', '5', '6'];
    my $domain = Selecto::Domain->parse($document, strict => 1);
    my $adapter = Selecto->adapter($backend => dbh => $dbh);
    my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter, scope => {tenant => 1});
    my %host = (base_path => '/coverage', id => 'coverage', publication => 'coverage-1', clock => '2026-08-15T00:00:00Z',
        default_limit => 30, count_exact => 1, limits => {max_limit => 100, max_groups => 100, max_buckets => 10});
    my $host = Selecto::API::Explorer->new(%host);
    my $call = sub {
        my ($query, $chosen_host, $chosen_engine) = @_;
        $chosen_host //= $host; $chosen_engine //= $engine;
        my $response = $chosen_host->request($chosen_engine, {method => 'POST', path => '/coverage/explorer-query',
            content_type => 'application/json', body => {format => 'selecto.explorer-query', format_version => 1,
                domain => {fingerprint => $chosen_host->features($chosen_engine)->{domain}{fingerprint}}, query => $query}});
        my $body = $json->decode($response->{body});
        return ($response->{status}, $body);
    };
    my $success = sub {
        my ($query) = @_;
        my ($status, $body) = $call->($query);
        is $status, 200, 'canonical request succeeds' or diag explain $body;
        return $body;
    };
    my $native = sub {
        my (%input) = @_;
        my $config = Selecto::Components::Config->new(id => 'coverage', path => '/coverage-native',
            title => 'Coverage items', engine_factory => sub { $engine },
            measures => [{id => 'n', label => 'N', aggregate => 'count'},
                {id => 'score', label => 'Score', aggregate => 'sum', field => 'points'},
                {id => 'weight', label => 'Weight', aggregate => 'sum', field => 'notes.weight'}]);
        my $controller = Mojolicious::Controller->new(app => Mojolicious->new);
        my $model = Selecto::Components::Explorer->new(config => $config)->model($controller,
            {q => 1, view => 'aggregate', field => ($input{rows_of} && $input{rows_of} ne '-' ? "$input{rows_of}.id" : 'id'), limit => 30, page => 1, measure => 'n', rows_of => '-', %input});
        ok $model->{state}->valid, 'native state valid' or diag explain $model->{state}->errors;
        is $model->{runtime_error}, undef, 'native Explorer executes';
        return $model->{result};
    };
    my $native_rows = sub {
        my ($result) = @_;
        return [map {
            my $record = $_;
            [map { my $c = $_; $c->{measure} ? $record->{$c->{key}}
                : $result->{rollup} && $c->{field} ne '' && $record->{__selecto_rollup_level} == 0 ? undef
                : $record->{$c->{key}} } @{$result->{columns}}];
        } grep { !$_->{__selecto_rollup_continued} } @{$result->{records}}];
    };

    subtest 'publication and optional admission' => sub {
        my $features = $host->features($engine);
        ok $features->{supports}{$_}, "published $_" for qw(as_of retarget pivot subtotal_position);
        is_deeply [map { $_->{path} } @{$features->{retargets}}], ['notes'];
        my %target_fields = map { ($_->{id} => $_) } @{$features->{retargets}[0]{fields}};
        ok !$target_fields{'notes.secret'}, 'retarget catalogue withholds hidden fields';
        ok $target_fields{'notes.kind'}{groupable}, 'retargeted many fields can group at target grain';
        my $openapi = $json->decode($host->request($engine, {method => 'GET', path => '/coverage/openapi.json'})->{body});
        my $props = $openapi->{paths}{'/coverage/explorer-query'}{post}{requestBody}{content}{'application/json'}{schema}{properties}{query}{properties};
        ok exists $props->{$_}, "OpenAPI describes $_" for qw(as_of retarget pivot subtotal_position);
        my %requests = (
            as_of => {select => [{aggregate => 'count', alias => 'n'}], as_of => '2026-05-10'},
            retarget => {select => [{aggregate => 'count', alias => 'n'}], retarget => 'notes'},
            pivot => {select => ['area', 'stage', {aggregate => 'count', alias => 'n'}], group_by => ['area', 'stage'], pivot => {column => 'stage'}},
            subtotal_position => {select => ['area', {aggregate => 'count', alias => 'n'}], group_by => ['area'], rollup => $true, subtotal_position => 'before'},
        );
        for my $flag (sort keys %requests) {
            my $restricted = Selecto::API::Explorer->new(%host, supports => {$flag => 0});
            my ($status, $body) = $call->($requests{$flag}, $restricted);
            is "$status $body->{error}{code}", '501 operation_unsupported', "$flag capability absent";
            isnt $restricted->features($engine)->{revision}, $features->{revision}, 'absence changes revision';
            my $spec = $json->decode($restricted->request($engine, {method => 'GET', path => '/coverage/openapi.json'})->{body});
            is $spec->{paths}{'/coverage/explorer-query'}{post}{requestBody}{content}{'application/json'}{schema}{properties}{query}{properties}{$flag},
                $false, 'OpenAPI refuses unpublished member';
        }
    };
    subtest 'As of including rollup' => sub {
        my $query = {select => ['area', {aggregate => 'count', alias => 'n'}], group_by => ['area'], rollup => $true,
            subtotal_position => 'before', as_of => '2026-05-10',
            filters => [{field => 'due_on', op => 'date_shortcut', value => 'today'}]};
        my $body = $success->($query);
        is $body->{meta}{as_of}, '2026-05-10', 'clock echoed at top-level meta even without request id';
        is_deeply $body->{data}{rows}, [[undef, 5], ['A', 3], ['B', 1], [undef, 1]], 'read clock controls shortcut and total';
        SKIP: {
            skip 'native components not installed', 1 unless $native_available;
            my $result = $native->(group => 'area', as_of => '2026-05-10', filter_field => 'due_on',
                filter_op => 'date_shortcut', filter_value => 'today');
            is_deeply $body->{data}{rows}, $native_rows->($result), 'same As of rollup as native Explorer';
        }
        my $instant = '2026-05-11T00:30:00+02:00';
        my $clock_zone = $backend eq 'postgresql' ? 'America/Denver' : 'UTC';
        my $clocked = $success->({select => ['area', {aggregate => 'sum', field => 'age', alias => 'age_sum'}],
            group_by => ['area'], as_of => $instant, timezone => $clock_zone});
        my $native_clock = $engine->all($engine->query->as_of($instant)->use_timezone($clock_zone)
            ->select('area', Selecto::Expression->sum('age')->as('age_sum'))->group_by('area'))->{rows};
        my $sort_rows = sub { [sort { $json->encode($a) cmp $json->encode($b) } @{$_[0]}] };
        is_deeply $sort_rows->($clocked->{data}{rows}), $sort_rows->($native_clock), 'computed clock also preserves native query timezone';
        is $clocked->{meta}{as_of}, $instant, 'offset timestamp echoed unchanged';
        my $plain = $success->({select => ['area', {aggregate => 'count', alias => 'n'}], group_by => ['area']});
        ok !exists $plain->{meta}, 'omitted clock adds no metadata';
        for my $bad (undef, 'yesterday', '2026-02-30', [], 23, '2026-05-10T25:00:00Z') {
            my ($status, $body) = $call->({%$query, as_of => $bad});
            is "$status $body->{error}{code}", '422 invalid_query', 'invalid clock refused';
        }
    };
    subtest 'retarget preserves context, roles and tenant scope' => sub {
        my $query = {retarget => 'notes', select => ['notes.kind', {aggregate => 'sum', field => 'notes.weight', alias => 'w'}],
            group_by => ['notes.kind'], filters => [{field => 'area', op => 'eq', value => 'A'}]};
        my $body = $success->($query);
        is_deeply $body->{data}{rows}, [['mark', 7], ['memo', 6]], 'target rows grouped under original filter and tenant';
        SKIP: {
            skip 'native components not installed', 1 unless $native_available;
            my $result = $native->(rows_of => 'notes', group => 'notes.kind', measure => 'weight',
                filter_field => 'area', filter_op => 'eq', filter_value => 'A');
            # Native aggregate adds a rollup total by default.
            my $canonical = $success->({%$query, rollup => $true, subtotal_position => 'before'});
            is_deeply $canonical->{data}{rows}, $native_rows->($result), 'same retarget plus group and filter as native Explorer';
        }
        for my $case (
            [{%$query, retarget => 'missing'}, '403 operation_forbidden'],
            [{%$query, retarget => {}}, '422 invalid_query'],
            [{%$query, select => ['notes.secret'], group_by => ['notes.secret']}, '403 hidden_field'],
            [{%$query, select => ['area', {aggregate => 'count', alias => 'n'}], group_by => ['area']}, '422 invalid_query'],
        ) {
            my ($status, $body) = $call->($case->[0]);
            is "$status $body->{error}{code}", $case->[1], 'retarget refusal';
        }
        my $unpublished = $json->decode($json->encode($document)); delete $unpublished->{retarget};
        my $other = Selecto::Engine->new(domain => Selecto::Domain->parse($unpublished), adapter => $adapter, scope => {tenant => 1});
        my ($status, $denied) = $call->($query, undef, $other);
        is "$status $denied->{error}{code}", '403 operation_forbidden', 'native-implicit but unpublished target refused remotely';
    };
    subtest 'subtotal placement and deterministic pages' => sub {
        for my $groups (['area'], ['area', 'stage']) {
            my $query = {select => [@$groups, {aggregate => 'count', alias => 'n'}], group_by => $groups,
                rollup => $true, subtotal_position => 'before'};
            my $all = $success->($query)->{data};
            SKIP: {
                skip 'native components not installed', 1 unless $native_available;
                is_deeply $all->{rows}, $native_rows->($native->(group => $groups)), 'whole subtotal sequence matches native Explorer';
            }
            for my $offset (0 .. @{$all->{rows}}) {
                my $page = $success->({%$query, limit => 2, offset => $offset})->{data};
                my @slice = grep { defined } @{$all->{rows}}[$offset .. $offset + 1];
                is_deeply $page->{rows}, \@slice, 'paged rows slice stable sequence';
                is $page->{page}{has_more}, @{$all->{rows}} > $offset + 2 ? $true : $false, 'stable has_more';
                if ($native_available && $offset % 2 == 0) {
                    my $native_page = $native->(group => $groups, limit => 2, page => 1 + $offset / 2);
                    is_deeply $page->{rows}, $native_rows->($native_page), 'same native page excluding display-only continued headers';
                }
            }
            my $omitted = {%$query}; delete $omitted->{subtotal_position};
            my $after = $success->($omitted)->{data};
            is $after->{row_meta}[-1]{kind}, 'total', 'legacy default totals after children';
            is_deeply $success->({%$omitted, subtotal_position => 'after'})->{data}, $after, 'explicit after preserves legacy result';
            for my $direction (qw(asc desc)) {
                my $ordered = $success->({%$query, order_by => [{field => 'n', direction => $direction}]});
                if ($native_available) {
                    is_deeply $ordered->{data}{rows}, $native_rows->($native->(group => $groups,
                        order => 'measure:n', direction => $direction)), 'explicit subtotal placement admits native measure ordering';
                }
            }
        }
        for my $bad (undef, [], 1, 'middle') {
            my ($status, $body) = $call->({select => ['area', {aggregate => 'count', alias => 'n'}],
                group_by => ['area'], rollup => $true, subtotal_position => $bad});
            is "$status $body->{error}{code}", '422 invalid_query', 'invalid subtotal position refused';
        }
        my ($status, $body) = $call->({select => ['area'], subtotal_position => 'before'});
        is "$status $body->{error}{code}", '422 invalid_query', 'placement requires subtotal mode';
        for my $mode ({cube => $true}, {grouping_sets => [[0, 1], [0], [1], []]}) {
            my $query = {select => ['area', 'stage', {aggregate => 'count', alias => 'n'}], group_by => ['area', 'stage'],
                %$mode, subtotal_position => 'before'};
            my $all = $success->($query)->{data}{rows};
            is_deeply $success->({%$query, offset => 2, limit => 3})->{data}{rows}, [@$all[2 .. 4]], 'cube/sets stable pages';
        }
    };
    subtest 'pivot chosen values, top-N, totals and native columns' => sub {
        my $base = {select => ['area', 'stage', {aggregate => 'count', alias => 'n'}], group_by => ['area', 'stage'],
            rollup => $true, subtotal_position => 'before'};
        my $compare_native = sub {
            my ($body, $result) = @_;
            my $pivot = $result->{pivot_data};
            my @groups = grep { !$_->{measure} } @{$result->{columns}};
            my @measures = grep { $_->{measure} } @{$result->{columns}};
            my @expected;
            for my $record (grep { !$_->{__selecto_rollup_continued} } @{$result->{records}}) {
                my @row = map { $record->{__selecto_rollup_level} == 0 ? undef : $record->{$_->{key}} } @groups;
                my $cells = $pivot->{cells_for}->($record);
                push @row, map { my $column = $_; map { ($cells->{$column->{key}} // {})->{$_->{key}} } @measures } @{$pivot->{columns}};
                push @row, map { $record->{$_->{key}} } @measures if $pivot->{totals};
                push @expected, \@row;
            }
            is_deeply $body->{data}{rows}, \@expected, 'same pivoted rows, cells, subtotals and totals as native Explorer';
            is_deeply [map { $_->{pivot}{other} ? 'Other' : $_->{pivot}{value} }
                grep { $_->{pivot} && !$_->{pivot}{total} } @{$body->{data}{columns}}],
                [map { $_->{value} } @{$pivot->{columns}}], 'same native pivot column order and values';
        };
        for my $chosen (['open', 'done', 'unused'], ['done', 'open']) {
            my $body = $success->({%$base, pivot => {column => 'stage', values => $chosen}});
            SKIP: {
                skip 'native components not installed', 1 unless $native_available;
                my $result = $native->(group => ['area', 'stage'], pivot_column => 'stage',
                    pivot_column_value => $chosen);
                $compare_native->($body, $result);
            }
            is $body->{data}{columns}[1]{pivot}{measure}, 'n', 'column describes source measure';
            is $body->{data}{columns}[-1]{pivot}{total}, $true, 'total columns explicitly identified';
            my $objects = $success->({%$base, pivot => {column => 'stage', values => $chosen}, row_format => 'objects'});
            is_deeply [map { my $row = $_; [map { $row->{$_->{id}} } @{$objects->{data}{columns}}] } @{$objects->{data}{rows}}],
                $body->{data}{rows}, 'object pivot rows use published ids';
        }
        for my $order (qw(rank natural)) {
            my $body = $success->({%$base, pivot => {column => 'stage', top => {limit => 1, measure => 'n', order => $order}, other => $true}});
            SKIP: {
                skip 'native components not installed', 1 unless $native_available;
                $compare_native->($body, $native->(group => ['area', 'stage'], pivot_column => 'stage',
                    pivot_column_top => 1, pivot_column_top_measure => 'n', pivot_column_top_order => $order, pivot_column_other => 1));
            }
        }
        my $retargeted = $success->({retarget => 'notes',
            select => ['notes.weight', 'notes.kind', {aggregate => 'count', alias => 'n'}],
            group_by => ['notes.weight', 'notes.kind'], filters => [{field => 'area', op => 'eq', value => 'A'}],
            rollup => $true, subtotal_position => 'before',
            pivot => {column => 'notes.kind', values => ['memo'], other => $true}});
        is_deeply $retargeted->{data}{rows}, [[undef, 2, 1, 3], [2, 1, undef, 1], [4, 1, undef, 1], [7, undef, 1, 1]],
            'combined retarget and pivot keeps cells at target grain, including unmatched roots';
        my $buckets = $success->({select => ['area', {group => 'score_bins'}, {aggregate => 'count', alias => 'n'}],
            group_by => ['area', {field => 'points', alias => 'score_bins', buckets => {kind => 'numeric',
                ranges => [{min => 0, max => 3, label => '0-3'}, {min => 4, label => '4+'}]}}],
            rollup => $true, subtotal_position => 'before', pivot => {column => 'score_bins'}});
        SKIP: {
            skip 'native components not installed', 1 unless $native_available;
            $compare_native->($buckets, $native->(group => ['area', 'points'], group_format => ['', 'buckets'],
                group_bucket_ranges => ['', '0-3,4+'], pivot_column => 'points'));
        }
        my $numeric = $success->({select => ['area', 'points', {aggregate => 'count', alias => 'n'}],
            group_by => ['area', 'points'], rollup => $true, subtotal_position => 'before', pivot => {column => 'points'}});
        is_deeply [map { $_->{pivot}{value} } grep { $_->{pivot} && !$_->{pivot}{total} } @{$numeric->{data}{columns}}],
            [7, 2, 3, 4, 5, 6], 'numeric axis honors string-valued native value_order metadata';
        my $formatted = $success->({select => ['area', {group => 'year'}, {aggregate => 'count', alias => 'n'}],
            group_by => ['area', {field => 'due_on', alias => 'year', format => 'year'}],
            rollup => $true, subtotal_position => 'before', pivot => {column => 'year'}});
        SKIP: {
            skip 'native components not installed', 1 unless $native_available;
            $compare_native->($formatted, $native->(group => ['area', 'due_on'], group_format => ['', 'year'], pivot_column => 'due_on'));
        }
        my $empty = $success->({%$base, filters => [{field => 'area', op => 'eq', value => 'none'}],
            pivot => {column => 'stage', top => {limit => 1, measure => 'n'}}});
        is_deeply $empty->{data}{rows}, [[undef, 0]], 'empty top-N keeps the empty summary total';
        my $chosen_null = $success->({%$base, pivot => {column => 'stage', values => [undef, 'done'], other => $true, totals => $false}});
        is_deeply $chosen_null->{data}{rows}[0], [undef, 1, 2, 3], 'NULL chosen value and NULL-safe Other exclude selected values';
        my $ordered = $success->({%$base, pivot => {column => 'stage'}});
        is_deeply [map { $_->{pivot}{value} } grep { $_->{pivot} && !$_->{pivot}{total} } @{$ordered->{data}{columns}}],
            ['open', 'done', undef], 'native value_order metadata governs discovered columns';
        my $paged = $success->({%$base, pivot => {column => 'stage'}, limit => 1, offset => 1});
        is_deeply $paged->{data}{columns}, $ordered->{data}{columns}, 'pivot columns independent of page';
        is_deeply $paged->{data}{rows}, [$ordered->{data}{rows}[1]], 'pivot pages ordinary summary rows';
        my $avg = $success->({select => ['area', 'stage', {aggregate => 'avg', field => 'points', alias => 'mean'},
                {aggregate => 'count_distinct', field => 'stage', alias => 'distinct_stages'}], group_by => ['area', 'stage'],
            rollup => $true, subtotal_position => 'before', pivot => {column => 'stage', values => ['open'], other => $true}});
        is 0 + $avg->{data}{rows}[0][-2], 4.5, 'grand average is independently calculated';
        is 0 + $avg->{data}{rows}[0][-1], 2, 'grand distinct count is independently calculated';
        for my $pivot ({column => 'stage', values => []}, {column => 'stage', values => ['open', 'open']},
            {column => 'stage', values => [{}]}, {column => 'stage', top => {limit => 0, measure => 'n'}},
            {column => 'stage', top => {limit => 1, measure => 'missing'}}, {column => 'stage', top => {limit => 1, measure => 'n', order => 'bad'}},
            {column => 'stage', other => $true}, {column => 'stage', totals => 1}, {column => 'missing'},
            {column => 'stage', values => ['open'], top => {limit => 1, measure => 'n'}}) {
            my ($status, $body) = $call->({%$base, pivot => $pivot});
            is $status, 422, 'invalid pivot refused';
        }
        for my $field ('secret', 'locked') {
            my ($status, $body) = $call->({select => ['area', $field, {aggregate => 'count', alias => 'n'}],
                group_by => ['area', $field], pivot => {column => $field}});
            is "$status $body->{error}{code}", $field eq 'secret' ? '403 hidden_field' : '422 invalid_field', 'pivot cannot bypass field grants';
        }
    };
    $dbh->do('DROP TABLE cov_notes');
    $dbh->do('DROP TABLE cov_items');
}

subtest 'SQLite native aggregate coverage' => sub {
    plan skip_all => 'DBD::SQLite required' unless eval { require DBD::SQLite; 1 };
    exercise('sqlite', DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, sqlite_unicode => 1}));
};
subtest 'PostgreSQL native aggregate coverage' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'owned PostgreSQL test URL not configured' unless $url;
    plan skip_all => 'DBD::Pg required' unless eval { require DBD::Pg; 1 };
    my $parsed = Mojo::URL->new($url);
    # The integration fixture must never fall back to a server default.
    die 'coverage tests require the disposable RAM server' unless $parsed->host eq '127.0.0.1' && $parsed->port == 55448;
    my $dbh = DBI->connect('dbi:Pg:host=127.0.0.1;port=55448;dbname=' . substr($parsed->path, 1),
        $parsed->username, $parsed->password, {RaiseError => 1, PrintError => 0});
    $dbh->do('SET client_min_messages TO warning');
    exercise('postgresql', $dbh);
    $dbh->disconnect;
};
done_testing;
