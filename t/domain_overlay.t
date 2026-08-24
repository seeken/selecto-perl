use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;

sub base_contract {
    return {
        schema_version => 1,
        domain_version => '1.0.0',
        name => 'Orders',
        source => {
            source_table => 'orders',
            primary_key => 'id',
            fields => [qw(id status total)],
            columns => {
                id => {type => 'integer'},
                status => {type => 'string'},
                total => {type => 'decimal'},
            },
            associations => {},
            redact_fields => ['internal_notes'],
        },
        schemas => {},
        joins => {},
        filters => {
            status => {field => 'status', label => 'Status'},
        },
        capabilities => {
            export => {operations => ['read']},
        },
        redact_fields => ['private_token'],
        extensions => ['BaseExtension'],
    };
}

my $overlay_one = Selecto::Domain::DSL->define(sub {
    my ($dsl) = @_;
    $dsl
        ->source_column(total => {label => 'Total'})
        ->source_redact_fields('tenant_secret')
        ->filter(status => {label => 'Order Status'})
        ->write_operation(update => {enabled => JSON::PP::true})
        ->write_field(status => {updatable => JSON::PP::true})
        ->query_view(open_orders => {segments => ['open']})
        ->component(query_params => JSON::PP::true)
        ->capability(export => {description => 'Export visible orders'})
        ->redact_fields('audit_secret')
        ->extensions('AuditExtension');
});

my $overlay_two = Selecto::Domain::DSL->new
    ->source_column(total => {format => 'currency'})
    ->source_redact_fields('tenant_secret')
    ->source_redact_fields(qw(tenant_secret audit_token))
    ->required_selected(qw(id status))
    ->capability(export => {operations => [qw(read csv)]})
    ->extensions('AuditExtension')
    ->extensions(qw(AuditExtension TenantExtension));

my $base = base_contract();
my ($domain, $diagnostics) = Selecto::Domain->compose($base, $overlay_one, $overlay_two);
isa_ok($domain, 'Selecto::Domain', 'composition returns a validated domain');
my $contract = $domain->contract;
is_deeply(
    $contract->{source}{columns}{total},
    {type => 'decimal', label => 'Total', format => 'currency'},
    'ordered overlays deep-merge nested source column metadata',
);
is_deeply(
    $contract->{source}{redact_fields},
    [qw(internal_notes tenant_secret audit_token)],
    'source redactions union uniquely in declaration order',
);
is_deeply(
    $contract->{redact_fields},
    [qw(private_token audit_secret)],
    'top-level redactions union uniquely',
);
is_deeply(
    $contract->{extensions},
    [qw(BaseExtension AuditExtension TenantExtension)],
    'extensions append uniquely across overlays',
);
is_deeply($contract->{required_selected}, [qw(id status)], 'ordinary lists are replaced');
is($contract->{filters}{status}{field}, 'status', 'deep merge preserves existing filter fields');
is($contract->{filters}{status}{label}, 'Order Status', 'deep merge applies filter override');
ok($contract->{writes}{operations}{update}{enabled}, 'write operation DSL builds governance data');
ok($contract->{writes}{fields}{status}{updatable}, 'write field DSL builds governance data');
is_deeply(
    $contract->{query_library}{views}{open_orders},
    {segments => ['open']},
    'query-library DSL builds named definitions',
);
ok($domain->components->{query_params}, 'component policy survives validation');
is($diagnostics->{overlay_count}, 2, 'diagnostics report the applied overlay count');
is(scalar(@{$diagnostics->{warnings}}), 2, 'each governance collision is reported');
is_deeply(
    [map { [$_->{code}, $_->{section}, $_->{key}, $_->{overlay_index}] }
        @{$diagnostics->{warnings}}],
    [
        ['domain_composition_collision', 'capabilities', 'export', 0],
        ['domain_composition_collision', 'capabilities', 'export', 1],
    ],
    'collision diagnostics identify the exact registry entry and overlay',
);
is_deeply(
    base_contract(),
    $base,
    'composition does not mutate the authored base contract',
);

my $simple = Selecto::Domain->new(
    name => 'People',
    table => 'people',
    fields => {id => 'integer', team_id => 'integer'},
    associations => {
        team => {
            table => 'teams',
            fields => {id => 'integer', name => 'string', region_id => 'integer'},
            owner_key => 'team_id',
            related_key => 'id',
            associations => {
                region => {
                    table => 'regions',
                    fields => {id => 'integer', name => 'string'},
                    owner_key => 'region_id', related_key => 'id',
                },
            },
        },
    },
);
my $simple_composed = $simple->compose(
    Selecto::Domain::DSL->define(sub {
        $_[0]->source_column(id => {label => 'Person ID'});
    }),
);
is($simple_composed->contract->{source}{columns}{id}{label}, 'Person ID',
    'constructor domains are promoted to portable contracts for composition');
is($simple_composed->resolve('team.name')->{type}, 'string',
    'constructor-domain associations survive contract promotion');
is($simple_composed->resolve('team.region.name')->{type}, 'string',
    'contract promotion preserves constructor-domain relationships at arbitrary depth');
my $promoted_contract = $simple_composed->contract;
my $team_schema = $promoted_contract->{source}{associations}{team}{queryable};
my $region_schema = $promoted_contract->{schemas}{$team_schema}{associations}{region}{queryable};
is($promoted_contract->{schemas}{$region_schema}{source_table}, 'regions',
    'promoted canonical schemas retain the nested relationship target');

my ($merged_contract, $merged_diagnostics) = Selecto::Domain::Overlay->merge_contracts(
    base_contract(),
    {default_selected => ['id']},
);
is_deeply($merged_contract->{default_selected}, ['id'], 'contract-only composition is available');
is($merged_diagnostics->{overlay_count}, 1, 'contract-only composition returns diagnostics');

my $error;
eval { Selecto::Domain->compose(base_contract(), 'not-an-overlay'); 1 } or $error = $@;
isa_ok($error, 'Selecto::Error', 'invalid overlay shape is typed');
is($error->code, 'invalid_domain_overlay', 'invalid overlay fails at the composition boundary');
is($error->details->{overlay_index}, 0, 'invalid overlay identifies its index');

eval { Selecto::Domain->compose(base_contract(), {writes => []}); 1 } or $error = $@;
is($error->code, 'invalid_domain_overlay', 'malformed overlay sections fail before merging');
is($error->details->{section}, 'writes', 'malformed overlay identifies its section');

eval {
    Selecto::Domain->compose(base_contract(), {
        source => {fields => [qw(id missing)]},
    });
    1;
} or $error = $@;
isa_ok($error, 'Selecto::Error', 'invalid composed domain is typed');
is($error->code, 'invalid_domain', 'composition validates the final domain fail closed');

done_testing;
