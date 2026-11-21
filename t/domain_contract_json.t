use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Domain;
use Selecto::Expression;
use Selecto ();
use DBI ();
use Selecto::CanonicalJSON;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);

my $json = JSON::PP->new->canonical;
sub relation {
    my ($table) = @_;
    return {source_table=>$table, primary_key=>'id', fields=>[qw(id label site_id)],
        columns=>{id=>{type=>'integer'}, label=>{type=>'string'}, site_id=>{type=>'integer'}}, associations=>{}};
}
sub base {
    return {schema_version=>1, name=>'Synthetic items', source=>relation('contract_items'), schemas=>{}, joins=>{}};
}
sub roundtrip {
    my ($raw, $name) = @_;
    my $domain = Selecto::Domain->parse($raw, strict=>1);
    my $data = $domain->contract_json;
    is($json->encode($data), $json->encode($domain->contract_json), "$name encodes identically twice");
    my $copy = Selecto::Domain->parse($json->decode($json->encode($data)), strict=>1);
    is($json->encode($copy->contract_json), $json->encode($domain->contract_json), "$name export is idempotent");
    for my $field (@{$raw->{source}{fields}}) {
        is($copy->field_is_public($field), $domain->field_is_public($field), "$name preserves visibility of $field");
    }
    for my $join (keys %{$raw->{source}{associations} // {}}) {
        my $schema = $raw->{source}{associations}{$join}{queryable};
        for my $field (@{$raw->{schemas}{$schema}{fields}}) {
            is($copy->field_is_public("$join.$field"), $domain->field_is_public("$join.$field"), "$name preserves joined visibility of $join.$field");
        }
    }
    $data->{name} = 'Changed copy';
    is($domain->name, 'Synthetic items', "$name returns a copy");
    return $domain;
}

subtest 'contract_keys copies the canonical parser tables' => sub {
    my $keys = Selecto::Domain->contract_keys;
    is_deeply([sort keys %$keys], [qw(association join join_types relation through top_level)], 'all six tables');
    is_deeply($keys->{join_types}, [qw(left inner star_dimension right full)], 'all accepted join types');
    push @{$keys->{join_types}}, 'synthetic_unknown';
    is_deeply(Selecto::Domain->contract_keys->{join_types}, [qw(left inner star_dimension right full)], 'join types are copied');
    for my $kind (qw(top_level relation association join through)) {
        ok(@{$keys->{$kind}}, "$kind has keys");
        push @{$keys->{$kind}}, 'synthetic_unknown';
        ok(!grep($_ eq 'synthetic_unknown', @{Selecto::Domain->contract_keys->{$kind}}), "$kind is copied");
    }
    my $raw = base();
    $raw->{synthetic_unknown} = {};
    eval { Selecto::Domain->parse($raw, strict=>1) };
    is($@->code, 'unknown_domain_key', 'copy mutation cannot widen parser');
};

subtest 'boolean positions preserve data types and omit trusted scope' => sub {
    my $raw = base();
    $raw->{require_tenant} = 0;
    $raw->{source}{columns}{label} = {type=>'string', hidden=>1, internal=>0,
        nullable=>JSON::PP::true, filterable=>0, selectable=>1, sortable=>1,
        groupable=>1, detail_selectable=>1, query_filterable=>0, aggregatable=>0,
        options=>{number=>17, fraction=>1.25, fraction_string=>'1.25', string=>'17', hidden=>'1'}};
    $raw->{components} = {query_params=>1, filter_choices=>{label=>{label=>'Labels', picker_hidden=>0,
        choices=>[{value=>'A', label=>'Synthetic'}]}}};
    my $domain = roundtrip($raw, 'flags');
    my $data = $domain->contract_json;
    ok(JSON::PP::is_bool($data->{require_tenant}), 'domain flag is JSON boolean');
    for my $key (qw(hidden internal nullable filterable selectable sortable groupable detail_selectable query_filterable aggregatable)) {
        ok(JSON::PP::is_bool($data->{source}{columns}{label}{$key}), "$key is JSON boolean");
    }
    ok(JSON::PP::is_bool($data->{components}{query_params}), 'UI flag is JSON boolean');
    ok(JSON::PP::is_bool($data->{components}{filter_choices}{label}{picker_hidden}), 'picker flag is JSON boolean');
    like($json->encode($data), qr/"number":17/, 'number stays numeric');
    like($json->encode($data), qr/"string":"17"/, 'string stays string');
    like($json->encode($data), qr/"fraction":1.25/, 'fraction stays numeric');
    like($json->encode($data), qr/"fraction_string":"1.25"/, 'numeric-looking fraction stays a string');
    is($data->{source}{columns}{label}{options}{hidden}, '1', 'arbitrary data named hidden stays a string');
    my $scoped = $domain->with_required_predicate(Selecto::Expression->eq('id', 93271));
    is($json->encode($scoped->contract_json), $json->encode($domain->contract_json), 'required predicate and its value are omitted');
    unlike($json->encode($scoped->contract_json), qr/93271|required_predicate/, 'trusted scope never serialized');
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError=>1,PrintError=>0});
    my $engine = Selecto::Engine->new(domain=>$domain->with_tenant_field('site_id'), adapter=>Selecto->adapter('sqlite',dbh=>$dbh));
    $engine = $engine->with_scope(tenant=>'private-scope-value');
    unlike($json->encode($engine->read_domain->contract_json), qr/private-scope-value|required_predicate/, 'engine tenant and effective predicate values are omitted');
    $dbh->disconnect;
};

