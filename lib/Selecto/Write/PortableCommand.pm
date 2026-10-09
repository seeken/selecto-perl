package Selecto::Write::PortableCommand;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed reftype);
use JSON::PP ();
use Selecto::Error ();
use Selecto::Domain::QueryContract ();
use Selecto::Domain::WriteContract ();
use Selecto::Expression ();
use Selecto::Write ();
use Selecto::Write::Operation ();
use Selecto::Write::Policy ();
use Selecto::Write::ConflictTarget ();
use Selecto::Write::QueryEnforcement ();

sub _fail { Selecto::Error->throw($_[0], $_[1], {code => $_[0], %{$_[2] // {}}}); }
sub _copy { Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value} }
sub _true { JSON::PP::is_bool($_[0]) ? ${$_[0]} == 1 : defined($_[0]) && !ref($_[0]) && $_[0] eq '1' }
sub _same { JSON::PP->new->canonical->encode([$_[0]]) eq JSON::PP->new->canonical->encode([$_[1]]) }

# The optional atom marker preserves distinct authored identifier spellings in
# languages with atoms. Plain Perl strings remain ordinary identifiers.
sub identifier {
    my ($class, $given) = @_;
    my $value = _copy($given);
    $value = $value->{'$atom'} if ref($value) eq 'HASH' && keys(%$value) == 1 && exists($value->{'$atom'});
    _fail('invalid_write_identifier', 'write identifier must name a root field')
        unless defined($value) && !ref($value) && $value =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return "$value";
}
sub _snapshot {
    my ($operation) = @_;
    _fail('opaque_planned_operation', 'opaque planned operations require the action authorization path')
        if (blessed($operation) // '') eq 'Selecto::Write::PlannedOperation';
    _fail('invalid_write_operation', 'portable compilation requires a constructed operation')
        unless (blessed($operation) // '') eq 'Selecto::Write::Operation';
    return $operation->snapshot;
}
sub _options {
    my ($given) = @_;
    my %opts = %$given;
    my $resolver = delete $opts{choice_membership_resolver};
    _fail('invalid_choice_resolver', 'choice membership resolver must be a trusted code reference')
        if defined($resolver) && ref($resolver) ne 'CODE';
    # The entire remaining host options and the complete Operation snapshot
    # are admitted before any resolver may be invoked.
    return (_copy(\%opts), $resolver);
}
sub compile {
    my ($class, $operation, %given) = @_;
    my $state = _snapshot($operation);
    my ($opts) = _options(\%given);
    my $contract = Selecto::Domain::WriteContract->compile($state->{domain});
    require Selecto::Write::NestedGraph;
    if (Selecto::Write::NestedGraph->nested($operation)) {
        return Selecto::Write::NestedGraph->compile($operation, %given);
    }
    return $class->compile_flat($operation, %given);
}
sub _fields {
    my ($contract) = @_;
    my %fields = map { $_ => 1 } @{$contract->{source}{fields} // []};
    $fields{$_} = 1 for keys %{$contract->{source}{columns} // {}};
    return \%fields;
}
sub requires_storage_candidate {
    my ($class, $operation) = @_;
    my $state = _snapshot($operation);
    my $contract = eval { Selecto::Domain::WriteContract->compile($state->{domain}) };
    if (my $error = $@) { die $error unless ref($error) eq 'Selecto::Error'; return 0; }
    return 0 unless keys %{$contract->{rules} // {}};
    require Selecto::DataRules;
    my $rules = Selecto::DataRules->parse($contract->{rules});
    return scalar(grep { @{$rules->applicable_paths($_, $state->{type})} } qw(candidate transaction evidence)) ? 1 : 0;
}
sub requires_prepared_record_state {
    my ($class, $operation) = @_;
    my $state = _snapshot($operation);
    return 0 unless ($state->{type} // '') eq 'update' || ($state->{type} // '') eq 'upsert';
    return $class->requires_storage_candidate($operation);
}
sub _values {
    my ($class, $given, $fields) = @_;
    my @pairs = ref($given) eq 'HASH' ? map { [$_, $given->{$_}] } sort keys %$given
        : ref($given) eq 'ARRAY' ? @$given : ();
    _fail('invalid_operation', 'write values must be an object or ordered field/value pairs')
        unless ref($given) eq 'HASH' || ref($given) eq 'ARRAY';
    my %values;
    for my $pair (@pairs) {
        _fail('invalid_operation', 'write assignment must contain a field and value')
            unless ref($pair) eq 'ARRAY' && @$pair == 2;
        my $field = $class->identifier($pair->[0]);
        _fail('duplicate_assignment_identifier', 'normalized assignment identifiers must be unique', {fields => [$field]})
            if exists($values{$field});
        _fail('undeclared_write_identifier', 'assignment field must be declared on the write source',
            {identifier_kind => 'assignment', fields => [$field]}) unless exists($fields->{$field});
        $values{$field} = $pair->[1];
    }
    return \%values;
}
sub _filters {
    my ($class, $given, $fields) = @_;
    _fail('invalid_predicate', 'portable write filters must be an array') unless ref($given) eq 'ARRAY';
    my (@filters, %spellings);
    for my $filter (@$given) {
        _fail('invalid_predicate', 'portable writes accept field comparisons, null tests and nonempty IN filters')
            unless ref($filter) eq 'ARRAY' && (@$filter == 2 || @$filter == 3);
        my $field = $class->identifier($filter->[0]);
        my $spelling = ref($filter->[0]) eq 'HASH' ? 'atom' : 'string';
        _fail('duplicate_filter_identifier', 'mixed normalized filter identifiers are ambiguous', {fields => [$field]})
            if exists($spellings{$field}) && $spellings{$field} ne $spelling;
        $spellings{$field} = $spelling;
        _fail('undeclared_write_identifier', 'filter field must be declared on the write source',
            {identifier_kind => 'filter', fields => [$field]}) unless exists($fields->{$field});
        my ($comparator, $value) = @$filter == 2 ? ('eq', $filter->[1]) : @$filter[1,2];
        my %names = ('=' => 'eq', '!=' => 'neq', '<>' => 'neq', '>' => 'gt', '>=' => 'gte', '<' => 'lt', '<=' => 'lte');
        $comparator = $class->identifier($comparator) if ref($comparator);
        _fail('invalid_predicate', 'unsupported portable write comparison') unless defined($comparator) && !ref($comparator);
        $comparator = $names{$comparator} // $comparator;
        _fail('invalid_predicate', 'unsupported portable write comparison')
            unless $comparator =~ /\A(?:eq|neq|gt|gte|lt|lte|in|is_null|not_null)\z/;
        _fail('invalid_predicate', 'IN requires a nonempty list')
            if $comparator eq 'in' && (ref($value) ne 'ARRAY' || !@$value);
        _fail('invalid_predicate', 'null tests require a null operand')
            if $comparator =~ /\A(?:is_null|not_null)\z/ && defined($value);
        push @filters, [$field, $comparator, $value];
    }
    return \@filters;
}
sub filters_predicate {
    my ($class, $filters) = @_;
    my @predicates = map {
        my ($field, $kind, $value) = @$_;
        $kind eq 'in' ? Selecto::Expression->in($field, $value)
            : $kind eq 'is_null' ? Selecto::Expression->is_null($field)
            : $kind eq 'not_null' ? Selecto::Expression->not_null($field)
            : Selecto::Expression->new($kind eq 'neq' ? 'ne' : $kind,
                Selecto::Expression->field($field), Selecto::Expression->literal($value));
    } @$filters;
    return undef unless @predicates;
    return @predicates == 1 ? $predicates[0] : Selecto::Expression->all(@predicates);
}
sub _returning_request {
    my ($class, $given, $fields) = @_;
    return $given unless ref($given) eq 'ARRAY';
    my (%seen, @result);
    for my $raw (@$given) {
        my $field = $class->identifier($raw);
        _fail('duplicate_returning_identifier', 'normalized returning identifiers must be unique', {fields => [$field]})
            if $seen{$field}++;
        _fail('undeclared_write_identifier', 'returning field must be declared on the write source',
            {identifier_kind => 'returning', fields => [$field]}) unless exists($fields->{$field});
        push @result, $field;
    }
    return \@result;
}
sub _required {
    my ($contract, $values, $context, $type, $initial) = @_;
    return unless $type eq 'insert' || $type eq 'upsert';
    my $tenant_field = $contract->{scope}{tenant}{field};
    my @missing;
    for my $field (sort keys %{$contract->{fields}}) {
        my $spec = $contract->{fields}{$field};
        next unless _true($spec->{required}) || ref($spec->{required_on}) eq 'ARRAY' && grep { $_ eq 'insert' } @{$spec->{required_on}};
        next if $initial && defined($tenant_field) && $field eq $tenant_field && defined($context->{tenant_id});
        my $fk = $contract->{constraints}{foreign_keys}{$field};
        next if $initial && ref($fk) eq 'HASH' && ref($fk->{source}) eq 'ARRAY' && $fk->{source}[0] eq 'context'
            && exists($context->{$fk->{source}[1]});
        push @missing, $field if !exists($values->{$field}) || !defined($values->{$field})
            || !ref($values->{$field}) && $values->{$field} !~ /\S/;
    }
    _fail('missing_required_write_fields', 'required write fields are missing', {fields => \@missing}) if @missing;
}
sub _assignment_policy {
    my ($contract, $values, $type, $tenant_field) = @_;
    for my $field (sort keys %$values) {
        next if defined($tenant_field) && $field eq $tenant_field && ($type eq 'insert' || $type eq 'upsert');
        my $spec = $contract->{fields}{$field} // {};
        my $grant = $type eq 'update' ? 'updatable' : 'insertable';
        my $reason = _true($spec->{server_managed}) ? 'server_managed'
            : $type eq 'update' && _true($spec->{immutable}) ? 'immutable'
            : !_true($spec->{$grant}) ? $grant : undef;
        _fail('write_field_not_writable', 'field is not writable for this operation', {field => $field, operation => $type, reason => $reason})
            if defined $reason;
    }
}
sub _choices {
    my ($domain, $contract, $values, $context, $resolver, $type, $filters) = @_;
    my @fields = grep {
        my $spec = $contract->{source}{columns}{$_} // {};
        defined($spec->{choice_source}) || ref($spec->{reference}) eq 'HASH' && defined($spec->{reference}{choice_source});
    } sort keys %$values;
    return unless @fields;
    _fail('choice_membership_resolver_required', 'choice-backed write fields require a trusted membership resolver', {fields => \@fields})
        unless $resolver;
    require Selecto::Domain::Choices;
    for my $field (@fields) {
        my $result = Selecto::Domain::Choices->validate_choice($domain, $field, $values->{$field},
            {actor => $context->{actor}, tenant => $context->{tenant_id}, record => $values,
                filters => [map { $_->[1] eq 'eq' ? [$_->[0], $_->[2]] : [@$_] } @$filters],
                context => $context->{choice_source_context} // {}, metadata => {surface => 'portable_write', operation => $type}}, $resolver);
        _fail('choice_membership_invalid', 'write value is not admitted by its choice source', {field => $field, reason_code => $result->reason_code})
            unless $result->outcome eq 'ok' && $result->status eq 'valid';
    }
}
sub compile_flat {
    my ($class, $operation, %given) = @_;
    my $state = _snapshot($operation);
    my ($opts, $resolver) = _options(\%given);
    my $contract = Selecto::Domain::WriteContract->compile($state->{domain});
    my $type = $state->{type};
    _fail('unsupported_operation', 'portable operation type is missing or unsupported')
        unless defined($type) && !ref($type) && $type =~ /\A(?:insert|update|upsert|delete)\z/;
    Selecto::Domain::WriteContract->require_write_policy($contract, $type);
    _fail('write_operation_not_enabled', 'operation is not enabled by the domain write contract', {operation => $type})
        unless Selecto::Domain::WriteContract->operation_enabled($contract, $type);
    require Selecto::Write::Context;
    my $context = Selecto::Write::Context->resolve($state, $opts);
    my $query_predicate = Selecto::Write::QueryEnforcement->compile($state, $contract);
    my $fields = _fields($contract);
    my $values = $type eq 'delete' ? {} : $class->_values($state->{values}, $fields);
    my $filters = $class->_filters([@{$state->{filters} // []}, @{$context->{required_filters} // []}], $fields);
    my $requested_returning = $class->_returning_request($state->{returning}, $fields);
    my $spec = $contract->{operations}{$type};
    my $cardinality = Selecto::Write::Policy->resolve_cardinality($spec, $state->{expected_cardinality});
    my $returning = Selecto::Write::Policy->resolve_returning($spec, $requested_returning, $fields);
    my $scope = $contract->{scope}{tenant};
    my $tenant_field = ref($scope) eq 'HASH' ? $scope->{field} : undef;
    my $tenant = $context->{tenant_id};
    _required($contract, $values, $context, $type, 1);
    if (defined $tenant_field) {
        _fail('missing_tenant_scope', 'tenant-scoped writes require trusted host context', {field => $tenant_field}) unless defined $tenant;
        _fail('tenant_mismatch', 'tenant assignment must match trusted context', {field => $tenant_field})
            if exists($values->{$tenant_field}) && !_same($values->{$tenant_field}, $tenant);
        for my $filter (@$filters) {
            next unless $filter->[0] eq $tenant_field;
            _fail('tenant_mismatch', 'tenant filter must match trusted context', {field => $tenant_field})
                unless $filter->[1] eq 'eq' && _same($filter->[2], $tenant);
        }
    }
    if ($type eq 'upsert') {
        my @unenforced = grep { !defined($tenant_field) || $_->[0] ne $tenant_field || $_->[1] ne 'eq' || !_same($_->[2], $tenant) } @$filters;
        _fail('query_enforcement_unsupported_operation', 'upsert cannot enforce non-tenant write filters', {operation => $type}) if @unenforced;
    }
    _assignment_policy($contract, $values, $type, $tenant_field) unless $type eq 'delete';
    # INPUT transformations precede field text normalization and trusted fills.
    if (keys %{$contract->{rules} // {}}) {
        require Selecto::DataRules;
        require Selecto::WriteRules;
        my $rules = Selecto::DataRules->parse($contract->{rules});
        $values = Selecto::WriteRules->evaluate($rules, 'input', $type, $values);
    }
    for my $field (keys %$values) {
        my $case = $contract->{source}{columns}{$field}{text_case};
        next unless defined($values->{$field}) && !ref($values->{$field}) && defined $case;
        $values->{$field} = uc($values->{$field}) if $case eq 'uppercase';
        $values->{$field} = lc($values->{$field}) if $case eq 'lowercase';
    }
    $values->{$tenant_field} = $tenant if defined($tenant_field) && ($type eq 'insert' || $type eq 'upsert');
    $values = Selecto::Write::Context->materialize($contract, $values, $type, $context);
    _required($contract, $values, $context, $type, 0);
    _assignment_policy($contract, $values, $type, $tenant_field) unless $type eq 'delete';
    _choices($state->{domain}, $contract, $values, $context, $resolver, $type, $filters);
    my $guards = Selecto::Write::Context->foreign_key_guards($state->{domain}, $contract, $values, $type, $context);
    my $relation = $contract->{source}{source_table} // $contract->{source}{table};
    _fail('invalid_domain', 'write domain must declare a source relation') unless defined($relation) && !ref($relation) && $relation =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    if (defined($tenant_field) && ($type eq 'update' || $type eq 'delete')) {
        $filters = [grep { $_->[0] ne $tenant_field } @$filters];
        push @$filters, [$tenant_field, 'eq', $tenant];
    }
    my $predicate = $type eq 'update' || $type eq 'delete' ? $class->filters_predicate($filters) : undef;
    my $required = Selecto::QueryEnforcement::combine($query_predicate,
        Selecto::Write::Context->required_predicate($contract, $context));
    my $backend = $opts->{storage_backend} // ($state->{query_enforcement} // {})->{storage_backend};
    _fail('query_enforcement_unsupported_operation', 'upsert cannot enforce required context predicates', {operation=>$type})
        if $type eq 'upsert' && defined $required;
    Selecto::Write::QueryEnforcement->validate_insert($state, $values, $required, $backend);
    if ($type eq 'insert' && ($backend // '') eq 'sqlite') {
        my @admission_filters = @$filters;
        push @admission_filters, [$tenant_field, 'eq', $tenant] if defined $tenant_field;
        $predicate = $class->filters_predicate(\@admission_filters);
    }
    if ($type eq 'update' || $type eq 'delete') {
        $predicate = defined($predicate) ? Selecto::Expression->all($predicate, $required) : $required if defined $required;
        _fail('missing_predicate', 'update and delete require a domain-governed filter') unless defined $predicate;
    }
    my %metadata = (expected_cardinality => $cardinality, returning => $returning,
        portable_foreign_key_guards => 1,
        required_capabilities => [$type], domain_fingerprint => $contract->{fingerprint},
        field_types => {map { $_ => $contract->{source}{columns}{$_}{type} } keys %{$contract->{source}{columns} // {}}},
        foreign_key_guards => [map { my %guard = %$_; delete @guard{qw(value tenants)}; \%guard } @$guards]);
    if ($type eq 'insert' && ($backend // '') eq 'sqlite' && (defined($predicate) || defined($required))) {
        push @{$metadata{required_capabilities}}, 'typed_insert_admission';
        $metadata{insert_admission} = {storage_backend=>'sqlite', predicate_fingerprint=>
            Selecto::QueryEnforcement::predicate_fingerprint_value(Selecto::QueryEnforcement::combine($predicate,$required))};
    }
    if (ref($state->{query_enforcement}) eq 'HASH') {
        $metadata{query_enforcement} = {source=>_copy($state->{query_enforcement}{source}),
            applied_query_library=>_copy($state->{query_enforcement}{applied_query_library}//{}),
            predicate_fingerprint=>Selecto::QueryEnforcement::predicate_fingerprint_value($required)};
    }
    if ($type eq 'upsert') {
        my $declared = $spec->{conflict_targets};
        my $target = $state->{conflict_target};
        $target //= $declared->[0] if ref($declared) eq 'ARRAY' && @$declared == 1;
        $target = [map { $class->identifier($_) } @$target] if ref($target) eq 'ARRAY';
        $metadata{conflict_target} = Selecto::Write::ConflictTarget->validate({operations => {upsert => $spec}}, $target, $fields);
        _fail('tenant_scope_conflict_target', 'tenant-scoped upsert conflict must include its tenant field')
            if defined($tenant_field) && !grep { $_ eq $tenant_field } @{$metadata{conflict_target}};
        $metadata{declared_conflict_targets} = $declared;
        $metadata{upsert_update_fields} = [grep {
            my $grant = $contract->{fields}{$_} // {};
            _true($grant->{updatable}) && !grep { _true($grant->{$_}) } qw(immutable write_once server_managed)
        } sort keys %$values];
    }
    my $command = Selecto::Write::Command->new(operation => $type, relation => $relation, assignments => $values,
        predicate => $predicate, scope_predicate => $required, expected_count => undef, metadata => \%metadata, foreign_key_guards => $guards);
    $command = Selecto::Write::Policy->apply($command,
        {operations => $contract->{operations}, fields => $contract->{fields}}, $fields,
        trusted_field => $tenant_field);
    return {command => $command, context => _copy($context)};
}

1;

__END__

=head1 NAME

Selecto::Write::PortableCommand - adapter-neutral authored write compilation

=head1 DESCRIPTION

C<compile($operation, %trusted_host_options)> returns an executable native
command or graph and independent canonical context as C<{command, context}>.
It never discovers a server, opens a connection, renders SQL or authorizes an
adapter call. Execute the result through a configured native Engine, which
independently governs it against the host's domain and trusted context.

Input accepts only constructed Operation values and complete bounded plain
metadata. Native objects, callbacks and resources are not write values.
C<choice_membership_resolver> is a separate explicit trusted host callback;
its results must come through the public choice-result API.

=cut
