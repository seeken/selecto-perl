use 5.034;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP ();
use Storable qw(dclone);
use Scalar::Util qw(refaddr);
use DBI;
use Selecto::Domain;
use Selecto::DomainCatalog;
use Selecto::DomainCatalog::Source::Code;
use Selecto::DomainCatalog::Source::File;
use Selecto::DomainCatalog::Source::Store;
use Selecto::DomainCatalog::MemoryStore;
use Selecto::Expression;
use Selecto::SQLite;
use Selecto::Engine;
use Selecto::Query;

sub contract {
    my ($id) = @_;
    return {
        schema_version => 1, domain_version => '1', name => 'Orders',
        source => {source_table => 'orders', primary_key => 'id',
            fields => [qw(id account_id state private_note secret)],
            columns => {id => {type => 'integer'}, account_id => {type => 'integer'},
                state => {type => 'string'}, private_note => {type => 'string', hidden => 1},
                secret => {type => 'string', redacted => 1}}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1, require_filter => 1}},
            fields => {state => {updatable => 1}}},
        actions => {finish => {label => 'Finish', type => 'bulk_action', scope => 'bulk',
            capability => 'orders.finish', execution => {kind => 'updato', operation => 'update',
                set => {state => 'done'}}}},
        capabilities => {'orders.finish' => {operations => ['action', 'update'], action => 'finish'}},
        extensions => {catalog => {id => $id, adapter => 'sqlite', scope_policy => 'by_account'},
            authorization => {field_groups => {account => {tag => 'orders.account',
                label => 'Account', fields => ['account_id']}}}},
    };
}

my $json = JSON::PP->new->canonical->utf8;
sub write_file {
    my ($path, $document) = @_;
    open(my $file, '>:raw', $path) or die $!;
    print {$file} $json->encode($document);
    close($file) or die $!;
}
sub policy { return {required_predicate => Selecto::Expression->eq('account_id', 11)} }
sub catalog {
    return Selecto::DomainCatalog->new(adapter => 'sqlite', allowed_sources => ['orders'],
        scope_policies => {by_account => \&policy}, @_);
}
sub failed_check {
    my ($report, $stage, $code) = @_;
    return scalar grep { $_->{stage} eq $stage && $_->{status} eq 'refused'
        && (!$code || $_->{code} eq $code) && $_->{path} =~ /^\$/ } @{$report->{checks}};
}
sub error_code {
    my ($callback) = @_;
    eval { $callback->(); 1 };
    return ref($@) ? $@->code : "$@";
}

my $directory = abs_path(tempdir(CLEANUP => 1));
write_file("$directory/orders.json", contract('file_orders'));
my $store = Selecto::DomainCatalog::MemoryStore->new->put('orders-key', 'r1', contract('store_orders'));
my $calls = 0;
my $direct = Selecto::Domain->parse(contract('code_orders'), strict => 1);
my $code = Selecto::DomainCatalog::Source::Code->new(label => 'orders registry',
    domains => {code_orders => sub { ++$calls; $direct }});
my $files = Selecto::DomainCatalog::Source::File->new(directory => $directory, commit => 'abc123');
my $stored = Selecto::DomainCatalog::Source::Store->new(store => $store, label => 'reference');
my $catalog = catalog(sources => [$code, $files, $stored]);
{
    no warnings 'redefine';
    local *Selecto::Engine::new = sub { die 'listing built an engine' };
    is_deeply([map { $_->{id} } @{$catalog->list}], [qw(code_orders file_orders store_orders)],
        'three kinds list together without engines');
}
is($calls, 1, 'code factory is evaluated once');
is($catalog->list->[1]{source}{ref}{commit}, 'abc123', 'file commit provenance retained');
is($catalog->list->[2]{source}{ref}{revision}, 'r1', 'store revision retained');
is($catalog->get('code_orders')->fingerprint, $direct->fingerprint, 'code-built identity preserved');
for my $id (qw(code_orders file_orders store_orders)) {
    my $entry = (grep { $_->{id} eq $id } @{$catalog->list})[0];
    my $parsed = Selecto::Domain->parse($catalog->document($id), strict => 1);
    is($entry->{fingerprint}, $parsed->fingerprint, "$id metadata and canonical document agree");
    is($entry->{fingerprint}, Selecto::Domain->parse(contract($id))->fingerprint,
        "$id has the directly parsed portable fingerprint");
    is(refaddr($catalog->get($id)), refaddr($catalog->get($id)), "$id returns a cached domain");
    is($catalog->report($id)->{status}, 'ok', "$id static report passes");
}
is($calls, 1, 'get and report do not rebuild code factories');
my $reports = $catalog->report_all;
is(scalar @$reports, 3, 'report_all covers all domains');
ok($json->encode($reports), 'reports are JSON-ready');
my $duplicate = Selecto::DomainCatalog::Source::Code->new(label => 'second registry',
    domains => {file_orders => sub { contract('file_orders') }});
