use 5.034;
use strict;
use warnings;
use utf8;

use Encode qw(decode);
use IO::Uncompress::Unzip ();
use JSON::PP ();
use Test::More;
use Selecto::API::ResultFormatter ();

my $result = {
    columns => [qw(id label exact nested formula empty)],
    rows => [[
        7,
        "Renée\t東京",
        '1.2500',
        [{code => 'A', value => 3}],
        '=2+2',
        undef,
    ]],
};

is(Selecto::API::ResultFormatter->negotiate(undef, undef), 'json',
    'JSON is the default response representation');
is(Selecto::API::ResultFormatter->negotiate(undef, 'text/csv'), 'csv',
    'CSV is selected through HTTP content negotiation');
is(Selecto::API::ResultFormatter->negotiate(undef,
    'application/json;q=0.5, text/tab-separated-values;q=0.9'), 'tsv',
    'content negotiation honors quality weights');
is(Selecto::API::ResultFormatter->negotiate('excel', 'application/json'), 'xlsx',
    'an explicit Excel alias selects XLSX');
is(Selecto::API::ResultFormatter->negotiate(undef,
    'application/json;q=0, */*;q=1'), 'csv',
    'an exact JSON exclusion overrides a broader wildcard');

my $csv = decode('UTF-8', Selecto::API::ResultFormatter->encode_result('csv', $result));
is $csv,
    qq{id,label,exact,nested,formula,empty\r\n7,"Renée\t東京",1.2500,"[{""code"":""A"",""value"":3}]",'=2+2,\r\n},
    'CSV retains exact strings, canonicalizes nested values, and guards formulas';

my $tsv = decode('UTF-8', Selecto::API::ResultFormatter->encode_result('tsv', $result));
is $tsv,
    qq{id\tlabel\texact\tnested\tformula\tempty\r\n7\t"Renée\t東京"\t1.2500\t"[{""code"":""A"",""value"":3}]"\t'=2+2\t\r\n},
    'TSV quotes embedded tabs and preserves the same safe tabular values';

my $object_csv = decode('UTF-8', Selecto::API::ResultFormatter->encode_result('csv', {
    columns => [qw(id label)], rows => [{label => 'Object row', id => 9}],
}));
is $object_csv, "id,label\r\n9,\"Object row\"\r\n",
    'object rows follow the declared column order';

my $xlsx = Selecto::API::ResultFormatter->encode_result('xlsx', $result);
is substr($xlsx, 0, 2), 'PK', 'XLSX output is an Office Open XML zip archive';
ok length($xlsx) > 1000, 'XLSX output contains a complete workbook';

my $wide_integer = 0 + '9007199254740993';
my $wide_xlsx = Selecto::API::ResultFormatter->encode_result('xlsx', {
    columns => ['id'], rows => [[7], [$wide_integer]],
});
my $archive = IO::Uncompress::Unzip->new(\$wide_xlsx)
    or die $IO::Uncompress::Unzip::UnzipError;
my %parts;
do {
    my $name = $archive->getHeaderInfo->{Name};
    if ($name eq 'xl/worksheets/sheet1.xml' || $name eq 'xl/sharedStrings.xml') {
        my $contents = '';
        my $chunk;
        $contents .= $chunk while $archive->read($chunk) > 0;
        $parts{$name} = $contents;
    }
} while $archive->nextStream > 0;
like $parts{'xl/worksheets/sheet1.xml'}, qr{<c r="A2"><v>7</v></c>},
    'safe XLSX integers remain numeric cells';
like $parts{'xl/worksheets/sheet1.xml'}, qr{<c r="A3" t="s"><v>1</v></c>},
    'integers outside Excel exact range become text cells';
like $parts{'xl/sharedStrings.xml'}, qr{<si><t>9007199254740993</t></si>},
    'wide integer text retains every digit';

my $error = eval {
    Selecto::API::ResultFormatter->negotiate(undef, 'application/pdf');
    undef;
} // $@;
is $error->code, 'response_format_not_acceptable',
    'unsupported Accept media types fail with a stable error';

$error = eval {
    Selecto::API::ResultFormatter->encode_result('csv', {
        columns => ['id'], rows => [[1, 2]],
    });
    undef;
} // $@;
is $error->code, 'invalid_api_result',
    'malformed tabular results fail closed';

done_testing;
