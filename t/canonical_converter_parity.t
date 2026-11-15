use strict;
use warnings;
use Test::More;
use B ();
use Scalar::Util qw(dualvar);
use Encode qw(encode_utf8);
use JSON::PP ();
use Selecto::PostgreSQL;
use DBI;
my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});

{package Local::NumberDecoder;use Mojo::Base 'Selecto::PostgreSQL';sub _canonical_server_version {150000}}
my @types=qw(int2 int4 int8 bool numeric float4 float8 text json jsonb date timestamp timestamptz unknown);
sub corpus {
    return (undef,'','0','-0','001','-12','9007199254740993','9223372036854775808',
        '1.2300','-0.000','12.','abc.2300','1e10','NaN','Infinity',
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
    @v=(undef,'','infinity','-infinity','2024-01-01','2024-01-01 12:00:00.000+00',
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
    for my $export (0,1) {
        local $adapter->{_selecto_export_scalars}=$export;
        for my $type (@types) {
            my $expected=rows($type);
            my $actual=rows($type);
            $adapter->_decode_rows_reference($expected,[$type]);
            $adapter->_decode_rows($actual,[$type]);
            is_deeply(snapshot($actual),snapshot($expected),"$class export=$export $type scalar flags and bytes");
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
done_testing;
