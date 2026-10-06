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
is $object_csv, "id,label\r\n9,Object row\r\n",
    'object rows follow the declared column order';

# The certified cross-runtime cell rules (api_export_rules; the reference
# encoder is selecto_backend_certification's Perf.Export): a cell is quoted
# for the separator, a quote, tab, CR, LF or any non-ASCII character, never
# for a space alone; a formula lead after leading Unicode White_Space is
# neutralized, the "'" going before the whitespace.
{
    my @cells = (
        'two words', ' lead', 'trail ', ' ', '   ', '', undef,
        'Renée', 'café', '東京', "nb\x{a0}sp", 'a,b', 'a;b|c', 'say "hi"',
        "tab\there", "lf\nx", "cr\rx", 'back\\slash',
        '=1+1', '+x', '-5', '@a', -5, '-12.50', "\t=1", "\r=1", "\n-1", "\t",
        '  =1+1', " \t\@x", " =HYPERLINK(\"http://x\")", "\x{3000}+1", "\x{a0}=x",
        "\x{2003}-1", "\x{0b}=x", "\x{85}=x", "\x{feff}=x", "\x{200b}=x",
        '1=1', 'a-b', 'x@y.z', '|calc', '%0A', "'=already", '=A1,B1', '-', '+',
        "\x01ctl\x1f", "\x7f", 0, 7, 0 + '9007199254740993', JSON::PP::true, JSON::PP::false,
        {b => 'say "hi"', a => [1, '東京']}, [], {'=k' => '-v', x => undef},
    );
    my @expected_csv = (
        'two words', ' lead', 'trail ', ' ', '   ', '', '',
        '"Renée"', '"café"', '"東京"', qq{"nb\x{a0}sp"}, '"a,b"', 'a;b|c', '"say ""hi"""',
        qq{"tab\there"}, qq{"lf\nx"}, qq{"cr\rx"}, 'back\\slash',
        "'=1+1", "'+x", "'-5", "'\@a", "'-5", "'-12.50", qq{"'\t=1"}, qq{"'\r=1"}, qq{"'\n-1"}, qq{"'\t"},
        "'  =1+1", qq{"' \t\@x"}, qq{"' =HYPERLINK(""http://x"")"}, qq{"'\x{3000}+1"}, qq{"'\x{a0}=x"},
        qq{"'\x{2003}-1"}, "'\x{0b}=x", qq{"'\x{85}=x"}, qq{"\x{feff}=x"}, qq{"\x{200b}=x"},
        '1=1', 'a-b', 'x@y.z', '|calc', '%0A', "'=already", qq{"'=A1,B1"}, "'-", "'+",
        "\x01ctl\x1f", "\x7f", '0', '7', '9007199254740993', 'true', 'false',
        '"{""a"":[1,""東京""],""b"":""say \\""hi\\""""}"', '[]', qq{"{""=k"":""-v"",""x"":null}"},
    );
    is scalar(@cells), scalar(@expected_csv), 'every rule sample has an expected cell';
    my @columns = map { "c$_" } 0 .. $#cells;
    my $body = decode('UTF-8', Selecto::API::ResultFormatter->encode_result('csv', {
        columns => \@columns, rows => [\@cells],
    }));
    my (undef, $line) = split /\r\n/, $body, 2;
    is $line, join(',', @expected_csv) . "\r\n", 'CSV cells follow the certified export rules';
    for my $index (0 .. $#cells) {
        my $cell = decode('UTF-8', Selecto::API::ResultFormatter->encode_result('csv', {
            columns => ['c'], rows => [[$cells[$index]]],
        }));
        is $cell, "c\r\n$expected_csv[$index]\r\n", "CSV cell $index";
    }

    my $tsv = decode('UTF-8', Selecto::API::ResultFormatter->encode_result('tsv', {
        columns => ['id', 'unit price', 'montant €', '-delta'],
        rows => [[1, 'a,b', '=A1,B1', 'two words'], [2, "tab\there", '  -padded', 'Renée']],
    }));
    is $tsv, join('', "id\tunit price\t\"montant €\"\t'-delta\r\n",
        "1\ta,b\t'=A1,B1\ttwo words\r\n",
        "2\t\"tab\there\"\t'  -padded\t\"Renée\"\r\n"),
        'TSV quotes for tabs and non-ASCII but not commas or spaces; headers follow the cell rules';

    is decode('UTF-8', Selecto::API::ResultFormatter->encode_result('csv', {
        columns => ['id', 'name'], rows => [],
    })), "id,name\r\n", 'an empty result exports the header row alone';
}

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
