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
use Selecto::Write::Scope ();
use Selecto::Action::Capability ();
use Selecto::Action::Planner ();

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
        scope => _trusted_scope($args{scope}),
    }, $class;
}

# Trusted scope comes from the host that built the engine (for example from an
# authenticated request), never from a write command or an action intent.
sub _trusted_scope {
    my ($scope) = @_;
    return {} unless defined $scope;
    Selecto::Error->throw('invalid_tenant_scope', 'engine scope must be an object')
        unless ref($scope) eq 'HASH';
    my @unknown = sort grep { $_ ne 'tenant' } keys %$scope;
    Selecto::Error->throw('invalid_tenant_scope', 'engine scope contains unsupported keys', {keys => \@unknown})
        if @unknown;
    my $tenant = Selecto::Write::Scope->trusted_tenant($scope->{tenant});
    return defined($tenant) ? {tenant => $tenant} : {};
}

sub scope { return {%{$_[0]->{scope}}}; }

# A copy of this engine bound to trusted scope. An engine that already holds a
# tenant cannot be re-scoped to a different one.
sub with_scope {
    my ($self, %scope) = @_;
    my $next = _trusted_scope(\%scope);
    my $current = $self->{scope}{tenant};
    Selecto::Error->throw('tenant_mismatch', 'engine is already scoped to a different tenant')
        if defined($current) && defined($next->{tenant}) && "$current" ne "$next->{tenant}";
    my $copy = bless {%$self}, ref($self);
    $copy->{scope} = {%{$self->{scope}}, %$next};
    return $copy;
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
        (defined($args{scope}) ? (scope => $args{scope}) : ()),
    );
}

