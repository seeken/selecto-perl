use 5.034;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Selecto::Domain ();
use Selecto::Importer ();

my $domain = Selecto::Domain->parse({
    schema_version => 1, domain_version => '1', domain_fingerprint => 'sha256:test-importer',
    name => 'Equipment',
    source => {
        source_table => 'equipment', primary_key => 'id', tenant_field => 'client_id',
        fields => [qw(id client_id vin short_desc description lic_no lic_state owner)],
        columns => {
            id => {type => 'integer'}, client_id => {type => 'integer'}, vin => {type => 'string'},
            short_desc => {type => 'string'}, description => {type => 'string'},
            lic_no => {type => 'string'}, lic_state => {type => 'string'}, owner => {type => 'string'},
        }, associations => {},
    }, schemas => {}, joins => {},
    writes => {
        operations => {insert => {enabled => 1}, update => {enabled => 1}},
        fields => {
            client_id => {insertable => 1, required => 1}, vin => {insertable => 1, updatable => 1},
            short_desc => {insertable => 1, updatable => 1, required => 1},
            description => {insertable => 1, updatable => 1, required => 1},
            lic_no => {insertable => 1, updatable => 1, required => 1},
            lic_state => {insertable => 1, updatable => 1, required => 1},
            owner => {insertable => 1, updatable => 1, required => 1},
        },
    },
    imports => {
            contract_version => 1, enabled => 1, field_policy => 'declared_only',
            fields => {
                id => {sources => ['column'], header_aliases => ['Truck ID'], match_only => 1},
                client_id => {sources => ['trusted'], trusted_provider => 'current_client_id', blank_policy => 'error'},
                vin => {sources => ['column'], header_aliases => ['VIN'], transforms => [qw(trim uppercase)]},
                short_desc => {sources => ['column'], header_aliases => ['Truck Name']},
                description => {sources => ['static']}, lic_no => {sources => ['column']},
                lic_state => {sources => ['static']}, owner => {sources => ['static']},
            },
            actions => {
                record_odometer => {
                    inputs => {
                        miles => {
                            sources => ['column'], header_aliases => ['Odometer'],
                            transforms => ['trim'], blank_policy => 'error',
                        },
                        read_date => {sources => ['static']},
                    },
                },
            },
            key_sets => [
                {
                    id => 'vin', fields => ['vin'], cardinality => 'zero_or_one',
                    allowed_on_match => [qw(update skip error)], allowed_on_missing => [qw(insert skip error)],
                    default_on_match => 'update', default_on_missing => 'insert',
                },
                {
                    id => 'truck_id', fields => ['id'], cardinality => 'zero_or_one',
                    allowed_on_match => [qw(update skip error)], allowed_on_missing => [qw(skip error)],
                    default_on_match => 'update', default_on_missing => 'error',
                },
            ],
            idempotency => {supported => 1},
    },
    actions => {
        record_odometer => {
            label => 'Record Odometer', description => 'Record a reading.',
            type => 'bulk_action', scope => 'row', bulk => {enabled => 1},
            capability => 'equipment.record_odometer', execution => {kind => 'host', operation => 'record_odometer'},
            inputs => {
                miles => {label => 'Odometer miles', type => 'number', required => 1},
                read_date => {label => 'Odometer reading date', type => 'date'},
            },
        },
    },
}, strict => 1);

my $importer = Selecto::Importer->new(domain => $domain);
is $domain->imports->{contract_version}, 1, 'domain exposes the canonical imports contract';
is ref($domain->actions->{record_odometer}{inputs}), 'HASH', 'action inputs use the canonical keyed map';
my $inspection = $importer->inspect_csv("VIN,Truck Name,lic_no\n abc ,Unit 7,T7\nEXISTING,Only changed,T8\n");
is $inspection->{row_count}, 2, 'CSV inspection counts data rows';
is $inspection->{columns}[0]{header}, 'VIN', 'CSV inspection preserves headers';
is $inspection->{rows}[0]{values}{c1}, ' abc ', 'inspection preserves source values for transforms';

my $configuration = {
    config_version => 1, domain_fingerprint => $importer->domain_fingerprint,
    mappings => [
        {target => 'client_id', source => {kind => 'trusted'}},
        {target => 'vin', source => {kind => 'column', column_id => 'c1'}, transforms => [qw(trim uppercase)]},
        {target => 'short_desc', source => {kind => 'column', column_id => 'c2'}},
        {target => 'lic_no', source => {kind => 'column', column_id => 'c3'}},
        {target => 'description', source => {kind => 'static', value => 'Imported truck'}},
        {target => 'lic_state', source => {kind => 'static', value => 'CO'}},
        {target => 'owner', source => {kind => 'static', value => 'AAA'}},
    ],
    match => {key_set => 'vin', on_match => 'update', on_missing => 'insert'},
    idempotency => {mode => 'source_row'},
};
my $preview = $importer->preview_rows($inspection, $configuration,
    trusted_values => {current_client_id => 44},
    key_resolver => sub {
        my ($values) = @_;
        return {matches => $values->{vin} eq 'EXISTING' ? [{id => 19}] : []};
    },
);
is $preview->{rows}[0]{decision}, 'insert', 'missing VIN produces governed insert plan';
is $preview->{rows}[0]{assignments}{vin}, 'ABC', 'configured transforms are applied server-side';
is $preview->{rows}[0]{write}{assignments}{client_id}, 44, 'trusted client context supplies tenant assignment';
is $preview->{rows}[1]{decision}, 'update', 'matching VIN produces governed update plan';
is $preview->{rows}[1]{write}{filters}[0]{value}, 19, 'update is filtered to the resolved target ID';
ok !exists($preview->{rows}[1]{write}{assignments}{client_id}), 'insert-only trusted client is omitted from a matched update';
is scalar @{$preview->{rows}[1]{errors}}, 0, 'update does not require unrelated insert-only fields';

