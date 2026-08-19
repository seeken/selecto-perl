use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempfile);
use JSON::PP ();
use Selecto::Certification ();

sub run_request {
    my ($request) = @_;
    my ($handle, $path) = tempfile('selecto-perl-request-XXXX', SUFFIX => '.json', UNLINK => 1);
    print {$handle} JSON::PP->new->encode($request);
    close $handle;
    my $output = qx{$^X -Ilib bin/selecto-certify --request "$path" 2>&1};
    return ($? >> 8, $output);
}

my $base = {
    protocol_version => 1,
    certification_spec => '2.3.0',
    target => {
        key => 'perl_postgresql', implementation => 'selecto_perl', runtime => 'perl',
        backend => 'postgresql', connection_env => 'SELECTO_CERT_PERL_POSTGRESQL_URL',
    },
    cases => [],
};

my ($status, $output) = run_request({ %$base, protocol_version => 99 });
isnt($status, 0, 'incompatible protocol is rejected before database access');
like($output, qr/unsupported protocol version/, 'protocol failure is explicit');

($status, $output) = run_request({ %$base, unexpected => JSON::PP::true });
isnt($status, 0, 'unknown request fields are rejected');
like($output, qr/request has unknown fields/, 'unknown field failure is explicit');

my %missing_target = %$base;
delete $missing_target{target};
($status, $output) = run_request(\%missing_target);
isnt($status, 0, 'missing request fields are rejected');
like($output, qr/request is missing fields/, 'missing field failure is explicit');

($status, $output) = run_request($base);
isnt($status, 0, 'valid request still requires a configured connection');
like($output, qr/connection environment .* is not configured/, 'connection requirement names only the environment variable');
unlike($output, qr/postgres:\/\//, 'error output does not contain a connection URL');

my ($dsn, $username, $password) = Selecto::Certification::_connection_parts(
    'postgres://selecto%20user:p%40ss@127.0.0.1:55435/selecto_cert?sslmode=disable'
);
is($username, 'selecto user', 'PostgreSQL URL username is decoded');
is($password, 'p@ss', 'PostgreSQL URL password is decoded');
is($dsn, q{dbi:Pg:dbname='selecto_cert';host='127.0.0.1';port=55435;sslmode='disable'}, 'PostgreSQL URL becomes a DBD::Pg DSN');

my ($sqlite_dsn, $sqlite_username, $sqlite_password) =
    Selecto::Certification::_connection_parts(':memory:', 'sqlite');
is($sqlite_dsn, 'dbi:SQLite:dbname=:memory:', 'SQLite in-memory connection becomes a DBD::SQLite DSN');
is($sqlite_username, undef, 'SQLite connection has no username');
is($sqlite_password, undef, 'SQLite connection has no password');

my ($duckdb_dsn, $duckdb_username, $duckdb_password) =
    Selecto::Certification::_connection_parts(':memory:', 'duckdb');
is($duckdb_dsn, 'dbi:DuckDB:dbname=:memory:', 'DuckDB in-memory connection becomes a DBD::DuckDB DSN');
is($duckdb_username, undef, 'DuckDB connection has no username');
is($duckdb_password, undef, 'DuckDB connection has no password');

my ($mysql_dsn, $mysql_username, $mysql_password) =
    Selecto::Certification::_connection_parts(
        'mysql://selecto%20user:p%40ss@127.0.0.1:53306/selecto_cert', 'mysql'
    );
is($mysql_dsn, 'dbi:MariaDB:database=selecto_cert;host=127.0.0.1;port=53306', 'MySQL URL becomes a DBD::MariaDB DSN');
is($mysql_username, 'selecto user', 'MySQL URL username is decoded');
is($mysql_password, 'p@ss', 'MySQL URL password is decoded');

my $sqlite_base = {
    %$base,
    target => {
        key => 'perl_sqlite', implementation => 'selecto_perl', runtime => 'perl',
        backend => 'sqlite', connection_env => 'SELECTO_CERT_PERL_SQLITE_TEST_URL',
    },
};
($status, $output) = run_request($sqlite_base);
isnt($status, 0, 'valid SQLite target still requires a configured connection');
like($output, qr/connection environment .* is not configured/, 'SQLite target is accepted before connection validation');

for my $backend (qw(mysql mariadb)) {
    my $service_base = {
        %$base,
        target => {
            key => "perl_$backend", implementation => 'selecto_perl', runtime => 'perl',
            backend => $backend, connection_env => 'SELECTO_CERT_PERL_SERVICE_TEST_URL',
        },
    };
    ($status, $output) = run_request($service_base);
    isnt($status, 0, "valid $backend target still requires a configured connection");
    like($output, qr/connection environment .* is not configured/, "$backend identity is accepted before connection validation");
}

my $mssql_base = {
    %$base,
    target => {
        key => 'perl_mssql', implementation => 'selecto_perl', runtime => 'perl',
        backend => 'mssql', connection_env => 'SELECTO_CERT_PERL_MSSQL_TEST_URL',
    },
};
($status, $output) = run_request($mssql_base);
isnt($status, 0, 'valid Microsoft SQL Server target still requires a configured connection');
like($output, qr/connection environment .* is not configured/, 'Microsoft SQL Server identity is accepted before connection validation');

{
    local $ENV{SELECTO_PERL_MSSQL_ODBC_DRIVER} = '/opt/selecto/libtdsodbc.so';
    my ($mssql_dsn, $mssql_username, $mssql_password) =
        Selecto::Certification::_connection_parts(
            'mssql://selecto%20user:p%40ss@127.0.0.1:51433/selecto_cert', 'mssql'
        );
    is(
        $mssql_dsn,
        'dbi:ODBC:Driver={/opt/selecto/libtdsodbc.so};Server=127.0.0.1;Port=51433;Database=selecto_cert;TDS_Version=7.4;ClientCharset=UTF-8',
        'Microsoft SQL Server URL becomes a credential-free FreeTDS ODBC DSN',
    );
    is($mssql_username, 'selecto user', 'Microsoft SQL Server URL username is decoded');
    is($mssql_password, 'p@ss', 'Microsoft SQL Server URL password is decoded');
}

{
    local $ENV{SELECTO_PERL_MSSQL_ODBC_DRIVER} = 'invalid;PWD=must-not-enter-dsn';
    my $ok = eval {
        Selecto::Certification::_connection_parts(
            'mssql://user:password@127.0.0.1:51433/selecto_cert', 'mssql'
        );
        1;
    };
    ok(!$ok, 'ODBC driver-name injection is rejected');
    like($@, qr/driver name is invalid/, 'ODBC driver-name rejection is explicit');
}

my $mismatched_key = {
    %$sqlite_base,
    target => { %{$sqlite_base->{target}}, key => 'perl_postgresql' },
};
($status, $output) = run_request($mismatched_key);
isnt($status, 0, 'backend and target-key mismatches are rejected');
like($output, qr/unsupported target identity/, 'target identity failure is explicit');

{
    package TestRunnerSuite;
    sub new { return bless {}, shift; }
    sub run_case { return [{ columns => ['id'], rows => [[1, 'Renée 東京']] }, { sql => 'SELECT 1' }]; }
}
my $observation = Selecto::Certification::_observe(TestRunnerSuite->new, 'Q001');
is(ref($observation->{value}), 'HASH', 'runner unpacks the public value from the case pair');
is($observation->{value}{rows}[0][1], 'Renée 東京', 'runner keeps Unicode logical values intact');
is($observation->{evidence}{sql}, 'SELECT 1', 'runner unpacks evidence separately');

done_testing;
