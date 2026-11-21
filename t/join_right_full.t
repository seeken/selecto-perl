use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Storable qw(dclone);
use Selecto;

# Join types right and full, and the join alias key. RIGHT and FULL keep the
# target's unmatched rows: the target's own restrictions (association where,
# tenant bounds) filter it before the join, the adapter must have the join,
# and a bridge or lateral association cannot take one. An alias names the
# join's SQL correlation and must stay distinct.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

{
    package Local::NoFullJoin;
    our @ISA = ('Selecto::SQLite');
    sub supports { my ($self, $feature) = @_; return 0 if $feature eq 'full_join'; return $self->SUPER::supports($feature) }
}

sub domain {
    my (%join) = @_;
    return {schema_version => 1, name => 'Orders',
        source => {source_table => 'oj_orders', primary_key => 'id', fields => [qw(id customer_id tenant_id)],
            tenant_field => 'tenant_id',
            columns => {id => {type => 'integer'}, customer_id => {type => 'integer'}, tenant_id => {type => 'integer'}},
            associations => {customer => {queryable => 'customers', owner_key => 'customer_id', related_key => 'id',
                where => {active => 1}}}},
        schemas => {customers => {source_table => 'oj_customers', primary_key => 'id', fields => [qw(id name active tenant_id)],
            tenant_field => 'tenant_id',
            columns => {id => {type => 'integer'}, name => {type => 'string'}, active => {type => 'integer'},
                tenant_id => {type => 'integer'}}}},
        joins => {customer => {type => 'left', %join}}};
}
sub caught { my ($run) = @_; return eval { $run->(); 1 } ? undef : $@ }

my @backends = (['sqlite', sub { DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0}) }]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '', {RaiseError => 1, PrintError => 0});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "$name rows" => sub {
        my $dbh = $connect->();
        $dbh->do($_) for 'DROP TABLE IF EXISTS oj_orders', 'DROP TABLE IF EXISTS oj_customers',
            'CREATE TABLE oj_orders (id INTEGER PRIMARY KEY, customer_id INTEGER, tenant_id INTEGER)',
            'CREATE TABLE oj_customers (id INTEGER PRIMARY KEY, name TEXT, active INTEGER, tenant_id INTEGER)',
            'INSERT INTO oj_orders VALUES (1, 1, 7), (2, 2, 7), (3, NULL, 7), (4, 9, 7), (5, 1, 8)',
            q{INSERT INTO oj_customers VALUES (1, 'ann', 1, 7), (2, 'bob', 0, 7), (3, 'cy', 1, 7), (4, 'di', 0, 7), (5, 'eve', 1, 8)};
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        # Under a tenant the root's tenant predicate is applied after the
        # join, as any WHERE is: a preserved target row has a NULL root, so
        # it never passes. The target restriction (active) holds either way.
        my %tenant = (
            left => [[1, 'ann'], [2, undef], [3, undef], [4, undef]],
            inner => [[1, 'ann']],
            right => [[1, 'ann']],
            full => [[1, 'ann'], [2, undef], [3, undef], [4, undef]],
        );
        # Without a tenant, unmatched active customers are kept.
        my %open = (
            left => [[1, 'ann'], [2, undef], [3, undef], [4, undef], [5, 'ann']],
            inner => [[1, 'ann'], [5, 'ann']],
            right => [[undef, 'cy'], [undef, 'eve'], [1, 'ann'], [5, 'ann']],
            full => [[undef, 'cy'], [undef, 'eve'], [1, 'ann'], [2, undef], [3, undef], [4, undef], [5, 'ann']],
        );
        my $rows = sub {
            my ($engine) = @_;
            return [sort { ($a->[0] // -1) <=> ($b->[0] // -1) || ($a->[1] // '') cmp ($b->[1] // '') }
                map { [defined($_->[0]) ? 0 + $_->[0] : undef, $_->[1]] }
                @{$engine->all($engine->query->select('id', 'customer.name'))->{rows}}];
        };
        for my $type (qw(left inner right full)) {
            my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(domain(type => $type, alias => 'cust')),
                adapter => $adapter)->with_tenant(7);
            is_deeply($rows->($engine), $tenant{$type}, "$type join under a tenant");
            like($engine->compile($engine->query->select('id', 'customer.name'))->{sql}, qr/AS "cust"/,
                "$type join uses the authored alias");
            my $untenanted = domain(type => $type);
            delete $_->{tenant_field} for $untenanted->{source}, $untenanted->{schemas}{customers};
            my $open = Selecto::Engine->new(domain => Selecto::Domain->parse($untenanted), adapter => $adapter);
            is_deeply($rows->($open), $open{$type}, "$type join without a tenant: inactive customers never appear");
        }
        $dbh->do($_) for 'DROP TABLE oj_orders', 'DROP TABLE oj_customers';
    };
}

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
$dbh->do('CREATE TABLE oj_orders (id INTEGER PRIMARY KEY, customer_id INTEGER, tenant_id INTEGER)');
$dbh->do('CREATE TABLE oj_customers (id INTEGER PRIMARY KEY, name TEXT, active INTEGER, tenant_id INTEGER)');

