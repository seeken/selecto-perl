package Selecto::Write::Multi;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed reftype);
use Cpanel::JSON::XS ();
use Selecto::Error ();
use Selecto::Domain::QueryContract ();
use Selecto::Domain ();
use Selecto::OperationBudget ();
use Selecto::Write ();
use Selecto::Write::Operation ();

fieldhash my %STATE;
my $MAX_OPERATIONS = 1000;
sub _error { Selecto::Error->throw($_[0], $_[1], $_[2] // {}) }
sub _copy { Selecto::Domain::QueryContract->copy_declaration($_[0]) }
sub _name {
    return defined($_[0]) && !defined(reftype($_[0]))
        && (B::svref_2object(\$_[0])->FLAGS & B::SVp_POK()) && $_[0] =~ /\S/;
}
sub _operations {
    my ($given) = @_;
    _error('invalid_operation', 'Multi operations must be a bounded ordered array')
        unless ref($given) eq 'ARRAY' && !defined(tied(@$given)) && @$given <= $MAX_OPERATIONS;
    my @operations;
    my $budget = Selecto::OperationBudget->new(code=>'invalid_operation');
    for my $index (0 .. $#$given) {
        _error('invalid_operation', 'Multi operation entries cannot be tied') if defined(tied($given->[$index]));
        my $pair = $given->[$index];
        _error('invalid_operation', 'Multi entries require a name and constructed operation')
            unless ref($pair) eq 'ARRAY' && !defined(tied(@$pair)) && @$pair == 2
                && !defined(tied($pair->[0])) && !defined(tied($pair->[1]));
        my ($name, $operation) = @$pair;
        _error('invalid_operation', 'Multi operation names must be authored nonempty strings') unless _name($name);
        _error('invalid_write_operation', 'Multi requires constructed portable operations')
            unless (blessed($operation) // '') eq 'Selecto::Write::Operation';
        $budget->check_tree({name=>$name, operation=>Selecto::Write::Operation::snapshot($operation)},
            label=>'cumulative portable Multi input');
        push @operations, ["$name", $operation];
    }
    return \@operations;
}
sub _seal {
    my ($operations) = @_;
    my $token = 0;
    my $object = bless \$token, __PACKAGE__;
    $STATE{$object} = _operations($operations);
    return $object;
}
sub new {
    my ($class, %args) = @_;
    _error('invalid_operation', 'Multi class is fixed')
        unless defined($class) && !defined(reftype($class)) && $class eq __PACKAGE__;
    _error('invalid_operation', 'Multi constructor only accepts operations') if grep { $_ ne 'operations' } keys %args;
    return _seal($args{operations} // []);
}
sub operations {
    my ($self) = @_;
    _error('invalid_operation', 'Multi must be constructed by its public API')
        unless (blessed($self) // '') eq __PACKAGE__ && (reftype($self) // '') eq 'SCALAR' && exists $STATE{$self};
    return [map { [@$_] } @{$STATE{$self}}];
}
sub append {
    my ($self, $name, $operation) = @_;
    return _seal([@{$self->operations}, [$name, $operation]]);
}
sub insert {
    my ($self, $name, $domain, $attrs) = @_;
    return $self->append($name, Selecto::Write::Operation->new($domain)->insert($attrs));
}
sub update {
    my ($self, $name, $domain, $given) = @_;
    my $options = _copy($given);
    _error('invalid_operation', 'Multi update requires changes and optional filters')
        unless ref($options) eq 'HASH' && exists($options->{changes}) && !grep { $_ ne 'changes' && $_ ne 'filters' } keys %$options;
    my $operation = Selecto::Write::Operation->new($domain)->update($options->{changes})
        ->filters($options->{filters} // []);
    return $self->append($name, $operation);
}
sub _merge_context {
    my ($left, $given) = @_;
    my $right = _copy($given);
    _error('invalid_operation', 'Compiled Multi context must be an object') unless ref($right) eq 'HASH';
    my $json = Cpanel::JSON::XS->new->canonical;
    my @conflicts = sort grep { exists($right->{$_}) && $json->encode($left->{$_}) ne $json->encode($right->{$_}) } keys %$left;
    _error((grep { $_ eq 'tenant_id' || $_ eq 'tenant' } @conflicts) ? 'tenant_mismatch' : 'invalid_operation',
        'Atomic write batch has conflicting trusted context', {code=>'batch_context_conflict', keys=>\@conflicts}) if @conflicts;
    return {%$left, %$right};
}
sub compile {
    my ($self, %opts) = @_;
    require Selecto::Write::PortableCommand;
    return Selecto::Write::PortableCommand->_with_field_validator_scope(sub {$self->_compile(%opts)});
}
sub _compile {
    my ($self, %opts) = @_;
    my $operations = $self->operations;
    _error('invalid_operation', 'Atomic write batches must contain operations') unless @$operations;
    my (%seen, %duplicates);
    for my $pair (@$operations) { $duplicates{$pair->[0]} = 1 if $seen{$pair->[0]}++ }
    _error('invalid_operation', 'Atomic write batch operation names must be unique',
        {code=>'duplicate_batch_operation_name', names=>[sort keys %duplicates]}) if %duplicates;
    require Selecto::Write::PortableCommand;
    my (@commands, $context);
    $context = {};
    my $budget = Selecto::OperationBudget->new(code=>'invalid_operation');
    for my $pair (@$operations) {
        _error('unsupported_operation', 'Atomic write batch requires prepared record-state support',
            {code=>'batch_rule_strategy_unsupported',name=>$pair->[0],operation=>$pair->[1]->snapshot->{type}})
            if Selecto::Write::PortableCommand->requires_prepared_record_state($pair->[1]);
        my $compiled = Selecto::Write::PortableCommand->compile($pair->[1], %opts, action_phase=>'execute');
        _error('unsupported_operation', 'Nested graph batches require a whole-plan native batch provider',
            {code=>'batch_graph_strategy_unsupported',name=>$pair->[0]})
            unless (blessed($compiled->{command}) // '') eq 'Selecto::Write::Command';
        $context = _merge_context($context, $compiled->{context});
        $budget->check_tree($compiled, label=>'cumulative compiled Multi output',
            allowed_classes=>[qw(Selecto::Write::Command Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement)]);
        push @commands, $compiled->{command};
    }
    return {command=>Selecto::Write::Batch->new(@commands), context=>$context};
}
sub run {
    my ($self, $engine, %opts) = @_;
    _error('configured_selecto_required', 'Multi writes require a configured Selecto engine')
        unless blessed($engine) && UNIVERSAL::isa($engine, 'Selecto::Engine');
    Selecto::Engine::assert_domain_identity($engine);
    require Selecto::Write::FieldValidators;
    return Selecto::Write::FieldValidators->with_budget(sub {$self->_run($engine,%opts)},limits=>$engine->limits);
}
sub _run {
    my ($self, $engine, %opts) = @_;
    require Selecto::Write::Context;
    my %context_options=%opts;my $resolver=delete $context_options{choice_membership_resolver};
    $context_options{context}=Selecto::Write::Context->resolve({opts=>{context=>$engine->write_context}},\%context_options);
    $context_options{choice_membership_resolver}=$resolver if defined $resolver;
    my $compiled = $self->compile(%context_options);
    my $target = $engine->with_write_context($compiled->{context});
    my $operations = $self->operations;
    my @engines = map {
        my $state = Selecto::Write::Operation::snapshot($_->[1]);
        my $domain=$state->{domain};
        $domain->{name} //= $domain->{source}{source_table} // $domain->{source}{table};
        Selecto::Engine->new(domain=>Selecto::Domain->parse($domain),
            adapter=>$target->adapter, limits=>$target->limits, write_context=>$target->write_context);
    } @$operations;
    my $results = $target->execute_batch($compiled->{command}, engines=>\@engines);
    my $actual = ref($results) eq 'ARRAY' ? scalar(@$results) : 'invalid';
    _error('adapter_failure', 'Atomic write batch returned an unexpected result count',
        {code=>'batch_result_count_mismatch',expected_result_count=>scalar(@$operations),actual_result_count=>$actual})
        unless ref($results) eq 'ARRAY' && @$results == @$operations;
    _error('adapter_failure', 'Atomic write batch returned a non-result member', {code=>'batch_result_type_mismatch'})
        if grep { (blessed($_) // '') ne 'Selecto::Write::Result' } @$results;
    return {map { ($operations->[$_][0] => $results->[$_]) } 0 .. $#$operations};
}
1;

__END__

=head1 NAME

Selecto::Write::Multi - ordered portable atomic write batches

=head1 DESCRIPTION

Build immutable named operations with C<new>, C<append>, C<insert> and C<update>.
C<compile> compiles every operation and merges equal trusted contexts before
constructing one native batch. C<run($engine)> uses the configured engine's
governed atomic dispatch and returns a complete name/result map. Duplicate
names, conflicting contexts and malformed adapter results are typed failures.
No prefix of a partially compiled batch is dispatched.

Nested graph members fail closed at the Command-only native batch boundary.
Each member's complete domain is configured independently against the same
adapter, limits and trusted context. Native engine checks remain authoritative
for every member; compilation alone grants no execution authority.

=cut
