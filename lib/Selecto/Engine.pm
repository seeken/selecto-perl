package Selecto::Engine;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Time::HiRes ();
use B ();
use Scalar::Util qw(blessed refaddr reftype);
use Hash::Util::FieldHash qw(fieldhash);
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
use Selecto::Write::Capabilities ();
use Selecto::Write::Policy ();
use Selecto::Write::Context ();
use Selecto::Write::FieldValidators ();
use Selecto::Action::Capability ();
use Selecto::Action::Grant ();
use Selecto::Action::Planner ();
use Selecto::Limits ();
use Selecto::OperationBudget ();
use Selecto::Write::ConflictTarget ();
use Selecto::WriteRules ();
use Selecto::Write::PortableCommand ();
use Selecto::DataRules ();
use Selecto::Action::Graph ();
use Selecto::ConfiguredDomain ();
use Selecto::Tenant::Context ();
use Selecto::QueryBinding ();

fieldhash my %ACTION_COMMAND_WORK;
fieldhash my %CONFIGURED_DOMAIN;

sub _read_authority {
    my ($self) = @_;
    return [$self->{scope}, $self->{write_context}, $self->{tenant_context}, $self->{tenant_required_filters}, $self->{query_mode}];
}

my $seal_domain = sub {
    my ($self) = @_;
    $CONFIGURED_DOMAIN{$self} = {
        domain => Selecto::ConfiguredDomain->digest($self->{domain}, $self->_read_authority),
    };
    return $self;
};

sub assert_domain_identity {
    my ($self) = @_;
    my $record = $CONFIGURED_DOMAIN{$self};
    Selecto::Error->throw('domain_modified_after_configuration',
        'configured domain identity has changed', {path => []})
        unless $record
            && $record->{domain} eq Selecto::ConfiguredDomain->digest($self->{domain}, $self->_read_authority)
            && (exists($record->{read}) == exists($self->{_read_domain}))
            && (!exists($record->{read}) || $record->{read} eq
                Selecto::ConfiguredDomain->digest($self->{_read_domain}, $self->_read_authority));
    return $self;
}

sub _action_command_digest {
    my ($self, $command) = @_;
    my $metadata = $command->{metadata};
    my $state = {
        (map { ($_ => $command->{$_}) } qw(operation relation assignments predicate scope_predicate
            query_enforcement expected_count foreign_key_guards)),
        metadata => {map { exists($metadata->{$_}) ? ($_ => $metadata->{$_}) : () }
            qw(returning conflict_target upsert_update_fields)},
    };
    Selecto::OperationBudget->new(limits => $self->{limits}, code => 'invalid_write')->check_tree(
        $state, label => 'accepted action command',
        allowed_classes => [qw(Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement)]);
    # Serializing the live records with Storable can add an integer cache to
    # a delivered NV (notably 1.0), changing later legacy-rule admission.
    # This bounded identity inspects native records without rewriting them.
    my $digest = eval { Selecto::Write::PortableCommand::_receipt_digest($state) };
    if (my $error = $@) {
        Selecto::Error->throw('invalid_write', 'accepted action command identity is invalid')
            if ref($error) eq 'Selecto::Error' && $error->code eq 'compiled_input_mismatch';
        die $error;
    }
    return $digest;
}

sub _accepted_command_work {
    my ($self, $command, $domain) = @_;
    return undef unless blessed($command) && $command->isa('Selecto::Write::Command');
    my $record = $ACTION_COMMAND_WORK{$command};
    return undef unless $record;
    $domain //= $self->{domain};
    Selecto::Error->throw('action_plan_mismatch', 'action command differs from accepted planning evidence')
        unless $record->{contract} eq JSON::PP->new->canonical->encode($domain->contract)
            && $record->{digest} eq $self->_action_command_digest($command);
    return $record->{work};
}

sub _retain_command_work {
    my ($self, $command, $work) = @_;
    $ACTION_COMMAND_WORK{$command} = {
        contract => JSON::PP->new->canonical->encode($self->{domain}->contract),
        digest => $self->_action_command_digest($command), work => $work,
    } if defined $work;
    return $command;
}

sub new {
    my ($class, %args) = @_;
    Selecto::Error->throw('invalid_domain', 'engine requires a domain')
        unless blessed($args{domain}) && UNIVERSAL::isa($args{domain}, 'Selecto::Domain');
    Selecto::Error->throw('invalid_adapter', 'engine requires a Selecto database adapter')
        unless blessed($args{adapter}) && $args{adapter}->isa('Selecto::Adapter');
    Selecto::Error->throw('invalid_domain_ref', 'engine domain_ref must be a Selecto domain reference')
        if defined($args{domain_ref})
            && !(blessed($args{domain_ref}) && $args{domain_ref}->isa('Selecto::Domain::Ref'));
    # Admit the raw structure before domain validation can inspect metadata.
    Selecto::ConfiguredDomain->digest($args{domain}, {});
    my $scope=_trusted_scope($args{scope});
    my $write_context=Selecto::Write::Context->resolve({}, {context=>$args{write_context}//{},
        (defined($scope->{tenant}) ? (tenant_id=>$scope->{tenant}) : ())});
    $scope->{tenant}=$write_context->{tenant_id} if defined $write_context->{tenant_id};
    my $limits = $args{limits} // Selecto::Limits->new;
    Selecto::Error->throw('invalid_limits', 'engine limits must be a Selecto::Limits object')
        unless blessed($limits) && $limits->isa('Selecto::Limits');
    $args{adapter}->assert_contract;
    $args{domain}->validate_query_library($limits);
    # Contradictory reference declarations are refused at admission, before
    # any query or write. A malformed foreign-key section stays a write error.
    if (my $references = eval { _domain_references($args{domain}) }) {
        _assert_reference_agreement($references);
    }
    _assert_unique_parent_keys($args{domain}, $scope);
    _assert_lookups_public($args{domain});
    my $mode = $args{mode} // 'permissive';
    Selecto::Error->throw('invalid_query_policy', 'mode must be strict or permissive')
        unless !defined(reftype($mode)) && ($mode eq 'strict' || $mode eq 'permissive');
    my $self = bless {
        query_mode => $mode,
        domain => $args{domain},
        adapter => $args{adapter},
        domain_ref => $args{domain_ref},
        scope => $scope,
        write_context=>$write_context,
        write_policy => _write_policy($args{write_policy}),
        limits => $limits,
    }, $class;
    Selecto::QueryBinding->configure_engine($self, $args{member_builders});
    return $seal_domain->($self);
}

# Trusted scope comes from the host that built the engine (for example from an
# authenticated request), never from a write command or an action intent.
sub _trusted_scope {
    my ($scope) = @_;
    return {} unless defined $scope;
    $scope=Selecto::Domain::QueryContract->copy_declaration({scope=>$scope})->{scope};
    Selecto::Error->throw('invalid_tenant_scope', 'engine scope must be an object')
        unless ref($scope) eq 'HASH';
    my @unknown = sort grep { $_ ne 'tenant' } keys %$scope;
    Selecto::Error->throw('invalid_tenant_scope', 'engine scope contains unsupported keys', {keys => \@unknown})
        if @unknown;
    my $tenant = Selecto::Write::Scope->trusted_tenant($scope->{tenant});
    return defined($tenant) ? {tenant => $tenant} : {};
}

# strict is the only write policy: a domain must declare writes.operations,
# and writes.fields for anything but deletes, before this engine writes it.
# The argument remains so callers may name strict explicitly; every other
# value, including the removed permissive policy, fails closed.
sub _write_policy {
    my ($policy) = @_;
    $policy //= 'strict';
    Selecto::Error->throw(
        'invalid_write_policy',
        'write_policy must be strict; the permissive write policy was removed',
    ) unless !ref($policy) && $policy eq 'strict';
    return $policy;
}

sub write_policy { return $_[0]->{write_policy}; }
sub limits { return $_[0]->{limits}; }

sub scope { return {%{$_[0]->{scope}}}; }
sub write_context {
    my ($self)=@_;$self->assert_domain_identity;
    return Selecto::Domain::QueryContract->copy_declaration({context=>$self->{write_context}})->{context};
}
sub with_write_context {
    my ($self,$context)=@_;$self->assert_domain_identity;
    my $next=Selecto::Write::Context->resolve({opts=>{context=>$self->{write_context}}},{context=>$context});
    my $read=$self->{tenant_context}//{};
    Selecto::Error->throw('tenant_context_mismatch','trusted write context conflicts with attached read context')
        if defined($read->{tenant_id}) && defined($next->{tenant_id}) && "$read->{tenant_id}" ne "$next->{tenant_id}";
    my $copy=bless {%$self,write_context=>$next,scope=>{%{$self->{scope}}}},ref($self);
    $copy->{scope}{tenant}=$next->{tenant_id} if defined $next->{tenant_id};
    delete $copy->{_read_domain};
    return $seal_domain->(Selecto::QueryBinding->inherit_engine($self,$copy,flat_input=>1));
}