subtest 'all domain UI and write boolean positions are JSON flags' => sub {
    my $raw = base();
    $raw->{co_domains} = {catalog=>{domain=>'synthetic_catalog',projection=>'summary',
        search=>{fields=>['label'],rank=>1},result=>{value_field=>'id',label_field=>'label'}}};
    $raw->{actions} = {inspect=>{prerequisite_column=>0,inputs=>{note=>{type=>'string',required=>1}}}};
    $raw->{detail_actions} = {inspect=>{name=>'Inspect',type=>'iframe_modal',required_fields=>['id'],
        payload=>{url_template=>'/items/{{id}}',navigation_enabled=>0}}};
    $raw->{writes} = {operations=>{update=>{enabled=>1,bulk=>0,require_filter=>1}},
        fields=>{label=>{updatable=>1,insertable=>0,required=>0,write_once=>0}}};
    $raw->{editors} = {inspect=>{fields=>[{field=>'label',readonly=>1,required=>0,nullable=>1}]}};
    my $d = roundtrip($raw, 'UI and write flags');
    my $c = $d->contract_json;
    ok(JSON::PP::is_bool($c->{co_domains}{catalog}{search}{rank}), 'co-domain rank normalized');
    ok(JSON::PP::is_bool($c->{actions}{inspect}{prerequisite_column}), 'action prerequisite switch normalized');
    ok(JSON::PP::is_bool($c->{actions}{inspect}{inputs}{note}{required}), 'action input required normalized');
    ok(JSON::PP::is_bool($c->{detail_actions}{inspect}{payload}{navigation_enabled}), 'navigation flag normalized');
    for my $key (qw(readonly required nullable)) {
        ok(JSON::PP::is_bool($c->{editors}{inspect}{fields}[0]{$key}), "editor $key normalized");
    }
    for my $key (qw(enabled bulk require_filter)) {
        ok(JSON::PP::is_bool($c->{writes}{operations}{update}{$key}), "write operation $key normalized");
    }
    for my $key (qw(updatable insertable required write_once)) {
        ok(JSON::PP::is_bool($c->{writes}{fields}{label}{$key}), "write field $key normalized");
    }
};

