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

# Lesson 41e: on a two-column root (source.tenant_field tenant_id,
# writes.scope.tenant site_id) a relation tenanted on site_id pairs by name
# only with a hop chained back to the root's tenant-bound rows: the root, or
# a site_id relation paired with it. A shared hop that merely stores site_id
# is not a pairing source. customers (tenant 7, site 5) -> shared bins (a bin
# at site 7) -> lines on site_id returned tenant 8's site 7 line by join,
# filter, retarget('bin.lines'), retarget('bin') plus lines.code and a
# collection after retarget('bin'); it is now refused with
# missing_tenant_scope, under an engine tenant or a required predicate.

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

sub contract {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Customers', domain_version => '1', domain_fingerprint => 'sha256:shared-hop-site-pairing',
        source => {%{relation($t->{customers}, id => 'integer', tenant_id => 'integer', site_id => 'integer', bin_id => 'integer')},
            tenant_field => 'tenant_id', associations => {
                bin => {queryable => 'bin', owner_key => 'bin_id', related_key => 'id'},
                own_lines => {queryable => 'line', owner_key => 'bin_id', related_key => 'bin_id', cardinality => 'many'},
            }},
        schemas => {
            bin => {%{relation($t->{bins}, id => 'integer', site_id => 'integer', label => 'string')},
                associations => {lines => {queryable => 'line', owner_key => 'id', related_key => 'bin_id', cardinality => 'many',
                    ($o{authored} ? (source_scope_key => 'site_id', target_scope_key => 'site_id') : ())}}},
            line => {%{relation($t->{lines}, id => 'integer', bin_id => 'integer', site_id => 'integer', code => 'string')},
                tenant_field => 'site_id'},
        },
        joins => {bin => {type => 'left', joins => {lines => {type => 'left'}}}, own_lines => {type => 'left'}},
        writes => {operations => {update => {enabled => 1}}, fields => {bin_id => {updatable => 1}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}},
        ($o{required} ? (required_filters => $o{required}) : ())};
}

my $handler = Selecto::API::EngineHandler->new;
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "a shared hop storing site_id is not a pairing source on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l41e_${_}_$suffix") } qw(customers bins lines);
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, site_id integer, bin_id integer)");
        $dbh->do("CREATE TABLE $t{bins} (id integer primary key, site_id integer, label text)");
        $dbh->do("CREATE TABLE $t{lines} (id integer primary key, bin_id integer, site_id integer, code text)");
        # Tenant 7's customer sits at site 5; the shared bin is at site 7,
        # which belongs to tenant 8.
        $dbh->do("INSERT INTO $t{customers} VALUES (1, 7, 5, 1), (2, 8, 7, 1)");
        $dbh->do("INSERT INTO $t{bins} VALUES (1, 7, 'bin at site 7')");
        $dbh->do("INSERT INTO $t{lines} VALUES (1, 1, 7, 'tenant 8 site 7 line'), (2, 1, 5, 'site 5 line')");
        my $engine = sub {
            my (%o) = @_;
            return Selecto::Engine->new(domain => Selecto::Domain->parse(contract(\%t, %o)), adapter => $adapter,
                ($o{tenant} ? (scope => {tenant => $o{tenant}}) : ()));
        };
        my %paths = (
            'join path' => sub { $_[0]->all($_[0]->query->select('id', 'bin.lines.code'))->{rows} },
            'filter oracle' => sub { $_[0]->all($_[0]->query->select('id')->where($x->eq('bin.lines.code', 'tenant 8 site 7 line')))->{rows} },
            'public query handler' => sub { $handler->query($_[0], {select => ['id', 'bin.lines.code']})->{rows} },
            'retarget through the shared bin' => sub { $_[0]->all($_[0]->query->retarget('bin.lines')->select('code'))->{rows} },
            'retarget to the shared bin, joined field' => sub { $_[0]->all($_[0]->query->retarget('bin')->select('id', 'lines.code'))->{rows} },
            'retarget to the shared bin, filter' => sub {
                $_[0]->all($_[0]->query->retarget('bin')->select('id')->where($x->eq('lines.code', 'tenant 8 site 7 line')))->{rows} },
            'collection after retarget' => sub {
                $_[0]->all($_[0]->query->retarget('bin')->select('id', $x->related_collection('lines', ['code'])->as('l')))->{rows} },
        );
        for my $case (
            ['engine tenant 7', tenant => 7],
            ['required tenant_id = 7', required => [['tenant_id', 7]]],
            ['required tenant_id IN (7, 8)', required => [['tenant_id', ['in', [7, 8]]]]],
            ['engine tenant 7, authored site_id pair on the shared hop', tenant => 7, authored => 1],
            ['required tenant_id = 7, authored site_id pair on the shared hop', required => [['tenant_id', 7]], authored => 1],
        ) {
            my ($label, @options) = @$case;
            my $e = $engine->(@options);
            for my $path (sort keys %paths) {
                my $rows;
                my $code = code_of(sub { $rows = $paths{$path}->($e) });
                is($code, 'missing_tenant_scope', "$label: $path is refused")
                    or diag(JSON::PP->new->canonical->encode($rows));
            }
            # The root's own site rows still pair by name with the root.
            is_deeply($e->all($e->query->select('id', 'own_lines.code')->where($x->eq('id', 1)))->{rows}, [[1, 'site 5 line']],
                "$label: a site_id relation paired with the root returns the caller's own site rows");
            is_deeply($e->all($e->query->select('id', 'bin.label')->where($x->eq('id', 1)))->{rows}, [[1, 'bin at site 7']],
                "$label: the shared hop itself is still read");
        }
        my $api = Selecto::API->new(domain => Selecto::Domain->parse(contract(\%t)), base_path => '/api');
        my $scoped = $engine->(tenant => 7);
        my $response = $api->request({method => 'POST', path => '/api/query', body => {select => ['id', 'bin.lines.code']}},
            {query => sub { ['ok', $handler->query($scoped, $_[0])] }});
        isnt($response->{status}, 200, 'the API route refuses the join');
        unlike($response->{body}, qr/tenant 8 site 7 line/, 'and never returns tenant 8\'s line');

        is(scalar @{$paths{'join path'}->($engine->())}, 4, 'a root with no boundary still reads every site');

        $dbh->do("DROP TABLE $t{$_}") for sort keys %t;
    };
}

done_testing;
