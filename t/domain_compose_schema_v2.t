use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Domain::SchemaV2;

# Composition keeps domain schema 2: a schema 2 base composed with overlays is
# a schema 2 domain whose tenant survives and whose fingerprint is computed for
# the composed document.
my $V2 = 'Selecto::Domain::SchemaV2';

sub base {
    return {
        schema_version => 2, name => 'Orders',
        tenant => {field => 'org_id', pins => [['org_id', 7]]},
        source => {source_table => 'orders', primary_key => 'id', associations => {},
            columns => {id => {type => 'integer'}, org_id => {type => 'integer'}, total => {type => 'decimal'}}},
        schemas => {}, joins => {},
        filters => {total => {field => 'total', label => 'Total'}},
    };
}

sub error_of {
    my ($code) = @_;
    return eval { $code->(); 1 } ? undef : $@;
}

subtest 'no overlays: the same schema 2 domain' => sub {
    my $base = Selecto::Domain->parse(base());
    my $composed = Selecto::Domain->compose(base());
    is($composed->schema_version, 2, 'schema 2');
    is($composed->fingerprint, $base->fingerprint, 'the same computed fingerprint');
    is($base->compose->fingerprint, $base->fingerprint, 'from a parsed domain too');
    is_deeply($composed->as_document, base(), 'as_document is the schema 2 document');
};

subtest 'overlays: schema 2 kept, tenant kept, fingerprint recomputed' => sub {
    my $overlay = {
        source => {columns => {note => {type => 'string', description => 'Free text'}}},
        filters => {total => {label => 'Order total'}},
    };
    for my $base (base(), Selecto::Domain->parse(base())) {
        my ($domain, $diagnostics) = Selecto::Domain->compose($base, $overlay);
        is($domain->schema_version, 2, 'the composed domain is schema 2');
        is_deeply($domain->schema_diagnostics, [], 'and reports no deprecation');
        my $document = $domain->as_document;
        is_deeply($document->{tenant}, {field => 'org_id', pins => [['org_id', 7]]}, 'the top-level tenant survives');
        ok(!exists($document->{source}{fields}) && !exists($document->{source}{tenant_field}), 'no schema 1 keys');
        is($document->{filters}{total}{field}, 'total', 'maps deep-merge');
        is($domain->fingerprint, $V2->fingerprint($document), 'the fingerprint is computed for the composed document');
        isnt($domain->fingerprint, Selecto::Domain->parse(base())->fingerprint, 'and differs from the base');
        is($domain->tenant_field, 'org_id', 'the tenant reaches the engine');
        is($domain->field_description('note'), 'Free text', 'the overlay column is a field');
        is_deeply($V2->validate($document), [], 'the composed document is valid schema 2');
        my $reparsed = Selecto::Domain->parse({%$document, domain_fingerprint => $domain->fingerprint});
        is($reparsed->fingerprint, $domain->fingerprint, 'it loads like any schema 2 document, declared fingerprint and all');
        is_deeply($diagnostics->{errors}, [], 'no errors');
    }
    is_deeply(Selecto::Domain::Overlay->merge_contracts(base(), $overlay)->{tenant}, base()->{tenant},
        'merge_contracts returns the schema 2 document');
};

subtest 'a declared base fingerprint is replaced by the computed one' => sub {
    my $base = base();
    $base->{domain_fingerprint} = $V2->fingerprint($base);
    my $domain = Selecto::Domain->compose($base, {source => {columns => {note => {type => 'string'}}}});
    ok(!exists($domain->as_document->{domain_fingerprint}), 'the stale declaration is dropped');
    is($domain->fingerprint, $V2->fingerprint($domain->as_document), 'the fingerprint is computed');
};

subtest 'an overlay tenant deep-merges' => sub {
    my $domain = Selecto::Domain->compose(base(), {tenant => {satisfied_by => ['trusted_context']}});
    is_deeply($domain->as_document->{tenant},
        {field => 'org_id', pins => [['org_id', 7]], satisfied_by => ['trusted_context']}, 'field and pins kept');
    is_deeply($domain->contract->{writes}{scope}{tenant}{satisfied_by}, ['trusted_context'], 'and it reaches the write scope');
    my $error = error_of(sub { Selecto::Domain->compose(base(), {tenant => {field => 'missing'}}) });
    is(blessed($error) && $error->details->{reason}, 'invalid_tenant_field', 'a tenant on no column refuses as schema 2 does');
};