for my $type (@{Selecto::Domain->contract_keys->{join_types}}) {
    subtest "$type shape round trip" => sub {
        my $raw = base();
        $raw->{schemas}{sites} = relation('contract_sites');
        $raw->{source}{associations}{site} = {queryable=>'sites', owner_key=>'site_id', related_key=>'id'};
        $raw->{joins}{site} = {type=>$type, name=>'Site', source=>'contract_sites',
            fields=>{id=>{type=>'integer'}, label=>{type=>'string'}, site_id=>{type=>'integer'}},
            on=>[{left=>'site_id', right=>'id'}]};
        if ($type eq 'star_dimension') {
            $raw->{joins}{site}{display_field} = 'label';
            $raw->{joins}{site}{dimension_key} = 'site_id';
        }
        roundtrip($raw, $type);
        $raw->{schemas}{areas} = relation('contract_areas');
        $raw->{schemas}{sites}{associations}{area} = {queryable=>'areas', owner_key=>'site_id', related_key=>'id'};
        $raw->{joins}{'site.area'} = {type=>'inner'};
        roundtrip($raw, "$type dotted nested join");
        # right and full joins take a direct association only.
        my $direct_only = $type eq 'right' || $type eq 'full';
        $raw->{source}{associations}{site}{through} = {table=>'contract_bridges', owner_key=>'item_id', related_key=>'site_id'};
        if ($direct_only) { ok(!eval { Selecto::Domain->parse($raw, strict=>1); 1 }, "$type through association refuses") }
        else { roundtrip($raw, "$type through association") }
        delete $raw->{source}{associations}{site}{through};
        $raw->{source}{associations}{site}{join_strategy} = 'lateral_lookup';
        if ($direct_only) { ok(!eval { Selecto::Domain->parse($raw, strict=>1); 1 }, "$type lookup association refuses") }
        else { roundtrip($raw, "$type lookup association") }
    };
}
subtest 'inline values and extensible metadata round trip' => sub {
    my $raw = base();
    my $values = relation('unused');
    delete $values->{source_table};
    $values->{values} = [{id=>7, label=>'007', site_id=>8}];
    $raw->{schemas}{sites} = $values;
    $raw->{source}{associations}{site} = {queryable=>'sites', owner_key=>'site_id', related_key=>'id'};
    $raw->{joins}{site} = {type=>'left'};
    $raw->{source}{columns}{label}{$_} = {number=>5, text=>'5'} for qw(link html_format foreign_key options action_prerequisites unit behavior text_case unknown_key);
    # Validated analytics/text metadata have typed forms; other metadata is opaque.
    delete @{$raw->{source}{columns}{label}}{qw(unit behavior)};
    $raw->{source}{columns}{label}{text_case} = 'uppercase';
    $raw->{operations} = {inspect=>{fields=>['label']}};
    $raw->{experiences} = {listing=>{field=>'label'}};
    $raw->{pagination} = {size=>20};
    $raw->{subfilters} = {};
    $raw->{window_functions} = {};
    $raw->{associations} = {};
    my $domain = roundtrip($raw, 'inline and native top-level metadata');
    like($json->encode($domain->contract_json->{schemas}{sites}{values}), qr/\"id\":7,\"label\":\"007\",\"site_id\":8/, 'inline numeric and string cell types survive export');
};
subtest 'raw flags keep origin parser acceptance and fingerprint algorithm' => sub {
    my @flags = ('', !!1, undef, 2, 'yes', JSON::PP::true, JSON::PP::false);
    for my $i (0..$#flags) {
        my $raw = base();
        $raw->{domain_fingerprint} = 'authored-label';
        $raw->{source}{columns}{label}{$_} = $flags[$i] for qw(hidden internal nullable filterable selectable sortable groupable);
        my $document = dclone($raw);
        delete $document->{domain_fingerprint};
        my $expected = 'sha256:' . sha256_hex(encode_utf8(Selecto::CanonicalJSON->encode($document)));
        my $d = roundtrip($raw, "raw flag $i");
        is($d->fingerprint, $expected, "raw flag $i matches origin algorithm byte for byte");
        my $flag = $d->contract_json->{source}{columns}{label}{hidden};
        ok(JSON::PP::is_bool($flag), 'export emits boolean');
        is($flag ? 1 : 0, $flags[$i] ? 1 : 0, 'export uses engine truthiness');
    }
};

subtest 'undefined tenant aliases use the engine defined-value fallback' => sub {
    for my $aliases (
        {tenant_required=>undef,require_tenant=>1},
        {tenant_required=>1,require_tenant=>undef},
        {tenant_required=>undef,require_tenant=>0},
        {tenant_required=>undef,require_tenant=>undef},
        {tenant_required=>undef},
    ) {
        my $raw = base();
        $raw->{source}{tenant_field} = 'site_id';
        @$raw{keys %$aliases} = values %$aliases;
        my $d = roundtrip($raw,'undefined tenant alias');
        my $data = $d->contract_json;
        my $copy = Selecto::Domain->parse($json->decode($json->encode($data)),strict=>1);
        is($copy->tenant_required,$d->tenant_required,'effective tenant requirement is preserved');
        my $expected = 'sha256:' . sha256_hex(encode_utf8(Selecto::CanonicalJSON->encode($raw)));
        is($d->fingerprint,$expected,'alias export leaves raw-document identity unchanged');
        for my $key (keys %$aliases) {
            ok(JSON::PP::is_bool($data->{$key}),"$key exports a JSON boolean");
            is($data->{$key} ? 1 : 0,$d->tenant_required ? 1 : 0,"$key exports the engine effective flag");
        }
    }
};

done_testing;
