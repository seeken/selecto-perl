use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Engine ();
use Selecto::Expression ();

# Lessons 41b and 41f: a tenant-scoped relation reached past an untenanted
# (shared) hop, root(tenant) -> shared bin -> tenant notes, is bounded by
# the root's admitted tenant set, not only by an engine tenant. Pairing is
# per adjacent edge, so with the root bounded only by a required predicate
# (tenant_id IN (7, 8) or = 7, no engine tenant) the notes went unbounded:
# a join path, a filter, the public query route and a retarget to the
# shared bin returned tenant 9's notes. The admitted set is now carried past
# untenanted hops onto later tenant joins, collections, retarget targets and
# members (as IN), and a bounded root whose boundary has no tenant set to
# carry refuses them with missing_tenant_scope.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

my $x = 'Selecto::Expression';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}
sub relation {
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}
# The distinct non-null values of a result column.
sub bodies {
    my ($rows, $index) = @_;
    my %seen = map { defined($_->[$index]) ? ($_->[$index] => 1) : () } @$rows;
    return [sort keys %seen];
}

sub contract {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Customers', domain_version => '1', domain_fingerprint => 'sha256:untenanted-hop-admitted-set',
        source => {%{relation($t->{customers}, id => 'integer', tenant_id => 'integer', bin_id => 'integer', name => 'string')},
            tenant_field => 'tenant_id',
            associations => {bin => {queryable => 'bin', owner_key => 'bin_id', related_key => 'id'}}},
        schemas => {
            bin => {%{relation($t->{bins}, id => 'integer', label => 'string')},
                associations => {
                    notes => {queryable => 'note', owner_key => 'id', related_key => 'bin_id', cardinality => 'many'},
                    tags => {queryable => 'tag', owner_key => 'id', related_key => 'id', cardinality => 'many',
                        through => {table => $t->{bin_tags}, owner_key => 'bin_id', related_key => 'tag_id'}},
                }},
            note => {%{relation($t->{notes}, id => 'integer', bin_id => 'integer', tenant_id => 'integer', body => 'string')},
                tenant_field => 'tenant_id'},
            tag => {%{relation($t->{tags}, id => 'integer', tenant_id => 'integer', label => 'string')}, tenant_field => 'tenant_id'},
        },
        joins => {bin => {type => 'left', joins => {notes => {type => 'left'}, tags => {type => 'left'}}}},
        ($o{required} ? (required_filters => $o{required}) : ())};
}