eval { catalog(sources => [$files, $duplicate]) };
is($@->code, 'duplicate_domain', 'duplicate id refused at construction');
is_deeply([map { $_->{kind} } @{$@->details->{sources}}], ['file', 'code'], 'duplicate identifies both kinds');
is($@->details->{sources}[1]{ref}{label}, 'second registry', 'duplicate identifies code label');
is($@->details->{sources}[0]{ref}{path}, "$directory/orders.json", 'duplicate identifies file path');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
$dbh->do('CREATE TABLE orders (id INTEGER PRIMARY KEY, account_id INTEGER, state TEXT, private_note TEXT, secret TEXT)');
$dbh->do("INSERT INTO orders VALUES (1, 11, 'open', '', ''), (2, 22, 'open', '', '')");
my $engine = Selecto::Engine->new(domain => $catalog->get('file_orders'), adapter => Selecto::SQLite->new(dbh => $dbh));
my $result = $engine->all(Selecto::Query->new->select('id'));
is_deeply($result->{rows}, [[1]], 'named host policy constrains real SQLite reads');
my $unscoped = Selecto::Engine->new(domain => $catalog->get('code_orders'), adapter => Selecto::SQLite->new(dbh => $dbh));
is_deeply($unscoped->all(Selecto::Query->new->select('id'))->{rows}, [[1], [2]], 'code domain scope remains unchanged');

for my $case (
    ['required predicate', sub { $_[0]{required_predicate} = ['eq', 'account_id', 22] }, 'scope_policy', 'document_scope_forbidden'],
    ['required filters', sub { $_[0]{required_filters} = [['account_id', 22]] }, 'scope_policy', 'document_scope_forbidden'],
    ['tenant field', sub { $_[0]{source}{tenant_field} = 'account_id' }, 'scope_policy', 'document_scope_forbidden'],
    ['tenant binding', sub { $_[0]{writes}{scope} = {tenant => {field => 'account_id'}} }, 'scope_policy', 'document_scope_forbidden'],
    ['schema 2 tenant', sub { $_[0]{tenant} = {field => 'account_id'} }, 'scope_policy', 'document_scope_forbidden'],
    ['unknown policy', sub { $_[0]{extensions}{catalog}{scope_policy} = 'unknown' }, 'scope_policy', 'unknown_scope_policy'],
    ['outside source', sub { $_[0]{source}{source_table} = 'notes' }, 'allowed_sources', 'source_not_allowed'],
    ['unknown top-level', sub { $_[0]{unexpected} = 1 }, 'strict_parse', 'unknown_domain_key'],
    ['unknown adapter', sub { $_[0]{extensions}{catalog}{adapter} = 'absent' }, 'engine_admission', 'unknown_adapter'],
    ['invalid segment', sub { $_[0]{query_library} = {segments => {open => {filters => [['eq', 'absent', 'open']]}}} },
        'query_library', 'invalid_query_library'],
) {
    my ($name, $mutate, $stage, $code) = @$case;
    my $document = contract('file_orders'); $mutate->($document);
    write_file("$directory/orders.json", $document);
    my $report = $catalog->report('file_orders');
    is($report->{status}, 'refused', "$name refused");
    ok(failed_check($report, $stage, $code), "$name has a stage, code and JSON path");
    is(error_code(sub { $catalog->get('file_orders') }), 'catalog_domain_refused', "$name cannot be served");
}
my $joined = contract('file_orders');
$joined->{source}{associations}{customer} = {queryable => 'customers', owner_key => 'id', related_key => 'id', cardinality => 'one'};
$joined->{schemas}{customers} = {source_table => 'customers', primary_key => 'id', fields => ['id'],
    columns => {id => {type => 'integer'}}, associations => {}};
