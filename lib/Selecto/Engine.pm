package Selecto::Engine;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Domain::Ref ();
use Selecto::Domain::Registry ();
use Selecto::Error ();
use Selecto::Query ();
use Selecto::QueryEnforcement ();
use Selecto::QueryLibrary ();
use Selecto::Write ();
use Selecto::Write::Expression ();

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_domain', 'engine requires a domain')
        unless blessed($args{domain}) && $args{domain}->isa('Selecto::Domain');
    Selecto::Error->throw('invalid_adapter', 'engine requires a Selecto database adapter')
        unless blessed($args{adapter}) && $args{adapter}->isa('Selecto::Adapter');
    Selecto::Error->throw('invalid_domain_ref', 'engine domain_ref must be a Selecto domain reference')
        if defined($args{domain_ref})
            && !(blessed($args{domain_ref}) && $args{domain_ref}->isa('Selecto::Domain::Ref'));
    $args{adapter}->assert_contract;
    return bless {
        domain => $args{domain},
        adapter => $args{adapter},
        domain_ref => $args{domain_ref},
    }, $class;
}

sub from_registry {
    my ($class, %args) = @_;
    my $subject = $args{domain};
    my $registry = $args{registry};
    Selecto::Error->throw('invalid_adapter', 'engine requires a Selecto database adapter')
        unless blessed($args{adapter}) && $args{adapter}->isa('Selecto::Adapter');
    if (blessed($subject) && $subject->isa('Selecto::Domain::Ref')) {
        $registry //= $subject->registry;
    }
    Selecto::Error->throw('invalid_domain_registry', 'registered engine requires a domain registry')
        unless blessed($registry) && $registry->isa('Selecto::Domain::Registry');
    my ($domain, $ref) = blessed($subject) && $subject->isa('Selecto::Domain::Ref')
        ? $registry->resolve_ref($subject, $args{context})
        : $registry->resolve($subject, $args{context});
    return $class->new(
        domain => $domain,
        domain_ref => $ref,
        adapter => $args{adapter},
    );
}

