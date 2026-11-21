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
use Selecto::SQLite ();

# A column marked redacted (redacted: true, on the root or on a related
# relation) is withheld exactly like a field named in redact_fields: it is
# not public, the canonical API does not publish it, the query handler
# refuses it with hidden_field, and a host write property may not replace
# it. redacted: false withholds nothing, and the export keeps the flag.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my ($t, $f) = (JSON::PP::true, JSON::PP::false);
my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1.0.0', domain_fingerprint => 'sha256:column-redacted-test',
    name => 'Column redaction',
    source => {source_table => 'items', primary_key => 'id', fields => [qw(id label maker_id secret token shown)],
        redact_fields => ['secret'],
        columns => {id => {type => 'integer'}, label => {type => 'string'}, maker_id => {type => 'integer'},
            secret => {type => 'string'}, token => {type => 'string', redacted => $t},
            shown => {type => 'string', redacted => $f}},
        associations => {maker => {queryable => 'makers', owner_key => 'maker_id', related_key => 'id'}}},
    schemas => {makers => {source_table => 'makers', primary_key => 'id', fields => [qw(id name code)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, code => {type => 'string', redacted => 1}},
        associations => {}}},
    joins => {maker => {type => 'left'}},
}, strict => 1);

my %public = (label => 1, shown => 1, secret => 0, token => 0, 'maker.name' => 1, 'maker.code' => 0);
is $domain->field_is_public($_) ? 1 : 0, $public{$_}, "$_ is " . ($public{$_} ? 'public' : 'withheld')
    for sort keys %public;
is $domain->field_metadata('token')->{redacted}, 1, 'a redacted column reports redacted metadata';

my $api = Selecto::API->new(domain => $domain, base_path => '/items');
my $handler = Selecto::API::EngineHandler->new;
$handler->describe_openapi($api);
is_deeply [map { $_->{path} } @{$api->openapi_document->{'x-selecto'}{fields}}],
    [qw(id label maker_id shown maker.id maker.name)], 'x-selecto.fields lists only public fields';

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
my $engine = Selecto::Engine->new(adapter => Selecto::SQLite->new(dbh => $dbh), domain => $domain);
sub outcome {
    my ($code) = @_;
    return 'accepted' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}
for my $field (sort keys %public) {
    my $want = $public{$field} ? 'accepted' : 'hidden_field';
    is outcome(sub { $handler->query($engine, {select => [$field], limit => 0}) }), $want, "select $field";
    is outcome(sub { $handler->query($engine, {select => ['id'], limit => 0,
        filters => [{field => $field, op => 'eq', value => 'x'}]}) }), $want, "filter $field";
    is outcome(sub { $handler->query($engine, {select => ['id'], limit => 0, order_by => [{field => $field}]}) }),
        $want, "order $field";
}
for my $field (qw(label shown secret token)) {
    is outcome(sub { $handler->describe_write_property($api, "p_$field", {type => 'string'}, replaces => [$field]) }),
        $public{$field} ? 'accepted' : 'invalid_api_host', "replaces $field";
}

my $export = $domain->contract_json;
ok JSON::PP::is_bool($export->{source}{columns}{token}{redacted}) && $export->{source}{columns}{token}{redacted},
    'the export keeps redacted: true';
ok JSON::PP::is_bool($export->{schemas}{makers}{columns}{code}{redacted}), 'a related flag is a JSON boolean';
ok !$export->{source}{columns}{shown}{redacted}, 'the export keeps redacted: false';

done_testing;
