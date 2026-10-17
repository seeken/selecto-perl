use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Encode qw(decode);
use JSON::PP ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();

# Canonical export scalars (Engine::all export_scalars => 1) on a live
# PostgreSQL: NUMERIC keeps its column scale, booleans are JSON booleans and
# JSON columns are decoded, while plain results stay exactly as before.

subtest 'adapters without export scalars refuse the option' => sub {
    plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE items (id INTEGER PRIMARY KEY, amount NUMERIC)');
    my $engine = Selecto::Engine->new(
        domain => TestSelecto::writable_domain(name => 'Items', table => 'items',
            fields => {id => 'integer', amount => 'decimal'}),
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)),
    );
    ok(!$engine->adapter->supports('export_scalars'), 'SQLite does not declare export scalars');
    my $error = eval { $engine->all($engine->query->select('id'), export_scalars => 1); 1 } ? undef : $@;
    is($error && $error->code, 'unsupported_feature', 'export_scalars is refused, not ignored');
    is_deeply($engine->all($engine->query->select('id'))->{rows}, [], 'plain all is unchanged');
};

eval { require Selecto::Certification; 1 }
    or do { done_testing; exit 0 };
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
unless (defined($url) && $url ne '' && eval { require DBD::Pg; 1 }) {
    note 'SELECTO_PERL_TEST_POSTGRES_URL or DBD::Pg is not available';
    done_testing;
    exit 0;
}

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
my $dbh = DBI->connect($dsn, $username, $password, {
    RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1,
});
my $table = 'selecto_perl_test_export_scalars';
$dbh->do("DROP TABLE IF EXISTS $table");
$dbh->do("CREATE TABLE $table (id integer primary key, label text not null, price numeric(10,2),
    ratio numeric(9,4), units numeric(8,0), open boolean, due date, logged timestamp, meta jsonb)");
$dbh->do("INSERT INTO $table VALUES
    (1, 'Crate, small', 19.9, 0.5, 12, true, '2024-03-01', '2024-03-01 08:00:00', '{\"z\": 1, \"a\": [\"ü\"]}'),
    (2, 'Größe', 300, -0.0002, -3, false, '2020-02-29', '2020-02-29 23:59:01', '[]'),
    (3, '  +lead', -0.4, 0, 0, null, null, null, null)");

my %types = (id => 'integer', label => 'string', price => 'decimal', ratio => 'decimal',
    units => 'decimal', open => 'boolean', due => 'date', logged => 'naive_datetime', meta => 'jsonb');
my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', domain_fingerprint => 'sha256:perl-test-export-scalars',
    name => 'Export Values',
    source => {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}},
    schemas => {}, joins => {},
}, strict => 1);
my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(postgresql => (dbh => $dbh)));
my @fields = qw(id label price ratio units open due logged meta);
my $query = $engine->query->select(@fields)->order_by('id');

is_deeply($engine->all($query, canonical_values => 1)->{rows}, [
    [1, 'Crate, small', '19.9', '0.5', '12', 1, '2024-03-01', '2024-03-01T08:00:00', '{"a": ["ü"], "z": 1}'],
    [2, 'Größe', '300', '-0.0002', '-3', 0, '2020-02-29', '2020-02-29T23:59:01', '[]'],
    [3, '  +lead', '-0.4', '0', '0', undef, undef, undef, undef],
], 'canonical results: normalized decimals, 1/0 booleans, JSON text');
is_deeply($engine->all($query)->{rows}, [
    [1, 'Crate, small', '19.90', '0.5000', '12', 1, '2024-03-01', '2024-03-01 08:00:00', '{"a": ["ü"], "z": 1}'],
    [2, 'Größe', '300.00', '-0.0002', '-3', 0, '2020-02-29', '2020-02-29 23:59:01', '[]'],
    [3, '  +lead', '-0.40', '0.0000', '0', undef, undef, undef, undef],
], 'default results are the driver values');

my $exported = $engine->all($query, export_scalars => 1);
is(JSON::PP->new->canonical->utf8(0)->encode($exported->{rows}),
    '[[1,"Crate, small","19.90","0.5000","12",true,"2024-03-01","2024-03-01T08:00:00",{"a":["ü"],"z":1}],'
    . '[2,"Größe","300.00","-0.0002","-3",false,"2020-02-29","2020-02-29T23:59:01",[]],'
    . '[3,"  +lead","-0.40","0.0000","0",null,null,null,null]]',
    'export scalars keep column scale, give JSON booleans and decode JSON');
is_deeply($exported->{columns}, $engine->all($query)->{columns}, 'same columns');

my $api = Selecto::API->new(domain => $domain, base_path => '/api');
my $handler = Selecto::API::EngineHandler->new;
my $body = {select => [@fields], order_by => [{field => 'id', direction => 'asc'}]};
my $response = $api->request({method => 'POST', path => '/api/query', body => $body, accept => 'text/csv'}, {
    query => sub { my $data = $handler->query($engine, $_[0], export_scalars => 1);
        return ['ok', {columns => [@fields], rows => $data->{rows}}] },
});
is($response->{status}, 200, 'CSV export succeeds');
is(decode('UTF-8', $response->{body}), join('',
    "id,label,price,ratio,units,open,due,logged,meta\r\n",
    qq{1,"Crate, small",19.90,0.5000,12,true,2024-03-01,2024-03-01T08:00:00,"{""a"":[""ü""],""z"":1}"\r\n},
    qq{2,"Größe",300.00,'-0.0002,'-3,false,2020-02-29,2020-02-29T23:59:01,[]\r\n},
    qq{3,'  +lead,'-0.40,0.0000,0,,,,\r\n},
), 'the CSV export carries the export scalars through the certified cell rules');

my $plain = $handler->query($engine, $body);
is_deeply($plain->{rows}, $engine->all($query, canonical_values => 1)->{rows},
    'the handler without export_scalars returns canonical values');

$dbh->do("DROP TABLE IF EXISTS $table");
done_testing;