subtest 'an adapter without the join refuses before SQL' => sub {
    my $statements = 0;
    my $count = sub { $statements++; return };
    my $adapter = bless {%{Selecto->adapter(sqlite => (dbh => $dbh))}}, 'Local::NoFullJoin';
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(domain(type => 'full')), adapter => $adapter)
        ->with_tenant(7);
    local $dbh->{Callbacks} = {prepare => $count, prepare_cached => $count, do => $count};
    my $error = caught(sub { $engine->all($engine->query->select('id', 'customer.name')) });
    is($error && $error->code, 'unsupported_feature', 'FULL JOIN refuses');
    is($statements, 0, 'no statement reached the driver');
    my $right = Selecto::Engine->new(domain => Selecto::Domain->parse(domain(type => 'right')), adapter => $adapter)
        ->with_tenant(7);
    ok(!caught(sub { $right->all($right->query->select('id', 'customer.name')) }), 'RIGHT JOIN still runs');
};

subtest 'domain refusals' => sub {
    my $through = domain(type => 'right');
    $through->{source}{associations}{customer}{through} = {table => 'oj_links', owner_key => 'order_id', related_key => 'customer_id'};
    delete $through->{source}{associations}{customer}{where};
    like(caught(sub { Selecto::Domain->parse($through) })->message, qr/direct association/, 'a right join through a bridge refuses');
    my $lateral = domain(type => 'full');
    $lateral->{source}{associations}{customer}{join_strategy} = 'lateral_lookup';
    like(caught(sub { Selecto::Domain->parse($lateral) })->message, qr/direct association/, 'a full lateral lookup refuses');
    is(caught(sub { Selecto::Domain->parse(domain(type => 'cross')) })->code, 'invalid_domain', 'other join types still refuse');
    is(caught(sub { Selecto::Domain->parse(domain(alias => '__selecto_x')) })->code, 'invalid_domain', 'the reserved prefix refuses');
    is(caught(sub { Selecto::Domain->parse(domain(alias => 'bad alias')) })->code, 'invalid_identifier', 'an alias is an identifier');
    my $twice = domain(alias => 'shared');
    $twice->{source}{associations}{again} = {%{$twice->{source}{associations}{customer}}};
    $twice->{joins}{again} = {type => 'left', alias => 'SHARED'};
    my $error = caught(sub { Selecto::Domain->parse($twice) });
    is($error->code, 'invalid_domain', 'two joins with one alias refuse, ignoring case');
    like($error->message, qr/unique/, 'the message says why');
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(domain(alias => 's0')),
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)))->with_tenant(7);
    is(caught(sub { $engine->compile($engine->query->select('id', 'customer.name')) })->code, 'invalid_domain',
        'an alias equal to the root alias refuses');
};

subtest 'contract and export keep type and alias' => sub {
    my $parsed = Selecto::Domain->parse(domain(type => 'full', alias => 'cust'));
    is_deeply([@{$parsed->as_contract->{joins}{customer}}{qw(type alias)}], ['full', 'cust'], 'as_contract');
    my $keys = Selecto::Domain->contract_keys;
    is_deeply($keys->{join_types}, [qw(left inner star_dimension right full)], 'join types');
    ok((grep { $_ eq 'alias' } @{$keys->{join}}), 'join table lists alias');
};

done_testing;