sub domain  { return $_[0]->{domain}; }
sub adapter { return $_[0]->{adapter}; }
sub domain_ref { return $_[0]->{domain_ref}; }
sub query   { return Selecto::Query->new; }
sub compile { my ($self, $query) = @_; return $self->{adapter}->compile($self->{domain}, $query); }
sub all     { my ($self, $query) = @_; return $self->{adapter}->execute_query($self->compile($query)); }
sub stream {
    my ($self, $query, %options) = @_;
    Selecto::Error->throw('unsupported_feature', 'configured adapter does not support streaming')
        unless $self->{adapter}->supports('stream') && $self->{adapter}->can('stream_query');
    return $self->{adapter}->stream_query($self->compile($query), %options);
}
sub preview_write {
    my ($self, $command) = @_;
    $self->_validate_write_command($command);
    return $self->{adapter}->preview_write($command);
}
sub execute_write {
    my ($self, $command) = @_;
    $self->_validate_write_command($command);
    return $self->{adapter}->execute_write($command);
}
sub execute_batch {
    my ($self, $batch) = @_;
    Selecto::Error->throw('invalid_write', 'execute_batch requires a Selecto::Write::Batch')
        unless blessed($batch) && $batch->isa('Selecto::Write::Batch');
    $self->_validate_write_command($_) for @{$batch->commands};
    return $self->{adapter}->execute_batch($batch);
}
sub execute_graph {
    my ($self, $graph) = @_;
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    my @nodes = @{$graph->nodes};
    $self->_validate_write_command($nodes[0]{command});
    my %contexts = ($nodes[0]{id} => {
        table         => $self->{domain}->table,
        primary_key   => $self->{domain}->primary_key,
        fields        => $self->{domain}->fields,
        fields_known  => 1,
        writes        => _checked_writes($self->{domain}->writes),
        relationships => _checked_writes($self->{domain}->writes)->{relationships},
    });
    for my $node (@nodes[1 .. $#nodes]) {
        $contexts{$node->{id}} = $self->_validate_graph_node($node, \%contexts);
    }
    return $self->{adapter}->execute_graph($graph);
}
sub query_library { my ($self) = @_; return Selecto::QueryLibrary->library($self->domain); }
sub apply_segment {
    my ($self, $query, $id, $params) = @_;
    return Selecto::QueryLibrary->apply_segment($self->domain, $query, $id, $params // {});
}
sub apply_segments {
    my ($self, $query, $ids, $params) = @_;
    return Selecto::QueryLibrary->apply_segments($self->domain, $query, $ids, $params // {});
}
sub apply_projection {
    my ($self, $query, $ids) = @_;
    return Selecto::QueryLibrary->apply_projection($self->domain, $query, $ids);
}
sub apply_ordering {
    my ($self, $query, $id) = @_;
    return Selecto::QueryLibrary->apply_ordering($self->domain, $query, $id);
}
sub apply_view {
    my ($self, $query, $id, $params) = @_;
    return Selecto::QueryLibrary->apply_view($self->domain, $query, $id, $params // {});
}

sub enforce_query {
    my ($self, $command, $query) = @_;
    return $self->enforce_query_evidence(
        $command,
        Selecto::QueryEnforcement->capture($self->domain, $query),
    );
}

sub enforce_query_evidence {
    my ($self, $command, $evidence) = @_;
    Selecto::Error->throw('query_enforcement_unsupported_operation', 'query-enforced upsert is not supported')
        if $command->operation eq 'upsert';
    Selecto::QueryEnforcement::validate_source($self->domain, $command->relation, $evidence);
    my $tenant_field = $self->domain->tenant_field;
    Selecto::Error->throw('missing_tenant_scope', 'trusted tenant scope is required')
        if defined($tenant_field) && !_has_tenant_conjunct($command->scope_predicate, $tenant_field);
    return $command->with_query_enforcement($evidence);
}

# A scope counts as tenant-scoped only when a positive conjunct (eq or in over
# literals) constrains the tenant field at the top level of the AND tree.
# Negations and OR branches never satisfy the requirement.
sub _has_tenant_conjunct {
    my ($expression, $field) = @_;
    return 0 unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    return _is_tenant_comparison($expression, $field)
        if $kind eq 'eq' || $kind eq 'in';
    return 0 unless $kind eq 'and';
    for my $conjunct (@{$expression->arguments->[0] // []}) {
        return 1 if _has_tenant_conjunct($conjunct, $field);
    }
    return 0;
}

sub _is_tenant_comparison {
    my ($expression, $field) = @_;
    my @arguments = @{$expression->arguments};
    return 0 unless @arguments >= 2;
    my $operand = $arguments[0];
    return 0 unless blessed($operand) && $operand->isa('Selecto::Expression');
    return 0 unless $operand->kind eq 'field';
    return 0 unless $operand->arguments->[0] eq $field;
    my $value = $arguments[1];
    if ($expression->kind eq 'eq') {
        return blessed($value) && $value->isa('Selecto::Expression') && $value->kind eq 'literal';
    }
    return 0 unless ref($value) eq 'ARRAY' && @$value;
    # Selecto::Expression->in stores raw scalar list elements; each is bound
    # as a parameter downstream, so only defined non-references qualify.
    for my $element (@$value) {
        return 0 if !defined($element) || ref($element);
    }
    return 1;
}

# Writes are governed by the engine's domain by default: commands must target
# the domain table, assignment fields must be declared root fields, and when
# the contract declares a writes section its per-operation switches and
# per-field permissions are enforced. enforce_query remains the row-guard.
sub _validate_write_command {
    my ($self, $command) = @_;
    Selecto::Error->throw('invalid_write', 'write command required')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    Selecto::Error->throw(
        'write_relation_mismatch',
        'write relation must be the domain table',
        { relation => $command->relation, expected => $self->{domain}->table },
    ) unless $command->relation eq $self->{domain}->table;
    if (defined $command->query_enforcement) {
        Selecto::QueryEnforcement::validate_source($self->{domain}, $command->relation, $command->query_enforcement);
        my $tenant_field = $self->{domain}->tenant_field;
        Selecto::Error->throw('missing_tenant_scope', 'trusted tenant scope is required')
            if defined($tenant_field) && !_has_tenant_conjunct($command->scope_predicate, $tenant_field);
    }
    return $self->_validate_command_against_contract(
        $command,
        fields      => $self->{domain}->fields,
        writes      => _checked_writes($self->{domain}->writes),
        allowed_ops => undef,
        label       => $command->relation,
    );
}

# Present-but-malformed write sections fail closed; absent sections stay optional.
sub _checked_writes {
    my ($writes) = @_;
    return {} unless defined($writes);
    Selecto::Error->throw('invalid_domain', 'writes section must be an object')
        unless ref($writes) eq 'HASH';
    for my $key (qw(operations fields relationships)) {
        next unless exists($writes->{$key}) && defined($writes->{$key});
        Selecto::Error->throw('invalid_domain', "writes.$key must be an object")
            unless ref($writes->{$key}) eq 'HASH';
    }
    return $writes;
}

sub _validate_command_against_contract {
    my ($self, $command, %context) = @_;
    my $operation = $command->operation;
    if ($context{allowed_ops}) {
        my %allowed = map { ("$_" => 1) } @{$context{allowed_ops}};
        Selecto::Error->throw(
            'write_operation_not_enabled',
            "operation $operation is not allowed for this relationship",
        ) unless $allowed{$operation};
    }
    my $writes = _checked_writes($context{writes});
    my $fields_spec = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : undef;
    if (ref($writes->{operations}) eq 'HASH') {
        my $op_spec = $writes->{operations}{$operation};
        Selecto::Error->throw(
            'write_operation_not_enabled',
            "operation $operation is not enabled by the write contract",
        ) unless ref($op_spec) eq 'HASH' && $op_spec->{enabled};
    }
    my $domain_fields = $context{fields};
    my $label = $context{label} // $command->relation;
    my $permission = $operation eq 'insert' || $operation eq 'upsert' ? 'insertable' : 'updatable';
    if ($domain_fields && $operation ne 'delete') {
        for my $field (sort keys %{$command->assignments}) {
            Selecto::Error->throw('unknown_field', "write field is not declared by $label", { field => $field })
                unless exists $domain_fields->{$field};
            next unless defined($fields_spec);
            my $spec = $fields_spec->{$field};
            Selecto::Error->throw(
                'write_field_not_writable',
                "field is not writable per the $label write contract",
                { field => $field },
            ) unless ref($spec) eq 'HASH' && $spec->{$permission};
        }
        for my $field (_mutation_reference_fields($command->assignments)) {
            Selecto::Error->throw(
                'unknown_field',
                "mutation expression field is not declared by $label",
                { field => $field },
            ) unless exists $domain_fields->{$field};
        }
    }
    return $self unless $domain_fields;
    # Metadata is validated for every operation, deletes included.
    my $metadata = $command->metadata;
    for my $key (qw(conflict_target returning)) {
        my $value = $metadata->{$key};
        next unless exists($metadata->{$key}) && defined($value);
        Selecto::Error->throw('invalid_write', "$key must be an array of field names")
            unless ref($value) eq 'ARRAY';
        for my $field (@$value) {
            Selecto::Error->throw('invalid_write', "$key entries must be field names")
                if ref($field);
            Selecto::Error->throw('unknown_field', "$key field is not declared by $label", { field => "$field" })
                unless exists $domain_fields->{"$field"};
        }
    }
    if ($operation eq 'upsert') {
        my $updates = $metadata->{upsert_update_fields};
        Selecto::Error->throw('invalid_write', 'upsert requires declared update fields')
            unless ref($updates) eq 'ARRAY' && @$updates;
        for my $field (@$updates) {
            Selecto::Error->throw('invalid_write', 'upsert update fields must be field names') if ref($field);
            Selecto::Error->throw('unknown_field', "upsert update field is not declared by $label", { field => "$field" })
                unless exists $domain_fields->{"$field"};
            next unless defined($fields_spec);
            my $spec = $fields_spec->{"$field"};
            Selecto::Error->throw(
                'write_field_not_writable',
                "upsert cannot update this field per the $label write contract",
                { field => "$field" },
            ) unless ref($spec) eq 'HASH' && $spec->{updatable};
        }
    }
    return $self;
}

sub _mutation_reference_fields {
    my ($assignments) = @_;
    my %fields;
    for my $value (values %$assignments) {
        next unless blessed($value) && $value->isa('Selecto::Write::Expression');
        $fields{$_} = 1 for @{$value->referenced_fields};
    }
    return sort keys %fields;
}

# Graph authorization is edge-aware: every child node must bind through a
# writable relationship declared on the exact parent node it references, and
# the binding must name that relationship's parent_key and child_key.
sub _validate_graph_node {
    my ($self, $node, $contexts) = @_;
    my $command = $node->{command};
    Selecto::Error->throw('invalid_write_graph', 'graph node requires a write command')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    my $bindings = $node->{bindings} // [];
    Selecto::Error->throw('invalid_write_graph', 'graph child must bind to its declared parent')
        unless @$bindings;
    my $edge;
    my $edge_id;
    for my $binding (@$bindings) {
        Selecto::Error->throw('invalid_write_graph', 'graph binding scope field must match its relationship field')
            if defined($binding->{scope_field}) && $binding->{scope_field} ne $binding->{field};
        my $parent = $contexts->{$binding->{from}};
        Selecto::Error->throw('invalid_write_graph', "graph binding references unavailable node $binding->{from}")
            unless $parent;
        my $found = $self->_match_relationship($parent, $binding, $command->relation);
        Selecto::Error->throw(
            'write_relation_mismatch',
            'graph binding does not match a declared writable relationship of its parent',
            { relation => $command->relation, parent => $binding->{from} },
        ) unless $found;
        # Every binding on the node must resolve to the same declared
        # relationship; mixing edges lets binding order pick the contract.
        if (defined($edge_id)) {
            Selecto::Error->throw(
                'write_relation_mismatch',
                'graph node binds through conflicting relationships',
                { relation => $command->relation, parent => $binding->{from} },
            ) unless $found->{edge_id} eq $edge_id;
        } else {
            $edge = $found;
            $edge_id = $found->{edge_id};
        }
    }
    my %nested_fields = %{$edge->{fields} // {}};
    $self->_validate_command_against_contract($command,
        ($edge->{fields_known} ? (fields => \%nested_fields) : (fields => undef)),
        writes      => $edge->{writes},
        allowed_ops => $edge->{allowed_ops},
        label       => $command->relation,
    );
    return {
        table         => $edge->{table},
        primary_key   => $edge->{primary_key},
        fields_known  => $edge->{fields_known},
        fields        => $edge->{fields},
        writes        => $edge->{writes},
        relationships => $edge->{relationships},
    };
}

sub _match_relationship {
    my (undef, $parent_context, $binding, $relation) = @_;
    my $relationships = $parent_context->{relationships};
    return undef unless ref($relationships) eq 'HASH';
    my $chosen;
    for my $name (sort keys %$relationships) {
        my $spec = $relationships->{$name};
        next unless ref($spec) eq 'HASH' && $spec->{writable};
        my $table = defined($spec->{table}) ? "$spec->{table}"
            : ref($spec->{domain}) eq 'HASH' && ref($spec->{domain}{source}) eq 'HASH'
                ? "$spec->{domain}{source}{source_table}" : undef;
        next unless defined($table) && $table eq $relation;
        my $child_key = defined($spec->{child_key}) ? "$spec->{child_key}"
            : defined($spec->{foreign_key}) ? "$spec->{foreign_key}" : undef;
        next unless defined($child_key) && "$binding->{field}" eq $child_key;
        my $parent_key = defined($spec->{parent_key}) ? "$spec->{parent_key}" : $parent_context->{primary_key};
        next unless defined($parent_key) && "$binding->{key}" eq $parent_key;
        my $candidate = _relationship_context($spec, $table,
            "$parent_context->{table}>$table/$child_key/$parent_key");
        Selecto::Error->throw(
            'invalid_domain',
            'relationship parent_key is not declared by its parent domain',
            {relationship => $name, field => $parent_key},
        ) if $parent_context->{fields_known}
            && !exists($parent_context->{fields}{$parent_key});
        Selecto::Error->throw(
            'invalid_domain',
            'relationship child_key is not declared by its nested domain',
            {relationship => $name, field => $child_key},
        ) if $candidate->{fields_known}
            && !exists($candidate->{fields}{$child_key});
        # Duplicate declarations of one physical edge must not let naming
        # order pick the governing policy.
        if ($chosen) {
            Selecto::Error->throw(
                'invalid_domain',
                'conflicting duplicate relationship declarations for one physical edge',
                { relation => $relation, parent => $parent_context->{table} },
            ) unless _same_contract($chosen, $candidate);
        } else {
            $chosen = $candidate;
        }
    }
    return $chosen;
}

sub _same_contract {
    my ($a, $b) = @_;
    return JSON::PP->new->canonical(1)->encode({
        map { ($_ => $a->{$_}) } grep { $_ ne 'edge_id' } sort keys %$a
    }) eq JSON::PP->new->canonical(1)->encode({
        map { ($_ => $b->{$_}) } grep { $_ ne 'edge_id' } sort keys %$b
    });
}

sub _relationship_context {
    my ($spec, $table, $edge_id) = @_;
    $spec //= {};
    if (exists($spec->{allowed_ops}) && defined($spec->{allowed_ops})) {
        Selecto::Error->throw('invalid_domain', 'relationship allowed_ops must be an array of operation names')
            unless ref($spec->{allowed_ops}) eq 'ARRAY'
            && !grep {
                !defined($_) || ref($_) || "$_" !~ /\A(?:insert|update|upsert|delete)\z/
            } @{$spec->{allowed_ops}};
    }
    my $nested = ref($spec->{domain}) eq 'HASH' ? $spec->{domain} : {};
    my $nested_writes = _checked_writes($nested->{writes});
    my $fields_known = ref($nested->{source}) eq 'HASH' && ref($nested->{source}{fields}) eq 'ARRAY';
    return {
        ($edge_id ? (edge_id => $edge_id) : ()),
        ($table ? (table => $table) : ()),
        ($fields_known ? (
            fields => { map { ("$_" => 1) } map { "$_" } @{$nested->{source}{fields}} },
            primary_key => defined($nested->{source}{primary_key}) ? "$nested->{source}{primary_key}" : 'id',
        ) : ()),
        fields_known  => $fields_known,
        writes        => $nested_writes,
        relationships => $nested_writes->{relationships},
        allowed_ops   => [map { "$_" } @{$spec->{allowed_ops} // []}],
    };
}

1;
