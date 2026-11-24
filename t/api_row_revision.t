use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();
use lib 't/lib';
use TestSavedViews ();

{
    package TestRevisionAPI::SQLite;
    use Mojo::Base 'Selecto::SQLite', -signatures;
    sub execute_query ($self, @args) {
        ++$self->{read_count};
        return $self->SUPER::execute_query(@args);
    }
    sub stream_query ($self, @args) {
        ++$self->{read_count};
        return $self->SUPER::stream_query(@args);
    }
    package TestRevisionAPI::PostgreSQL;
    use Mojo::Base 'Selecto::PostgreSQL', -signatures;
    sub execute_query ($self, @args) {
        ++$self->{read_count};
        return $self->SUPER::execute_query(@args);
    }
    sub stream_query ($self, @args) {
        ++$self->{read_count};
        return $self->SUPER::stream_query(@args);
    }
}

sub guarded {
    my ($work) = @_;
    my $data = eval { $work->() };
    return ['ok', $data] unless $@;
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    # Exercise the API's default status mapping, without a host override.
    return ['error', {code => $error->code, message => $error->message, details => $error->details}];
}

sub declaration {
    my ($revision) = @_;
    return {
        schema_version => 1, domain_version => '1.0.0', name => 'RevisionPanels',
        domain_fingerprint => 'sha256:revision-panels-api',
        source => {source_table => 'sv_api_panels', primary_key => 'id',
            fields => [qw(id name version secret)],
            columns => {id => {type => 'integer'}, name => {type => 'string'},
                version => {type => 'string'}, secret => {type => 'string', internal => 1}},
            associations => {}}, schemas => {},
        writes => {
            (defined($revision) ? (row_revision => $revision) : ()),
            operations => {map { $_ => {enabled => JSON::PP::true} } qw(insert update delete)},
            fields => {id => {insertable => 1}, name => {insertable => 1, updatable => 1},
                version => {insertable => 1, updatable => 1}},
        },
    };
}