my $id_inspection = $importer->inspect_csv("Truck ID,Truck Name,Odometer\n19,Renamed unit,12345\n");
my $id_preview = $importer->preview_rows($id_inspection, {
    config_version => 1, domain_fingerprint => $importer->domain_fingerprint,
    mappings => [
        {target => 'id', source => {kind => 'column', column_id => 'c1'}},
        {target => 'client_id', source => {kind => 'trusted'}},
        {target => 'short_desc', source => {kind => 'column', column_id => 'c2'}},
    ],
    actions => [{
        action => 'record_odometer',
        inputs => {
            miles => {source => {kind => 'column', column_id => 'c3'}, transforms => ['trim']},
            read_date => {source => {kind => 'static', value => '2026-09-14'}},
        },
    }],
    match => {key_set => 'truck_id', on_match => 'update', on_missing => 'error'},
}, trusted_values => {current_client_id => 44}, key_resolver => sub {
    my ($values) = @_;
    return {matches => $values->{id} == 19 ? [{id => 19}] : []};
});
is $id_preview->{rows}[0]{decision}, 'update', 'a match-only ID can select an existing record';
is $id_preview->{rows}[0]{key}{id}, 19, 'match-only ID is passed to the key resolver';
ok !exists($id_preview->{rows}[0]{write}{assignments}{id}), 'match-only ID is never included in the governed write';
ok !exists($id_preview->{rows}[0]{write}{assignments}{client_id}), 'trusted insert-only client is not included in an ID-matched update';
is $id_preview->{rows}[0]{write}{assignments}{short_desc}, 'Renamed unit', 'mapped write fields remain governed assignments';
is $id_preview->{rows}[0]{actions}[0]{action}, 'record_odometer', 'published importer action is planned for a matched row';
is_deeply $id_preview->{rows}[0]{actions}[0]{target}, {ids => [19]}, 'import action targets the resolved governed record';
is $id_preview->{rows}[0]{actions}[0]{inputs}{miles}, 12345, 'action input is mapped from its file column';
is $id_preview->{rows}[0]{actions}[0]{inputs}{read_date}, '2026-09-14', 'date action input is mapped from a static ISO date';

my $invalid_date_preview = $importer->preview_rows($id_inspection, {
    config_version => 1, domain_fingerprint => $importer->domain_fingerprint,
    mappings => [{target => 'id', source => {kind => 'column', column_id => 'c1'}}],
    actions => [{action => 'record_odometer', inputs => {
        miles => {source => {kind => 'column', column_id => 'c3'}},
        read_date => {source => {kind => 'static', value => '09/14/2026'}},
    }}],
    match => {key_set => 'truck_id', on_match => 'update', on_missing => 'error'},
}, trusted_values => {current_client_id => 44}, key_resolver => sub { return {matches => [{id => 19}]}; });
is $invalid_date_preview->{rows}[0]{decision}, 'error', 'an invalid static action date fails while previewing';
is $invalid_date_preview->{rows}[0]{errors}[0]{code}, 'import_invalid_action_input', 'preview explains the invalid action date';

my $bad = {%$configuration, mappings => [grep { $_->{target} ne 'owner' } @{$configuration->{mappings}}]};
my $bad_preview = $importer->preview_rows($inspection, $bad,
    trusted_values => {current_client_id => 44}, key_resolver => sub { return {matches => []} },
);
is $bad_preview->{rows}[0]{decision}, 'error', 'missing required insert field fails before execution';
ok scalar(grep { $_->{field} eq 'owner' } @{$bad_preview->{rows}[0]{errors}}), 'required field error identifies owner';

my $error = eval {
    $importer->normalize_configuration({%$configuration, match => {key_set => 'bad'}}, columns => $inspection->{columns});
    undef;
} // $@;
is $error->code, 'import_key_set_not_found', 'unknown key sets fail closed';

my $unsafe_contract = $domain->contract;
$unsafe_contract->{imports}{key_sets}[0]{allowed_on_match} = ['insert'];
my $unsafe_domain = Selecto::Domain->parse($unsafe_contract, strict => 1);
my $unsafe_error = eval { Selecto::Importer->new(domain => $unsafe_domain); undef } // $@;
is $unsafe_error->code, 'invalid_import_contract', 'insert is never an allowed matched-row decision';

done_testing;