my $handler = Selecto::API::EngineHandler->new;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "untenanted hops carry the root's admitted set on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l41f_${_}_$suffix") } qw(customers bins notes bin_tags tags);
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, bin_id integer, name text)");
        $dbh->do("CREATE TABLE $t{bins} (id integer primary key, label text)");
        $dbh->do("CREATE TABLE $t{notes} (id integer primary key, bin_id integer, tenant_id integer, body text)");
        $dbh->do("CREATE TABLE $t{bin_tags} (id integer primary key, bin_id integer, tag_id integer)");
        $dbh->do("CREATE TABLE $t{tags} (id integer primary key, tenant_id integer, label text)");
        # One shared bin holds a note and a tag of each tenant.
        $dbh->do("INSERT INTO $t{customers} VALUES (1, 7, 1, 'seven'), (2, 8, 1, 'eight'), (3, 9, 1, 'nine')");
        $dbh->do("INSERT INTO $t{bins} VALUES (1, 'shared bin')");
        $dbh->do("INSERT INTO $t{notes} VALUES (1, 1, 7, 'note seven'), (2, 1, 8, 'note eight'), (3, 1, 9, 'note nine')");
        $dbh->do("INSERT INTO $t{bin_tags} VALUES (1, 1, 1), (2, 1, 2), (3, 1, 3)");
        $dbh->do("INSERT INTO $t{tags} VALUES (1, 7, 'tag seven'), (2, 8, 'tag eight'), (3, 9, 'tag nine')");
        my $engine = sub {
            my (%o) = @_;
            return Selecto::Engine->new(domain => Selecto::Domain->parse(contract(\%t, %o)), adapter => $adapter,
                ($o{tenant} ? (scope => {tenant => $o{tenant}}) : ()));
        };
        my %paths = (
            'join path' => sub { bodies($_[0]->all($_[0]->query->select('id', 'bin.notes.body'))->{rows}, 1) },
            # Tags are named like notes, so one admitted set checks both.
            'through join' => sub { [map { s/tag/note/r } @{bodies($_[0]->all($_[0]->query->select('id', 'bin.tags.label'))->{rows}, 1)}] },
            # A row matching tenant 9's note is the oracle leaking it.
            'filter oracle' => sub { @{$_[0]->all($_[0]->query->select('id')->where($x->eq('bin.notes.body', 'note nine')))->{rows}}
                ? ['note nine'] : [] },
            'public query handler' => sub { bodies($handler->query($_[0], {select => ['id', 'bin.notes.body']})->{rows}, 1) },
            'retarget to the shared bin' => sub { bodies($_[0]->all($_[0]->query->retarget('bin')->select('id', 'notes.body'))->{rows}, 1) },
            'retarget through the shared bin' => sub { bodies($_[0]->all($_[0]->query->retarget('bin.notes')->select('body'))->{rows}, 0) },
            'collection after retarget' => sub {
                my $rows = $_[0]->all($_[0]->query->retarget('bin')->select('id', $x->related_collection('notes', ['body'])->as('n')))->{rows};
                [sort map { my $c = $_->[1]; $c = JSON::PP::decode_json($c) unless ref $c; map { $_->{body} } @$c } @$rows] },
        );
        my @paths = sort keys %paths;

        my %cases = (
            'required IN (7, 8)' => [[required => [['tenant_id', ['in', [7, 8]]]]], ['note eight', 'note seven']],
            'required = 7' => [[required => [['tenant_id', 7]]], ['note seven']],
            'engine tenant 7' => [[tenant => 7], ['note seven']],
            'engine tenant 7 and required IN (7, 8)' => [[tenant => 7, required => [['tenant_id', ['in', [7, 8]]]]], ['note seven']],
        );
        for my $case (sort keys %cases) {
            my ($options, $allowed) = @{$cases{$case}};
            my $e = $engine->(@$options);
            my %allowed = map { ($_ => 1) } @$allowed;
            for my $path (@paths) {
                my $got;
                my $code = code_of(sub { $got = $paths{$path}->($e) });
                is($code, 'ok', "$case: $path reads") or next;
                my @leaked = grep { !$allowed{$_} } @$got;
                is_deeply(\@leaked, [], "$case: $path returns only the admitted tenants' rows");
            }
        }
        my $api = Selecto::API->new(domain => Selecto::Domain->parse(contract(\%t, required => [['tenant_id', ['in', [7, 8]]]])), base_path => '/api');
        my $bounded = $engine->(required => [['tenant_id', ['in', [7, 8]]]]);
        my $response = $api->request({method => 'POST', path => '/api/query', body => {select => ['id', 'bin.notes.body', 'bin.tags.label']}},
            {query => sub { ['ok', $handler->query($bounded, $_[0])] }});
        is($response->{status}, 200, 'the API route answers');
        unlike($response->{body}, qr/nine/, 'the API route never returns tenant 9\'s notes or tags');

        # A bounded root whose boundary carries no tenant set refuses.
        my $by_name = $engine->(required => [['name', 'seven']]);
        is(code_of(sub { $paths{$_}->($by_name) }), 'missing_tenant_scope', "a non-tenant boundary refuses the $_")
            for 'join path', 'retarget to the shared bin', 'retarget through the shared bin';
        is_deeply($by_name->all($by_name->query->select('id', 'bin.label'))->{rows}, [[1, 'shared bin']],
            'and still reads the shared hop itself');

        my $open = $engine->();
        is_deeply($paths{'join path'}->($open), ['note eight', 'note nine', 'note seven'],
            'a root with no boundary still reads every tenant');

        $dbh->do("DROP TABLE $t{$_}") for sort keys %t;
    };
}

done_testing;
