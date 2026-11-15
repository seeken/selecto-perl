use strict;
use warnings;
use Test::More;
use B ();
use Scalar::Util qw(dualvar);
use Encode qw(encode_utf8);
use JSON::PP ();
use Selecto::PostgreSQL;
use DBI;
use utf8;
# Unicode decimal digits match Perl's historical integer regex but int emits
# this expected warning. Keep all other warnings visible.
local $SIG{__WARN__}=sub { warn $_[0] unless $_[0] =~ /isn't numeric in int/ };
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});

{package Local::NumberDecoder;use Mojo::Base 'Selecto::PostgreSQL';sub _canonical_server_version {150000}}
my @types=qw(int2 int4 int8 bool numeric float4 float8 text json jsonb date timestamp timestamptz bytea uuid time timetz interval varchar bpchar unknown);
sub corpus {
    my $wide_ascii='1.2300'; utf8::upgrade($wide_ascii);
    my $wide_zero='-0.000'; utf8::upgrade($wide_zero);
    my $byte_text=pack('C*',99,97,102,233);
    return ($wide_ascii,$wide_zero,$byte_text,JSON::PP::true,JSON::PP::false,undef,'','0','-0','001','-12','9007199254740993','9223372036854775808',
        '1.2300','-0.000','12.','.0','..000','1.0e0','+0.00',"1.000\n","a\0b",'abc.2300','1e10','NaN','Infinity',
        't','f','1','false',0,1,-1,1.5,dualvar(42,'0042'),dualvar(5,'five'),
        "caf\x{e9}","\x{6771}\x{4eac}","\x{661}\x{662}",
        '{"a":true,"n":1.20}','[null,false,"é"]',
        'infinity','-infinity','2024-01-01','2024-01-01 10:20:30.000+00',
        '2024-01-01 10:20:30.120+00:00','2024-01-01 10:20:30.000Z',
        '2024-01-01 10:20:30.120+05:30');
}
sub rows {
    my ($type)=@_;
    my @v=corpus();
    # Dates intentionally refuse non-ISO text; test refusals separately.
    my $wide_timestamp='2024-01-01 12:00:00.000+00';utf8::upgrade($wide_timestamp);
    @v=($wide_timestamp,undef,'','infinity','-infinity','2024-01-01','2024-01-01 12:00:00.000+00',
        '2024-01-01 12:00:00.010Z','2024-01-01 12:00:00.00+05:30') if $type=~/date|timestamp/;
    @v=(undef,'{"a":true,"n":1.20}','[null,false,"é"]') if $type=~/\Ajson/;
    return [map {[$_]} @v];
}
sub snapshot {
    my ($rows)=@_;
    return [map {
        my $v=$_->[0];
        my $flags=B::svref_2object(\$v)->FLAGS & (B::SVf_IOK()|B::SVp_IOK()|B::SVf_NOK()|B::SVp_NOK()|B::SVf_POK()|B::SVp_POK()|B::SVf_UTF8());
        ref($v) ? [$flags, ref($v), JSON::PP->new->canonical->encode($v)] : defined($v) ? [$flags, ref($v), unpack('H*',encode_utf8("$v"))] : [$flags,'undef'];
    } @$rows];
}
for my $class ('Selecto::PostgreSQL','Local::NumberDecoder') {
    my $adapter=$class->new(dbh=>$dbh);
    for my $pure (0,1) {
    local $Selecto::PostgreSQL::PURE_PERL=$pure;
    for my $export (0,1) {
        local $adapter->{_selecto_export_scalars}=$export;
        for my $type (@types) {
            my $expected=rows($type);
            my $actual=rows($type);
            $adapter->_decode_rows_reference($expected,[$type]);
            $adapter->_decode_rows($actual,[$type]);
            is_deeply(snapshot($actual),snapshot($expected),"$class pure=$pure export=$export $type scalar flags and bytes");
            for my $row (@{rows($type)}) {
                my $left=[[@$row]];my $right=[[@$row]];
                $adapter->_decode_rows_reference($left,[$type]);
                $adapter->_decode_rows($right,[$type]);
                is_deeply(snapshot($right),snapshot($left),"single scalar $type pure=$pure export=$export");
            }
        }
    }
    }
    for my $type (qw(date timestamp timestamptz)) {
        for my $method (qw(_decode_rows_reference _decode_rows)) {
            eval {$adapter->$method([['01/02/2024']],[$type])};
            is(ref($@) ? $@->code : '', 'query_rule_not_evaluable', "$method refuses non-ISO $type");
        }
    }
}
my $adapter=Selecto::PostgreSQL->new(dbh=>$dbh);
my $r=[['t']];$adapter->_decode_rows($r,['bool']);is($r->[0][0],1,'bool plan');
$r=[['t']];$adapter->_decode_rows($r,['text']);is($r->[0][0],'t','type change replaces plan');
{local $adapter->{_selecto_raw_values}=1;$r=[['1.00']];$adapter->_decode_rows($r,['numeric']);is($r->[0][0],'1.00','raw bypass');}
if (Selecto::PostgreSQL::_xs_available()) {
    ok(Selecto::PostgreSQL::CanonicalXS::convert_column([['1.200']],0,0),'XS fast numeric callable');
    my $r=[['2024-01-01 12:00:00.000+00']];
    ok(Selecto::PostgreSQL::CanonicalXS::convert_column($r,0,1),'XS fast timestamp callable');
    is($r->[0][0],'2024-01-01T12:00:00','XS timestamp result');
    my $calls=0;my $native=\&Selecto::PostgreSQL::CanonicalXS::convert_column;
    no warnings 'redefine';
    local *Selecto::PostgreSQL::CanonicalXS::convert_column=sub {$calls++;$native->(@_)};
    local $ENV{SELECTO_PERL_PURE}=0;
    $adapter->_decode_rows([['1.00']],['numeric']);
    ok($calls,'native column path actually executed');
    my $before=$calls;
    { local $ENV{SELECTO_PERL_PURE}=1;
      $adapter->_decode_rows([['1.00']],['numeric']); }
    is($calls,$before,'environment can force Perl after native execution');
    { local $Selecto::PostgreSQL::PURE_PERL=1;
      $adapter->_decode_rows([['1.00']],['numeric']); }
    is($calls,$before,'package flag can force Perl after native execution');
} elsif ($ENV{SELECTO_REQUIRE_XS}) {
    fail('required XS did not load');
}
done_testing;