$joined->{joins}{customer} = {source => 'customers', type => 'left'};
write_file("$directory/orders.json", $joined);
my $join_report = $catalog->report('file_orders');
ok(failed_check($join_report, 'allowed_sources', 'source_not_allowed'), 'joined source outside allowlist refused');
ok(grep($_->{path} eq '$.schemas.customers.source_table', @{$join_report->{checks}}), 'joined refusal names schema source');
write_file("$directory/orders.json", contract('file_orders'));
my $bad_policy = catalog(sources => [$files], scope_policies => {by_account => sub { {} }});
ok(failed_check($bad_policy->report('file_orders'), 'scope_policy', 'invalid_scope_policy'), 'policy must return an actual predicate');
my $warning = catalog(sources => [$files], checks => [sub {
    my ($domain, $entry) = @_;
    return [{status => 'warning', code => 'host_review', message => 'Review the declaration', path => '$.actions'}];
}]);
is($warning->report('file_orders')->{status}, 'warning', 'host warnings affect aggregate status');
isa_ok($warning->get('file_orders'), 'Selecto::Domain', 'warning can still be served');
my $host_failure = catalog(sources => [$files], checks => [sub {
    return [{status => 'refused', code => 'host_refused', message => 'Host refused this declaration', path => '$.actions'}];
}]);
ok(failed_check($host_failure->report('file_orders'), 'host', 'host_refused'), 'host failure retained');
is(error_code(sub { $host_failure->get('file_orders') }), 'catalog_domain_refused', 'host failure prevents serving');
my $exception = catalog(sources => [$files], checks => [sub { die 'sensitive-example-value' }]);
unlike($json->encode($exception->report('file_orders')), qr/sensitive-example-value/, 'host exception text redacted');

my $old = contract('file_orders');
my $fingerprint = Selecto::Domain->parse($old)->fingerprint;
my $pinned = catalog(sources => [$files], pins => {file_orders => {fingerprint => $fingerprint}});
my $changed = dclone($old);
$changed->{source}{fields} = [@{$changed->{source}{fields}}, 'priority'];
$changed->{source}{columns}{priority} = {type => 'integer'};
delete $changed->{actions}{finish};
delete $changed->{capabilities}{'orders.finish'};
$changed->{extensions}{authorization}{field_groups}{account}{tag} = 'orders.account.review';
write_file("$directory/orders.json", $changed);
my $changed_report = $pinned->report('file_orders');
is($changed_report->{status}, 'changed', 'pin mismatch is visible separately from validation');
is($changed_report->{validation_status}, 'ok', 'changed current declaration can be otherwise valid');
is_deeply($changed_report->{diff}{fields}{added}, [{name => 'priority', path => '$.source.columns.priority'}], 'diff names added field');
is($changed_report->{diff}{actions}{removed}[0]{name}, 'finish', 'diff names removed action');
is_deeply($changed_report->{diff}{authorization}{changed}[0], {
    name => 'field_groups.account', path => '$.extensions.authorization.field_groups.account',
    changes => ['$.extensions.authorization.field_groups.account.tag']}, 'diff names changed field group and member');
is($pinned->list->[0]{status}, 'changed', 'list exposes mismatch');
is_deeply($pinned->list->[0]{diff}, $changed_report->{diff}, 'list includes structured pin diff');
ok(!exists($pinned->get('file_orders')->fields->{priority}), 'get keeps serving retained file pin');
is(Selecto::Domain->parse($pinned->document('file_orders'))->fingerprint, $fingerprint, 'document returns served pinned version');
my $restarted = catalog(sources => [$files], pins => {file_orders => {fingerprint => $fingerprint, document => $old}});
ok(!exists($restarted->get('file_orders')->fields->{priority}), 'explicit document restores file pin after restart');
my $unavailable = catalog(sources => [$files], pins => {file_orders => {fingerprint => $fingerprint}});
is(error_code(sub { $unavailable->get('file_orders') }), 'catalog_pin_unavailable', 'missing file pin refuses serving');
is($unavailable->report('file_orders')->{status}, 'changed', 'unavailable baseline still reports mismatch');
is_deeply($catalog->report('file_orders', against => $old)->{diff}, $changed_report->{diff}, 'explicit earlier document uses same diff');
is_deeply($pinned->report('file_orders', against => $fingerprint)->{diff}, $changed_report->{diff}, 'retained fingerprint resolves baseline');
is(error_code(sub { $catalog->report('file_orders', against => 'unseen') }), 'catalog_baseline_missing', 'unknown baseline is explicit');

