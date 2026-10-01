package Selecto::Engine;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Time::HiRes ();
use Scalar::Util qw(blessed refaddr);
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
use Selecto::Write::Authorization ();
use Selecto::Action::Capability ();
use Selecto::Action::Grant ();
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
        write_policy => _write_policy($args{write_policy}),
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

# strict (default): a domain must declare writes.operations, and writes.fields
# for anything but deletes, before this engine writes it. permissive keeps the
# earlier behavior, where absent sections allow the write; it must be chosen
# explicitly.
sub _write_policy {
    my ($policy) = @_;
    $policy //= 'strict';
    Selecto::Error->throw('invalid_write_policy', 'write_policy must be strict or permissive')
        unless !ref($policy) && ($policy eq 'strict' || $policy eq 'permissive');
    return $policy;
}

sub write_policy { return $_[0]->{write_policy}; }

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
    delete $copy->{_read_domain};
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
        (defined($args{write_policy}) ? (write_policy => $args{write_policy}) : ()),
    );
}

sub domain  { return $_[0]->{domain}; }
sub adapter { return $_[0]->{adapter}; }
sub domain_ref { return $_[0]->{domain_ref}; }
sub query   { return Selecto::Query->new; }
sub compile { my ($self, $query) = @_; return $self->{adapter}->compile($self->read_domain, $query); }
sub all     { my ($self, $query) = @_; return $self->{adapter}->execute_query($self->compile($query)); }

# The domain reads compile against. An engine holding a trusted tenant scopes
# every read of a tenant_field domain to that tenant, as it already scopes
# writes, so a read path that forgets with_required_predicate cannot see other
# tenants' rows. Query members inherit the added condition through the
# required predicate. A required predicate whose tenant condition excludes the
# trusted tenant is a host error rather than an empty result.
sub read_domain {
    my ($self) = @_;
    return $self->{_read_domain} //= do {
        my $domain = $self->{domain};
        my $tenant = $self->{scope}{tenant};
        my $field = $domain->tenant_field;
        if (defined($tenant) && defined($field)) {
            my $required = $domain->required_predicate;
            Selecto::Error->throw(
                'tenant_mismatch', 'required predicate excludes the engine tenant',
                {tenant_field => "$field"},
            ) if _excludes_tenant($required, $field, $tenant);
            my $trusted = Selecto::Expression->eq($field, $tenant);
            $domain = $domain->with_required_predicate(
                defined($required) ? Selecto::Expression->all($required, $trusted) : $trusted);
        }
        $domain;
    };
}

# The tenant boundary public surfaces (the API write and query handlers,
# canned pages, co-domain lookups) require on a tenant_field domain. Either the
# engine holds a trusted tenant (for writes, on the field writes.scope.tenant
# declares, since execution applies it there), or the trusted host scope has a
# positive tenant conjunct: the required predicate ANDed with any host
# predicate the surface accepts. Any other host predicate, such as a status
# filter, is not a boundary. Engine::all itself stays available for trusted
# host reads that deliberately span tenants.
sub assert_tenant_boundary {
    my ($self, %args) = @_;
    my $access = $args{access} // '';
    Selecto::Error->throw('invalid_tenant_scope', 'tenant boundary access must be read or write')
        unless $access eq 'read' || $access eq 'write';
    my $field = $self->{domain}->tenant_field;
    return $self unless defined $field;
    return $self if $access eq 'write' ? $self->_scopes_tenant_field($field) : defined($self->{scope}{tenant});
    return $self if grep { _has_tenant_conjunct($_, $field) }
        grep { defined } $self->{domain}->required_predicate, $args{host_predicate};
    Selecto::Error->throw('missing_tenant_scope', 'trusted tenant scope is required',
        {tenant_field => "$field"});
}

# True when a top-level positive tenant conjunct (eq or in over literals) on
# the field cannot match the trusted tenant.
sub _excludes_tenant {
    my ($expression, $field, $tenant) = @_;
    return 0 unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    if ($kind eq 'and') {
        for my $conjunct (@{$expression->arguments->[0] // []}) {
            return 1 if _excludes_tenant($conjunct, $field, $tenant);
        }
        return 0;
    }
    return 0 unless ($kind eq 'eq' || $kind eq 'in') && _is_tenant_comparison($expression, $field);
    my $value = $expression->arguments->[1];
    my @allowed = $kind eq 'eq' ? ($value->arguments->[0]) : @$value;
    return !grep { "$_" eq "$tenant" } @allowed;
}
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
    return $self->_execute_governed(execute_write => $self->governed_write($command));
}