for my $backend (grep { $_->[0] eq 'sqlite' || $_->[0] eq 'postgresql' } TestSavedViews->backends) {
    my ($name, $connect) = @$backend;
    subtest "row version API on $name" => sub {
        my $dbh = $connect->();
        $dbh->do('CREATE TABLE sv_api_panels (id INTEGER PRIMARY KEY, name VARCHAR(100), version VARCHAR(100), secret VARCHAR(100))');
        my $class = $name eq 'sqlite' ? 'TestRevisionAPI::SQLite' : 'TestRevisionAPI::PostgreSQL';
        my $adapter = $class->new(dbh => $dbh);
        for my $mode (qw(column columns)) {
            subtest "$mode revision" => sub {
                $dbh->do('DELETE FROM sv_api_panels');
                $dbh->do(q{INSERT INTO sv_api_panels VALUES (1,'First','1','private'), (2,'Second','2','hidden'), (3,'Third','3','hidden')});
                my $revision = {$mode => $mode eq 'column' ? 'version' : [qw(name version secret)], required => JSON::PP::true};
                my $domain = Selecto::Domain->parse(declaration($revision));
                my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
                my $handler = Selecto::API::EngineHandler->new;
                my $api = Selecto::API->new(domain => $domain, base_path => '/api', resources => 1, publish_domain => 1);
                $handler->describe_openapi($api);
                my $call = sub {
                    my ($h, $method, $path, %request) = @_;
                    my $response = $api->request({method => $method, path => $path, %request}, {
                        query => sub { my ($body) = @_; guarded(sub { $h->query($engine, $body) }) },
                        resource => sub { my (undef, $params) = @_; guarded(sub { $h->resource($engine, $params) }) },
                        write => sub { my ($body, $params) = @_; guarded(sub { $h->write($engine, $body, $params) }) },
                    });
                    return ($response, JSON::PP->new->decode($response->{body}));
                };
                my $before = $adapter->{read_count} // 0;
                my ($response, $body) = $call->($handler, GET => '/api/resources/1', fields => 'name');
                is $response->{status}, 200, 'resource succeeds';
                my $token = $body->{data}{row_revision};
                ok defined($token), 'resource contains a revision';
                is $body->{data}{aggregate_version}, $token, 'aggregate_version defaults to the row revision without requesting it';
                is $response->{headers}{etag}, qq{"$token"}, 'the revision is the strong quoted ETag';
                is $adapter->{read_count} - $before, 1, 'resource version uses one SELECT';
                ok !exists($body->{data}{secret}), 'hidden revision input stays private';
                is $token, '1', 'column keeps exact storage token' if $mode eq 'column';
                like $token, qr/\Asha256:[0-9a-f]{64}\z/, 'computed token uses hidden inputs' if $mode eq 'columns';
                for my $bounded (0, 1) {
                    my $reader = Selecto::API::EngineHandler->new(bounded_results => $bounded);
                    for my $format (qw(arrays objects)) {
                        $before = $adapter->{read_count};
                        ($response, $body) = $call->($reader, POST => '/api/query', body => {
                            select => ['name', 'aggregate_version', {field => 'aggregate_version', alias => 'v'}],
                            row_format => $format, order_by => [{field => 'id'}], offset => 1, limit => 1,
                        });
                        is $response->{status}, 200, "$format query succeeds (bounded=$bounded)";
                        is $adapter->{read_count} - $before, 1, 'query versions use one SELECT';
                        is_deeply $body->{data}{columns}, [qw(name aggregate_version v)], 'virtual column and alias replace placeholders';
                        my $revision = $body->{data}{row_revisions}[0];
                        is_deeply $body->{data}{rows}, $format eq 'arrays'
                            ? [['Second', $revision, $revision]]
                            : [{name => 'Second', aggregate_version => $revision, v => $revision, row_revision => $revision}],
                            'versions follow pagination and preserve the requested row format';
                        is scalar(@{$body->{data}{row_revisions}}), 1, 'revision vector excludes lookahead row';
                        ($response, $body) = $call->($reader, POST => '/api/query', body => {select => ['aggregate_version'], limit => 0});
                        is $response->{status}, 200, 'zero-limit version query succeeds';
                        is_deeply $body->{data}{rows}, [], 'zero-limit version query stays empty';
                    }
                }
                ($response, $body) = $call->($handler, POST => '/api/query', body => {
                    select => ['aggregate_version'], filters => [{field => 'id', op => 'eq', value => 999}],
                });
                is $response->{status}, 200, 'empty query with version succeeds';
                is_deeply $body->{data}{rows}, [], 'empty query returns no versions';
                ($response, $body) = $call->($handler, GET => '/api/domain');
                ok $body->{source}{columns}{aggregate_version}{read_only}, 'describe publishes a read-only virtual column';
                ok !$body->{source}{columns}{aggregate_version}{filterable}, 'virtual version cannot be filtered';
                ($response, $body) = $call->($handler, GET => '/api/openapi.json');
                ok scalar(grep { $_->{path} eq 'aggregate_version' } @{$body->{'x-selecto'}{fields}}), 'OpenAPI lists the virtual version';
                is $body->{paths}{'/api/write'}{post}{parameters}[0]{name}, 'If-Match', 'OpenAPI advertises header';
                ok $body->{paths}{'/api/write'}{post}{responses}{412}, 'OpenAPI documents stale status';
                ok $body->{paths}{'/api/write'}{post}{responses}{428}, 'OpenAPI documents missing status';

                my $write = sub {
                    my ($h, $operation, %request) = @_;
                    my $body = {operation => $operation, filters => [{field => 'id', op => 'eq', value => 1}],
                        ($operation eq 'update' ? (assignments => {name => 'Changed', version => '4'}) : ()),
                        %{delete($request{extra_body}) // {}}};
                    return $call->($h, POST => '/api/write', body => $body, %request);
                };
                my $refuse = sub {
                    my ($code, $status, $h, $op, %request) = @_;
                    my ($response, $body) = $write->($h, $op, %request);
                    is $response->{status}, $status, "$code has HTTP $status on $op";
                    is $body->{error}{code}, $code, "$code is named on $op";
                };
                for my $op (qw(update delete)) {
                    $refuse->('row_revision_required', 428, $handler, $op);
                    $refuse->('row_revision_mismatch', 422, $handler, $op,
                        headers => {'If-Match' => qq{"$token"}}, extra_body => {row_revision => 'different'});
                    for my $bad ('*', qq{W/"$token"}, qq{"$token", "$token"}, $token, '""', '"has space"', '"has"quote"', "\"bad\r\nvalue\"", undef, []) {
                        $refuse->('invalid_if_match', 422, $handler, $op, headers => {'If-Match' => $bad});
                    }
                    $refuse->('invalid_if_match', 422, $handler, $op,
                        headers => {'If-Match' => qq{"$token"}, 'if-match' => qq{"$token"}});
                }
                ($response, $body) = $call->($handler, POST => '/api/write',
                    body => {operation => 'insert', assignments => {id => 4, name => 'Fourth'}},
                    headers => {'If-Match' => qq{"$token"}});
                is $body->{error}{code}, 'if_match_not_supported', 'If-Match cannot turn an insert into a revision write';
                ($response, $body) = $call->($handler, POST => '/api/query', body => {
                    select => ['aggregate_version'], group_by => ['id'],
                });
                is $body->{error}{code}, 'invalid_api_query', 'grouped rows cannot publish an individual version';
                is $dbh->selectrow_array('SELECT name FROM sv_api_panels WHERE id=1'), 'First', 'all refused writes preserve row';
                my $version_calls = 0;
                my $versioned = $handler->with_versioner(sub {
                    my ($engine, $keys) = @_;
                    ++$version_calls;
                    return {map { $_ => 'host-v1' } @$keys};
                });
                ($response, $body) = $call->($versioned, GET => '/api/resources/1', fields => 'name,aggregate_version');
                is $body->{data}{aggregate_version}, 'host-v1', 'host versioner overrides row revision';
                is $body->{data}{row_revision}, $token, 'host versioner leaves write revision available';
                is $response->{headers}{etag}, '"host-v1"', 'host versioner controls ETag';
                is $version_calls, 1, 'host versioner called once';
                ($response, $body) = $call->($versioned, GET => '/api/resources/1', fields => 'name');
                ok !exists($body->{data}{aggregate_version}), 'host version remains opt-in';
                ok !exists($response->{headers}{etag}), 'no host ETag unless requested';
                is $version_calls, 1, 'unrequested host version has no lookup';
                ($response, $body) = $call->($versioned, POST => '/api/query', body => {select => ['aggregate_version']});
                is $body->{data}{rows}[0][0], 'host-v1', 'query versioner also wins';
                for my $op (qw(update delete)) {
                    # Even a row-token-looking tag cannot be used under a versioner.
                    $refuse->('if_match_not_supported', 422, $versioned, $op,
                        headers => {'If-Match' => qq{"$token"}}, extra_body => {row_revision => $token});
                }
                ($response, $body) = $write->($handler, 'update', headers => {'iF-mAtCh' => " \t\"$token\"\t "},
                    extra_body => {row_revision => $token});
                is $response->{status}, 200, 'current tag with matching body succeeds, header name is case-insensitive';
                for my $op (qw(update delete)) {
                    $refuse->('stale_revision', 412, $handler, $op, headers => {'If-Match' => qq{"$token"}});
                    $refuse->('stale_revision', 412, $handler, $op, extra_body => {row_revision => $token});
                }
                is $dbh->selectrow_array('SELECT name FROM sv_api_panels WHERE id=1'), 'Changed', 'stale writes preserve winning value';
                ($response, $body) = $call->($handler, GET => '/api/resources/1');
                my $current = $body->{data}{row_revision};
                ($response, $body) = $write->($versioned, 'update', extra_body => {row_revision => $current});
                is $response->{status}, 200, 'host versioner writes still use only body row_revision';
                ($response, $body) = $call->($handler, GET => '/api/resources/1');
                $current = $body->{data}{row_revision};
                ($response, $body) = $write->($handler, 'delete', headers => {'If-Match' => qq{"$current"}});
                is $response->{status}, 200, 'header-only current tag deletes';
                $refuse->('stale_revision', 412, $handler, 'delete', headers => {'If-Match' => qq{"$current"}});
                ($response, $body) = $call->($handler, GET => '/api/resources/1');
                is $response->{status}, 404, 'deleted resource is absent';

                my $optional = Selecto::Engine->new(adapter => $adapter,
                    domain => Selecto::Domain->parse(declaration({%$revision, required => JSON::PP::false})));
                $dbh->do(q{INSERT INTO sv_api_panels VALUES (1,'Optional','1','private')});
                my $intent = {operation => 'update', assignments => {name => 'No token'},
                    filters => [{field => 'id', op => 'eq', value => 1}]};
                is $handler->write($optional, $intent)->{affected_rows}, 1, 'optional omission preserves existing writes';
                my $optional_token = $handler->resource($optional, {id => 1})->{row_revision};
                my $command = $handler->write_command($optional, $intent, {if_match => qq{"$optional_token"}});
                is $command->metadata->{row_revision}, $optional_token, 'write_command accepts the header as governed metadata';
                is $optional->execute_write($command)->affected_rows, 1, 'optional header token executes through the governed path';
                if ($mode eq 'column') {
                    # Reuse the unchanged ETag character rules, including zero,
                    # null, and opaque punctuation that needs no unescaping.
                    for my $case (['0', 1], ['tag,with\\punctuation', 1], ['has space', 0], ['has"quote', 0], [chr(233), 0], [undef, 0]) {
                        my ($value, $safe) = @$case;
                        $dbh->do('UPDATE sv_api_panels SET version=? WHERE id=1', undef, $value);
                        ($response, $body) = $call->($handler, GET => '/api/resources/1');
                        is $response->{status}, 200, 'resource permits an opaque stored revision';
                        is $body->{data}{aggregate_version}, $body->{data}{row_revision}, 'opaque revision reused exactly';
                        is !!exists($response->{headers}{etag}), !!$safe, 'ETag uses existing character rules';
                        next unless $safe;
                        ($response, $body) = $write->($handler, 'update', headers => {'If-Match' => $response->{headers}{etag}},
                            extra_body => {row_revision => $value eq '0' ? 0 : $value});
                        is $response->{status}, 200, 'opaque ETag round-trips without unescaping; numeric zero agrees';
                    }
                    my $plain = Selecto::Engine->new(adapter => $adapter,
                        domain => Selecto::Domain->parse(declaration(undef)));
                    is $handler->write($plain, $intent)->{affected_rows}, 1, 'undeclared domains keep ordinary writes';
                    my $error = eval { $handler->write($plain, $intent, {if_match => '"1"'}); undef } // $@;
                    is $error->code, 'if_match_not_supported', 'undeclared domains refuse If-Match';
                }
            };
        }
        $dbh->do('DROP TABLE sv_api_panels');
        $dbh->disconnect;
    };
}
done_testing;