my $store_old = contract('store_orders');
my $store_pin = Selecto::Domain->parse($store_old)->fingerprint;
my $store_new = dclone($store_old); $store_new->{domain_version} = '2';
$store->put('orders-key', 'r2', $store_new);
my $store_catalog = catalog(sources => [$stored], pins => {store_orders => {fingerprint => $store_pin, revision => 'r1'}});
is($store_catalog->report('store_orders')->{status}, 'changed', 'store pin detects current revision change');
is($json->decode($store_catalog->document('store_orders'))->{domain_version}, '1', 'store serves pinned immutable revision');
is(error_code(sub { $store->put('orders-key', 'r1', $store_new) }), 'immutable_revision', 'memory store refuses revision overwrite');
my $copy = $store->fetch('orders-key', 'r1'); $copy->{name} = 'Changed';
is($store->fetch('orders-key', 'r1')->{name}, 'Orders', 'store fetch isolates containers');

my $surface = $direct->authorization_surface;
is_deeply($surface->{surfaces}, [{kind => 'read'}, {kind => 'write', operations => ['update']}, {kind => 'action'}], 'authorization surfaces describe enabled operations');
is_deeply($surface->{actions}, [{id => 'finish', label => 'Finish', capability => 'orders.finish', scope => 'bulk'}], 'action capability and scope described');
is_deeply($surface->{field_groups}, [{key => 'account', tag => 'orders.account', label => 'Account', fields => ['account_id']}], 'field group metadata described');
is_deeply($surface->{fields}, {hidden => ['private_note'], internal => ['secret'], redacted => ['secret']}, 'marked fields contain names only');
ok($json->encode($surface), 'authorization surface is JSON-ready');
$surface->{field_groups}[0]{fields}[0] = 'changed';
is($direct->authorization_surface->{field_groups}[0]{fields}[0], 'account_id', 'authorization output is isolated');
my $read_only = contract('read_only'); delete @$read_only{qw(writes actions capabilities)};
is_deeply(Selecto::Domain->parse($read_only)->authorization_surface->{surfaces}, [{kind => 'read'}], 'read-only domain only declares read');

{
    my $parse_calls = 0;
    my $parse = \&Selecto::Domain::parse;
    no warnings 'redefine';
    local *Selecto::Domain::parse = sub { ++$parse_calls; goto &$parse };
    my $once = catalog(sources => [Selecto::DomainCatalog::Source::Code->new(domains => {orders => sub { contract('orders') }})]);
    $once->list; $once->get('orders'); $once->document('orders'); $once->report_all;
    is($parse_calls, 1, 'same contract is strictly parsed once');
}

my $same_contract = contract('same_orders');
my $same_store = Selecto::DomainCatalog::MemoryStore->new->put('same', 'one', $json->encode($same_contract));
my $same_directory = abs_path(tempdir(CLEANUP => 1));
write_file("$same_directory/orders.json", $same_contract);
my @equivalent_sources = (
    Selecto::DomainCatalog::Source::Code->new(domains => {same_orders => sub { $same_contract }}),
    Selecto::DomainCatalog::Source::File->new(directory => $same_directory),
    Selecto::DomainCatalog::Source::Store->new(store => $same_store),
);
my @equivalent = map { catalog(sources => [$_]) } @equivalent_sources;
is_deeply([map { $_->document('same_orders') } @equivalent],
    [($equivalent[0]->document('same_orders')) x 3], 'canonical document is identical for all source kinds');
is_deeply([map { $_->list->[0]{fingerprint} } @equivalent],
    [($equivalent[0]->list->[0]{fingerprint}) x 3], 'identity is independent of source kind');

my $bad_store_doc = contract('store_refused');
$bad_store_doc->{source}{tenant_field} = 'account_id';
my $bad_store = Selecto::DomainCatalog::MemoryStore->new->put('refused', 'one', $bad_store_doc);
my $bad_store_catalog = catalog(sources => [Selecto::DomainCatalog::Source::Store->new(store => $bad_store)]);
ok(failed_check($bad_store_catalog->report('store_refused'), 'scope_policy', 'document_scope_forbidden'),
    'store documents use the same safety boundary');

my $duck_document = contract('duck_orders');
$duck_document->{extensions}{catalog}{adapter} = 'duckdb';
$duck_document->{writes}{row_revision} = {column => 'id'};
my $duck_catalog = catalog(sources => [Selecto::DomainCatalog::Source::Code->new(
    domains => {duck_orders => sub { $duck_document }})]);
ok(failed_check($duck_catalog->report('duck_orders'), 'engine_admission', 'write_capability_missing'),
    'static adapter admission refuses unsupported DuckDB writes without a database');