subtest 'schema 1 shaped overlays' => sub {
    my $domain = Selecto::Domain->compose(base(), {
        source => {fields => [qw(total id org_id note)], columns => {note => {type => 'string'}}},
    });
    my $document = $domain->as_document;
    ok(!exists $document->{source}{fields}, 'a fields list is not kept');
    is_deeply($document->{source}{field_order}, [qw(total id org_id note)], 'it becomes the field_order');

    $domain = Selecto::Domain->compose(base(), {
        source => {fields => [qw(id note org_id total)], columns => {note => {type => 'string'}}},
    });
    ok(!exists $domain->as_document->{source}{field_order}, 'the sorted order needs no field_order');

    my $ordered = base();
    $ordered->{source}{field_order} = [qw(total org_id id)];
    $domain = Selecto::Domain->compose($ordered, {source => {columns => {b => {type => 'string'}, a => {type => 'string'}}}});
    is_deeply($domain->as_document->{source}{field_order}, [qw(total org_id id a b)],
        'columns added under a base field_order are appended, sorted');

    $domain = Selecto::Domain->compose(base(), {schemas => {customer => {source_table => 'customers', primary_key => 'id',
        fields => [qw(name id)], columns => {id => {type => 'integer'}, name => {type => 'string'}}}}});
    is_deeply($domain->as_document->{schemas}{customer}{field_order}, [qw(name id)], 'an overlay relation in schema 1 shape too');

    my %refusals = (
        overlay_fields_not_columns => {source => {fields => [qw(id total)]}},
        tenant_field_removed => {source => {tenant_field => 'org_id'}},
        writes_scope_tenant_removed => {writes => {scope => {tenant => {field => 'org_id'}}}},
        overlay_schema_version => {schema_version => 1},
        domain_fingerprint_computed => {domain_fingerprint => 'orders-v1'},
    );
    for my $reason (sort keys %refusals) {
        my $error = error_of(sub { Selecto::Domain->compose(base(), {}, $refusals{$reason}) });
        is(blessed($error) && $error->code, 'invalid_domain_overlay', "$reason refuses");
        is(blessed($error) && $error->details->{reason}, $reason, "with reason $reason");
    }
    my $error = error_of(sub { Selecto::Domain->compose(base(), {}, {source => {tenant_field => 'org_id'}}) });
    is($error->details->{overlay_index}, 1, 'naming the overlay');
    ok(Selecto::Domain->compose(base(), {schema_version => 2}), 'an overlay may restate schema_version 2');
};

subtest 'a schema 1 base stays schema 1' => sub {
    my $v1 = $V2->to_version_1(base());
    my $domain = Selecto::Domain->compose($v1, {source => {tenant_field => 'org_id'}});
    is($domain->schema_version, 1, 'schema 1');
    is($domain->as_contract->{schema_version}, 1, 'as_document is its contract');
};

subtest 'a derived domain composes from its migrated contract' => sub {
    my $base = base();
    $base->{actions} = {archive => {label => 'Archive', capability => 'archive',
        execution => {kind => 'write_operation', operation => 'archive'}}};
    my $domain = eval { Selecto::Domain->parse($base) };
    plan skip_all => "this action shape does not parse: $@" unless $domain;
    my $derived = $domain->without_action_prerequisites('archive');
    my $composed = $derived->compose;
    is($composed->schema_version, 2, 'still schema 2');
    is($composed->fingerprint, $V2->fingerprint($composed->as_document), 'computed fingerprint');
};

subtest 'compose_identity keeps schema 2' => sub {
    my $overlay = {source => {columns => {note => {type => 'string'}}}};
    for my $base (base(), Selecto::Domain->parse(base())) {
        my $result = Selecto::Domain->compose_identity($base, [$overlay]);
        ok($result->{ok}, 'composes');
        my $normalized = $result->{normalized};
        is($normalized->{schema_version}, 2, 'schema 2');
        ok(!grep({ $_->{code} eq 'unsupported_schema_version' } @{$result->{diagnostics}{warnings}}), 'schema 2 is supported');
        is_deeply($normalized->{domain}{tenant}, base()->{tenant}, 'the tenant survives');
        ok(!exists $normalized->{domain}{writes}, 'no writes key is added');
        my $document = {%{$normalized->{domain}}};
        delete $document->{domain_fingerprint};
        is($normalized->{domain_fingerprint}, $V2->fingerprint($document), 'domain_fingerprint is computed for the composed document');
        is(Selecto::Domain->parse($normalized->{domain})->fingerprint, $normalized->{domain_fingerprint},
            'and the composed document loads with it');
        ok(Selecto::Domain->validate_identity($normalized->{domain})->{ok}, 'it validates');
    }
    my $result = Selecto::Domain->compose_identity(base(), [{source => {tenant_field => 'org_id'}}]);
    ok(!$result->{ok}, 'a schema 1 tenancy key is an error');
    is($result->{diagnostics}{errors}[0]{code}, 'tenant_field_removed', 'naming the rule');
    is($result->{diagnostics}{errors}[0]{overlay_index}, 0, 'and the overlay');
    $result = Selecto::Domain->validate_identity({%{base()}, source => {%{base()->{source}}, fields => ['id']}});
    is($result->{diagnostics}{errors}[0]{code}, 'fields_removed', 'validate_identity applies the schema 2 rules');
};

done_testing;