# Read context is attached independently of the existing trusted write scope.
# A row context must be explicitly applied as required query obligations.
sub with_tenant {
    my ($self, $given) = @_;
    $self->assert_domain_identity;
    my $context = Selecto::Tenant::Context->normalize($given);
    my $old_context = $self->{tenant_context} // {};
    for my $key (qw(tenant_id tenant_field prefix)) {
        my $old = $old_context->{$key};
        Selecto::Error->throw('tenant_context_mismatch', 'read tenant context cannot replace an attached identity')
            if defined($old) && (!defined($context->{$key}) || "$old" ne "$context->{$key}");
    }
    if (defined($context->{tenant_id})) {
        $self->{domain}->resolve($context->{tenant_field});
        Selecto::Error->throw('tenant_context_mismatch', 'read context conflicts with trusted engine scope')
            if defined($self->{scope}{tenant}) && "$self->{scope}{tenant}" ne "$context->{tenant_id}";
    }
    my $copy = bless {%$self, tenant_context => $context}, ref($self);
    delete $copy->{_read_domain};
    # Initial attachment may consume this engine's existing flat intent. The
    # target still enforces its required scope; attached-context rewrites do
    # not establish another input lineage.
    return $seal_domain->(Selecto::QueryBinding->inherit_engine($self, $copy,
        flat_input => !keys(%$old_context)));
}
sub tenant_context {
    my ($self) = @_;
    $self->assert_domain_identity;
    require Selecto::Domain::QueryContract;
    return Selecto::Domain::QueryContract->copy_declaration($self->{tenant_context} // {});
}
sub require_tenant_filter {
    my ($self, $field, $value) = @_;
    $self->assert_domain_identity;
    my $filter = Selecto::Tenant::Context->filter($field, $value);
    $self->{domain}->resolve($filter->[0]);
    my $filters = Selecto::Tenant::Context->unique_filters([@{$self->{tenant_required_filters} // []}, $filter]);
    my $copy = bless {%$self, tenant_required_filters => $filters}, ref($self);
    $copy->_assert_engine_tenant_agrees;
    delete $copy->{_read_domain};
    return $seal_domain->(Selecto::QueryBinding->inherit_engine($self, $copy, flat_input => 1));
}
sub validate_tenant_scope {
    my ($self) = @_;
    $self->assert_domain_identity;
    require Selecto::QueryPolicy;
    my $filters = $self->required_filters;
    return Selecto::Tenant::Context->report($self->{domain}->tenant_required,
        $self->{tenant_context} // {}, $filters);
}
sub required_filters {
    my ($self) = @_;
    $self->assert_domain_identity;
    require Selecto::QueryPolicy;
    my $filters = Selecto::QueryPolicy->filters($self->{domain}, $self->query, $self->{limits});
    push @$filters, @{$self->{tenant_required_filters} // []};
    my $read_field = $self->{domain}->tenant_field;
    push @$filters, [$read_field, $self->{scope}{tenant}]
        if defined($read_field) && defined($self->{scope}{tenant});
    require Selecto::Domain::QueryContract;
    return Selecto::Domain::QueryContract->copy_declaration({filters => $filters})->{filters};
}
sub apply_tenant_scope {
    my ($self, %options) = @_;
    $self->assert_domain_identity;
    Selecto::Error->throw('invalid_tenant_context', 'scope application takes its attached context; overrides are unsupported') if keys %options;
    my $report = $self->validate_tenant_scope;
    Selecto::Error->throw($report->{error}{code}, 'attached tenant context conflicts with required query filters', $report->{error})
        if !$report->{valid} && $report->{error}{code} ne 'tenant_scope_missing';
    my $copy = $self;
    my $context = $self->{tenant_context} // {};
    $copy = $copy->require_tenant_filter(@$_) for @{$context->{required_filters} // []};
    $copy = $copy->require_tenant_filter($context->{tenant_field}, $context->{tenant_id}) if defined $context->{tenant_id};
    return $copy;
}
sub merge_execution_options {
    my ($self, %options) = @_;
    $self->assert_domain_identity;
    Selecto::Error->throw('invalid_tenant_context', 'read execution options only support prefix') if grep { $_ ne 'prefix' } keys %options;
    my $attached = ($self->{tenant_context} // {})->{prefix};
    if (exists $options{prefix}) {
        require Selecto::Domain::QueryContract;
        my $copy = Selecto::Domain::QueryContract->copy_declaration({prefix => $options{prefix}});
        $options{prefix} = Selecto::Identifier::checked($copy->{prefix});
    }
    Selecto::Error->throw('tenant_prefix_mismatch', 'execution prefix conflicts with attached tenant context')
        if defined($attached) && exists($options{prefix}) && $options{prefix} ne $attached;
    $options{prefix} = $attached if defined $attached;
    return \%options;
}
sub _check_read_execution_options {
    my ($self, $options) = @_;
    $self->assert_domain_identity;
    return unless exists $options->{prefix};
    $self->merge_execution_options(prefix => $options->{prefix});
    Selecto::Error->throw('invalid_tenant_context', 'execution prefix requires an attached read context')
        unless defined(($self->{tenant_context} // {})->{prefix});
}
sub _ensure_write_context {
    my ($self) = @_;
    $self->assert_domain_identity;
    Selecto::Error->throw('unsupported_feature', 'read tenant context does not authorize writes')
        if keys %{$self->{tenant_context} // {}} || @{$self->{tenant_required_filters} // []};
}
sub _ensure_read_scope {
    my ($self) = @_;
    $self->_assert_engine_tenant_agrees;
    my $report = $self->validate_tenant_scope;
    Selecto::Error->throw($report->{error}{code}, 'required read tenant scope is missing or inconsistent', $report->{error}) unless $report->{valid};
    return;
}
# Lesson 43: every read of a tenant_field domain under a trusted engine
# tenant is bound to it, intersected with the required predicate and any
# required tenant filter. One whose tenant condition excludes the engine
# tenant is refused with tenant_mismatch before any read path runs, rather
# than reported as an ambiguous scope or read as an empty result.
sub _assert_engine_tenant_agrees {
    my ($self) = @_;
    my $tenant = $self->{scope}{tenant};
    my $field = $self->{domain}->tenant_field;
    return unless defined($tenant) && defined($field);
    Selecto::Error->throw('tenant_mismatch', 'required predicate excludes the engine tenant', {tenant_field => "$field"})
        if _excludes_tenant($self->{domain}->required_predicate, $field, $tenant)
            || grep { $_->[0] eq "$field" && _excludes_tenant(Selecto::Expression->eq(@$_), $field, $tenant) }
                @{$self->{tenant_required_filters} // []};
    return;
}
sub _has_read_tenant_policy {
    my ($self) = @_;
    $self->assert_domain_identity;
    return $self->{domain}->tenant_required || keys(%{$self->{tenant_context} // {}}) || @{$self->{tenant_required_filters} // []};
}
sub _read_policy_identity {
    my ($self) = @_;
    $self->assert_domain_identity;
    return Selecto::ConfiguredDomain->digest($self->{domain}, $self->_read_authority);
}

# Trusted hosts may tighten a request's budget without reconfiguring its
# domain. Preserve the already checked private evidence on the new engine.
sub with_limits {
    my ($self, $limits) = @_;
    $self->assert_domain_identity;
    my $copy = bless {%$self, limits => $self->{limits}->intersect($limits)}, ref($self);
    $CONFIGURED_DOMAIN{$copy} = {%{$CONFIGURED_DOMAIN{$self}}};
    return Selecto::QueryBinding->inherit_engine($self, $copy, flat_input => 1);
}

# A copy of this engine bound to trusted scope. An engine that already holds a
# tenant cannot be re-scoped to a different one.
sub with_scope {
    my ($self, %scope) = @_;
    $self->assert_domain_identity;
    my $next = _trusted_scope(\%scope);
    my $read_context = $self->{tenant_context} // {};
    Selecto::Error->throw('tenant_context_mismatch', 'trusted engine scope conflicts with attached read context')
        if defined($read_context->{tenant_id}) && defined($next->{tenant}) && "$read_context->{tenant_id}" ne "$next->{tenant}";
    my $current = $self->{scope}{tenant};
    Selecto::Error->throw('tenant_mismatch', 'engine is already scoped to a different tenant')
        if defined($current) && defined($next->{tenant}) && "$current" ne "$next->{tenant}";
    my $copy = bless {%$self}, ref($self);
    $copy->{scope} = {%{$self->{scope}}, %$next};
    $copy->{write_context}=Selecto::Write::Context->resolve({}, {context=>$self->{write_context},
        (defined($copy->{scope}{tenant}) ? (tenant_id=>$copy->{scope}{tenant}) : ())});
    delete $copy->{_read_domain};
    return $seal_domain->(Selecto::QueryBinding->inherit_engine($self, $copy, flat_input => 1));
}

# A copy of this engine whose domain omits the prerequisite columns of the
# named actions; see Selecto::Domain::without_action_prerequisites.
sub without_action_prerequisites {
    my ($self, @action_ids) = @_;
    $self->assert_domain_identity;
    my $domain = $self->{domain}->without_action_prerequisites(@action_ids);
    return $self if $domain == $self->{domain};
    my $copy = bless {%$self}, ref($self);
    $copy->{domain} = $domain;
    delete $copy->{_read_domain};
    return $seal_domain->(Selecto::QueryBinding->inherit_engine($self, $copy));
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
        (defined($args{write_context}) ? (write_context => $args{write_context}) : ()),
        (defined($args{write_policy}) ? (write_policy => $args{write_policy}) : ()),
        (defined($args{limits}) ? (limits => $args{limits}) : ()),
        (defined($args{mode}) ? (mode => $args{mode}) : ()),
        (defined($args{member_builders}) ? (member_builders => $args{member_builders}) : ()),
    );
}

sub domain  { $_[0]->assert_domain_identity; return $_[0]->{domain}; }
sub adapter { return $_[0]->{adapter}; }
sub domain_ref { return $_[0]->{domain_ref}; }
sub query_mode { $_[0]->assert_domain_identity; return $_[0]->{query_mode}; }
sub query   { $_[0]->assert_domain_identity; return Selecto::QueryBinding->bind($_[0], Selecto::Query->new); }
sub validate_query {
    my ($self, $query) = @_;
    $self->assert_domain_identity;
    $self->_ensure_read_scope;
    Selecto::OperationBudget->new(limits => $self->{limits}, code => 'invalid_query')->check_tree(
        $query, label => 'query', allowed_classes => [qw(Selecto::Query Selecto::Expression Selecto::Domain Selecto::Domain::Association)],
        allowed_base_classes => ['Selecto::Query']);
    Selecto::QueryBinding->validate($self, $query);
    return 1;
}
sub query_filters {
    my ($self, $query) = @_;
    require Selecto::QueryPolicy;
    return Selecto::QueryPolicy->filters($self->read_domain, $query, $self->{limits});
}
sub compile {
    my ($self, $query) = @_;
    $self->assert_domain_identity;
    $self->_ensure_read_scope;
    Selecto::OperationBudget->new(limits => $self->{limits}, code => 'invalid_query')->check_tree(
        $query, label => 'query', allowed_classes => [qw(Selecto::Query Selecto::Expression Selecto::Domain Selecto::Domain::Association)],
        allowed_base_classes => ['Selecto::Query']);
    Selecto::QueryBinding->validate($self, $query);
    if (defined(($self->{tenant_context} // {})->{prefix})) {
        Selecto::Error->throw('unsupported_feature', 'prefix read contexts do not support retargeted queries')
            if $query->retarget_spec;
    }
    local $self->{adapter}{_selecto_compile_engine} = $self;
    local $self->{adapter}{_selecto_compile_limits} = $self->{limits};
    # This query was just admitted under these limits, and its parameters are
    # admitted below under them too, so the SQL adapter skips repeating the
    # identical checks for this exact query (nested queries are still checked).
    local $self->{adapter}{_selecto_admitted_query} = $query;
    my $statement = $self->{adapter}->compile($self->read_domain, $query);
    $self->{adapter}->admit_parameters(
        Selecto::OperationBudget->new(limits => $self->{limits}, code => 'invalid_query'),
        $statement->params, label => 'statement parameter');
    $self->assert_domain_identity;
    return $statement;
}
sub all {
    my ($self, $query, %options) = @_;
    $self->_check_read_execution_options(\%options);
    my $statement = $self->compile($query);
    $self->assert_domain_identity;
    return $self->{adapter}->execute_query($statement, $self->_canonical_option(%options))
        unless $options{export_scalars};
    # Export scalars are opt-in: only adapters that provide them may be asked.
    Selecto::Error->throw('unsupported_feature', 'configured adapter does not provide export scalars')
        unless $self->{adapter}->supports('export_scalars');
    return $self->{adapter}->execute_query($statement, export_scalars => 1);
}

# The domain reads compile against. An engine holding a trusted tenant scopes
# every read of a tenant_field domain to that tenant, as it already scopes
# writes, so a read path that forgets with_required_predicate cannot see other
# tenants' rows. Query members inherit the added condition through the
# required predicate. A required predicate whose tenant condition excludes the
# trusted tenant is a host error rather than an empty result. On a two-column
# root (writes.scope.tenant on another column) reads bind tenant_field only
# (lesson 41c); relations tenanted on the write-scope column pair with the
# root by name and are never bound to the engine value.
sub read_domain {
    my ($self) = @_;
    $self->assert_domain_identity;
    $self->_ensure_read_scope;
    return $self->{_read_domain} if exists $self->{_read_domain};
    my $read = do {
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
        if (@{$self->{tenant_required_filters} // []}) {
            my @required = map { Selecto::Expression->eq(@$_) } @{$self->{tenant_required_filters}};
            unshift @required, $domain->required_predicate if defined $domain->required_predicate;
            my $predicate = Selecto::Expression->all(@required);
            $predicate->{_query_filter_list} = 1;
            $domain = $domain->with_required_predicate($predicate);
        }
        my $prefix = ($self->{tenant_context} // {})->{prefix};
        if (defined $prefix) {
            $domain = bless {%$domain, _read_prefix => $prefix}, ref($domain);
        }
        $domain;
    };
    $self->{_read_domain} = $read;
    $CONFIGURED_DOMAIN{$self}{read} = Selecto::ConfiguredDomain->digest($read, $self->_read_authority);
    return $read;
}

# The tenant boundary public surfaces (the API write and query handlers,
# canned pages, co-domain lookups) require on a tenant_field domain. Either the
# engine holds a trusted tenant (which every write binds on tenant_field,
# lesson 47), or the trusted host scope has a positive tenant conjunct: the required predicate ANDed with any host
# predicate the surface accepts. Any other host predicate, such as a status
# filter, is not a boundary. Engine::all itself stays available for trusted
# host reads that deliberately span tenants.
sub assert_tenant_boundary {
    my ($self, %args) = @_;
    $self->assert_domain_identity;
    my $access = $args{access} // '';
    Selecto::Error->throw('invalid_tenant_scope', 'tenant boundary access must be read or write')
        unless $access eq 'read' || $access eq 'write';
    my $field = $self->{domain}->tenant_field;
    return $self unless defined $field;
    my $column = $self->_write_tenant_column;
    if ($access eq 'write' && defined($self->{scope}{tenant}) && defined($column)) {
        # Lesson 47: an engine tenant bounds every write; a host boundary
        # that excludes it is a host error, refused before any write.
        Selecto::Error->throw('tenant_mismatch', 'required predicate excludes the engine tenant',
            {tenant_field => "$column"})
            if grep { _excludes_tenant($_, $column, $self->{scope}{tenant}) }
                grep { defined } $self->_host_required_predicate, $args{host_predicate};
    }
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
    my ($self, $query, $column, %options) = @_;
    Selecto::Error->throw('unsupported_feature', 'configured adapter does not support projection sums')
        unless $self->{adapter}->supports('projection_sum')
            && $self->{adapter}->can('projection_sum_statement');
    my $statement = $self->{adapter}->projection_sum_statement($self->compile($query), $column);
    my $result = $self->{adapter}->execute_query($statement, $self->_canonical_option(%options));
    my $rows = $result->{rows};
    Selecto::Error->throw('invalid_query', 'projection sum returned an invalid result')
        unless ref($rows) eq 'ARRAY' && @$rows == 1
            && ref($rows->[0]) eq 'ARRAY' && @{$rows->[0]} == 1
            && defined($rows->[0][0]);
    return $rows->[0][0];
}
sub stream {
    my ($self, $query, %options) = @_;
    $self->_check_read_execution_options(\%options);
    Selecto::Error->throw('unsupported_feature', 'configured adapter does not support streaming')
        unless $self->{adapter}->supports('stream') && $self->{adapter}->can('stream_query');
    my %canonical = $self->_canonical_option(%options);
    delete $options{canonical_values};
    my $statement = $self->compile($query);
    $self->assert_domain_identity;
    return $self->{adapter}->stream_query($statement, %options, %canonical);
}

# canonical_values reaches only adapters that choose between driver and
# canonical values (supports('canonical_values')); the others always return
# their canonical values and keep their execute_query signatures.
sub _canonical_option {
    my ($self, %options) = @_;
    return () unless exists($options{canonical_values})
        && $self->{adapter}->supports('canonical_values');
    return (canonical_values => $options{canonical_values} ? 1 : 0);
}
sub preview_write {
    my ($self, $command) = @_;
    $self->assert_domain_identity;
    Selecto::Write::Capabilities->requirements($command);
    return Selecto::Write::FieldValidators->with_budget(sub {
        return Selecto::DataRules->_with_proof_budget(sub { $self->_preview_write($command) },
            accepted_work => $self->_accepted_command_work($command), limits => $self->{limits});
    },limits=>$self->{limits});
}
sub _preview_write {
    my ($self, $command) = @_;
    my $accepted_input=Selecto::Write::PortableCommand->_accepted_input($command);
    my $accepted_upsert=Selecto::Write::PortableCommand->_accepted_protected_upsert($command);
    my $input = Selecto::WriteRules->literal_input($command);
    $command = $self->governed_write($command);
    $command = Selecto::WriteRules->prepare_submitted($self,$command,input=>$input,accepted_input=>$accepted_input);
    $self->preflight_write($command);
    return $self->{adapter}->preview_write($command) unless Selecto::WriteRules->has_stored_rules($self->{domain}, $command->operation);
    return $self->_rules_transaction(sub {
        return $self->{adapter}->preview_write(Selecto::WriteRules->govern(
            $self, $command, input_prepared => 1, accepted_upsert => $accepted_upsert));
    });
}
sub execute_write {
    my ($self, $command) = @_;
    $self->assert_domain_identity;
    Selecto::Write::Capabilities->requirements($command);
    return Selecto::Write::FieldValidators->with_budget(sub {
        return Selecto::DataRules->_with_proof_budget(sub { $self->_execute_write($command) },
            accepted_work => $self->_accepted_command_work($command), limits => $self->{limits});
    },limits=>$self->{limits});
}
sub _execute_write {
    my ($self, $command) = @_;
    my $accepted_input=Selecto::Write::PortableCommand->_accepted_input($command);
    my $accepted_upsert=Selecto::Write::PortableCommand->_accepted_protected_upsert($command);
    my $input = Selecto::WriteRules->literal_input($command);
    $command = $self->governed_write($command);
    $command = Selecto::WriteRules->prepare_submitted($self,$command,input=>$input,accepted_input=>$accepted_input);
    $self->preflight_write($command);
    return $self->_execute_governed(execute_write => $command) unless Selecto::WriteRules->has_stored_rules($self->{domain}, $command->operation);
    return $self->_rules_transaction(sub {
        return $self->_execute_governed(execute_write => Selecto::WriteRules->govern(
            $self, $command, input_prepared => 1, accepted_upsert => $accepted_upsert));
    });
}

# Hands a governed write object to the adapter with the engine's single-use
# authorization for it.
sub _execute_governed {
    my ($self, $method, $subject) = @_;
    $self->assert_domain_identity;
    $self->_ensure_write_context;
    $self->preflight_write($subject) unless $method eq 'execute_transaction';
    return $self->{adapter}->$method($subject, Selecto::Write::Authorization->_issue($subject));
}

# Capability discovery belongs to real dispatch, not adapter-neutral domain
# governance/portable compilation. Admit the write before invoking a provider.
sub preflight_write {
    my ($self, $write) = @_;
    return Selecto::Write::Capabilities->preflight($self->{adapter}, $write);
}
sub _rules_transaction {
    my ($self, $work) = @_;
    Selecto::Error->throw('required_data_rule_pending', 'adapter cannot protect stored candidates')
        unless $self->{adapter}->can('execute_transaction');
    my $protected_work = sub {
        return $self->{adapter}->rule_upsert_scope($work)
            if $self->{adapter}->can('rule_upsert_scope');
        return $work->();
    };
    my $request = bless {work => sub {
        Selecto::DataRules->_with_proof_budget($protected_work, limits => $self->{limits});
    }}, 'Selecto::Write::Transaction';
    return $self->_execute_governed(execute_transaction => $request);
}
sub execute_batch {
    my ($self, $batch, @options) = @_;
    $self->assert_domain_identity;
    Selecto::Write::Capabilities->requirements($batch);
    Selecto::Error->throw('invalid_write', 'execute_batch requires a Selecto::Write::Batch')
        unless blessed($batch) && $batch->isa('Selecto::Write::Batch');
    my $engines=$self->_batch_engines($batch,\@options);
    my $commands=$batch->commands;
    my @work = map { $engines->[$_]->_accepted_command_work($commands->[$_]) } 0..$#$commands;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return Selecto::DataRules->_with_proof_budget(sub { $self->_execute_batch($batch,$engines) },
            accepted_work => \@work, limits => $self->{limits});
    },limits=>$self->{limits});
}
sub _batch_engines {
    my ($self,$batch,$options)=@_;
    $self->_ensure_write_context;
    Selecto::Error->throw('invalid_write','batch options require key/value pairs') if @$options % 2;
    return [map{$self}@{$batch->commands}] unless @$options;
    Selecto::Error->throw('invalid_write','batch accepts only one trusted engines option')
        unless @$options==2 && !defined(reftype($options->[0])) && defined($options->[0]) && $options->[0] eq 'engines';
    my $engines=$options->[1];
    Selecto::Error->throw('invalid_write','batch engines must match every command')
        unless ref($engines) eq 'ARRAY' && !defined(tied(@$engines)) && @$engines==@{$batch->commands};
    Selecto::OperationBudget->new(limits=>$self->{limits},code=>'invalid_write')->consume_count(
        'max_expression_nodes',scalar(@$engines),label=>'configured batch engines');
    my $context=JSON::PP->new->canonical->encode($self->{write_context});
    for my $index (0..$#$engines) {
        Selecto::Error->throw('invalid_write','batch engines cannot contain tied values') if defined(tied($engines->[$index]));
        my $engine=$engines->[$index];
        Selecto::Error->throw('invalid_write','batch requires genuinely configured engines')
            unless ref($engine) eq 'Selecto::Engine' && $CONFIGURED_DOMAIN{$engine};
        $engine->assert_domain_identity;
        $engine->_ensure_write_context;
        Selecto::Error->throw('invalid_write','batch engines must use the identical adapter')
            unless refaddr($engine->{adapter})==refaddr($self->{adapter});
        Selecto::Error->throw('tenant_mismatch','batch engines must agree on trusted write context')
            unless JSON::PP->new->canonical->encode($engine->{write_context}) eq $context;
    }
    return [@$engines];
}
sub _execute_batch {
    my ($self, $batch, $engines) = @_;
    Selecto::Error->throw('invalid_write', 'execute_batch requires a Selecto::Write::Batch')
        unless blessed($batch) && $batch->isa('Selecto::Write::Batch');
    my @input = map { Selecto::WriteRules->literal_input($_) } @{$batch->commands};
    my @accepted_input = map { Selecto::Write::PortableCommand->_accepted_input($_) } @{$batch->commands};
    $engines//=[map{$self}@{$batch->commands}];
    my $original=$batch->commands;
    my @commands = map { $engines->[$_]->governed_write($original->[$_]) } 0..$#$original;
    @commands = map { Selecto::WriteRules->prepare_submitted($engines->[$_],$commands[$_],input=>$input[$_],accepted_input=>$accepted_input[$_]) } 0..$#commands;
    my $prepared = Selecto::Write::Batch->new(@commands);
    $self->preflight_write($prepared);
    return $self->_execute_governed(execute_batch => $prepared)
        unless grep { Selecto::WriteRules->has_stored_rules($engines->[$_]->domain, $commands[$_]->operation) } 0..$#commands;
    return $self->_rules_transaction(sub {
        # Stored batch deltas may overlap or depend on earlier mutations. They
        # need a prospective whole-plan provider; do not dispatch a prefix.
        Selecto::Error->throw('required_data_rule_pending', 'protected stored batch deltas require a whole-plan candidate provider')
            if grep { $_->operation ne 'insert' } @commands;
        my $admitted = Selecto::WriteRules->_with_stored_failure_deferral(sub {
            my @admitted = map { Selecto::WriteRules->govern($engines->[$_], $commands[$_], input_prepared => 1) } 0 .. $#commands;
            return Selecto::Write::Batch->new(@admitted);
        });
        return $self->_execute_governed(execute_batch => $admitted);
    });
}
sub execute_graph {
    my ($self,$graph)=@_;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return Selecto::DataRules->_with_proof_budget(sub { $self->_execute_graph($graph) },limits=>$self->{limits});
    },limits=>$self->{limits});
}
sub _execute_graph {
    my ($self, $graph) = @_;
    $self->assert_domain_identity;
    Selecto::Write::Capabilities->requirements($graph);
    my ($prepared, $contexts) = $self->_prepared_graph($graph);
    $self->preflight_write($prepared);
    my $work = sub {
        $prepared = Selecto::WriteRules->admit_graph($self, $prepared, $contexts) if $prepared->{_requires_rules};
        return $self->_execute_governed(execute_graph => $prepared);
    };
    my @accepted = map { $self->_accepted_command_work($_->{command}, $contexts->{$_->{id}}{domain}) }
        @{$graph->nodes};
    return Selecto::DataRules->_with_proof_budget(sub {
        return $self->_rules_transaction($work) if $prepared->{_requires_rules};
        return $work->();
    }, accepted_work => \@accepted, limits => $self->{limits});
}
sub _prepared_graph {
    my ($self,$graph,%options)=@_;
    return Selecto::Write::FieldValidators->with_budget(sub { $self->_prepare_graph($graph,%options) },limits=>$self->{limits});
}
sub _prepare_graph {
    my ($self, $graph,%options) = @_;
    Selecto::Error->throw('invalid_write_graph', 'execute_graph requires a Selecto::Write::Graph')
        unless blessed($graph) && $graph->isa('Selecto::Write::Graph');
    my $accepted_inputs=Selecto::Write::PortableCommand->_accepted_graph_inputs($graph);
    my @nodes = @{$graph->nodes};
    # The constructor materializes downstream keys for execution, but result
    # policy governs only the caller's public returning intent. Re-derive the
    # internal keys after every node has passed its actual domain policy.
    for my $node (@nodes) {
        my $metadata=$node->{command}->metadata;
        my $returning=$graph->public_returning($node->{id});
        if (defined $returning) { $metadata->{returning}=$returning }
        else { delete $metadata->{returning} }
        $node->{command}=$node->{command}->with_metadata($metadata);
    }
    my $relationship_work=Selecto::OperationBudget->new(limits=>$self->{limits},code=>'invalid_write_graph');
    my %rule_inputs = map { ($_->{id} => Selecto::WriteRules->literal_input($_->{command})) } @nodes;
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
        domain        => $self->{domain},
        rule_input    => $rule_inputs{$nodes[0]{id}},
        operation     => $nodes[0]{command}->operation,
    });
    my $root_scope = $self->{domain}->write_tenant_scope;
    my $tenants = $self->_trusted_tenant_sets($self->_host_required_predicate);
    for my $node (@nodes[1 .. $#nodes]) {
        ($contexts{$node->{id}}, $node->{command}) =
            $self->_validate_graph_node($node, \%contexts, $root_scope, $tenants,$graph->owned_sets,$relationship_work);
        $contexts{$node->{id}}{rule_input} = $rule_inputs{$node->{id}};
    }
    for my $node ($options{submitted_prepared} ? () : @nodes) {
        my $engine=$self->_graph_engine($contexts{$node->{id}}{domain});
        $node->{command}=Selecto::WriteRules->prepare_submitted($engine,$node->{command},input=>$rule_inputs{$node->{id}},accepted_input=>$accepted_inputs->{$node->{id}});
    }
    my $prepared = Selecto::Write::Graph->new(nodes => \@nodes, owned_sets => $graph->owned_sets,metadata=>$graph->metadata);
    my $sets = $self->_govern_owned_sets($graph->owned_sets, $prepared->{nodes}, \%contexts,$relationship_work,$tenants);
    $prepared->{_governed_owned_sets} = $sets;
    $prepared->{_reference_domains} = {map { ($_ => $contexts{$_}{domain}) } keys %contexts};
    $prepared->{_requires_rules} = scalar(grep {
        $contexts{$_->{id}}{domain} && Selecto::WriteRules->has_stored_rules($contexts{$_->{id}}{domain}, $_->{command}->operation)
    } @nodes);
    for my $set (@{$graph->owned_sets}) {
        my $edge = $contexts{$set->{parent}}{relationships}{$set->{relationship}};
        $prepared->{_requires_rules} ||= Selecto::WriteRules->has_stored_rules(_native_relationship_domain($edge->{domain}), 'delete');
    }
    return ($prepared, \%contexts);
}

sub _govern_owned_sets {
    my ($self, $sets, $nodes, $contexts,$relationship_work,$tenants) = @_;
    return [] unless @$sets;
    my %nodes = map { ($_->{id} => $_) } @$nodes;
    my %position = map { ($nodes->[$_]{id} => $_) } 0 .. $#$nodes;
    my %physical;
    my @prepared;
    for my $set (@$sets) {
        my $parent = $contexts->{$set->{parent}};
        my $edge = $parent->{relationships}{$set->{relationship}};
        my $policy=_relationship_policy($edge,$relationship_work);
        Selecto::Error->throw('write_relation_mismatch', 'owned sync requires a declared writable relationship')
            unless $policy->{writable} && ref($edge->{domain}) eq 'HASH';
        Selecto::Error->throw('write_operation_not_enabled', 'relationship does not grant owned sync cleanup')
            unless $policy->{owned_sync};
        my $child = _native_relationship_domain($edge->{domain});
        my $parent_key = $edge->{parent_key} // $parent->{primary_key};
        my $child_key = $edge->{child_key} // $edge->{foreign_key};
        my $identity = $edge->{identity_fields};
        my %identity;
        Selecto::Error->throw('invalid_domain', 'owned sync requires exact declared stored identity and binding keys')
            unless defined($parent_key) && exists($parent->{fields}{$parent_key})
                && ref($parent->{domain}->_field_metadata_view($parent_key)->{computed}) ne 'HASH'
                && defined($child_key) && exists($child->fields->{$child_key})
                && ref($child->_field_metadata_view($child_key)->{computed}) ne 'HASH'
                && ref($identity) eq 'ARRAY' && @$identity
                && !grep { !defined($_) || ref($_) || $identity{$_}++ || !exists($child->fields->{$_})
                    || ref($child->_field_metadata_view($_)->{computed}) eq 'HASH' } @$identity;
        Selecto::Error->throw('invalid_write_graph', 'owned set duplicates a physical relationship')
            if $physical{join('/', $set->{parent}, $child->table, $parent_key, $child_key)}++;
        Selecto::Error->throw('invalid_write_graph', 'owned sync parent must affect exactly one row')
            unless defined($nodes{$set->{parent}}{command}->expected_count)
                && $nodes{$set->{parent}}{command}->expected_count == 1
                && $nodes{$set->{parent}}{command}->operation ne 'delete';
        my %members = map { ($_ => 1) } @{$set->{nodes}};
        for my $node (@$nodes) {
            $relationship_work->consume_count('max_expression_nodes',1,label=>'owned relationship work') if $relationship_work;
            my @matches = grep { $_->{from} eq $set->{parent} && $_->{field} eq $child_key
                && $_->{key} eq $parent_key } @{$node->{bindings}};
            next unless $members{$node->{id}} || (@matches && $node->{command}->relation eq $child->table);
            Selecto::Error->throw('invalid_write_graph', 'owned set must include every row on its exact relationship edge')
                unless $members{$node->{id}} && @matches == 1 && @{$node->{bindings}} == 1
                    && $node->{command}->relation eq $child->table
                    && defined($node->{command}->expected_count) && $node->{command}->expected_count == 1;
            my $metadata = $node->{command}->metadata;
            $metadata->{returning} = [@{$metadata->{returning} // []}, @$identity];
            my %seen;
            $metadata->{returning} = [grep { !$seen{$_}++ } @{$metadata->{returning}}];
            $node->{command} = $node->{command}->with_metadata($metadata);
        }
        my $root_metadata = $nodes{$set->{parent}}{command}->metadata;
        $root_metadata->{returning} = [@{$root_metadata->{returning} // []}, $parent_key];
        my %returned;
        $root_metadata->{returning} = [grep { !$returned{$_}++ } @{$root_metadata->{returning}}];
        $nodes{$set->{parent}}{command} = $nodes{$set->{parent}}{command}->with_metadata($root_metadata);
        my $child_engine = $self->_graph_engine($child);
        # Cleanup is limited to owned rows. Its exact parent key is supplied
        # from the root's actual RETURNING result during graph execution; this
        # necessary ownership condition survives alongside that later binding.
        # A tenant ownership key instead receives Scope's trusted equality.
        my $child_scope = $child->write_tenant_scope;
        my $ownership_scope = $child_scope && $child_scope->{field} eq $child_key
            ? undef : Selecto::Expression->not_null($child_key);
        my $cleanup = $child_engine->governed_write(Selecto::Write::Command->new(
            operation => 'delete', relation => $child->table, expected_count => undef,
            scope_predicate => $ownership_scope));
        # Cleanup deletes only rows the root's tenant boundary admits.
        ($cleanup) = $self->_confine_child_tenants($cleanup, $tenants, $child->fields,
            owned_set => $set->{relationship}) unless $child_scope;
        push @prepared, {%$set, parent_key => $parent_key, child_key => $child_key,
            identity_fields => [@$identity], cleanup => $cleanup};
    }
    return [sort { $position{$a->{parent}} <=> $position{$b->{parent}} } @prepared];
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
    $self->assert_domain_identity;
    $self->_ensure_write_context;
    Selecto::Error->throw('invalid_write', 'write command required')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    my $accepted_work = $self->_accepted_command_work($command);
    Selecto::OperationBudget->new(limits => $self->{limits}, code => 'invalid_write')->check_tree(
        {assignments => $command->{assignments}, predicate => $command->{predicate},
            scope_predicate => $command->{scope_predicate}, query_enforcement => $command->{query_enforcement}},
        label => 'write', allowed_classes => [qw(Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement)]);
    # Command admission owns write-shape errors. Inspect the sealed trusted
    # policy only after that boundary, before normalization or any provider.
    Selecto::Write::FieldValidators->admit_domain({writes=>$self->{domain}->writes},limits=>$self->{limits});
    Selecto::Error->throw(
        'write_relation_mismatch',
        'write relation must be the domain table',
        { relation => $command->relation, expected => $self->{domain}->table },
    ) unless $command->relation eq $self->{domain}->table;
    Selecto::Write::PortableCommand->_require_protected_upsert_host($command, $self);
    $command = $self->_materialize_write_context($command);
    $command = $self->_normalize_write_command($command);
    my $required = $self->required_write_guard($command->operation, %details);
    my $trusted;
    ($command, $trusted) = $self->_apply_write_tenant($command, $required, %details);
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
    $command = Selecto::Write::Policy->apply($command, $self->{domain}->writes, $self->{domain}->fields,
        trusted_field => $trusted);
    $self->_validate_write_command($command, trusted_field => $trusted);
    $self->_check_required_tenant_assignment($command, $required, %details);
    # Adapter bounded-write preflight must use the governing domain identity,
    # never a key supplied by the caller's command metadata.
    $command = $command->with_metadata({%{$command->metadata},
        __selecto_primary_key => $self->{domain}->primary_key,
        __selecto_insert_types => $self->{domain}->fields,
        __selecto_limits => $self->{limits},
        __selecto_write_limit => $self->{limits}->get('max_action_targets')});
    # Set on every governed command, replacing any a caller supplied.
    $command = $command->with_foreign_key_guards(_foreign_key_guards(
        _domain_references($self->{domain}), $command, $self->_trusted_tenant_sets($required), %details,
    ));
    return $self->_retain_command_work($command, $accepted_work);
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
    my $required = $self->_host_required_predicate;
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

# The host-authored write boundary: the domain's required predicate ANDed
# with the trusted write context's required filters.
sub _host_required_predicate {
    my ($self) = @_;
    my $contract=$self->{domain}->_contract_view // {};
    my $source=$contract->{source} // {fields=>[sort keys %{$self->{domain}->fields}]};
    return Selecto::QueryEnforcement::combine($self->{domain}->required_predicate,
        Selecto::Write::Context->required_predicate({source=>$source},$self->{write_context}));
}

# Lesson 47/47a: how a trusted engine tenant governs writes of this engine's
# domain. bind is the column it binds: source.tenant_field, else the
# writes.scope.tenant field (legacy when writes.scope.tenant names it, and
# Selecto::Write::Scope applies it). On a two-column domain (writes.scope.tenant
# on another column than tenant_field) the engine value means tenant_field on
# writes as on reads (41c), and the scope column is pinned: never bound to
# the engine value. A graph child (an engine made by _graph_engine) never
# binds a column the root pins, and binds its own tenant_field only when it
# pairs by name with the root's bound column or the root has none; a
# child's own writes.scope.tenant on another column keeps binding it.
sub _write_tenant_rules {
    my ($self) = @_;
    my $domain = $self->{domain};
    my $scope = $domain->write_tenant_scope;
    my $field = $domain->tenant_field;
    my (%rules, @pinned);
    my $column = $scope ? $scope->{field} : $field;
    if ($scope && defined($field) && $scope->{field} ne $field) {
        ($column, @pinned) = ($field, $scope->{field});
    } elsif ($scope) {
        $rules{legacy} = 1;
    }
    if ((my $root = $self->{_graph_root}) && defined $column) {
        if (exists $root->{pinned}{$column}) {
            unshift @pinned, $column;
            ($column, $rules{legacy}) = (undef, 0);
        } elsif (!$rules{legacy} && defined($root->{bind}) && $column ne $root->{bind}) {
            $column = undef;
        }
    }
    return {%rules, bind => $column, pinned => \@pinned};
}
sub _write_tenant_column { return $_[0]->_write_tenant_rules->{bind}; }

# The tenant conditions a stored row of this engine's domain must meet to be
# one this engine's writes may reach: the bound column equal to the engine
# tenant, and each pinned column inside its pin. Empty without an engine
# tenant.
sub _write_tenant_conditions {
    my ($self) = @_;
    my $tenant = $self->{scope}{tenant};
    return () unless defined $tenant;
    my $rules = $self->_write_tenant_rules;
    my @conditions = defined($rules->{bind}) ? (Selecto::Expression->eq($rules->{bind}, $tenant)) : ();
    for my $column (@{$rules->{pinned}}) {
        my $pins = $self->_tenant_pins($column) or next;
        push @conditions, @$pins == 1 ? Selecto::Expression->eq($column, $pins->[0])
            : Selecto::Expression->in($column, [@$pins]);
    }
    return @conditions;
}

# Lesson 47: a trusted engine tenant limits every write of a domain with a
# tenant column, with or without writes.scope.tenant. Any top-level eq/in
# conjunct on that column, in the host's required predicate or trusted
# context filters, the caller's predicate or scope, or query evidence, must
# admit the tenant (an IN list is intersected with it) or the write is
# refused with tenant_mismatch before any DML. A writes.scope.tenant on that
# column is applied by Selecto::Write::Scope as before; otherwise updates and
# deletes match only rows of the tenant, inserts and upserts carry it
# (filled when absent, tenant_mismatch when another value is given), an
# upsert must resolve conflicts on a target including the column
# (tenant_scope_conflict_target). Returns the command and the fields the
# engine assigns from trusted scope.
sub _apply_write_tenant {
    my ($self, $command, $required, %details) = @_;
    my $tenant = $self->{scope}{tenant};
    my $scope = $self->{domain}->write_tenant_scope;
    my $rules = $self->_write_tenant_rules;
    my $column = $rules->{bind};
    my @trusted;
    if ($rules->{legacy}) {
        $command = Selecto::Write::Scope->apply(
            $command, $scope, $tenant, label => $command->relation, details => \%details,
        );
        push @trusted, $scope->{field};
    } elsif ($scope) {
        # A two-column (or root-pinned) writes.scope.tenant still requires a
        # trusted tenant, but the engine value never binds its column.
        Selecto::Write::Scope->require_trusted($scope, $tenant, label => $command->relation, details => \%details);
    }
    return ($command, \@trusted) unless defined $tenant;
    if (defined $column) {
        my %where = (relation => $command->relation, field => "$column", %details);
        for my $expression (grep { defined } $required, $command->predicate, $command->scope_predicate,
            defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef) {
            Selecto::Error->throw('tenant_mismatch', 'tenant value must match the trusted tenant scope', \%where)
                if _excludes_tenant($expression, $column, $tenant);
        }
        unless ($rules->{legacy}) {
            push @trusted, $column;
            $command = _bind_write_tenant($command, $column, $tenant, %where);
        }
    }
    for my $pinned (@{$rules->{pinned}}) {
        my $set;
        ($command, $set) = $self->_pin_write_tenant($command, $pinned, %details);
        push @trusted, $pinned if $set;
    }
    return ($command, \@trusted);
}

# Lesson 47b: under an engine tenant, a write that sets a pinned column
# (the site_id of a two-column domain, or a graph child column the root
# pins) is refused with missing_tenant_scope unless a host trusted-scope or
# required predicate pins the allowed values (a positive top-level eq/IN
# conjunct; host and required pins, and a child's and its root's, are
# intersected). The value must be a literal inside the pin
# (tenant_mismatch). An insert or upsert omitting the column is assigned
# the pin when exactly one value is pinned and refused otherwise. Without
# this, once writes bind tenant_id only (47a), tenant 7 could relabel its
# own row to tenant 8's site and then read tenant 8's site rows through
# by-name site pairing (41c). Updates and deletes keep matching only rows
# inside a pin; a write that does not set the column is otherwise
# unaffected. Returns the command and whether the column was set.
sub _pin_write_tenant {
    my ($self, $command, $column, %details) = @_;
    my $operation = $command->operation;
    my %where = (relation => $command->relation, field => "$column", %details);
    my $assignments = $command->assignments;
    my $sets = $operation ne 'delete' && exists $assignments->{$column};
    my $inserts = $operation eq 'insert' || $operation eq 'upsert';
    my $pins = $self->_tenant_pins($column);
    Selecto::Error->throw('tenant_mismatch', 'host and required pins admit no value', \%where)
        if $pins && !@$pins;
    if ($sets || $inserts) {
        Selecto::Error->throw('missing_tenant_scope',
            'a write setting a pinned tenant column requires a host or required pin', \%where) unless $pins;
        if ($sets) {
            my $value = _literal_value($assignments->{$column});
            Selecto::Error->throw('tenant_mismatch', 'tenant value must match the trusted tenant scope', \%where)
                unless defined($value) && !ref($value) && grep { "$_" eq "$value" } @$pins;
        } else {
            Selecto::Error->throw('missing_tenant_scope',
                'an insert omitting a pinned tenant column requires exactly one pinned value', \%where)
                unless @$pins == 1;
            $command = $command->with_assignments({%$assignments, $column => $pins->[0]});
        }
    }
    if ($pins && ($operation eq 'update' || $operation eq 'delete')) {
        my $guard = @$pins == 1 ? Selecto::Expression->eq($column, $pins->[0]) : Selecto::Expression->in($column, [@$pins]);
        $command = $command->with_scope_predicate(Selecto::QueryEnforcement::combine($command->scope_predicate, $guard))
            unless grep { $_->kind eq $guard->kind && _is_tenant_comparison($_, $column)
                && JSON::PP->new->canonical->encode([_comparison_values($_)])
                    eq JSON::PP->new->canonical->encode([_comparison_values($guard)]) } _conjuncts($command->scope_predicate);
    }
    return ($command, $sets || $inserts);
}

sub _comparison_values {
    my ($expression) = @_;
    my $argument = $expression->arguments->[1];
    return map { "$_" } $expression->kind eq 'eq' ? ($argument->arguments->[0]) : @$argument;
}

sub _bind_write_tenant {
    my ($command, $column, $tenant, %where) = @_;
    my $operation = $command->operation;
    return _scope_tenant($command, $column, $tenant) if $operation eq 'delete';
    my $assignments = $command->assignments;
    if (exists $assignments->{$column}) {
        my $value = _literal_value($assignments->{$column});
        Selecto::Error->throw('tenant_mismatch', 'tenant value must match the trusted tenant scope', \%where)
            unless defined($value) && !ref($value) && "$value" eq "$tenant";
    } elsif ($operation eq 'insert' || $operation eq 'upsert') {
        $assignments->{$column} = $tenant;
    }
    if ($operation eq 'upsert') {
        my $target = $command->metadata->{conflict_target};
        Selecto::Error->throw(
            'tenant_scope_conflict_target',
            'tenant-scoped upsert must resolve conflicts on a target that includes the tenant field',
            \%where,
        ) unless ref($target) eq 'ARRAY' && grep { defined($_) && !ref($_) && "$_" eq $column } @$target;
    }
    return _scope_tenant($command->with_assignments($assignments), $column, $tenant);
}

# ANDs column = tenant into the command's scope once.
sub _scope_tenant {
    my ($command, $column, $tenant) = @_;
    my $existing = $command->scope_predicate;
    return $command if grep {
        $_->kind eq 'eq' && _is_tenant_comparison($_, $column) && "${\$_->arguments->[1]->arguments->[0]}" eq "$tenant"
    } _conjuncts($existing);
    my $guard = Selecto::Expression->eq($column, $tenant);
    return $command->with_scope_predicate(defined($existing) ? Selecto::Expression->all($existing, $guard) : $guard);
}

# The top-level conjuncts of an expression, through nested ANDs.
sub _conjuncts {
    my ($expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    return ($expression) unless $expression->kind eq 'and';
    return map { _conjuncts($_) } @{$expression->arguments->[0] // []};
}

sub _literal_value {
    my ($value) = @_;
    return $value unless blessed($value) && $value->isa('Selecto::Write::Expression');
    return $value->kind eq 'literal' ? $value->arguments->[0] : undef;
}

# An engine for a graph child or owned-sync relation of this engine's graph,
# carrying the root's tenant columns so the child binds only the columns
# that pair with them.
sub _graph_engine {
    my ($self, $domain) = @_;
    my $engine = ref($self)->new(domain => $domain, adapter => $self->{adapter},
        scope => $self->{scope}, write_context => $self->{write_context}, limits => $self->{limits});
    $engine->{_graph_root} = $self->{_graph_root} // do {
        my $rules = $self->_write_tenant_rules;
        my $required = @{$rules->{pinned}} ? $self->_host_required_predicate : undef;
        {bind => $rules->{bind}, pinned => {map { ($_ => _pin_set($required, $_)) } @{$rules->{pinned}}}};
    };
    return $engine;
}

# The values a predicate's top-level eq/in conjuncts on $column admit,
# intersected (possibly none); undef when no conjunct names the column.
sub _pin_set {
    my ($predicate, $column) = @_;
    my $values;
    for my $conjunct (_conjuncts($predicate)) {
        next unless ($conjunct->kind eq 'eq' || $conjunct->kind eq 'in') && _is_tenant_comparison($conjunct, $column);
        my $argument = $conjunct->arguments->[1];
        my @allowed = $conjunct->kind eq 'eq' ? ($argument->arguments->[0]) : @$argument;
        my %allowed = map { ("$_" => 1) } @allowed;
        $values = $values ? [grep { $allowed{"$_"} } @$values] : [@allowed];
    }
    return $values;
}

# The site values a write of this engine's domain may store in a pinned
# column: the host's required and trusted-context conjuncts on it,
# intersected with the root's pin when this is a graph child. Undef when
# nothing pins it.
sub _tenant_pins {
    my ($self, $column) = @_;
    my $own = _pin_set($self->_host_required_predicate, $column);
    my $root = $self->{_graph_root};
    my $inherited = $root && exists($root->{pinned}{$column}) ? $root->{pinned}{$column} : undef;
    return $own unless $inherited;
    return $inherited unless $own;
    my %own = map { ("$_" => 1) } @$own;
    return [grep { $own{"$_"} } @$inherited];
}

# Context-owned fields are checked as authored literal values before native
# type normalization. Other native mutation expressions keep their ordinary
# meaning; none can supply a context-owned identity.
sub _materialize_write_context {
    my ($self,$command)=@_;
    my $keys=_declared_foreign_keys($self->{domain}->writes);
    return $command unless keys %$keys;
    my $assignments=$command->assignments;my (%context_keys,%plain);
    for my $field (sort keys %$keys) {
        my $spec=$keys->{$field};
        Selecto::Error->throw('invalid_domain','foreign key must have a declaration') unless ref($spec) eq 'HASH';
        my $source=$spec->{source};
        my $context=ref($source) eq 'ARRAY' || ref($source) eq 'HASH';
        if (!$context) {
            Selecto::Error->throw('missing_foreign_key','required foreign-key value is missing',{field=>$field})
                if $command->operation =~ /\A(?:insert|upsert)\z/ && $spec->{required} && !exists($assignments->{$field});
            next;
        }
        $context_keys{$field}=$spec;
        next unless exists $assignments->{$field};
        my $value=$assignments->{$field};
        if (blessed($value) && ref($value) eq 'Selecto::Write::Expression' && $value->kind eq 'literal') {
            $value=$value->arguments->[0];
        }
        Selecto::Error->throw('foreign_key_source_mismatch','context-owned foreign key must be a literal',{field=>$field})
            if ref($value) && !JSON::PP::is_bool($value);
        $plain{$field}=$value;
    }
    my $values=Selecto::Write::Context->materialize({constraints=>{foreign_keys=>\%context_keys}},\%plain,
        $command->operation,$self->{write_context});
    return $command->with_assignments({%$assignments,%$values});
}

# The required predicate limits the rows an update matches, not the values it
# writes. When it carries the tenant boundary, an update may set the tenant
# field only to a literal tenant the boundary admits, so it cannot move a row
# to another tenant. Inserts are checked as candidates against the predicate.
sub _check_required_tenant_assignment {
    my ($self, $command, $required, %details) = @_;
    return unless defined($required) && $command->operation eq 'update';
    my $domain = $self->{domain};
    # Every root tenant column, the writes.scope.tenant column included.
    for my $field (@{_root_tenant_fields($domain->tenant_field, $domain->write_tenant_scope)}) {
        next unless exists($command->assignments->{$field}) && _has_tenant_conjunct($required, $field);
        my $value = _literal_value($command->assignments->{$field});
        Selecto::Error->throw(
            'tenant_mismatch', 'tenant value must match the trusted tenant scope',
            {relation => $command->relation, field => "$field", %details},
        ) if !defined($value) || ref($value) || _excludes_tenant($required, $field, $value);
    }
}

# TW-05: the trusted tenants a write is confined to: the engine tenant, or
# the tenant values of the domain's required tenant predicate. Undef when the
# write has no tenant boundary.
sub _trusted_write_tenants {
    my ($self, $required) = @_;
    return [$self->{scope}{tenant}] if defined $self->{scope}{tenant};
    return _required_tenants($required, $self->{domain}->tenant_field);
}

# The tenants a required predicate's top-level eq/in conjuncts on $field
# admit, intersected; undef when none bounds the field.
sub _required_tenants {
    my ($required, $field) = @_;
    return undef unless defined($field) && defined($required);
    my $values;
    for my $conjunct (_conjuncts($required)) {
        next unless ($conjunct->kind eq 'eq' || $conjunct->kind eq 'in') && _is_tenant_comparison($conjunct, $field);
        my $argument = $conjunct->arguments->[1];
        my @allowed = $conjunct->kind eq 'eq' ? ($argument->arguments->[0]) : @$argument;
        my %allowed = map { ("$_" => 1) } @allowed;
        $values = $values ? [grep { $allowed{"$_"} } @$values] : [@allowed];
    }
    return $values && @$values ? $values : undef;
}

# Lesson 33: a graph child or owned-sync row that stores a root tenant column
# is confined to that column's admitted set exactly as the root is, whether
# the set comes from the engine tenant or only from the root's required
# predicate: an update or delete matches only rows inside the set, an insert
# must land inside it (the adapter admits insert candidates against the
# scope), an assignment to the column must be one of the set's literal
# values (tenant_mismatch), and an upsert is refused, as on a root with a
# required predicate. $sets is _trusted_tenant_sets' answer for the root. A
# child that declares its own writes.scope.tenant is governed by that scope
# instead, and is not passed here.
sub _confine_child_tenants {
    my ($self, $command, $sets, $fields, %details) = @_;
    return ($command, []) unless $sets && ref($fields) eq 'HASH';
    my %columns = ref($sets) eq 'HASH' ? %{$sets->{columns}}
        : map { ($_ => $sets) } @{_root_tenant_fields($self->{domain}->tenant_field, $self->{domain}->write_tenant_scope)};
    # Lesson 47: a child insert omitting the column the engine tenant binds
    # on the root carries the tenant, as a root insert does.
    my $tenant = $self->{scope}{tenant};
    my $bound = defined($tenant) ? $self->_write_tenant_column : undef;
    my (@scopes, @filled);
    for my $column (sort keys %columns) {
        my $set = $columns{$column};
        next unless $set && exists $fields->{$column};
        my %where = (relation => $command->relation, field => $column, %details);
        Selecto::Error->throw('query_enforcement_unsupported_operation',
            'upsert is not supported on a graph child confined to a tenant set', \%where)
            if $command->operation eq 'upsert';
        if ($command->operation ne 'delete' && exists $command->assignments->{$column}) {
            my $value = _literal_value($command->assignments->{$column});
            Selecto::Error->throw('tenant_mismatch', 'tenant value must match the trusted tenant scope', \%where)
                if !defined($value) || ref($value) || !grep { "$_" eq "$value" } @$set;
        } elsif ($command->operation eq 'insert' && defined($bound) && $column eq $bound) {
            $command = $command->with_assignments({%{$command->assignments}, $column => $tenant});
            push @filled, $column;
        }
        push @scopes, @$set == 1 ? Selecto::Expression->eq($column, $set->[0]) : Selecto::Expression->in($column, [@$set]);
    }
    return ($command, \@filled) unless @scopes;
    return ($command->with_scope_predicate(Selecto::QueryEnforcement::combine($command->scope_predicate, @scopes)), \@filled);
}

# Lesson 29e: the admitted tenants of each root tenant column, for reference
# guards. On a root with at most one tenant column every guard keeps the one
# trusted set (_trusted_write_tenants). On a two-column root
# (writes.scope.tenant on one column, source.tenant_field on another) each
# column has its own set: the engine tenant bounds only the tenant_field
# column (lesson 47a, as on reads), and the write-scope column is bounded
# only by the required predicate's conjuncts on it (host trusted-context
# filters included), never by the engine value. A guard then takes the set
# of the root column it pairs with (see _tenant_pairs).
sub _trusted_tenant_sets {
    my ($self, $required) = @_;
    my $tenants = $self->_trusted_write_tenants($required);
    my $scope = $self->{domain}->write_tenant_scope;
    my $field = $self->{domain}->tenant_field;
    return $tenants unless $scope && defined($field) && $scope->{field} ne $field;
    return {
        any => $tenants,
        columns => {
            $scope->{field} => _required_tenants($required, $scope->{field}),
            $field => defined($self->{scope}{tenant}) ? [$self->{scope}{tenant}]
                : _required_tenants($required, $field),
        },
    };
}

# The references a relation declares, for the foreign-key tenant guard:
# writes.constraints.foreign_keys and its direct to-one associations, with
# what the domain records about each referenced relation's tenancy.
sub _domain_references {
    my ($domain) = @_;
    # Read-only: the description below copies what it keeps, and its
    # foreign_keys entry is only read by _foreign_key_guards.
    my $contract = $domain->_contract_view // {};
    my $schemas = ref($contract->{schemas}) eq 'HASH' ? $contract->{schemas} : {};
    my $associations = $domain->associations;
    my $scope = $domain->write_tenant_scope;
    return {
        table => $domain->table,
        primary_key => $domain->primary_key,
        tenant_field => $scope ? $scope->{field} : $domain->tenant_field,
        tenant_data => $scope || defined($domain->tenant_field) ? 1 : 0,
        root_tenant_fields => _root_tenant_fields($domain->tenant_field, $scope),
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
                source_scope_key => $association->source_scope_key,
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
        root_tenant_fields => _root_tenant_fields($source->{tenant_field}, $scope),
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
                source_scope_key => $spec->{source_scope_key},
                target_scope_key => $spec->{target_scope_key},
                target_tenant_field => ref($target) eq 'HASH' ? $target->{tenant_field} : undef,
            } : ()
        } sort keys %$associations],
    };
}

# The root's tenant columns: source.tenant_field and writes.scope.tenant.field.
# Two distinct columns make a two-column root.
sub _root_tenant_fields {
    my ($tenant_field, $scope) = @_;
    my %fields = map { (defined($_) && !ref($_) ? ("$_" => 1) : ()) } $tenant_field, $scope ? $scope->{field} : undef;
    return [sort keys %fields];
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
            stores => {map { (defined($_) && !ref($_) ? ("$_" => 1) : ()) }
                (ref($schema->{fields}) eq 'ARRAY' ? @{$schema->{fields}} : ()),
                (ref($schema->{columns}) eq 'HASH' ? keys %{$schema->{columns}} : ())},
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
    my ($references, $command, $sets, %details) = @_;
    _assert_reference_agreement($references, %details);
    return [] if $command->operation eq 'delete';
    # One trusted set, or (on a two-column root) a set per root tenant column.
    my $columns = ref($sets) eq 'HASH' ? $sets->{columns} : undef;
    my $tenants = ref($sets) eq 'HASH' ? $sets->{any} : $sets;
    my $assignments = $command->assignments;
    my $tenant_scoped = $tenants && $references->{tenant_data};
    my $relation = $command->relation;
    my (@candidates, %declared);
    my $work=Selecto::OperationBudget->new(code=>'invalid_domain');
    my $output=Selecto::OperationBudget->new(code=>'invalid_write');
    my $foreign_keys = $references->{foreign_keys};
    for my $field (sort keys %$foreign_keys) {
        $work->consume_count('max_expression_nodes',1,label=>'foreign-key work');
        $declared{$field} = 1;
        next unless exists $assignments->{$field};
        $work->consume_count('max_expression_nodes',scalar(@{$references->{schemas}}),label=>'foreign-key work');
        my $spec = $foreign_keys->{$field};
        my $target = ref($spec) eq 'HASH' ? $spec->{references} : undef;
        Selecto::Error->throw('invalid_domain', 'foreign key references must name a relation and field',
            {code => 'invalid_foreign_key', field => $field, relation => $relation, %details},
        ) unless ref($target) eq 'HASH'
            && grep({ defined($target->{$_}) && !ref($target->{$_}) && "$target->{$_}" =~ /\A[A-Za-z_][A-Za-z0-9_.]*\z/ }
                qw(relation field)) == 2;
        my $candidate = {
            field => $field, relation => "$target->{relation}", target_field => "$target->{field}", declared => 1,
            tenancy => _declared_tenancy($references, $target),
            context_owned => ref($spec->{source}) ? 1 : 0,
        };
        # A foreign key that records no tenancy of its own does not drop the
        # tenancy an association on the same owner key records (item 34):
        # its context-owned existence-only exemption applies only when
        # nothing declares the target's tenancy.
        if ($candidate->{tenancy}[0] eq 'undeclared') {
            my ($association) = grep { $_->{owner_key} eq $field && $_->{table} eq $candidate->{relation} }
                _guarded_associations($references);
            my $tenancy = $association ? _association_tenancy($references, $association) : undef;
            @{$candidate}{qw(tenancy association)} = ($tenancy, $association) if $tenancy && $tenancy->[0] eq 'tenant';
        }
        push @candidates, $candidate;
    }
    for my $association (_guarded_associations($references)) {
        $work->consume_count('max_expression_nodes',1,label=>'foreign-key work');
        my $field = $association->{owner_key};
        next if $declared{$field} || !exists($assignments->{$field});
        push @candidates, {
            field => $field, relation => $association->{table}, target_field => $association->{related_key},
            tenancy => _association_tenancy($references, $association), association => $association,
        };
    }
    my (%seen, @guards);
    for my $candidate (@candidates) {
        $work->consume_count('max_expression_nodes',1,label=>'foreign-key work');
        my ($kind, $tenant_field) = @{$candidate->{tenancy}};
        my $value = $assignments->{$candidate->{field}};
        $value = $value->kind eq 'literal' ? $value->arguments->[0] : $value
            if blessed($value) && $value->isa('Selecto::Write::Expression');
        next unless defined $value;    # a null reference names no parent
        my %where = (field => $candidate->{field}, relation => $relation, %details);
        Selecto::Error->throw('invalid_domain', 'foreign-key tenant scope is invalid',
            {%where, code => $tenant_field, referenced => $candidate->{relation}},
        ) if $kind eq 'error';
        my $existence=$candidate->{context_owned} || $command->{metadata}{portable_foreign_key_guards};
        next if $kind eq 'shared' && !$existence;
        if ($kind eq 'undeclared') {
            Selecto::Error->throw('invalid_domain',
                'a reference on a tenant-scoped write must declare the referenced relation\'s tenant field',
                {%where, code => 'foreign_key_tenant_scope_undeclared', referenced => $candidate->{relation},
                    required => ['references', 'tenant_field']},
            ) if $tenant_scoped && !$candidate->{context_owned};
            next unless $existence;
        }
        if ($kind eq 'tenant' && !$tenants) {
            Selecto::Error->throw('missing_tenant_scope',
                'a foreign key to a tenant-scoped relation requires a trusted tenant',
                {%where, referenced => $candidate->{relation}, tenant_field => $tenant_field},
            ) if $candidate->{declared};
            next;
        }
        Selecto::Error->throw('invalid_write', 'a reference on a tenant-scoped write must be a literal value',
            \%where,
        ) if ref($value);
        # Each guarded column of the referenced row and the set it must lie
        # in: the one trusted set, or on a two-column root the set of the root
        # column it pairs with (lesson 29e). A column whose root column no
        # set bounds is left unguarded; a reference none can confine fails.
        my @conditions = $kind ne 'tenant' ? ()
            : !$columns ? ([$tenant_field, $tenants])
            : map { my $set = $columns->{$_->[1]}; $set ? ([$_->[0], $set]) : () }
                _tenant_pairs($references, $candidate, [sort keys %$columns], %where);
        Selecto::Error->throw('missing_tenant_scope',
            'no trusted tenant set bounds the root tenant column this reference pairs with',
            {%where, referenced => $candidate->{relation}, tenant_field => $tenant_field},
        ) if $kind eq 'tenant' && !@conditions;
        my $key = join "\0", @{$candidate}{qw(field relation target_field)}, map { $_->[0] } @conditions;
        next if $seen{$key}++;
        my ($first, @more) = @conditions;
        my $guard={
            field => $candidate->{field}, relation => $candidate->{relation},
            target_field => $candidate->{target_field}, value => $value,
            ($first ? (tenant_field => $first->[0], tenants => [@{$first->[1]}]) : ()),
            (@more ? (more_tenant_fields => [map { {tenant_field => $_->[0], tenants => [@{$_->[1]}]} } @more]) : ()),
        };
        $output->check_tree($guard,label=>'foreign-key guards');push @guards,$guard;
    }
    return \@guards;
}

# Direct to-one associations whose owner key references another row: not the
# row's own key, a to-many or bridged association, or a static value list.
sub _guarded_associations {
    my ($references) = @_;
    return grep {
        my $field = $_->{owner_key};
        defined($field) && $field ne ($references->{primary_key} // '') && $_->{cardinality} eq 'one'
            && !$_->{through} && !$_->{static} && defined($_->{table})
    } @{$references->{associations}};
}

# The tenant column an association guards on its target, and the root tenant
# column it pairs that column with. A source_scope_key that is not a root
# tenant column (such as region_id) relates rows within a tenant; it never
# makes its target_scope_key a guard column for the tenant set. On a
# single-column root such an association is guarded by the target's declared
# tenancy, and refused when the target declares none; on a two-column root
# it is refused outright ('refuse' tenancies fail domain admission).
sub _association_tenancy {
    my ($references, $association) = @_;
    my @roots = @{$references->{root_tenant_fields} // []};
    my $source = $association->{source_scope_key};
    my $self = $association->{table} eq $references->{table} && defined($references->{tenant_field});
    if (defined($source) && !grep { $_ eq $source } @roots) {
        return ['refuse', 'non_tenant_scope_key_on_two_column_root'] if @roots > 1;
        my $declared = $association->{target_tenant_field};
        return ['tenant', "$declared", $references->{tenant_field}]
            if defined($declared) && !ref($declared) && "$declared" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        return ['tenant', $references->{tenant_field}, $references->{tenant_field}] if $self;
        return @roots ? ['refuse', 'non_tenant_scope_key_target_undeclared'] : ['undeclared'];
    }
    my $root = defined($source) ? $source : $references->{tenant_field};
    return defined($association->{target_scope_key}) ? ['tenant', $association->{target_scope_key}, $root]
        : defined($association->{target_tenant_field}) ? ['tenant', $association->{target_tenant_field}, $root]
        : $self ? ['tenant', $references->{tenant_field}, $root]
        : ['undeclared'];
}

# Lesson 29e: on a two-column root, the root tenant column each guarded
# column of a referenced row pairs with, as [guard column, root column].
#  - A target that is the root's own table or stores both root columns is
#    guarded on each root column by name, each with its own set.
#  - An association whose source_scope_key is a root tenant column pairs its
#    target_scope_key with that column, whatever the target column is named
#    (tenant_id -> warehouse.site_id guards site_id with the tenant_id set).
#  - Any other tenant column (a declared tenant_field, references.tenant_field)
#    pairs with the root column of its own name.
# Anything else is refused with invalid_domain rather than guessed: scope
# keys that disagree with the target's declared tenant_field, an authored
# pair crossing names on a target storing both root columns, a column two
# pairings would give different sets, and a column pairing with no root
# column.
sub _tenant_pairs {
    my ($references, $candidate, $roots, %where) = @_;
    my $refuse = sub {
        Selecto::Error->throw('invalid_domain', $_[0], {%where, code => 'foreign_key_tenant_scope_undeclared',
            reason => $_[1], referenced => $candidate->{relation}});
    };
    my %root = map { ($_ => 1) } @$roots;
    my $guard = $candidate->{tenancy}[1];
    my $both = $candidate->{relation} eq $references->{table}
        || grep { $_->{table} eq $candidate->{relation} && !grep { !$_ } @{$_->{stores}}{@$roots} }
            @{$references->{schemas}};
    my (%pairs, @pairs);
    my $add = sub {
        my ($column, $root) = @_;
        $refuse->('a referenced tenant column pairs with two root tenant columns', 'conflicting_tenant_pairings')
            if exists($pairs{$column}) && $pairs{$column} ne $root;
        push @pairs, [$column, $root] unless exists $pairs{$column};
        $pairs{$column} = $root;
    };
    if ($both) { $add->($_, $_) for @$roots; }
    my $association = $candidate->{association} // {};
    my ($source, $target) = @{$association}{qw(source_scope_key target_scope_key)};
    if (defined($source) && $root{$source}) {
        my $declared = $association->{target_tenant_field};
        if ($both) {
            $refuse->('an authored scope pair crosses root tenant column names on a target storing both',
                'crossed_scope_pair') if $root{$target} && $target ne $source;
        } else {
            $refuse->('a reference\'s scope keys disagree with the referenced tenant field', 'scope_keys_disagree')
                if defined($declared) && $declared ne $target;
            $refuse->('a referenced tenant column pairs with two root tenant columns', 'conflicting_tenant_pairings')
                if defined($declared) && $root{$target} && $target ne $source;
        }
        $add->($target, $source);
        return @pairs;
    }
    return @pairs if $both && $root{$guard};
    $refuse->('a referenced tenant column pairs with no root tenant column', 'unpaired_tenant_column')
        unless $root{$guard};
    $add->($guard, $guard);
    return @pairs;
}

# Lesson 37: a choice source or co-domain lookup hands back the value, label
# and description fields its declaration names. A declaration that would
# expose a redacted (or internal or hidden) field is refused when the engine
# is built, with invalid_domain: details code choice_source_redacted_field
# or co_domain_redacted_field. Fields of another domain are checked where
# this contract describes it (a schema backed by that relation, or this
# domain itself); a co-domain lookup also refuses non-public fields of its
# target engine's domain at lookup time.
sub _assert_lookups_public {
    my ($domain) = @_;
    my $contract = $domain->_contract_view;
    return unless ref($contract) eq 'HASH';
    my $schemas = ref($contract->{schemas}) eq 'HASH' ? $contract->{schemas} : {};
    my $work = Selecto::OperationBudget->new(code => 'invalid_domain');
    # True when $path names a field this contract withholds.
    my $withheld = sub {
        my ($path) = @_;
        return 0 unless defined($path) && !ref($path) && length("$path");
        return 1 unless $domain->field_is_public("$path");
        my ($schema, $field) = "$path" =~ /\A([^.]+)\.([^.]+)\z/ or return 0;
        my $spec = $schemas->{$schema};
        return 0 unless ref($spec) eq 'HASH';
        return 1 if Selecto::Domain::_redacted($spec, $field);
        my $column = ref($spec->{columns}) eq 'HASH' ? $spec->{columns}{$field} : undef;
        return ref($column) eq 'HASH' && ($column->{internal} || $column->{hidden}) ? 1 : 0;
    };
    # The relations this contract describes as another domain: this domain
    # itself, or schemas keyed or backed by that name.
    my $targets = sub {
        my ($name) = @_;
        return () unless defined($name) && !ref($name);
        return ('') if defined($contract->{name}) && "$name" eq "$contract->{name}";
        return map { "$_." } grep { ref($schemas->{$_}) eq 'HASH'
            && ($_ eq "$name" || ($schemas->{$_}{source_table} // '') eq "$name") } sort keys %$schemas;
    };
    my $refuse = sub {
        my ($code, %details) = @_;
        Selecto::Error->throw('invalid_domain', 'a lookup declaration exposes a redacted field',
            {code => $code, %details});
    };
    my $sources = ref($contract->{choice_sources}) eq 'HASH' ? $contract->{choice_sources} : {};
    for my $id (sort keys %$sources) {
        my $spec = $sources->{$id};
        next unless ref($spec) eq 'HASH';
        for my $key (qw(value_source caption_source description_source)) {
            $work->consume_count('max_expression_nodes', 1, label => 'lookup redaction work');
            $refuse->('choice_source_redacted_field', choice_source => $id, key => $key, field => "$spec->{$key}")
                if $withheld->($spec->{$key});
        }
        for my $prefix ($targets->($spec->{domain})) {
            for my $key (qw(value_field label_field description_field)) {
                $work->consume_count('max_expression_nodes', 1, label => 'lookup redaction work');
                my $field = $spec->{$key};
                next unless defined($field) && !ref($field);
                $refuse->('choice_source_redacted_field', choice_source => $id, key => $key, field => "$field")
                    if $withheld->($prefix . $field);
            }
        }
    }
    my @columns = ([ref($contract->{source}) eq 'HASH' ? $contract->{source}{columns} : undef, '']);
    push @columns, map { [$schemas->{$_}{columns}, "$_."] } grep { ref($schemas->{$_}) eq 'HASH' } sort keys %$schemas;
    for my $group (@columns) {
        my ($columns, $prefix) = @$group;
        next unless ref($columns) eq 'HASH';
        for my $name (sort keys %$columns) {
            my $reference = ref($columns->{$name}) eq 'HASH' ? $columns->{$name}{reference} : undef;
            next unless ref($reference) eq 'HASH';
            for my $key (qw(value_source caption_source caption_field)) {
                $work->consume_count('max_expression_nodes', 1, label => 'lookup redaction work');
                $refuse->('choice_source_redacted_field', field => "$prefix$name", key => "reference.$key",
                    source => "$reference->{$key}") if $withheld->($reference->{$key});
            }
        }
    }
    my $co_domains = $domain->co_domains;
    for my $id (sort keys %$co_domains) {
        my $definition = $co_domains->{$id};
        next unless ref($definition) eq 'HASH';
        my $result = ref($definition->{result}) eq 'HASH' ? $definition->{result} : {};
        my $search = ref($definition->{search}) eq 'HASH' ? $definition->{search} : {};
        for my $prefix ($targets->($definition->{domain})) {
            for my $field ($result->{value_field}, $result->{label_field}, @{$result->{description_fields} // []},
                @{$search->{fields} // []}) {
                $work->consume_count('max_expression_nodes', 1, label => 'lookup redaction work');
                $refuse->('co_domain_redacted_field', co_domain => $id, field => "$field")
                    if defined($field) && !ref($field) && $withheld->($prefix . $field);
            }
        }
    }
    return;
}

# Lesson 36: under a tenant-bounded root, a graph or sync relationship's
# parent_key must identify one parent row: the parent's primary key, or
# exactly a single-column upsert conflict target the parent declares. A
# non-unique key (a code two tenants' items share) would bind a child, and
# its children, under every parent with that value, another tenant's
# included. A composite conflict target (tenant_id, code) or a sync identity
# (unique only per owner) does not count. Checked for every hop of nested
# relationship domains, when the engine is built.
sub _assert_unique_parent_keys {
    my ($domain, $scope) = @_;
    my $bounded = defined($scope->{tenant}) || defined($domain->tenant_field)
        || $domain->write_tenant_scope || defined($domain->required_predicate);
    return unless $bounded;
    my $writes = $domain->writes;
    return unless ref($writes) eq 'HASH';
    my $work = Selecto::OperationBudget->new(code => 'invalid_domain');
    my @pending = ([$domain->table, $domain->primary_key, $writes, []]);
    while (my $entry = shift @pending) {
        my ($table, $primary_key, $parent_writes, $path) = @$entry;
        my $relationships = ref($parent_writes) eq 'HASH' ? $parent_writes->{relationships} : undef;
        next unless ref($relationships) eq 'HASH';
        my $upsert = ref($parent_writes->{operations}) eq 'HASH' ? $parent_writes->{operations}{upsert} : undef;
        my $targets = ref($upsert) eq 'HASH' ? $upsert->{conflict_targets} : undef;
        my %unique = map { ("$_->[0]" => 1) }
            grep { ref($_) eq 'ARRAY' && @$_ == 1 && defined($_->[0]) && !ref($_->[0]) }
            (ref($targets) eq 'ARRAY' ? @$targets : ());
        for my $name (sort keys %$relationships) {
            $work->consume_count('max_expression_nodes', 1, label => 'relationship work');
            my $spec = $relationships->{$name};
            next unless ref($spec) eq 'HASH';
            my $parent_key = $spec->{parent_key};
            Selecto::Error->throw('invalid_domain',
                'a relationship\'s parent_key must be its parent\'s primary key or a single-column upsert conflict target',
                {code => 'foreign_key_tenant_scope_undeclared', relationship => join('.', @$path, $name),
                    relation => $table, parent_key => "$parent_key"},
            ) if defined($parent_key) && !ref($parent_key)
                && "$parent_key" ne ($primary_key // '') && !$unique{"$parent_key"};
            my $child = $spec->{domain};
            next unless ref($child) eq 'HASH';
            my $source = ref($child->{source}) eq 'HASH' ? $child->{source} : {};
            push @pending, [$source->{source_table} // $spec->{table}, $source->{primary_key} // 'id',
                $child->{writes}, [@$path, $name]];
        }
    }
    return;
}

# A declared foreign key and the associations on the same owner key must
# describe one reference: the same relation, and the same target tenant
# column paired with the same root tenant column. Otherwise whichever
# declaration won would silently drop the other's tenant guard, so the
# contradictory domain is refused before any query or write. An explicit
# shared foreign key (references.tenant_field false) is authoritative and
# agrees with any tenancy the association records for the same relation.
sub _assert_reference_agreement {
    my ($references, %details) = @_;
    my %by_key;
    my $foreign_keys = $references->{foreign_keys} // {};
    for my $field (sort keys %$foreign_keys) {
        my $target = ref($foreign_keys->{$field}) eq 'HASH' ? $foreign_keys->{$field}{references} : undef;
        next unless ref($target) eq 'HASH' && defined($target->{relation}) && !ref($target->{relation});
        my $tenancy = _declared_tenancy($references, $target);
        push @{$by_key{$field}}, {relation => "$target->{relation}",
            tenancy => $tenancy->[0] eq 'tenant' ? [@$tenancy, $references->{tenant_field}] : $tenancy};
    }
    for my $association (_guarded_associations($references)) {
        my $tenancy = _association_tenancy($references, $association);
        Selecto::Error->throw('invalid_domain',
            'an association scope key that is not a root tenant column cannot guard its target',
            {code => 'foreign_key_tenant_scope_undeclared', field => $association->{owner_key},
                association => $association->{name}, reason => $tenancy->[1], relation => $references->{table},
                referenced => $association->{table}, required => ['schemas', 'tenant_field'], %details},
        ) if $tenancy->[0] eq 'refuse';
        push @{$by_key{$association->{owner_key}}}, {relation => $association->{table}, tenancy => $tenancy,
            association => $association};
    }
    # Lesson 29e: on a two-column root every tenant-guarded reference must
    # pair each guarded column with one root tenant column, at admission.
    my @roots = @{$references->{root_tenant_fields} // []};
    if (@roots > 1) {
        for my $field (sort keys %by_key) {
            for my $declared (@{$by_key{$field}}) {
                next unless $declared->{tenancy}[0] eq 'tenant';
                _tenant_pairs($references, {relation => $declared->{relation}, tenancy => $declared->{tenancy},
                    association => $declared->{association}}, \@roots,
                    field => $field, relation => $references->{table}, %details);
            }
        }
    }
    for my $field (sort keys %by_key) {
        my @declared = @{$by_key{$field}};
        for my $i (0 .. $#declared - 1) {
            for my $other (@declared[$i + 1 .. $#declared]) {
                my ($one, $two) = ($declared[$i]{tenancy}, $other->{tenancy});
                my $reason = $declared[$i]{relation} ne $other->{relation} ? 'different_relations'
                    : $one->[0] eq 'tenant' && $two->[0] eq 'tenant'
                        && ($one->[1] ne $two->[1] || ($one->[2] // '') ne ($two->[2] // ''))
                        ? 'different_tenant_columns' : undef;
                next unless defined $reason;
                Selecto::Error->throw('invalid_domain',
                    'declarations of one reference disagree on its relation or tenant columns',
                    {code => 'foreign_key_tenant_scope_undeclared', field => $field, reason => $reason,
                        relation => $references->{table},
                        referenced => [sort($declared[$i]{relation}, $other->{relation})], %details});
            }
        }
    }
    return;
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
    $self->assert_domain_identity;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return Selecto::Action::Planner->plan($self->{domain}, $intent, limits => $self->{limits});
    },limits=>$self->{limits});
}

my %ACTION_COMPARATOR = (eq => 'eq', neq => 'ne', gt => 'gt', gte => 'gte', lt => 'lt', lte => 'lte');

# The write command for an action plan, before tenant scope. Plan filters
# already carry the target, transition source state, and declared
# preconditions; the planned cardinality becomes the expected row count.
sub action_command {
    my ($self,$plan,%options)=@_;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return $self->_action_command_with_work($plan,%options);
    },limits=>$self->{limits});
}
sub _action_command_with_work {
    my ($self, $plan, %options) = @_;
    $self->assert_domain_identity;
    my $command = $self->_action_command($plan, %options);
    my $work = Selecto::Action::Planner->_accepted_proof_work($plan);
    if (defined($work) || $self->{domain}->rules
        && @{$self->{domain}->rules->applicable_paths('action_input', $plan->operation, $plan->action)}) {
        $self->_validate_selected_action($plan);
    }
    return $self->_retain_command_work($command, $work);
}
sub _action_command {
    my ($self, $plan, %options) = @_;
    Selecto::Action::Planner->validate_plan_limits($self->{domain}, $plan, limits => $self->{limits});
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
            assignments => _action_assignments($plan, $self->{domain}),
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
        assignments => $operation eq 'delete' ? {} : _action_assignments($plan, $self->{domain}),
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
    my $target = Selecto::Write::ConflictTarget->validate(
        $writes, $plan->conflict_target, $self->{domain}->fields);
    my %key = map { ("$_" => 1) } @$target;
    my $fields = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : {};
    my @updates = sort grep {
        !$key{$_} && ref($fields->{$_}) eq 'HASH' && $fields->{$_}{updatable}
    } keys %{$plan->changes // {}};
    Selecto::Error->throw('invalid_action_plan', 'upsert actions need at least one updatable change',
        {action => $plan->action}) unless @updates || $self->_admits_empty_upsert_mask;
    return (conflict_target => [map { "$_" } @$target], upsert_update_fields => \@updates);
}
# An empty update mask compiles to DO NOTHING only where the native branch is
# proved: a SQLite engine whose domain has stored UPSERT rules, so the command
# is governed through the protected candidate and its receipt. Every other
# adapter and unprotected path keeps requiring a non-empty mask.
sub _admits_empty_upsert_mask {
    my ($self) = @_;
    return $self->{adapter}->name eq 'sqlite' && $self->{adapter}->can('rule_upsert_candidate')
        && Selecto::WriteRules->has_stored_rules($self->{domain}, 'upsert') ? 1 : 0;
}

sub preview_action {
    my ($self,$plan,%options)=@_;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return $self->_preview_action($plan,%options);
    },limits=>$self->{limits});
}
sub _preview_action {
    my ($self, $plan, %options) = @_;
    $self->assert_domain_identity;
    $self->_validate_selected_action($plan) unless exists($options{grant});
    my $decision = $self->_authorize_action($plan, 'preview', %options);
    $self->_validate_selected_action($plan) if exists($options{grant});
    return Selecto::DataRules->_with_proof_budget(sub {
        if (ref($plan->collection_patches) eq 'HASH' && keys %{$plan->collection_patches}) {
            my ($graph) = Selecto::Action::Graph->build($self, $plan, %options);
            return {phase => 'preview', action => $plan->action, decision => $decision,
                statement => $self->_rules_transaction(sub { Selecto::Action::Graph->preview($self, $graph) })};
        }
        my $command = $self->action_command($plan, %options);
        return {
            phase => 'preview',
            action => $plan->action,
            decision => $decision,
            statement => $self->preview_write($command),
        };
    }, accepted_work => Selecto::Action::Planner->_accepted_proof_work($plan), limits => $self->{limits});
}

sub execute_action {
    my ($self,$plan,%options)=@_;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return $self->_execute_action($plan,%options);
    },limits=>$self->{limits});
}
sub _execute_action {
    my ($self, $plan, %options) = @_;
    $self->assert_domain_identity;
    $self->_validate_selected_action($plan) unless exists($options{grant});
    my $decision = $self->_authorize_action($plan, 'execute', %options);
    $self->_validate_selected_action($plan) if exists($options{grant});
    return Selecto::DataRules->_with_proof_budget(sub {
        if (ref($plan->collection_patches) eq 'HASH' && keys %{$plan->collection_patches}) {
            my ($graph, $clients) = Selecto::Action::Graph->build($self, $plan, %options);
            return {phase => 'execute', action => $plan->action, decision => $decision,
                result => $self->_rules_transaction(sub { Selecto::Action::Graph->result($self->execute_graph($graph), $clients) })};
        }
        my $command = $self->action_command($plan, %options);
        return {
            phase => 'execute',
            action => $plan->action,
            decision => $decision,
            result => $self->execute_write($command),
        };
    }, accepted_work => Selecto::Action::Planner->_accepted_proof_work($plan), limits => $self->{limits});
}

# Issues a single-use grant for one phase of $plan after the host's resolver
# enables it. The grant is bound to the phase, the plan's content, this
# engine's domain and trusted tenant, and the actor in the context.
sub _validate_selected_action {
    my ($self, $plan) = @_;
    Selecto::Error->throw('invalid_action_plan', 'action plan required')
        unless blessed($plan) && $plan->isa('Selecto::Action::Plan');
    Selecto::Action::Planner->validate_plan_limits($self->{domain}, $plan, limits => $self->{limits});
    Selecto::Write::FieldValidators->admit($self->{domain}->writes->{fields}//{},
        fields=>[sort keys %{$plan->changes // {}}],limits=>$self->{limits});
    return 1 if Selecto::Action::Planner->_accepted_plan($self->{domain}, $plan);
    Selecto::Error->throw('required_data_rule_pending', 'ACTION_INPUT requires an original accepted plan')
        if $self->{domain}->rules && @{$self->{domain}->rules->applicable_paths('action_input', $plan->operation, $plan->action)};
    my $inputs = Selecto::Action::Planner->_copy_values($plan->inputs // {},
        limits => $self->limits, code => 'invalid_action_plan');
    my $action = $self->domain->actions->{$plan->action};
    for my $declared ($action->{inputs} // {},
        Selecto::Action::Planner->input_form($action, $inputs)->{inputs}) {
        for my $name (keys %$inputs) {
            my $value = $inputs->{$name};
            my $default = ref($declared->{$name}) eq 'HASH' ? $declared->{$name}{default} : undef;
            delete $inputs->{$name} if ref($value) eq 'ARRAY' && @$value == 2
                && ($value->[0] // '') eq 'system' && ($value->[1] // '') eq 'now'
                && ref($default) eq 'ARRAY' && @$default == 2
                && ($default->[0] // '') eq 'system' && ($default->[1] // '') eq 'now';
        }
    }
    my $selected = $self->plan_action({action => $plan->action, target => $plan->target, inputs => $inputs});
    Selecto::Error->throw('action_plan_mismatch', 'plan differs from the selected declared action')
        unless Selecto::Action::Grant->plan_digest($selected) eq Selecto::Action::Grant->plan_digest($plan);
    return 1;
}
sub grant_action {
    my ($self,$plan,%options)=@_;
    return Selecto::Write::FieldValidators->with_budget(sub {
        return $self->_grant_action($plan,%options);
    },limits=>$self->{limits});
}
sub _grant_action {
    my ($self, $plan, %options) = @_;
    $self->assert_domain_identity;
    $self->_validate_selected_action($plan);
    Selecto::Action::Planner->validate_plan_limits($self->{domain}, $plan, limits => $self->{limits});
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
    Selecto::Action::Planner->validate_plan_limits($self->{domain}, $plan, limits => $self->{limits});
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

# Only the planner's separate authored-instruction map grants executable
# meaning. A literal JSON array with the same display value stays literal.
sub _action_assignments {
    my ($plan, $domain) = @_;
    my $changes = $plan->changes;
    my $system = $plan->system_values // {};
    Selecto::Error->throw('invalid_action_changes', 'system values must be an object')
        unless ref($system) eq 'HASH';
    my %assignments;
    for my $field (keys %{$changes // {}}) {
        my $value = $changes->{$field};
        my $type = $domain->fields->{$field} // '';
        if (exists($system->{$field})) {
            Selecto::Error->throw('invalid_action_changes', 'action change value is not portable',
                {field => $field})
                unless defined($system->{$field}) && !ref($system->{$field}) && $system->{$field} eq 'now'
                    && ref($value) eq 'ARRAY' && @$value == 2
                    && ($value->[0] // '') eq 'system' && ($value->[1] // '') eq 'now'
                    && $type =~ /\A(?:utc_datetime|naive_datetime|datetime|timestamp|date)\z/;
            $value = Selecto::Write::Expression->current_timestamp;
        } elsif (ref($value) && !JSON::PP::is_bool($value)) {
            Selecto::Error->throw('invalid_action_changes', 'structured input requires a JSON field', {field => $field})
                unless $type =~ /\A(?:json|jsonb|map)\z/;
            my $encoded = eval {JSON::PP->new->canonical->encode($value)};
            Selecto::Error->throw('invalid_action_changes', 'action JSON value is not portable', {field => $field}) if $@;
            $value = $encoded;
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
    return Selecto::QueryLibrary->apply_segment($self->domain, $query, $id, $params // {}, $self->{limits});
}
sub apply_segments {
    my ($self, $query, $ids, $params) = @_;
    return Selecto::QueryLibrary->apply_segments($self->domain, $query, $ids, $params // {}, $self->{limits});
}
sub apply_projection {
    my ($self, $query, $ids) = @_;
    return Selecto::QueryLibrary->apply_projection($self->domain, $query, $ids, $self->{limits});
}
sub apply_ordering {
    my ($self, $query, $id) = @_;
    return Selecto::QueryLibrary->apply_ordering($self->domain, $query, $id);
}
sub apply_view {
    my ($self, $query, $id, $params) = @_;
    return Selecto::QueryLibrary->apply_view($self->domain, $query, $id, $params // {}, $self->{limits});
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
    my $column = $self->_write_tenant_column;
    return defined($self->{scope}{tenant}) && defined($column) && $column eq $field;
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
        ) if ref($self->{domain}->_field_metadata_view($field)->{computed}) eq 'HASH';
    }
    return $self->_validate_command_against_contract(
        $command,
        fields      => $self->{domain}->fields,
        writes      => _checked_writes($self->{domain}->writes),
        values_foreign_keys => $self->{domain}->values_foreign_keys,
        allowed_ops => undef,
        label       => $command->relation,
        trusted_field => $options{trusted_field},
        empty_upsert_mask => $self->_admits_empty_upsert_mask,
        computed    => sub { ref($self->{domain}->_field_metadata_view($_[0])->{computed}) eq 'HASH' },
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
    # An engine writes only what a domain explicitly grants. A graph edge
    # grants its operations through the relationship's allowed_ops.
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
            next if $permission eq 'insertable'
                && grep { $field eq $_ } Selecto::Write::Policy::_trusted_fields($context{trusted_field});
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
    if (!$domain_fields) {
        Selecto::Write::ConflictTarget->validate($writes, $command->metadata->{conflict_target}, undef)
            if $operation eq 'upsert';
        return $self;
    }
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
        Selecto::Write::ConflictTarget->validate(
            $writes, $metadata->{conflict_target}, $domain_fields);
        my $updates = $metadata->{upsert_update_fields};
        Selecto::Error->throw('invalid_write', 'upsert requires declared update fields')
            unless ref($updates) eq 'ARRAY' && (@$updates || $context{empty_upsert_mask});
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

# Bound graph children must follow a declared writable relationship. An
# independent row can use only the actual root relation and root governance;
# absence of a binding never infers a grant from another table's shape.
sub _validate_graph_node {
    my ($self, $node, $contexts, $root_scope, $tenants,$owned_sets,$relationship_work) = @_;
    my $command = $node->{command};
    Selecto::Error->throw('invalid_write_graph', 'graph node requires a write command')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    Selecto::OperationBudget->new(limits => $self->{limits}, code => 'invalid_write')->check_tree(
        {assignments => $command->{assignments}, predicate => $command->{predicate},
            scope_predicate => $command->{scope_predicate}, query_enforcement => $command->{query_enforcement}},
        label => 'write', allowed_classes => [qw(Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement)]);
    my $bindings = $node->{bindings} // [];
    unless (@$bindings) {
        Selecto::Error->throw('write_relation_mismatch', 'independent graph row must use the root domain relation')
            unless $command->relation eq $self->{domain}->table;
        $command = $self->governed_write($command, graph_node => $node->{id});
        my $writes = _checked_writes($self->{domain}->writes);
        return ({table => $self->{domain}->table, primary_key => $self->{domain}->primary_key,
            fields => $self->{domain}->fields, fields_known => 1, writes => $writes,
            relationships => $writes->{relationships}, tenant_scope => $self->{domain}->write_tenant_scope,
            domain => $self->{domain},operation=>$command->operation}, $command);
    }
    my $edge;
    my $edge_id;
    for my $binding (@$bindings) {
        Selecto::Error->throw('invalid_write_graph', 'graph binding scope field must match its relationship field')
            if defined($binding->{scope_field}) && $binding->{scope_field} ne $binding->{field};
        my $parent = $contexts->{$binding->{from}};
        Selecto::Error->throw('invalid_write_graph', "graph binding references unavailable node $binding->{from}")
            unless $parent;
        my $found = $self->_match_relationship($parent, $binding, $command->relation,$relationship_work);
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
    # the child can be checked, so the engine refuses the edge.
    Selecto::Error->throw(
        'write_policy_missing',
        'nested writes must declare their relationship domain',
        {relation => $command->relation, graph_node => $node->{id}},
    ) unless $edge->{fields_known};
    if ($edge->{relationship_policy}{requires_owned_set}
        && ($contexts->{$bindings->[0]{from}}{operation}//'') eq 'update') {
        # A full-set omission request has an actual owned-set operation. An
        # informational command mode cannot replace that cleanup structure.
        my $binding=$bindings->[0];my $parent=$contexts->{$binding->{from}};my $matched=0;
        for my $set (@{$owned_sets//[]}) {
            $relationship_work->consume_count('max_expression_nodes',1,label=>'owned relationship work') if $relationship_work;
            next unless $set->{parent} eq $binding->{from};
            my $spec=$parent->{relationships}{$set->{relationship}};next unless ref($spec) eq 'HASH';
            my $table=$spec->{table}//(ref($spec->{domain}) eq 'HASH' && ref($spec->{domain}{source}) eq 'HASH' ? $spec->{domain}{source}{source_table} : undef);
            $matched=1 if defined($table) && $table eq $command->relation
                && ($spec->{child_key}//$spec->{foreign_key}//'') eq $binding->{field}
                && ($spec->{parent_key}//$parent->{primary_key}) eq $binding->{key};
        }
        Selecto::Error->throw('invalid_write_graph','declared full-set omission requires its actual owned-set operation') unless $matched;
    }
    my $scope = $edge->{tenant_scope};
    my $nested_domain = _native_relationship_domain($edge->{contract});
    my $nested_engine = $self->_graph_engine($nested_domain);
    $command=$nested_engine->_materialize_write_context($command);
    $command = $command->with_assignments($nested_domain->normalize_write_assignments($command->assignments));
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
    my $required = $nested_engine->required_write_guard($command->operation, graph_node => $node->{id});
    my ($trusted, $filled);
    ($command, $trusted) = $nested_engine->_apply_write_tenant($command, $required, graph_node => $node->{id});
    $command = $command->with_scope_predicate(
        Selecto::QueryEnforcement::combine($command->scope_predicate, $required)) if defined $required;
    ($command, $filled) = $self->_confine_child_tenants($command, $tenants, $edge->{fields}, graph_node => $node->{id})
        unless $scope;
    $trusted = [@$trusted, @{$filled // []}];
    my %nested_fields = %{$edge->{fields} // {}};
    $command = Selecto::Write::Policy->apply($command, $edge->{writes}, \%nested_fields,
        trusted_field => $trusted);
    $self->_validate_command_against_contract($command,
        ($edge->{fields_known} ? (fields => \%nested_fields) : (fields => undef)),
        writes      => $edge->{writes},
        allowed_ops => $edge->{allowed_ops},
        label       => $command->relation,
        trusted_field => $trusted,
    );
    # A bound field takes its value from the parent this graph wrote, so only
    # the child's own assignments are guarded.
    $command = $command->with_foreign_key_guards(_foreign_key_guards(
        _contract_references($edge->{contract}, $edge->{table}), $command, $tenants,
        graph_node => $node->{id},
    ));
    $command = $command->with_metadata({%{$command->metadata},
        __selecto_primary_key => $edge->{primary_key},
        __selecto_insert_types => $edge->{field_types},
        __selecto_limits => $self->{limits},
        __selecto_write_limit => $self->{limits}->get('max_action_targets')});
    return ({
        table         => $edge->{table},
        primary_key   => $edge->{primary_key},
        fields_known  => $edge->{fields_known},
        fields        => $edge->{fields},
        writes        => $edge->{writes},
        relationships => $edge->{relationships},
        tenant_scope  => $scope,
        domain        => $nested_domain,
        operation     => $command->operation,
    }, $command);
}

# Portable relationship domains do not require a display name. The native
# parser's name is descriptive only; take it from the actual declared source
# without modifying the authored domain or inventing a relation/grant.
sub _native_relationship_domain {
    my ($raw)=@_;
    return Selecto::Domain->parse($raw) if ref($raw) eq 'HASH' && exists($raw->{name});
    my $copy=Selecto::Domain::QueryContract->copy_declaration({domain=>$raw})->{domain};
    Selecto::Error->throw('invalid_domain','relationship domain must declare its native source relation')
        unless ref($copy) eq 'HASH' && ref($copy->{source}) eq 'HASH'
            && defined($copy->{source}{source_table}) && !ref($copy->{source}{source_table});
    $copy->{name}=Selecto::Identifier::checked($copy->{source}{source_table});
    return Selecto::Domain->parse($copy);
}

sub _match_relationship {
    my (undef, $parent_context, $binding, $relation,$relationship_work) = @_;
    my $relationships = $parent_context->{relationships};
    return undef unless ref($relationships) eq 'HASH';
    my $chosen;
    for my $name (sort keys %$relationships) {
        my $spec = $relationships->{$name};
        next unless ref($spec) eq 'HASH';
        my $policy=_relationship_policy($spec,$relationship_work);
        next unless $policy->{writable};
        my $table = defined($spec->{table}) ? "$spec->{table}"
            : ref($spec->{domain}) eq 'HASH' && ref($spec->{domain}{source}) eq 'HASH'
                ? "$spec->{domain}{source}{source_table}" : undef;
        next unless defined($table) && $table eq $relation;
        my $child_key = defined($spec->{child_key}) ? "$spec->{child_key}"
            : defined($spec->{foreign_key}) ? "$spec->{foreign_key}" : undef;
        next unless defined($child_key) && "$binding->{field}" eq $child_key;
        my $parent_key = defined($spec->{parent_key}) ? "$spec->{parent_key}" : $parent_context->{primary_key};
        next unless defined($parent_key) && "$binding->{key}" eq $parent_key;
        Selecto::Error->throw('write_operation_not_enabled','nested parent insert requires declared relationship create permission')
            if $policy->{modern} && ($parent_context->{operation}//'') eq 'insert' && !$policy->{semantic}{create};
        my $candidate = _relationship_context($spec, $table,
            "$parent_context->{table}>$table/$child_key/$parent_key",$policy);
        Selecto::Error->throw(
            'unknown_field',
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
    my ($spec, $table, $edge_id,$policy) = @_;
    $spec //= {};
    if (exists($spec->{allowed_ops}) && defined($spec->{allowed_ops})) {
        Selecto::Error->throw('invalid_domain', 'relationship allowed_ops must be an array of operation names')
            unless ref($spec->{allowed_ops}) eq 'ARRAY'
            && !grep {
                !defined($_) || ref($_) || "$_" !~ /\A(?:insert|update|upsert|delete)\z/
            } @{$spec->{allowed_ops}};
    }
    my $nested = ref($spec->{domain}) eq 'HASH' ? $spec->{domain} : {};
    Selecto::Error->throw('write_relation_mismatch','relationship domain must own its actual native relation')
        if ref($nested->{source}) eq 'HASH' && defined($nested->{source}{source_table})
            && $nested->{source}{source_table} ne $table;
    $policy//=_relationship_policy($spec);
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
            field_types => { map { ($_ => $nested->{source}{columns}{$_}{type}) }
                grep { ref($nested->{source}{columns}{$_}) eq 'HASH' }
                @{$nested->{source}{fields}} },
            primary_key => defined($nested->{source}{primary_key}) ? "$nested->{source}{primary_key}" : 'id',
        ) : ()),
        fields_known  => $fields_known,
        writes        => $nested_writes,
        relationships => $nested_writes->{relationships},
        allowed_ops   => $policy->{allowed_ops},
        relationship_policy=>$policy,
        ($tenant_scope ? (tenant_scope => $tenant_scope) : ()),
    };
}

sub _relationship_flag {
    my ($value)=@_;return 0 unless defined $value;
    return $$value ? 1 : 0 if JSON::PP::is_bool($value);
    Selecto::Error->throw('invalid_domain','relationship write grants must be explicit Booleans')
        if defined(reftype($value)) || !(B::svref_2object(\$value)->FLAGS & B::SVf_IOK())
            || ($value!=0 && $value!=1);
    return $value==1 ? 1 : 0;
}

# This is a bridge from authored host declarations to physical operations,
# not a grant carried by the compiled graph's informational metadata.
sub _relationship_policy {
    my ($spec,$work)=@_;
    Selecto::Error->throw('invalid_domain','relationship must be an object') unless ref($spec) eq 'HASH';
    ($work//Selecto::OperationBudget->new(code=>'invalid_domain'))->check_tree(
        {map{exists($spec->{$_})?($_=>$spec->{$_}):()}qw(allowed_ops writable enabled ownership cardinality strategy delete_missing write)},
        label=>'relationship policy work');
    my $legacy=$spec->{allowed_ops}//[];
    Selecto::Error->throw('invalid_domain','relationship allowed_ops must name native operations')
        unless ref($legacy) eq 'ARRAY' && !grep { !defined($_) || ref($_) || $_ !~ /\A(?:insert|update|delete|upsert)\z/ } @$legacy;
    my %legacy=map{$_=>1}@$legacy;
    my $write=$spec->{write};
    unless (defined $write) {
        return {modern=>0,writable=>(_relationship_flag($spec->{writable})||_relationship_flag($spec->{enabled}))?1:0,allowed_ops=>[sort keys%legacy],
            owned_sync=>(!defined(reftype($spec->{ownership})) && ($spec->{ownership}//'') =~ /\A(?:owned|composition)\z/
                && !defined(reftype($spec->{strategy})) && ($spec->{strategy}//'') eq 'sync'
                && _relationship_flag($spec->{delete_missing}) && $legacy{delete})?1:0};
    }
    Selecto::Error->throw('invalid_domain','relationship write policy must be an object') unless ref($write) eq 'HASH';
    my $modes=$write->{modes}//[];
    Selecto::Error->throw('invalid_domain','relationship mutation modes must be a declared list')
        unless ref($modes) eq 'ARRAY' && !grep { !defined($_) || ref($_) || $_ !~ /\A(?:append_only|delta|full_set|replace_one|link_delta)\z/ } @$modes;
    my %modes=map{$_=>1}@$modes;
    Selecto::Error->throw('invalid_domain','relationship ownership and cardinality must be scalar names')
        if defined(reftype($spec->{ownership})) || defined(reftype($spec->{cardinality}));
    my $ownership=$spec->{ownership}//'';
    $ownership={owned=>'composition',shared_reference=>'shared_association',join_only=>'join_association'}->{$ownership}//$ownership;
    Selecto::Error->throw('invalid_domain','native relationship needs declared writable ownership and cardinality')
        unless $ownership =~ /\A(?:composition|shared_association|join_association)\z/
            && ($spec->{cardinality}//'') =~ /\A(?:one|many)\z/;
    my %semantic=map {$_=>_relationship_flag($write->{$_})} qw(create update delete reorder link unlink);
    $semantic{create}||=$legacy{insert}//0;$semantic{update}||=$legacy{update}//0;$semantic{delete}||=$legacy{delete}//0;
    my $shared=$ownership ne 'composition';
    Selecto::Error->throw('invalid_domain','relationship ownership cannot grant this mutation mode')
        if $shared ? grep {$_ ne 'link_delta'} keys %modes : $modes{link_delta};
    Selecto::Error->throw('invalid_domain','shared association policy cannot mutate target rows')
        if $shared && grep {$semantic{$_}} qw(create update delete reorder);
    Selecto::Error->throw('invalid_domain','composition policy cannot grant link mutations')
        if !$shared && ($semantic{link} || $semantic{unlink});
    Selecto::Error->throw('invalid_domain','relationship cardinality is incompatible with its mutation mode')
        if ($spec->{cardinality} eq 'one' && ($modes{append_only} || $modes{full_set}))
            || ($spec->{cardinality} eq 'many' && $modes{replace_one});
    my %physical;
    if ($shared) {
        $physical{insert}=1 if $semantic{link};$physical{delete}=1 if $semantic{unlink};
    } else {
        $physical{insert}=1 if $semantic{create};
        $physical{update}=1 if $semantic{update} && (!%modes || $modes{delta} || $modes{full_set} || $modes{replace_one});
        $physical{delete}=1 if $semantic{delete} && (!%modes || $modes{delta} || $modes{replace_one});
        $physical{upsert}=1 if $legacy{upsert};
    }
    my $delete_missing=($write->{omission}//'') eq 'delete_missing' || _relationship_flag($spec->{delete_missing});
    my $full=$modes{full_set} || !%modes && ($spec->{strategy}//'') eq 'sync';
    my $owned_sync=!$shared && $full && $delete_missing && $semantic{delete};
    return {modern=>1,writable=>(_relationship_flag($spec->{writable})||_relationship_flag($spec->{enabled})||%modes)?1:0,
        allowed_ops=>[sort keys%physical],semantic=>\%semantic,ownership=>$ownership,modes=>[sort keys%modes],owned_sync=>$owned_sync?1:0,
        requires_owned_set=>($owned_sync && keys(%modes)==1 && $modes{full_set})?1:0};
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
      write_context => {tenant_id => 42, account_id => 7}, # optional trusted host values
      write_policy => 'strict',         # optional; strict is the only write policy
      mode         => 'strict',         # optional read policy; default permissive
      domain_ref   => $ref,             # optional Selecto::Domain::Ref
  );

C<scope> accepts only a C<tenant> key. When the domain has a C<tenant_field>,
reads are restricted to that tenant, inserts receive it, and updates and
deletes are confined to it (see L</TENANT SCOPE>).

C<write_context> supplies bounded plain trusted values independently of write
commands. Its tenant must agree with C<scope>; context-owned foreign keys are
materialized and checked before normalization and field policy validation.
The engine's private identity seals the entire context. C<write_context()>
returns an independent snapshot; C<with_write_context($values)> creates a
copy that can add equal or new obligations but cannot replace an identity.
Trusted required filters become native write guards. A compiler's context or
command metadata cannot supply this execution authority.

C<write_policy> is always C<strict>: a domain must declare
C<writes.operations> (with the operation enabled) and, for everything except
deletes, C<writes.fields> before anything is written; otherwise writes fail
with C<write_policy_missing>. A graph edge must declare its relationship
domain and grants its operations through C<allowed_ops> or explicit modern
C<write> grants and mutation modes. Composition and membership operations are
checked against their actual ownership, child relation and native operation;
informational graph metadata grants nothing. The argument may be
omitted or given as C<strict>; any other value, including the removed
C<permissive> policy, throws C<invalid_write_policy>. There is no mode that
writes a domain without a declared write policy.

Ordinary C<execute_batch($batch)> keeps this engine's single-domain boundary.
A trusted host may use C<execute_batch($batch, engines =E<gt> \@engines)> for
multiple configured domains. Each member requires its own real engine, the
identical adapter and equal canonical write context. Every member is governed
before capability discovery or mutation, then the complete native batch is
authorized once. Protected stored deltas still require a whole-plan candidate
provider and fail closed when one is unavailable.

C<mode> is C<permissive> by default. C<strict> admits declared associations and
named query members, and refuses ad-hoc row sources before dispatch. It does
not change write grants. Query copies retain private configured-domain, mode
and tenant provenance; set operands with different modes or scopes refuse.
C<validate_query($query)> checks that public composition boundary without
executing SQL. The private binding helper is internal lifecycle machinery.

C<member_builders> is an explicit trusted-host registry keyed by
C<ctes:member_id> or C<subqueries:member_id>. Each CODE callback receives the
configured engine and must return a query made by a compatible configured
engine. This registry is outside portable metadata. Inert
C<{kind =E<gt> 'declared_callback'}> declarations never execute themselves.
Scope mismatches, changed configured domains and unconfigured scoped children
are refused. Hosts remain responsible for effects inside callbacks they supply.

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

  my $result = $engine->all($query, canonical_values => 1);

Compiles and executes the query and returns every row. With the PostgreSQL
adapter, values are the driver's own (DBD::Pg) unless canonical values are
asked for, per call with C<< canonical_values => 1 >> or for the whole
adapter with its C<canonical_values> attribute; canonical values are
integers as numbers, booleans as C<1> or C<0>, exact decimals and floats
without trailing zeros, and timestamps in ISO form (see
L<Selecto::PostgreSQL/RESULT VALUES>). C<< canonical_values => 0 >> asks for
the driver's values even when the adapter's default is canonical. The other
adapters always normalize, as before, and ignore the option.

With C<< export_scalars => 1 >> (C<< $engine->all($query, export_scalars => 1) >>)
the rows hold canonical export scalars instead: exact decimals keep the
column's scale as the database writes them (C<533.10>, C<7152.00>,
C<0.0000>), booleans are L<JSON::PP> booleans, and JSON columns are decoded
JSON values. Integers, text, dates (C<YYYY-MM-DD>) and timestamps
(C<YYYY-MM-DDTHH:MM:SS>) are canonical values, as with
C<< canonical_values => 1 >>. Exports (L<Selecto::API::ResultFormatter>) use
these values. Only adapters that support C<export_scalars> accept it (the
PostgreSQL adapter does); others throw C<unsupported_feature>.

C<all> applies the domain's required predicate and the engine's tenant, but
an explicit C<tenant_required> domain or attached read context also requires
valid read scope. Hosts that omit read tenant policy retain ordinary trusted
cross-tenant reads. Public surfaces also call L</assert_tenant_boundary>.

=head2 with_tenant, apply_tenant_scope, validate_tenant_scope

  my $attached = $engine->with_tenant({tenant_id => 'tenant-a'});
  my $scoped = $attached->apply_tenant_scope;
  my $report = $scoped->validate_tenant_scope; # {valid => JSON boolean, ...}

Attaches bounded plain read context without silently applying row scope.
Explicit application adds required field/value obligations; ordinary query
filters cannot satisfy them. Context supports C<tenant_id> (alias C<id>),
C<tenant_field> (default C<tenant_id>), C<prefix>, boolean C<required>
(alias C<require_tenant>) and scalar-pair C<required_filters>. Callback/tied/
cyclic inputs are refused before copying. An attached identity cannot be
replaced. Domain C<tenant_required> (alias C<require_tenant>) fails closed;
a context's false flag cannot weaken a required configured domain.

Row scope requires a matching single trusted required value. Missing,
contradictory and ambiguous scope produce typed errors before compilation or
execution. C<require_tenant_filter($field, $value)> adds an obligation through
an approved copy. C<required_filters> and C<tenant_context> return isolated
plain metadata copies. Scope and read-cache structures join the engine's
private configured-domain identity; mutating their public records is refused.

A prefix names a separately quoted schema identifier. Prefix/compound reads
support declared associations, native CTEs/subqueries and set operations.
Every physical relation uses the separately quoted attached prefix; local
VALUES/CTE names remain local. Retargeted prefix queries still fail closed. Execution options cannot substitute the attached prefix.
C<merge_execution_options(prefix =E<gt> ...)> checks that identity; C<all>,
C<stream> and bounded execution enforce the same check. The attached read
context does not authorize writes; all engine write dispatch refuses it.
Existing C<with_scope> and declared C<writes.scope.tenant> remain the separate
trusted write-authority lifecycle. This API does not execute declared UDFs or
portable callback markers. Explicit host member builders use the separate
constructor registry above. See L<Selecto::Verification::QuerySafety> for the
finite read-scope model.

=head2 stream

  my $stream = $engine->stream($query, fetch_size => 500);
  while (my $row = $stream->next) { ... }
  $stream->close;

Returns a L<Selecto::Stream> that decodes one row at a time. Requires the
adapter's C<stream> capability. Server-side cursor behavior is up to the
DBI driver. Rows hold the same values as C<all>: pass
C<< canonical_values => 1 >> for canonical values from PostgreSQL.

=head2 assert_domain_identity

Recheck the private structural identity retained when this engine was configured.
Changing the domain, trusted scope or cached read domain throws
C<domain_modified_after_configuration> with C<path> C<[]> before compilation or
execution. The public fingerprint does not authorize changes. Prepared bounded
queries recheck this identity before dispatch. Raw adapter tooling has its own
independent contract.

C<with_scope>, C<without_action_prerequisites> and C<with_limits> are checked
host transitions. C<with_limits> intersects a trusted C<Selecto::Limits> with
current ceilings and preserves existing private domain evidence. There is no
public reseal operation. Configured identity does not implement unsupported
filter/function policy metadata or establish native catalog authority.

=head2 compile

Returns the L<Selecto::Statement> the adapter would execute for a query.

=head2 projection_sum

  my $total = $engine->projection_sum($query, 'total');
  my $total = $engine->projection_sum($query, 'total', canonical_values => 1);

Wraps the compiled query and returns the sum of one selected result column
over the rows it returns (zero when there are none), as the driver's value
or, with C<< canonical_values => 1 >>, as a canonical value. Requires the adapter's
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
C<< access => 'write' >> a trusted tenant counts when every write binds it
to the tenant field (lesson 47), and a required predicate, trusted
C<write_context> filter or C<host_predicate> excluding it is refused with
C<tenant_mismatch>. Returns the engine.

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

Every governed upsert requires a nonempty, duplicate-free C<conflict_target>
that exactly matches one ordered entry in
C<writes.operations.upsert.conflict_targets>. Omitting the allowlist refuses
upserts. The check is shared by direct writes, actions, batches and nested
graph domains. MySQL and MariaDB refuse target-specific upserts with
C<unsupported_upsert_conflict_target> because their native syntax cannot
guarantee this identity when another unique key collides.

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
it again in the same statement. For inserts canonical typed values are checked
before dispatch, then the candidate is compared using verified actual column
storage inside the write transaction, before its INSERT. Preview compilation
does not establish that live storage check. Upserts and
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
predicate, its changes become assignments and its cardinality becomes
C<expected_count>. Only a timestamp authored in the selected template or
default, recorded in the plan's separate C<system_values> provenance, becomes
the current timestamp. Scalar caller inputs reject references; structured
JSON values remain bound literals even when they contain C<['system','now']>.
The command
then passes through the same governance and tenant scope as any other write.
Pass C<< returning => [...] >> to request values back.

The resolver is called as C<< $resolver->($request, $context, \%options) >>
and returns C<enabled>, C<disabled>, C<hidden> or a hash with a C<status>. A
missing resolver fails with C<missing_capability_resolver>; a denial fails
with C<action_capability_denied>. Insert and upsert actions create one row;
upserts resolve conflicts on a target declared under
C<writes.operations.upsert.conflict_targets>. Collection patches require a
host executor (C<unsupported_action_collection_patch>).

The engine accepts a trusted C<Selecto::Limits> object in its constructor's
C<limits> option and exposes it through C<limits>. Action planning, grant
issuance, preview and execution recheck its finite C<max_action_targets>
ceiling before invoking capability resolvers. The default is 1,000; an action's
C<selection.max_rows> can reduce it. The selected conflict target and system
instruction provenance are included in the grant digest, so changing either
invalidates an issued grant.

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

=head2 without_action_prerequisites

  my $for_user = $engine->without_action_prerequisites(@hidden_action_ids);

Returns a copy whose domain omits the C<can_E<lt>actionE<gt>> prerequisite
columns of the named actions (see
L<Selecto::Domain/without_action_prerequisites>), or the engine itself when
none of them has one.

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

A trusted engine tenant limits every write of a domain with a
C<source.tenant_field> whether or not it declares C<writes.scope.tenant>
(lesson 47): updates, deletes, upserts, batch members, graph roots,
owned-sync cleanup, actions and query-enforced writes add
C<< tenant_field = tenant >> to their scope; inserts and upserts carry the
tenant (filled when absent, C<tenant_mismatch> for another value); an
update may not re-tag a row; upserts must resolve conflicts on a target
including the tenant field (C<tenant_scope_conflict_target>). A required
predicate, trusted C<write_context> C<required_filters>, caller predicate or
query evidence whose top-level C<eq>/C<in> conjunct on the tenant field
excludes the engine tenant is refused with C<tenant_mismatch> before any
DML; one that admits it (C<IN (7, 8)>) is intersected with it. A graph child
binds the engine tenant only onto a column that pairs by name with the
root's. Every update of a root tenant column must keep a value the required
and host conjuncts on it admit.

On a two-column domain (C<source.tenant_field> C<tenant_id>,
C<writes.scope.tenant> C<site_id>) the engine tenant means C<tenant_id> on
writes as on reads (lesson 47a): writes bind C<tenant_id> by the rules
above, and C<site_id> is never bound to the engine value. It is pinned only
by a positive top-level C<eq>/C<in> conjunct of the required predicate or a
trusted C<write_context> filter. The C<writes.scope.tenant> declaration still
requires a trusted tenant. A graph child never binds the engine value onto
a column the root pins, such as a child tenanted on C<site_id>.

Under an engine tenant, a write that sets the pinned C<site_id> (insert,
update, upsert, batch member, graph root or child, owned-sync row) is
refused with C<missing_tenant_scope> unless such a pin exists (lesson 47b).
Host and required pins count alike and are intersected (with the root's
pin for a graph child); a set they leave empty is C<tenant_mismatch>. The
value must be a literal inside the pin (C<tenant_mismatch>). An insert
omitting C<site_id> is assigned the pin when exactly one site is pinned,
and refused otherwise. Updates and deletes of a graph child match only
rows inside a pin. Writes that do not set C<site_id> are unaffected.

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

On a two-column root (C<writes.scope.tenant> on one column,
C<source.tenant_field> on another) each root column has its own admitted
set: the engine tenant bounds the C<tenant_field> column (lesson 47a), and
the required predicate's and trusted C<write_context> filters' C<eq>/C<in>
conjuncts bound (pin) the write-scope column; the engine value never does. A
reference guard takes the set of the root column it pairs with. An
association whose C<source_scope_key> is a root tenant column pairs its
C<target_scope_key> with that column, whatever the target column is named
(C<tenant_id -E<gt> warehouses.site_id> guards C<site_id> with the
C<tenant_id> set); a target that is the root's table or stores both root
columns is guarded on each of them by name, in one C<EXISTS>; any other
tenant column pairs with the root column of its own name. Scope keys that
disagree with the target's C<tenant_field>, a column two pairings would give
different sets, an authored pair crossing names on a target storing both
root columns, and a tenant column pairing with no root column are refused
with C<invalid_domain> (C<foreign_key_tenant_scope_undeclared>) when the
engine is built. A reference whose paired root column no set bounds fails
with C<missing_tenant_scope>.

A graph child or owned-sync row that stores a root tenant column, and
declares no C<writes.scope.tenant> of its own, is confined to that column's
admitted tenants as the root is, also when only the root's required
predicate bounds them: its updates, deletes and sync cleanup match only rows
inside the set, its inserts must land inside it, an assignment to the column
outside it fails with C<tenant_mismatch>, and an upsert is refused.

Under a tenant-bounded root (an engine tenant, a C<tenant_field>,
C<writes.scope.tenant> or a required predicate) every graph or sync
relationship's C<parent_key>, at every hop, must be its parent's primary key
or exactly a single-column upsert conflict target the parent declares;
otherwise the engine is refused with C<invalid_domain>
(C<foreign_key_tenant_scope_undeclared>). A non-unique key would bind
children under every parent sharing the value, another tenant's included.

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

=item *

Guarded insert admission currently verifies ordinary PostgreSQL and SQLite
tables with integer, decimal, string/text or boolean policy fields. Each
guarded field requires an explicit canonical value (or literal assignment).
The database applies actual precision/scale and collation to the prospective
row. Only TRUE admits it; FALSE or UNKNOWN produces C<query_rule_violation>.
Malformed numeric values, unverified adapters or storage, generated policy
columns, defaults, user triggers/rules and unsupported table forms fail closed.
Pure L<Selecto::QueryEnforcement> scalar comparison remains a separate contract.
This check applies through common single, batch, graph and action execution;
earlier commands in a transaction may already have run when a later one fails.

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