# Hands a governed write object to the adapter with the engine's single-use
# authorization for it.
sub _execute_governed {
    my ($self, $method, $subject) = @_;
    return $self->{adapter}->$method($subject, Selecto::Write::Authorization->_issue($subject));
}
sub execute_batch {
    my ($self, $batch) = @_;
    Selecto::Error->throw('invalid_write', 'execute_batch requires a Selecto::Write::Batch')
        unless blessed($batch) && $batch->isa('Selecto::Write::Batch');
    my @commands = map { $self->governed_write($_) } @{$batch->commands};
    return $self->_execute_governed(execute_batch => Selecto::Write::Batch->new(@commands));
}
sub execute_graph {
    my ($self, $graph) = @_;
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    my @nodes = @{$graph->nodes};
    $nodes[0]{command} = $self->governed_write($nodes[0]{command}, graph_node => $nodes[0]{id});
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
    my $tenants = $self->_trusted_write_tenants($self->{domain}->required_predicate);
    for my $node (@nodes[1 .. $#nodes]) {
        ($contexts{$node->{id}}, $node->{command}) =
            $self->_validate_graph_node($node, \%contexts, $root_scope, $tenants);
    }
    return $self->_execute_governed(execute_graph => Selecto::Write::Graph->new(nodes => \@nodes));
}

# A write command bound to this engine's domain, checked now for earlier
# feedback. Execution governs it again: this check is advice, not authority.
#
#   my $command = $engine->write_command(
#       operation => 'update', assignments => {title => 'x'},
#       filter => ['eq', 'id', 42],       # filter AST, or predicate => Selecto::Expression
#   );
sub write_command {
    my ($self, %args) = @_;
    my @unknown = sort grep {
        !/\A(?:operation|assignments|filter|predicate|expected_count|metadata)\z/
    } keys %args;
    Selecto::Error->throw('invalid_write', 'write_command received unsupported arguments', {keys => \@unknown})
        if @unknown;
    Selecto::Error->throw('invalid_write', 'write_command takes filter or predicate, not both')
        if exists($args{filter}) && exists($args{predicate});
    my $predicate = exists($args{filter}) ? Selecto::Expression->from_filter_ast($args{filter})
        : $args{predicate};
    my $command = Selecto::Write::Command->new(
        operation => $args{operation},
        relation => $self->{domain}->table,
        assignments => $args{assignments} // {},
        (defined($predicate) ? (predicate => $predicate) : ()),
        (exists($args{expected_count}) ? (expected_count => $args{expected_count}) : ()),
        metadata => $args{metadata} // {},
    );
    $self->governed_write($command);
    return $command;
}

# The single path from a caller's command to the command an adapter receives:
# normalize assignments, apply the domain's tenant scope with the engine's
# trusted tenant and the domain's required predicate, then validate against
# the domain contract.
sub governed_write {
    my ($self, $command, %details) = @_;
    Selecto::Error->throw('invalid_write', 'write command required')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    Selecto::Error->throw(
        'write_relation_mismatch',
        'write relation must be the domain table',
        { relation => $command->relation, expected => $self->{domain}->table },
    ) unless $command->relation eq $self->{domain}->table;
    $command = $self->_normalize_write_command($command);
    my $required = $self->required_write_guard($command->operation, %details);
    my $scope = $self->{domain}->write_tenant_scope;
    $command = Selecto::Write::Scope->apply(
        $command, $scope, $self->{scope}{tenant}, label => $command->relation, details => \%details,
    );
    # The required predicate is host-authored, so it joins the scope after
    # writes.scope.tenant has checked the caller's own tenant references;
    # both boundaries then hold in the same statement.
    if (defined $required) {
        my $existing = $command->scope_predicate;
        $command = $command->with_scope_predicate(
            Selecto::QueryEnforcement::combine($existing, $required)
        ) unless _has_conjunct($existing, $required)
            || (defined($command->query_enforcement)
                && _has_conjunct($command->query_enforcement->predicate, $required));
    }
    $self->_validate_write_command($command, trusted_field => $scope ? $scope->{field} : undef);
    $self->_check_required_tenant_assignment($command, $required, %details);
    # Set on every governed command, replacing any a caller supplied.
    return $command->with_foreign_key_guards(_foreign_key_guards(
        _domain_references($self->{domain}), $command, $self->_trusted_write_tenants($required), %details,
    ));
}

# Every required predicate guards engine writes, beyond the shared protocol's
# earlier rule that required predicates are read scopes. Returns the domain's
# required predicate (undef when it has none) after refusing what it cannot
# guard: a predicate that reaches into an association has no portable write
# form, so every write on the domain fails closed; and an upsert conflict can
# resolve to a row outside the predicate, so upsert is refused. Updates and
# deletes then match only rows inside the predicate, and the adapter checks
# insert candidates against it before the transaction opens.
sub required_write_guard {
    my ($self, $operation, %details) = @_;
    my $required = $self->{domain}->required_predicate;
    return undef unless defined $required;
    my $relation = $self->{domain}->table;
    my @paths = _association_paths($required);
    Selecto::Error->throw(
        'query_rule_unsupported_field',
        'association fields are not portable write guards',
        { relation => $relation, fields => \@paths, %details },
    ) if @paths;
    Selecto::Error->throw(
        'query_enforcement_unsupported_operation',
        'upsert is not supported on a domain with a required predicate',
        { relation => $relation, %details },
    ) if ($operation // '') eq 'upsert';
    return $required;
}

# The required predicate limits the rows an update matches, not the values it
# writes. When it carries the tenant boundary, an update may set the tenant
# field only to a literal tenant the boundary admits, so it cannot move a row
# to another tenant. Inserts are checked as candidates against the predicate.
sub _check_required_tenant_assignment {
    my ($self, $command, $required, %details) = @_;
    my $field = $self->{domain}->tenant_field;
    return unless defined($required) && defined($field) && $command->operation eq 'update'
        && exists($command->assignments->{$field}) && _has_tenant_conjunct($required, $field);
    my $value = $command->assignments->{$field};
    $value = $value->kind eq 'literal' ? $value->arguments->[0] : undef
        if blessed($value) && $value->isa('Selecto::Write::Expression');
    Selecto::Error->throw(
        'tenant_mismatch', 'tenant value must match the trusted tenant scope',
        {relation => $command->relation, field => "$field", %details},
    ) if !defined($value) || ref($value) || _excludes_tenant($required, $field, $value);
}

# TW-05: the trusted tenants a write is confined to: the engine tenant, or
# the tenant values of the domain's required tenant predicate. Undef when the
# write has no tenant boundary.
sub _trusted_write_tenants {
    my ($self, $required) = @_;
    return [$self->{scope}{tenant}] if defined $self->{scope}{tenant};
    my $field = $self->{domain}->tenant_field;
    return undef unless defined($field) && defined($required);
    my $values;
    for my $conjunct ($required->kind eq 'and' ? @{$required->arguments->[0] // []} : ($required)) {
        next unless blessed($conjunct) && $conjunct->isa('Selecto::Expression')
            && ($conjunct->kind eq 'eq' || $conjunct->kind eq 'in') && _is_tenant_comparison($conjunct, $field);
        my $argument = $conjunct->arguments->[1];
        my @allowed = $conjunct->kind eq 'eq' ? ($argument->arguments->[0]) : @$argument;
        my %allowed = map { ("$_" => 1) } @allowed;
        $values = $values ? [grep { $allowed{"$_"} } @$values] : [@allowed];
    }
    return $values && @$values ? $values : undef;
}

# The references a relation declares, for the foreign-key tenant guard:
# writes.constraints.foreign_keys and its direct to-one associations, with
# what the domain records about each referenced relation's tenancy.
sub _domain_references {
    my ($domain) = @_;
    my $contract = $domain->contract // {};
    my $schemas = ref($contract->{schemas}) eq 'HASH' ? $contract->{schemas} : {};
    my $associations = $domain->associations;
    my $scope = $domain->write_tenant_scope;
    return {
        table => $domain->table,
        primary_key => $domain->primary_key,
        tenant_field => $scope ? $scope->{field} : $domain->tenant_field,
        tenant_data => $scope || defined($domain->tenant_field) ? 1 : 0,
        foreign_keys => _declared_foreign_keys($contract->{writes}),
        schemas => _schema_tenancy($schemas),
        associations => [map {
            my $association = $associations->{$_};
            my $target = defined($association->queryable) ? $schemas->{$association->queryable} : undef;
            {
                name => $_,
                owner_key => $association->owner_key,
                related_key => $association->related_key,
                cardinality => $association->cardinality,
                table => $association->table,
                static => defined($association->values) || (ref($target) eq 'HASH' && defined($target->{values})) ? 1 : 0,
                through => defined($association->through) ? 1 : 0,
                target_scope_key => $association->target_scope_key,
                target_tenant_field => ref($target) eq 'HASH' ? $target->{tenant_field} : undef,
            }
        } sort keys %$associations],
    };
}

# The same description from a raw contract, for a graph child's nested domain.
sub _contract_references {
    my ($contract, $table) = @_;
    $contract = {} unless ref($contract) eq 'HASH';
    my $source = ref($contract->{source}) eq 'HASH' ? $contract->{source} : {};
    my $schemas = ref($contract->{schemas}) eq 'HASH' ? $contract->{schemas} : {};
    my $scope = Selecto::Write::Scope->parse_tenant($contract->{writes}, tenant_field => $source->{tenant_field});
    my $associations = ref($source->{associations}) eq 'HASH' ? $source->{associations} : {};
    return {
        table => $source->{source_table} // $table,
        primary_key => $source->{primary_key} // 'id',
        tenant_field => $scope ? $scope->{field} : $source->{tenant_field},
        tenant_data => $scope || defined($source->{tenant_field}) ? 1 : 0,
        foreign_keys => _declared_foreign_keys($contract->{writes}),
        schemas => _schema_tenancy($schemas),
        associations => [map {
            my $spec = $associations->{$_};
            my $target = ref($spec) eq 'HASH' && defined($spec->{queryable}) ? $schemas->{$spec->{queryable}} : undef;
            ref($spec) eq 'HASH' ? {
                name => $_,
                owner_key => $spec->{owner_key},
                related_key => $spec->{related_key},
                cardinality => lc($spec->{cardinality} // 'one'),
                table => ref($target) eq 'HASH' ? $target->{source_table} : $spec->{table},
                static => ref($target) eq 'HASH' && defined($target->{values}) ? 1 : 0,
                through => defined($spec->{through}) ? 1 : 0,
                target_scope_key => $spec->{target_scope_key},
                target_tenant_field => ref($target) eq 'HASH' ? $target->{tenant_field} : undef,
            } : ()
        } sort keys %$associations],
    };
}

sub _declared_foreign_keys {
    my ($writes) = @_;
    my $constraints = ref($writes) eq 'HASH' ? $writes->{constraints} : undef;
    return {} unless ref($constraints) eq 'HASH' && defined($constraints->{foreign_keys});
    Selecto::Error->throw('invalid_domain', 'writes.constraints.foreign_keys must be an object')
        unless ref($constraints->{foreign_keys}) eq 'HASH';
    return $constraints->{foreign_keys};
}

sub _schema_tenancy {
    my ($schemas) = @_;
    return [map {
        my $schema = $schemas->{$_};
        ref($schema) eq 'HASH' ? {
            table => $schema->{source_table} // $_,
            tenant_field => $schema->{tenant_field},
            static => defined($schema->{values}) ? 1 : 0,
        } : ()
    } sort keys %$schemas];
}

# TW-05: on a write with trusted tenants, every assigned reference to tenant
# data gets a guard: the adapter writes only when the referenced row exists
# in one of those tenants, inside the same statement, so another tenant's
# parent and a missing one are refused alike. References are declared by
# writes.constraints.foreign_keys (its references.tenant_field names the
# referenced tenant column, or false for a relation every tenant shares) or
# by the owner key of a direct to-one association. A tenant-scoped write that
# assigns a reference whose tenancy the domain does not record fails closed,
# as in the Elixir core (foreign_key_tenant_scope_undeclared).
sub _foreign_key_guards {
    my ($references, $command, $tenants, %details) = @_;
    return [] if $command->operation eq 'delete';
    my $assignments = $command->assignments;
    my $tenant_scoped = $tenants && $references->{tenant_data};
    my $relation = $command->relation;
    my (@candidates, %declared);
    my $foreign_keys = $references->{foreign_keys};
    for my $field (sort keys %$foreign_keys) {
        $declared{$field} = 1;
        next unless exists $assignments->{$field};
        my $spec = $foreign_keys->{$field};
        my $target = ref($spec) eq 'HASH' ? $spec->{references} : undef;
        Selecto::Error->throw('invalid_domain', 'foreign key references must name a relation and field',
            {code => 'invalid_foreign_key', field => $field, relation => $relation, %details},
        ) unless ref($target) eq 'HASH'
            && grep({ defined($target->{$_}) && !ref($target->{$_}) && "$target->{$_}" =~ /\A[A-Za-z_][A-Za-z0-9_.]*\z/ }
                qw(relation field)) == 2;
        push @candidates, {
            field => $field, relation => "$target->{relation}", target_field => "$target->{field}", declared => 1,
            tenancy => _declared_tenancy($references, $target),
        };
    }
    for my $association (@{$references->{associations}}) {
        my $field = $association->{owner_key};
        next if !defined($field) || $declared{$field} || !exists($assignments->{$field});
        # Only a reference from this row to another: not the row's own key, a
        # to-many or bridged association, or a static value list.
        next if $field eq ($references->{primary_key} // '') || $association->{cardinality} ne 'one'
            || $association->{through} || $association->{static} || !defined($association->{table});
        my $tenancy = defined($association->{target_scope_key}) ? ['tenant', $association->{target_scope_key}]
            : defined($association->{target_tenant_field}) ? ['tenant', $association->{target_tenant_field}]
            : $association->{table} eq $references->{table} && defined($references->{tenant_field})
                ? ['tenant', $references->{tenant_field}]
            : ['undeclared'];
        push @candidates, {
            field => $field, relation => $association->{table}, target_field => $association->{related_key},
            tenancy => $tenancy,
        };
    }
    my (%seen, @guards);
    for my $candidate (@candidates) {
        my ($kind, $tenant_field) = @{$candidate->{tenancy}};
        my $value = $assignments->{$candidate->{field}};
        $value = $value->kind eq 'literal' ? $value->arguments->[0] : $value
            if blessed($value) && $value->isa('Selecto::Write::Expression');
        next unless defined $value;    # a null reference names no parent
        my %where = (field => $candidate->{field}, relation => $relation, %details);
        Selecto::Error->throw('invalid_domain', 'foreign-key tenant scope is invalid',
            {%where, code => $tenant_field, referenced => $candidate->{relation}},
        ) if $kind eq 'error';
        next if $kind eq 'shared';
        if ($kind eq 'undeclared') {
            Selecto::Error->throw('invalid_domain',
                'a reference on a tenant-scoped write must declare the referenced relation\'s tenant field',
                {%where, code => 'foreign_key_tenant_scope_undeclared', referenced => $candidate->{relation},
                    required => ['references', 'tenant_field']},
            ) if $tenant_scoped;
            next;
        }
        unless ($tenants) {
            Selecto::Error->throw('missing_tenant_scope',
                'a foreign key to a tenant-scoped relation requires a trusted tenant',
                {%where, referenced => $candidate->{relation}, tenant_field => $tenant_field},
            ) if $candidate->{declared};
            next;
        }
        Selecto::Error->throw('invalid_write', 'a reference on a tenant-scoped write must be a literal value',
            \%where,
        ) if ref($value);
        my $key = join "\0", @{$candidate}{qw(field relation target_field)}, $tenant_field;
        next if $seen{$key}++;
        push @guards, {
            field => $candidate->{field}, relation => $candidate->{relation},
            target_field => $candidate->{target_field}, tenant_field => $tenant_field,
            value => $value, tenants => [@$tenants],
        };
    }
    return \@guards;
}

# references.tenant_field when declared (a field, or false/null for a shared
# relation); otherwise the tenant field the domain records for the
# referenced relation: the root for a self-reference, or its schemas.
sub _declared_tenancy {
    my ($references, $target) = @_;
    my $relation = "$target->{relation}";
    my @candidates = (
        ($relation eq $references->{table} ? ({table => $relation, tenant_field => $references->{tenant_field}}) : ()),
        grep { $_->{table} eq $relation } @{$references->{schemas}},
    );
    if (exists $target->{tenant_field}) {
        my $field = $target->{tenant_field};
        return ['shared'] if !defined($field) || (JSON::PP::is_bool($field) && !$field);
        return ['error', 'invalid_foreign_key_tenant_field']
            if ref($field) || "$field" !~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        return ['tenant', "$field"];
    }
    my %fields = map { ("$_->{tenant_field}" => 1) } grep { defined $_->{tenant_field} } @candidates;
    my @fields = sort keys %fields;
    return ['undeclared'] unless @fields;
    return ['error', 'ambiguous_foreign_key_tenant_field'] if @fields > 1;
    return ['tenant', $fields[0]];
}

# Dotted (association) field paths an expression reads anywhere in its tree,
# including beneath AND, OR and NOT; sorted and unique.
sub _association_paths {
    my %paths;
    my @pending = grep { defined } @_;
    while (@pending) {
        my $node = shift @pending;
        if (ref($node) eq 'ARRAY') {
            push @pending, @$node;
            next;
        }
        next unless blessed($node) && $node->isa('Selecto::Expression');
        my $kind = $node->kind;
        my $arguments = $node->arguments;
        if ($kind eq 'field') {
            $paths{"$arguments->[0]"} = 1 if "$arguments->[0]" =~ /\./;
            next;
        }
        push @pending, @$arguments;
    }
    return sort keys %paths;
}

# True when $target is $expression itself or a conjunct of its top-level AND
# tree, compared by identity.
sub _has_conjunct {
    my ($expression, $target) = @_;
    return 0 unless blessed($expression) && $expression->isa('Selecto::Expression');
    return 1 if refaddr($expression) == refaddr($target);
    return 0 unless $expression->kind eq 'and';
    for my $conjunct (@{$expression->arguments->[0] // []}) {
        return 1 if _has_conjunct($conjunct, $target);
    }
    return 0;
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
        'core action execution supports insert, update, upsert, and delete plans',
        {operation => $operation},
    ) unless $operation =~ /\A(?:insert|update|upsert|delete)\z/;
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
    if ($operation eq 'insert' || $operation eq 'upsert') {
        Selecto::Error->throw('invalid_action_plan', 'insert and upsert plans create exactly one row')
            unless $count == 1 && !@{$plan->filters // []};
        return Selecto::Write::Command->new(
            operation => $operation,
            relation => $self->{domain}->table,
            assignments => _action_assignments($plan->changes),
            expected_count => 1,
            metadata => {
                ($operation eq 'upsert' ? $self->_action_upsert_metadata($plan) : ()),
                ($options{returning} ? (returning => [@{$options{returning}}]) : ()),
            },
        );
    }
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

# An upsert action resolves conflicts on a target the domain declares under
# writes.operations.upsert.conflict_targets: the action's execution.conflict_target,
# or the only declared target. DO UPDATE sets the changed fields the write
# contract marks updatable, never the conflict keys.
sub _action_upsert_metadata {
    my ($self, $plan) = @_;
    my $writes = _checked_writes($self->{domain}->writes);
    my $upsert = ref($writes->{operations}) eq 'HASH' ? $writes->{operations}{upsert} : undef;
    my $declared = ref($upsert) eq 'HASH' && ref($upsert->{conflict_targets}) eq 'ARRAY'
        ? $upsert->{conflict_targets} : [];
    my $action = $self->{domain}->actions->{$plan->action} // {};
    my $execution = ref($action->{execution}) eq 'HASH' ? $action->{execution} : {};
    my $target = $execution->{conflict_target} // (@$declared == 1 ? $declared->[0] : undef);
    Selecto::Error->throw(
        'conflict_target_not_declared',
        'upsert actions resolve conflicts on a target declared by writes.operations.upsert.conflict_targets',
        {action => $plan->action},
    ) unless ref($target) eq 'ARRAY' && @$target
        && grep { ref($_) eq 'ARRAY' && join("\0", @$_) eq join("\0", @$target) } @$declared;
    my %key = map { ("$_" => 1) } @$target;
    my $fields = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : {};
    my @updates = sort grep {
        !$key{$_} && ref($fields->{$_}) eq 'HASH' && $fields->{$_}{updatable}
    } keys %{$plan->changes // {}};
    Selecto::Error->throw('invalid_action_plan', 'upsert actions need at least one updatable change',
        {action => $plan->action}) unless @updates;
    return (conflict_target => [map { "$_" } @$target], upsert_update_fields => \@updates);
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
        result => $self->_execute_governed(execute_write => $command),
    };
}

# Issues a single-use grant for one phase of $plan after the host's resolver
# enables it. The grant is bound to the phase, the plan's content, this
# engine's domain and trusted tenant, and the actor in the context.
sub grant_action {
    my ($self, $plan, %options) = @_;
    my $phase = $options{phase} // 'execute';
    my $decision = Selecto::Action::Capability->authorize(
        $plan, $phase, resolver => $options{resolver}, context => $options{context} // {},
    );
    # Every grant expires. A grant bridges a confirmation step, so it defaults
    # to the five minutes (and at most the hour) the Elixir planned operation
    # allows a confirmation.
    my $expires_in = $options{expires_in} // 300;
    Selecto::Error->throw('invalid_action_grant', 'expires_in must be a positive number of seconds up to 3600')
        unless $expires_in =~ /\A\d+(?:\.\d+)?\z/ && $expires_in > 0 && $expires_in <= 3600;
    return Selecto::Action::Grant->_issue(
        $self->_grant_binding($plan, $phase, $options{context}),
        decision => $decision,
        expires_at => Time::HiRes::time() + $expires_in,
    );
}

sub _grant_binding {
    my ($self, $plan, $phase, $context) = @_;
    my $actor = ref($context) eq 'HASH' ? $context->{actor} : undef;
    $actor = $actor->{id} if ref($actor) eq 'HASH';
    return (
        phase => "$phase",
        plan => Selecto::Action::Grant->plan_digest($plan),
        domain => $self->{domain}->fingerprint,
        tenant => $self->{scope}{tenant},
        actor => defined($actor) && !ref($actor) ? "$actor" : undef,
    );
}

# With grant => $grant the phase consumes that grant; otherwise it asks the
# resolver directly, which is the same as issuing and consuming a grant.
sub _authorize_action {
    my ($self, $plan, $phase, %options) = @_;
    Selecto::Error->throw('invalid_action_plan', 'action plan is required')
        unless blessed($plan) && $plan->isa('Selecto::Action::Plan');
    return Selecto::Action::Grant->consume(
        $options{grant}, $self->_grant_binding($plan, $phase, $options{context}),
    ) if exists $options{grant};
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
    my $label = $context{label} // $command->relation;
    if ($context{allowed_ops}) {
        my %allowed = map { ("$_" => 1) } @{$context{allowed_ops}};
        Selecto::Error->throw(
            'write_operation_not_enabled',
            "operation $operation is not allowed for this relationship",
        ) unless $allowed{$operation};
    }
    my $writes = _checked_writes($context{writes});
    my $fields_spec = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : undef;
    if ($self->{write_policy} eq 'strict') {
        # A strict engine writes only what a domain explicitly grants. A graph
        # edge grants its operations through the relationship's allowed_ops.
        Selecto::Error->throw(
            'write_policy_missing',
            "the $label write contract declares no writes.operations",
            {relation => $context{label} // $command->relation, operation => $operation},
        ) unless ref($writes->{operations}) eq 'HASH'
            || (ref($context{allowed_ops}) eq 'ARRAY' && @{$context{allowed_ops}});
        Selecto::Error->throw(
            'write_policy_missing',
            "the $label write contract declares no writes.fields",
            {relation => $context{label} // $command->relation, operation => $operation},
        ) unless defined($fields_spec) || $operation eq 'delete';
    }
    if (ref($writes->{operations}) eq 'HASH') {
        my $op_spec = $writes->{operations}{$operation};
        Selecto::Error->throw(
            'write_operation_not_enabled',
            "operation $operation is not enabled by the write contract",
        ) unless ref($op_spec) eq 'HASH' && $op_spec->{enabled};
    }
    my $domain_fields = $context{fields};
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
    my ($self, $node, $contexts, $root_scope, $tenants) = @_;
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
    # Without a nested domain no predicate, returning, or conflict field of
    # the child can be checked, so a strict engine refuses the edge.
    Selecto::Error->throw(
        'write_policy_missing',
        'nested writes under a strict write policy must declare their relationship domain',
        {relation => $command->relation, graph_node => $node->{id}},
    ) if $self->{write_policy} eq 'strict' && !$edge->{fields_known};
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
        $command, $scope, $self->{scope}{tenant},
        label => $command->relation, details => {graph_node => $node->{id}},
    );
    my %nested_fields = %{$edge->{fields} // {}};
    $self->_validate_command_against_contract($command,
        ($edge->{fields_known} ? (fields => \%nested_fields) : (fields => undef)),
        writes      => $edge->{writes},
        allowed_ops => $edge->{allowed_ops},
        label       => $command->relation,
        trusted_field => $scope ? $scope->{field} : undef,
    );
    # A bound field takes its value from the parent this graph wrote, so only
    # the child's own assignments are guarded.
    $command = $command->with_foreign_key_guards(_foreign_key_guards(
        _contract_references($edge->{contract}, $edge->{table}), $command, $tenants,
        graph_node => $node->{id},
    ));
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
        contract      => $nested,
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

__END__

=head1 NAME

Selecto::Engine - run governed queries, writes and actions for one domain

=head1 SYNOPSIS

  my $engine = Selecto::Engine->new(
      domain  => $domain,
      adapter => Selecto->adapter(postgresql => (dbh => $dbh)),
      scope   => {tenant => $session->tenant_id},   # trusted, from your auth layer
  );

  # Reads
  my $result = $engine->all($engine->query->select('id', 'name')->order_by('id'));
  my $stream = $engine->stream($query, fetch_size => 500);
  my $sql    = $engine->compile($query);            # Selecto::Statement

  # Writes
  my $command = $engine->write_command(
      operation   => 'update',
      assignments => {status => 'closed'},
      filter      => ['eq', 'id', 42],
  );
  my $preview = $engine->preview_write($command);   # {sql => ..., params => [...]}
  my $written = $engine->execute_write($command);   # Selecto::Write::Result

  # Actions
  my $plan = $engine->plan_action({action => 'archive', target => 42});
  my $done = $engine->execute_action($plan, resolver => $policy, context => $ctx);

=head1 DESCRIPTION

An engine binds one L<Selecto::Domain> to one L<Selecto::Adapter> and is the
object applications use. It compiles queries against the domain, applies
the domain's required predicate and the engine's trusted tenant to every
read, guards every write with the same required predicate (see
L</REQUIRED PREDICATES>), and validates every write against the domain's
C<writes> contract before handing it to the adapter with a single-use
L<Selecto::Write::Authorization>.

Engines are cheap. Build one per request with the tenant taken from your
authenticated session, and never accept the tenant, the domain or the adapter
from a client.

=head1 CONSTRUCTORS

=head2 new

  my $engine = Selecto::Engine->new(
      domain       => $domain,          # required, a Selecto::Domain
      adapter      => $adapter,         # required, a Selecto::Adapter
      scope        => {tenant => 42},   # optional trusted scope
      write_policy => 'strict',         # or 'permissive'
      domain_ref   => $ref,             # optional Selecto::Domain::Ref
  );

C<scope> accepts only a C<tenant> key. When the domain has a C<tenant_field>,
reads are restricted to that tenant, inserts receive it, and updates and
deletes are confined to it (see L</TENANT SCOPE>).

C<write_policy> is C<strict> by default: a domain must declare
C<writes.operations> (with the operation enabled) and, for everything except
deletes, C<writes.fields> before anything is written; otherwise writes fail
with C<write_policy_missing>. C<permissive> lets domains without a C<writes>
section be written and exists for legacy tooling.

Throws C<invalid_domain>, C<invalid_adapter>, C<invalid_tenant_scope> or
C<invalid_write_policy>.

=head2 from_registry

  my $engine = Selecto::Engine->from_registry(
      domain   => 'orders',       # an id, or a Selecto::Domain::Ref
      registry => $registry,      # optional when domain is a Ref
      context  => \%context,      # passed to registry providers
      adapter  => $adapter,
      scope    => {tenant => 42},
  );

Resolves the domain through a L<Selecto::Domain::Registry> and records the
provenance reference as C<domain_ref>. See also
L<Selecto/engine_registered>.

=head1 READING

=head2 query

Returns a new empty L<Selecto::Query>.

=head2 all

  my $result = $engine->all($query);
  # {columns => ['id', 'name'], rows => [[1, 'Anvil'], ...]}

Compiles and executes the query and returns every row. Values are
normalized by the adapter (integers as numbers, exact decimals without
trailing zeros, timestamps in ISO form).

C<all> applies the domain's required predicate and the engine's tenant, but
it does not require a tenant boundary: it is meant for trusted host code,
including deliberate cross-tenant reads. Public surfaces call
L</assert_tenant_boundary> first.

=head2 stream

  my $stream = $engine->stream($query, fetch_size => 500);
  while (my $row = $stream->next) { ... }
  $stream->close;

Returns a L<Selecto::Stream> that decodes one row at a time. Requires the
adapter's C<stream> capability. Server-side cursor behavior is up to the
DBI driver.

=head2 compile

Returns the L<Selecto::Statement> the adapter would execute for a query.

=head2 projection_sum

  my $total = $engine->projection_sum($query, 'total');

Wraps the compiled query and returns the sum of one selected result column
over the rows it returns (zero when there are none). Requires the adapter's
C<projection_sum> capability (PostgreSQL); remove C<limit> and C<offset>
first to sum the whole result.

=head2 read_domain

The domain reads compile against: the engine's domain with the trusted
tenant added to its required predicate. Throws C<tenant_mismatch> if the
domain's own required predicate excludes the engine's tenant.

=head2 assert_tenant_boundary

  $engine->assert_tenant_boundary(access => 'read', host_predicate => $predicate);

Throws C<missing_tenant_scope> unless a domain with a C<tenant_field> has a
tenant boundary: a trusted engine tenant, or a positive C<eq>/C<in> conjunct
on the tenant field in the required predicate or in C<host_predicate>. With
C<< access => 'write' >> only a trusted tenant on the field
C<writes.scope.tenant> names counts. Returns the engine.

=head1 WRITING

=head2 write_command

  my $command = $engine->write_command(
      operation      => 'insert',          # insert, update, upsert, delete
      assignments    => {name => 'Anvil'},
      filter         => ['eq', 'id', 42],  # filter AST, or
      predicate      => $expression,       # a Selecto::Expression, not both
      expected_count => 1,                 # default 1; undef disables the check
      metadata       => {returning => ['id']},
  );

Builds a L<Selecto::Write::Command> for the domain's table and validates it
immediately, so forms and APIs get early errors. Validation is advice:
execution validates again.

=head2 preview_write

Validates the command and returns C<< {sql => $sql, params => \@params} >>
without executing anything.

=head2 execute_write

Validates and executes a command in a transaction, returning a
L<Selecto::Write::Result>. The affected-row count must equal
C<expected_count> or the transaction rolls back with C<cardinality_mismatch>.

=head2 execute_batch

  my $results = $engine->execute_batch(Selecto::Write::Batch->new(@commands));

Validates every command, then runs them in one transaction.

=head2 execute_graph

  my $result = $engine->execute_graph($graph);   # Selecto::Write::Graph

Runs an ordered multi-table write graph in one transaction, checking each
child node against the writable relationship and nested domain its parent
declares. See L<Selecto::Write/WRITE GRAPHS>.

=head2 governed_write

The single path from a caller's command to what the adapter receives:
normalizes assignments, applies tenant scope and the required-predicate
guard (L</REQUIRED PREDICATES>), then validates against the contract.
Returns the governed command. Used by the methods above; call it directly
only to inspect the result.

=head2 required_write_guard

  my $predicate = $engine->required_write_guard($operation);

Returns the domain's required predicate, or C<undef> when it has none, after
refusing what it cannot guard: C<query_rule_unsupported_field> when the
predicate reads an association field (for every operation), and
C<query_enforcement_unsupported_operation> for C<upsert>. L</governed_write>
calls it for every write; public surfaces call it for early feedback.

=head2 enforce_query

  my $eligible = $engine->query->where(Selecto::Expression->all(
      Selecto::Expression->eq('id', 42), Selecto::Expression->eq('status', 'active')));
  my $guarded = $engine->enforce_query($command, $eligible);
  $engine->execute_write($guarded);

Attaches the predicate of a read query to a write so the database applies
it again in the same statement. For inserts the candidate row is checked
against the captured predicate before the transaction opens. Upserts and
predicates that reach into associations are rejected, and on a tenant-field
domain the command must be tenant-scoped (C<missing_tenant_scope>).

=head2 enforce_query_evidence

  my $guarded = $engine->enforce_query_evidence($command, $evidence);

Like L</enforce_query>, with evidence captured earlier by
C<< Selecto::QueryEnforcement->capture($domain, $query) >>.

=head1 ACTIONS

See L<Selecto::Action> for how actions are declared.

=head2 plan_action

  my $plan = $engine->plan_action({action => 'archive', target => 42, inputs => {...}});

Returns a L<Selecto::Action::Plan>. C<target> is a primary-key value for row
actions or C<< {ids => [...]} >> for bulk actions.

=head2 preview_action, execute_action

  my $preview = $engine->preview_action($plan, resolver => $policy, context => $ctx);
  # {phase => 'preview', action => 'archive', decision => {...}, statement => {sql, params}}

  my $done = $engine->execute_action($plan, resolver => $policy, context => $ctx);
  # {phase => 'execute', action => 'archive', decision => {...}, result => Selecto::Write::Result}

Both authorize the plan through the capability resolver (or a C<grant>, see
below), then build the write command from the plan: the plan's filters
(target, transition source state, declared preconditions) become the
predicate, its changes become assignments (C<['system', 'now']> becomes the
current timestamp) and its cardinality becomes C<expected_count>. The command
then passes through the same governance and tenant scope as any other write.
Pass C<< returning => [...] >> to request values back.

The resolver is called as C<< $resolver->($request, $context, \%options) >>
and returns C<enabled>, C<disabled>, C<hidden> or a hash with a C<status>. A
missing resolver fails with C<missing_capability_resolver>; a denial fails
with C<action_capability_denied>. Insert and upsert actions create one row;
upserts resolve conflicts on a target declared under
C<writes.operations.upsert.conflict_targets>. Collection patches require a
host executor (C<unsupported_action_collection_patch>).

=head2 grant_action

  my $grant = $engine->grant_action($plan, phase => 'execute',
      resolver => $policy, context => $ctx, expires_in => 300);
  # later, e.g. after a confirmation dialog:
  my $done = $engine->execute_action($plan, grant => $grant, context => $ctx);

Authorizes now and returns a single-use L<Selecto::Action::Grant> bound to
the phase, the plan's content, the domain fingerprint, the engine's tenant
and C<< $context->{actor} >>. It expires after C<expires_in> seconds (default
300, at most 3600). A mismatched use fails with
C<action_grant_mismatch> and revokes the grant; a used, expired, revoked or
forged grant fails with C<action_grant_invalid>.

=head2 action_command

Returns the L<Selecto::Write::Command> an action plan would execute, before
tenant scope, without authorizing it.

=head1 QUERY LIBRARY

C<query_library>, C<apply_segment($query, $id, \%params)>,
C<apply_segments($query, \@ids, \%params)>,
C<apply_projection($query, $id_or_ids)>, C<apply_ordering($query, $id)> and
C<apply_view($query, $id, \%params)> apply the domain's named definitions to
a query. See L<Selecto::QueryLibrary>.

=head1 ACCESSORS

C<domain>, C<adapter>, C<domain_ref>, C<write_policy>, and C<scope> (a copy
of the trusted scope).

=head2 with_scope

  my $scoped = $engine->with_scope(tenant => 42);

Returns a copy bound to a trusted tenant. An engine that already has a
different tenant throws C<tenant_mismatch>.

=head1 TENANT SCOPE

A domain that declares C<writes.scope.tenant> cannot be written without a
trusted tenant. For every command, batch member and graph node:

=over 4

=item *

updates and deletes add C<< tenant_field = tenant >> to their predicate;

=item *

inserts and upserts are assigned the tenant (the field needs no
C<insertable> grant);

=item *

restating the same tenant is allowed; naming another tenant, or comparing the
tenant field in any other way, fails with C<tenant_mismatch>;

=item *

upserts must use a conflict target that includes the tenant field
(C<tenant_scope_conflict_target>);

=item *

an engine without a tenant fails with C<missing_tenant_scope>, as does a
graph whose nested domain stores the tenant field without declaring its own
C<writes.scope.tenant>.

=back

Reads of a domain with a C<tenant_field> are always restricted to the
engine's tenant. Domains that rely on a required predicate as their tenant
boundary are described under L<Selecto::Domain/with_required_predicate>.

=head2 References to other tenants' rows

A write with trusted tenants (the engine tenant, or the tenant values of a
required tenant predicate, where an C<in> list allows each of its tenants)
may only point a reference at a parent row of one of those tenants. A
reference is a field declared under C<writes.constraints.foreign_keys>:

  writes => {constraints => {foreign_keys => {
      customer_id => {source => 'input',
          references => {relation => 'customers', field => 'id', tenant_field => 'site_id'}},
      country_id  => {source => 'input',
          references => {relation => 'countries', field => 'id', tenant_field => JSON::PP::false}},
  }}}

or the owner key of a direct to-one association (not the row's primary key,
a C<through> or values-backed association). The referenced tenant column is
C<references.tenant_field> (C<false> or C<undef>: a relation every tenant
shares, left unguarded), else the association's C<target_scope_key>, else
the C<tenant_field> of the domain relation backed by the referenced table
(the root's for a self-reference). Every assigned, non-null reference to
tenant data is compiled into the write statement as
C<EXISTS (SELECT 1 FROM parent AS selecto_fk_parent WHERE ... = ? AND tenant = ?)>:
inserts and upserts insert through a C<SELECT ... WHERE> (C<FROM DUAL> on
MySQL and MariaDB), updates add it to their C<WHERE>, and SQL Server's
C<MERGE> adds it to both branches. A refused write affects no row and fails
with C<cardinality_mismatch>, even without an C<expected_count>, exactly
like one naming a parent that does not exist. A batch or graph child may
reference a row written earlier in the same transaction; a graph child's
bound parent key is not a caller assignment and is not guarded.

On a write to tenant data, a reference whose tenancy the domain does not
record fails closed with C<invalid_domain> (details C<code>
C<foreign_key_tenant_scope_undeclared>); declare
C<references.tenant_field>, a C<tenant_field> on the target schema, or
association scope keys. A declared foreign key to tenant data without
trusted tenants fails with C<missing_tenant_scope>, and a computed reference
value cannot be guarded (C<invalid_write>).

=head1 REQUIRED PREDICATES

Every required predicate (L<Selecto::Domain/with_required_predicate>) guards
writes as well as reads, whether or not the domain has a C<tenant_field>.
This deliberately goes beyond the shared protocol's earlier rule that
required predicates are read scopes. It applies to L</execute_write>,
L</preview_write>, L</write_command>, every member of L</execute_batch>, the
root node of L</execute_graph> (children are confined to their parent row),
L</"preview_action, execute_action"> (the preview shows the guarded
statement), and L<Selecto::API::EngineHandler> writes:

=over 4

=item *

a predicate over root fields is ANDed into update and delete scope, so they
match only rows inside it and C<expected_count> counts only those rows;
inserted rows must satisfy it (C<query_rule_violation>, or
C<query_rule_not_evaluable> when a value it reads is not assigned);

=item *

upserts are refused with C<query_enforcement_unsupported_operation>;

=item *

a predicate that reads any association field refuses every write with
C<query_rule_unsupported_field> (details: C<relation> and the sorted
association C<fields> paths); reads are unaffected;

=item *

C<writes.scope.tenant> still applies, and both conditions must hold. The
predicate is added once: a command that already carries it as a conjunct of
its scope or query enforcement is not guarded twice.

=back

=head1 ERRORS

All failures are L<Selecto::Error> exceptions. Codes you are likely to
handle: C<unknown_field>, C<invalid_query>, C<unsupported_feature>,
C<query_error> (database failure, message withheld), C<write_policy_missing>,
C<write_operation_not_enabled>, C<write_field_not_writable>,
C<write_relation_mismatch>, C<missing_required_write_fields>,
C<cardinality_mismatch>, C<tenant_mismatch>, C<missing_tenant_scope>,
C<query_rule_violation>, C<query_rule_unsupported_field>,
C<query_enforcement_unsupported_operation>,
C<action_capability_denied>, C<missing_capability_resolver>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain>, L<Selecto::Query>, L<Selecto::Write>,
L<Selecto::Action>, L<Selecto::Adapter>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