sub domain  { return $_[0]->{domain}; }
sub adapter { return $_[0]->{adapter}; }
sub domain_ref { return $_[0]->{domain_ref}; }
sub query   { return Selecto::Query->new; }
sub compile { my ($self, $query) = @_; return $self->{adapter}->compile($self->{domain}, $query); }
sub all     { my ($self, $query) = @_; return $self->{adapter}->execute_query($self->compile($query)); }
sub projection_sum {
    my ($self, $query, $column) = @_;
    Selecto::Error->throw('unsupported_feature', 'configured adapter does not support projection sums')
        unless $self->{adapter}->supports('projection_sum')
            && $self->{adapter}->can('projection_sum_statement');
    my $statement = $self->{adapter}->projection_sum_statement($self->compile($query), $column);
    my $result = $self->{adapter}->execute_query($statement);
    my $rows = $result->{rows};
    Selecto::Error->throw('invalid_query', 'projection sum returned an invalid result')
        unless ref($rows) eq 'ARRAY' && @$rows == 1
            && ref($rows->[0]) eq 'ARRAY' && @{$rows->[0]} == 1
            && defined($rows->[0][0]);
    return $rows->[0][0];
}
sub stream {
    my ($self, $query, %options) = @_;
    Selecto::Error->throw('unsupported_feature', 'configured adapter does not support streaming')
        unless $self->{adapter}->supports('stream') && $self->{adapter}->can('stream_query');
    return $self->{adapter}->stream_query($self->compile($query), %options);
}
sub preview_write {
    my ($self, $command) = @_;
    return $self->{adapter}->preview_write($self->governed_write($command));
}
sub execute_write {
    my ($self, $command) = @_;
    return $self->{adapter}->execute_write($self->governed_write($command));
}
sub execute_batch {
    my ($self, $batch) = @_;
    Selecto::Error->throw('invalid_write', 'execute_batch requires a Selecto::Write::Batch')
        unless blessed($batch) && $batch->isa('Selecto::Write::Batch');
    my @commands = map { $self->governed_write($_) } @{$batch->commands};
    return $self->{adapter}->execute_batch(Selecto::Write::Batch->new(@commands));
}
sub execute_graph {
    my ($self, $graph) = @_;
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    my @nodes = @{$graph->nodes};
    $nodes[0]{command} = $self->governed_write($nodes[0]{command});
    my $writes = _checked_writes($self->{domain}->writes);
    my %contexts = ($nodes[0]{id} => {
        table         => $self->{domain}->table,
        primary_key   => $self->{domain}->primary_key,
        fields        => $self->{domain}->fields,
        fields_known  => 1,
        writes        => $writes,
        relationships => $writes->{relationships},
        tenant_scope  => $self->{domain}->write_tenant_scope,
    });
    my $root_scope = $self->{domain}->write_tenant_scope;
    for my $node (@nodes[1 .. $#nodes]) {
        ($contexts{$node->{id}}, $node->{command}) =
            $self->_validate_graph_node($node, \%contexts, $root_scope);
    }
    return $self->{adapter}->execute_graph(Selecto::Write::Graph->new(nodes => \@nodes));
}

# The single path from a caller's command to the command an adapter receives:
# normalize assignments, apply the domain's tenant scope with the engine's
# trusted tenant, then validate against the domain contract.
sub governed_write {
    my ($self, $command) = @_;
    Selecto::Error->throw('invalid_write', 'write command required')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    Selecto::Error->throw(
        'write_relation_mismatch',
        'write relation must be the domain table',
        { relation => $command->relation, expected => $self->{domain}->table },
    ) unless $command->relation eq $self->{domain}->table;
    $command = $self->_normalize_write_command($command);
    my $scope = $self->{domain}->write_tenant_scope;
    $command = Selecto::Write::Scope->apply(
        $command, $scope, $self->{scope}{tenant}, label => $command->relation,
    );
    $self->_validate_write_command($command, trusted_field => $scope ? $scope->{field} : undef);
    return $command;
}

# ---------------------------------------------------------------------------
# Domain actions: plan -> authorize -> governed write.
#
# preview_action and execute_action authorize the plan through the same
# capability path with their own phase, then build the command from the plan
# exactly once, so preview shows the statement execute would run.

sub plan_action {
    my ($self, $intent) = @_;
    return Selecto::Action::Planner->plan($self->{domain}, $intent);
}

my %ACTION_COMPARATOR = (eq => 'eq', neq => 'ne', gt => 'gt', gte => 'gte', lt => 'lt', lte => 'lte');

# The write command for an action plan, before tenant scope. Plan filters
# already carry the target, transition source state, and declared
# preconditions; the planned cardinality becomes the expected row count.
sub action_command {
    my ($self, $plan, %options) = @_;
    Selecto::Error->throw('invalid_action_plan', 'action plan is required')
        unless blessed($plan) && $plan->isa('Selecto::Action::Plan');
    Selecto::Error->throw('invalid_action_plan', 'action plan belongs to a different domain')
        unless ref($self->{domain}->actions) eq 'HASH' && $self->{domain}->actions->{$plan->action};
    my $operation = $plan->operation // '';
    Selecto::Error->throw(
        'unsupported_action_operation',
        'core action execution supports update and delete plans',
        {operation => $operation},
    ) unless $operation eq 'update' || $operation eq 'delete';
    Selecto::Error->throw(
        'unsupported_action_collection_patch',
        'collection patches require a host executor',
    ) if ref($plan->collection_patches) eq 'ARRAY' && @{$plan->collection_patches}
        || ref($plan->collection_patches) eq 'HASH' && keys %{$plan->collection_patches};
    my ($kind, $count) = @{$plan->expected_cardinality // []};
    Selecto::Error->throw(
        'unsupported_action_cardinality',
        'action plans must declare an exact cardinality',
    ) unless defined($kind) && $kind eq 'exactly' && defined($count) && "$count" =~ /\A[1-9][0-9]*\z/;
    my @filters = map { _action_filter($_) } @{$plan->filters // []};
    Selecto::Error->throw('invalid_action_plan', 'action plans must filter their target') unless @filters;
    return Selecto::Write::Command->new(
        operation => $operation,
        relation => $self->{domain}->table,
        assignments => $operation eq 'delete' ? {} : _action_assignments($plan->changes),
        predicate => @filters == 1 ? $filters[0] : Selecto::Expression->all(@filters),
        expected_count => 0 + $count,
        metadata => {$options{returning} ? (returning => [@{$options{returning}}]) : ()},
    );
}

sub preview_action {
    my ($self, $plan, %options) = @_;
    my $decision = $self->_authorize_action($plan, 'preview', %options);
    my $command = $self->governed_write($self->action_command($plan, %options));
    return {
        phase => 'preview',
        action => $plan->action,
        decision => $decision,
        statement => $self->{adapter}->preview_write($command),
    };
}

sub execute_action {
    my ($self, $plan, %options) = @_;
    my $decision = $self->_authorize_action($plan, 'execute', %options);
    my $command = $self->governed_write($self->action_command($plan, %options));
    return {
        phase => 'execute',
        action => $plan->action,
        decision => $decision,
        result => $self->{adapter}->execute_write($command),
    };
}

sub _authorize_action {
    my ($self, $plan, $phase, %options) = @_;
    return Selecto::Action::Capability->authorize(
        $plan, $phase,
        resolver => $options{resolver},
        context => $options{context} // {},
    );
}

# Plan filters are field-first: [field, value] or [field, comparator, value].
sub _action_filter {
    my ($filter) = @_;
    Selecto::Error->throw('invalid_action_plan', 'action filters must be arrays')
        unless ref($filter) eq 'ARRAY' && (@$filter == 2 || @$filter == 3);
    my ($field, @rest) = @$filter;
    return Selecto::Expression->eq($field, $rest[0]) if @rest == 1;
    my ($comparator, $value) = @rest;
    return Selecto::Expression->in($field, $value) if $comparator eq 'in';
    my $method = $ACTION_COMPARATOR{$comparator}
        // Selecto::Error->throw('invalid_action_plan', 'unsupported action filter comparator',
            {comparator => $comparator});
    return Selecto::Expression->$method($field, $value);
}

# ['system', 'now'] is the one portable system value an action may assign.
sub _action_assignments {
    my ($changes) = @_;
    my %assignments;
    for my $field (keys %{$changes // {}}) {
        my $value = $changes->{$field};
        if (ref($value) eq 'ARRAY') {
            Selecto::Error->throw('invalid_action_changes', 'action change value is not portable',
                {field => $field})
                unless @$value == 2 && ($value->[0] // '') eq 'system' && ($value->[1] // '') eq 'now';
            $value = Selecto::Write::Expression->current_timestamp;
        }
        $assignments{$field} = $value;
    }
    return \%assignments;
}

sub _normalize_write_command {
    my ($self, $command) = @_;
    return $command unless blessed($command)
        && $command->isa('Selecto::Write::Command')
        && $command->relation eq $self->{domain}->table
        && $command->operation ne 'delete';
    return $command->with_assignments(
        $self->{domain}->normalize_write_assignments($command->assignments),
    );
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
        if defined($tenant_field) && !_has_tenant_conjunct($command->scope_predicate, $tenant_field)
            && !$self->_scopes_tenant_field($tenant_field);
    return $command->with_query_enforcement($evidence);
}

# True when execution will add the trusted tenant for this field itself.
sub _scopes_tenant_field {
    my ($self, $field) = @_;
    my $scope = $self->{domain}->write_tenant_scope;
    return $scope && $scope->{field} eq $field && defined($self->{scope}{tenant});
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
        return 0 unless blessed($value) && $value->isa('Selecto::Expression') && $value->kind eq 'literal';
        my $literal = $value->arguments->[0];
        return defined($literal) && !ref($literal);
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
    my ($self, $command, %options) = @_;
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
    # Computed fields are derived by the adapter; they never have storage.
    for my $field (sort keys %{$command->assignments}) {
        Selecto::Error->throw(
            'write_field_not_writable', 'computed fields are read-only', {field => $field},
        ) if ref($self->{domain}->field_metadata($field)->{computed}) eq 'HASH';
    }
    return $self->_validate_command_against_contract(
        $command,
        fields      => $self->{domain}->fields,
        writes      => _checked_writes($self->{domain}->writes),
        values_foreign_keys => $self->{domain}->values_foreign_keys,
        allowed_ops => undef,
        label       => $command->relation,
        trusted_field => $options{trusted_field},
        computed    => sub { ref($self->{domain}->field_metadata($_[0])->{computed}) eq 'HASH' },
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
    if (defined($fields_spec) && ($operation eq 'insert' || $operation eq 'upsert')) {
        my @missing = sort grep {
            my $spec = $fields_spec->{$_};
            ref($spec) eq 'HASH' && $spec->{required}
                && _required_write_value_missing($command->assignments, $_)
        } keys %$fields_spec;
        Selecto::Error->throw(
            'missing_required_write_fields',
            "$operation is missing required fields: " . join(', ', @missing),
            {operation => $operation, fields => \@missing, missing_fields => \@missing},
        ) if @missing;
    }
    if ($domain_fields && $operation ne 'delete') {
        for my $field (sort keys %{$command->assignments}) {
            Selecto::Error->throw('unknown_field', "write field is not declared by $label", { field => $field })
                unless exists $domain_fields->{$field};
            next unless defined($fields_spec);
            # The trusted tenant is assigned by scope, not granted to callers.
            next if $permission eq 'insertable' && defined($context{trusted_field})
                && $field eq $context{trusted_field};
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
    if ($domain_fields) {
        for my $field (_predicate_fields($command->predicate, $command->scope_predicate)) {
            Selecto::Error->throw(
                'unknown_field',
                "write predicate field is not a stored field of $label",
                { field => $field },
            ) unless exists($domain_fields->{$field})
                && !($context{computed} && $context{computed}->($field));
        }
    }
    _validate_values_foreign_keys(
        $command->assignments, $context{values_foreign_keys}, $label,
    ) if $operation ne 'delete';
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

sub _validate_values_foreign_keys {
    my ($assignments, $foreign_keys, $label) = @_;
    return unless ref($foreign_keys) eq 'HASH';
    for my $field (sort keys %$foreign_keys) {
        next unless exists $assignments->{$field};
        my $value = $assignments->{$field};
        next unless defined $value;
        next if blessed($value) && $value->isa('Selecto::Write::Expression');
        my $spec = $foreign_keys->{$field};
        next unless ref($spec) eq 'HASH' && ref($spec->{values}) eq 'ARRAY';
        next if grep {
            defined($_) && !ref($_) && "$_" eq "$value"
        } @{$spec->{values}};
        my $display_name = $spec->{display_name}
            // $spec->{association} // $field;
        Selecto::Error->throw(
            'write_foreign_key_violation',
            "field $field must reference an available $display_name value",
            {
                field => $field,
                relation => $label,
                association => $spec->{association},
                value => "$value",
                allowed_values => [@{$spec->{values}}],
            },
        );
    }
}

# Every governed field a write predicate reads. Write predicates address the
# written relation only, so association paths never resolve.
sub _predicate_fields {
    my %fields;
    my @pending = grep { defined } @_;
    while (@pending) {
        my $node = shift @pending;
        if (ref($node) eq 'ARRAY') {
            push @pending, @$node;
            next;
        }
        next unless blessed($node) && $node->isa('Selecto::Expression');
        if ($node->kind eq 'field') {
            $fields{$node->arguments->[0]} = 1;
            next;
        }
        push @pending, @{$node->arguments};
    }
    return sort keys %fields;
}

sub _required_write_value_missing {
    my ($assignments, $field) = @_;
    return 1 unless exists $assignments->{$field};
    my $value = $assignments->{$field};
    return 1 unless defined $value;
    return 1 if !ref($value) && "$value" =~ /\A\s*\z/;
    return 0;
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
    my ($self, $node, $contexts, $root_scope) = @_;
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
    my $scope = $edge->{tenant_scope};
    if (!$scope && $root_scope) {
        # A tenant-scoped graph cannot reach a node whose tenant it cannot see.
        Selecto::Error->throw(
            'missing_tenant_scope',
            'nested writes under a tenant-scoped domain must declare their domain',
            {relation => $command->relation, graph_node => $node->{id}},
        ) unless $edge->{fields_known};
        Selecto::Error->throw(
            'missing_tenant_scope',
            'nested domain stores the tenant field but declares no writes.scope.tenant',
            {relation => $command->relation, graph_node => $node->{id}, field => $root_scope->{field}},
        ) if exists $edge->{fields}{$root_scope->{field}};
    }
    $command = Selecto::Write::Scope->apply(
        $command, $scope, $self->{scope}{tenant}, label => $command->relation,
    );
    my %nested_fields = %{$edge->{fields} // {}};
    $self->_validate_command_against_contract($command,
        ($edge->{fields_known} ? (fields => \%nested_fields) : (fields => undef)),
        writes      => $edge->{writes},
        allowed_ops => $edge->{allowed_ops},
        label       => $command->relation,
        trusted_field => $scope ? $scope->{field} : undef,
    );
    return ({
        table         => $edge->{table},
        primary_key   => $edge->{primary_key},
        fields_known  => $edge->{fields_known},
        fields        => $edge->{fields},
        writes        => $edge->{writes},
        relationships => $edge->{relationships},
        tenant_scope  => $scope,
    }, $command);
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
    my $tenant_scope = Selecto::Write::Scope->parse_tenant(
        $nested->{writes},
        ($fields_known ? (fields => { map { ("$_" => 1) } @{$nested->{source}{fields}} }) : ()),
        tenant_field => ref($nested->{source}) eq 'HASH' ? $nested->{source}{tenant_field} : undef,
    );
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
        ($tenant_scope ? (tenant_scope => $tenant_scope) : ()),
    };
}

1;
