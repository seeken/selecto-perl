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
    certification_spec => '1.1.0',
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
