use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::API::Explorer;
use lib 't/lib';
use TestSelecto;

# Compilation evidence only. No database driver is executed by this fixture;
# SQLite/PostgreSQL execution and native equivalence live in the coverage test.
{
    package Coverage::CompileEngine;
    use parent 'Selecto::Engine';
    our @statements;
    sub all {
        my ($self, $query) = @_;
        my $statement = $self->compile($query);
        push @statements, $statement;
        my @values = map {
            $_->kind eq 'field' ? ($_->arguments->[0] =~ /area/ ? 'A' : 'open') : 1
        } @{$query->selections};
        return {columns => $statement->columns, rows => [\@values]};
    }
}
my $json = JSON::PP->new->canonical;
my $true = JSON::PP::true;
my $domain = Selecto::Domain->parse({schema_version => 1, domain_version => '1', domain_fingerprint => 'sha256:dialect-coverage',
    name => 'Dialect items', source => {source_table => 'dialect_items', primary_key => 'id',
        fields => [qw(id area stage points day)], columns => {id => {type => 'integer'}, area => {type => 'string'},
            stage => {type => 'string'}, points => {type => 'integer'}, day => {type => 'date'}},
        associations => {notes => {queryable => 'notes', owner_key => 'id', related_key => 'item_id', cardinality => 'many'}}},
    schemas => {notes => {source_table => 'dialect_notes', primary_key => 'id', fields => [qw(id item_id area stage)],
        columns => {id => {type => 'integer'}, item_id => {type => 'integer'}, area => {type => 'string'}, stage => {type => 'string'}}, associations => {}}},
    joins => {}, retarget => {targets => {notes => {}}}});
for my $backend (qw(postgresql sqlite mysql mariadb duckdb)) {
    subtest "$backend compiles every extended aggregate path" => sub {
        my $engine = Coverage::CompileEngine->new(domain => $domain,
            adapter => Selecto->adapter($backend => dbh => TestSelecto::DBH->new));
        my $host = Selecto::API::Explorer->new(base_path => '/dialects', id => 'dialects', publication => 'one',
            clock => '2026-05-10T00:00:00Z');
        @Coverage::CompileEngine::statements = ();
        my $post = sub {
            my ($query) = @_;
            my $response = $host->request($engine, {method => 'POST', path => '/dialects/explorer-query',
                content_type => 'application/json', body => {format => 'selecto.explorer-query', format_version => 1,
                    domain => {fingerprint => 'sha256:dialect-coverage'}, query => $query}});
            is $response->{status}, 200, 'extended request compiles' or diag $response->{body};
            return $json->decode($response->{body});
        };
        my $base = {select => ['area', 'stage', {aggregate => 'count', alias => 'n'}], group_by => ['area', 'stage'],
            rollup => $true, subtotal_position => 'before', as_of => '2026-05-10',
            filters => [{field => 'day', op => 'date_shortcut', value => 'today'}]};
        my $all = $post->($base);
        is_deeply $post->({%$base, limit => 1, offset => 1})->{data}{rows}, [$all->{data}{rows}[1]], 'subtotal paging is dialect-independent';
        $post->({%$base, pivot => {column => 'stage', values => ['open'], other => $true}});
        $post->({%$base, pivot => {column => 'stage', top => {limit => 1, measure => 'n'}, other => $true}});
        $post->({select => ['notes.area', 'notes.stage', {aggregate => 'count', alias => 'n'}], group_by => ['notes.area', 'notes.stage'],
            filters => [{field => 'area', op => 'eq', value => 'A'}], retarget => 'notes',
            rollup => $true, subtotal_position => 'before', pivot => {column => 'notes.stage', values => ['open']}});
        ok @Coverage::CompileEngine::statements > 10, 'compiled grouped, context and per-value statements';
        ok !(grep { $_->sql =~ /2026-05-10|\x27open\x27/ } @Coverage::CompileEngine::statements), 'clock bounds and pivot values stay bound';
        ok scalar(grep { $_->sql =~ /dialect_notes/ && $_->sql =~ /dialect_items/ } @Coverage::CompileEngine::statements),
            'target statements retain original context relation';
        ok scalar(grep { grep { defined($_) && $_ eq 'open' } @{$_->params} } @Coverage::CompileEngine::statements),
            'cell predicates actually compiled';
    };
}
done_testing;