my $broken_directory = abs_path(tempdir(CLEANUP => 1));
open(my $broken_file, '>:raw', "$broken_directory/broken.json") or die $!;
print {$broken_file} '{'; close($broken_file);
my $broken_catalog = catalog(sources => [Selecto::DomainCatalog::Source::File->new(directory => $broken_directory)]);
is($broken_catalog->report_all->[0]{status}, 'refused', 'malformed JSON remains reportable');
is($broken_catalog->list->[0]{status}, 'refused', 'malformed JSON cannot look healthy in metadata');
my $factory_failure = catalog(sources => [Selecto::DomainCatalog::Source::Code->new(
    domains => {orders => sub { die 'private-factory-message' }})]);
unlike($json->encode($factory_failure->report('orders')), qr/private-factory-message/, 'factory error is redacted');

my $v2 = {schema_version => 2, name => 'Orders',
    source => {source_table => 'orders', primary_key => 'id', columns => {
        id => {type => 'integer'}, account_id => {type => 'integer'}}}, schemas => {}, joins => {},
    extensions => {catalog => {id => 'v2_orders', adapter => 'sqlite', scope_policy => 'by_account'}}};
my $v2_store = Selecto::DomainCatalog::MemoryStore->new->put('v2', 'one', $v2);
my $v2_catalog = catalog(sources => [Selecto::DomainCatalog::Source::Store->new(store => $v2_store)]);
is($v2_catalog->report('v2_orders')->{status}, 'ok', 'schema 2 reuses strict parser');
is(Selecto::Domain->parse($v2_catalog->document('v2_orders'))->fingerprint,
    Selecto::Domain->parse($v2)->fingerprint, 'schema 2 document preserves its computed identity');

my $marked = dclone($joined);
$marked->{schemas}{customers}{columns}{id}{internal} = 1;
is_deeply(Selecto::Domain->parse($marked)->authorization_surface->{fields}{internal},
    ['secret', 'customer.id'], 'associated internal fields use public dotted paths');

my $diff_before = contract('diff_orders');
my $diff_after = dclone($diff_before);
$diff_after->{source}{columns}{state}{description} = 'A revised description';
$diff_after->{source}{associations}{customer} = {queryable => 'customers'};
$diff_after->{joins}{customer} = {type => 'left', joins => {notes => {type => 'inner'}}};
$diff_after->{writes}{fields}{state}{updatable} = 0;
$diff_after->{query_library}{segments}{open} = {filters => [['eq', 'state', 'private-literal']]};
my $diff = Selecto::DomainCatalog::Diff->compare($diff_before, $diff_after);
is($diff->{fields}{changed}[0]{name}, 'state', 'diff names changed field');
is($diff->{associations}{added}[0]{name}, 'customer', 'diff names added association');
is_deeply([map { $_->{name} } @{$diff->{joins}{added}}], ['customer', 'customer.notes'],
    'diff names every nested join');
is($diff->{writes}{changed}[0]{name}, 'fields.state', 'write changes name the declared write field');
is($diff->{segments}{added}[0]{name}, 'open', 'diff names added segment');
unlike($json->encode($diff), qr/private-literal|revised description/, 'diff does not contain declaration values');

my $extra_finding = catalog(sources => [$files], checks => [sub { return [{
    status => 'ok', code => 'host_ok', message => 'Accepted', path => '$',
    stage => 'spoofed', data => ['private-row-value'],
}] }]);
my $public_findings = $extra_finding->report('file_orders');
is($public_findings->{checks}[-1]{stage}, 'host', 'host cannot replace its finding stage');
unlike($json->encode($public_findings), qr/private-row-value/, 'host finding projection excludes arbitrary payloads');

my $missing_group_shape = contract('group_orders');
$missing_group_shape->{extensions}{authorization}{field_groups}{account}{fields} = {};
is(error_code(sub { Selecto::Domain->parse($missing_group_shape)->authorization_surface }),
    'invalid_authorization_surface', 'malformed field groups refuse public projection');

my $plain_names = contract('file_orders');
$plain_names->{source}{fields} = [@{$plain_names->{source}{fields}}, 'tenant', 'table'];
$plain_names->{source}{columns}{tenant} = {type => 'string'};
$plain_names->{source}{columns}{table} = {type => 'string'};
write_file("$directory/orders.json", $plain_names);
is($catalog->report('file_orders')->{status}, 'ok', 'ordinary field names do not impersonate scope or source declarations');

done_testing;
