package Selecto::Write::QueryEnforcement;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed reftype refaddr);
use bytes ();
use Encode qw(encode_utf8);
use JSON::PP ();
use Selecto::Error ();
use Selecto::Limits ();
use Selecto::Expression ();
use Selecto::Domain::QueryContract ();
use Selecto::QueryEnforcement ();
use Selecto::QueryBinding ();

my $LIMITS = Selecto::Limits->new;
sub _fail { Selecto::Error->throw($_[0], $_[1], {code => $_[0], %{$_[2] // {}}}) }
sub _copy { Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value} }
sub _id {
    my ($value) = @_;
    $value = $value->{'$atom'} if ref($value) eq 'HASH' && keys(%$value) == 1 && exists($value->{'$atom'});
    _fail('query_rule_unsupported_field', 'query guards require declared root fields')
        unless defined($value) && !defined(reftype($value)) && $value =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return "$value";
}
sub _operator {
    my ($value) = @_;
    $value = $value->{'$atom'} if ref($value) eq 'HASH' && keys(%$value) == 1 && exists($value->{'$atom'});
    return undef if !defined($value) || defined(reftype($value));
    my %alias = ('='=>'eq', ne=>'neq', '!='=>'neq', '<>'=>'neq', '>'=>'gt', '>='=>'gte', '<'=>'lt', '<='=>'lte', not_nil=>'not_null');
    return $alias{$value} // "$value";
}
sub _comparison {
    my ($kind, $field, $value, $fields) = @_;
    $field = _id($field);
    _fail('query_rule_unsupported_field', 'query guards require declared root fields', {fields=>[$field]}) unless $fields->{$field};
    if ($kind eq 'is_null' || $kind eq 'not_null') {
        _fail('query_rule_unsupported_predicate', 'null tests require a null operand') if defined $value;
        return $kind eq 'is_null' ? Selecto::Expression->is_null($field) : Selecto::Expression->not_null($field);
    }
    if ($kind eq 'in' || $kind eq 'not_in') {
        _fail('query_rule_unsupported_predicate', 'query guard IN requires nonempty non-null literal values')
            unless ref($value) eq 'ARRAY' && @$value && !grep { !defined($_) || defined(reftype($_)) && !JSON::PP::is_bool($_) } @$value;
        my $predicate = Selecto::Expression->in($field, [map { JSON::PP::is_bool($_) ? ($$_ ? 1 : 0) : $_ } @$value]);
        return $kind eq 'not_in' ? Selecto::Expression->not($predicate) : $predicate;
    }
    _fail('query_rule_unsupported_predicate', 'query guard uses an unsupported comparison') unless $kind =~ /\A(?:eq|neq|gt|gte|lt|lte)\z/;
    unless (defined $value) {
        return Selecto::Expression->is_null($field) if $kind eq 'eq';
        return Selecto::Expression->not_null($field) if $kind eq 'neq';
        _fail('query_rule_unsupported_predicate', 'ordered query guard comparisons require a value');
    }
    _fail('query_rule_unsupported_predicate', 'query guards require literal scalar values') if defined(reftype($value)) && !JSON::PP::is_bool($value);
    $value = $$value ? 1 : 0 if JSON::PP::is_bool($value);
    return Selecto::Expression->new($kind eq 'neq' ? 'ne' : $kind, Selecto::Expression->field($field), Selecto::Expression->literal($value));
}
sub _filter {
    my ($filter, $fields, $depth) = @_;
    _fail('query_rule_unsupported_predicate', 'query guards require bounded filter tuples')
        unless ref($filter) eq 'ARRAY' && @$filter && $depth <= $LIMITS->get('max_expression_depth');
    my $first = _operator($filter->[0]);
    return _field_filter($filter->[0], $filter->[1], $fields)
        if @$filter == 2 && !defined(reftype($filter->[0])) && defined($filter->[0]) && $fields->{$filter->[0]};
    if (defined($first) && ($first eq 'and' || $first eq 'or')) {
        my $children = @$filter == 2 && ref($filter->[1]) eq 'ARRAY' ? $filter->[1] : [@$filter[1..$#$filter]];
        _fail('query_rule_unsupported_predicate', 'boolean query guards require a nonempty group') unless @$children;
        my @expressions = map { _filter($_, $fields, $depth+1) } @$children;
        return $first eq 'and' ? Selecto::Expression->all(@expressions) : Selecto::Expression->any(@expressions);
    }
    if (defined($first) && $first eq 'not') {
        _fail('query_rule_unsupported_predicate', 'NOT requires one query guard') unless @$filter == 2;
        return Selecto::Expression->not(_filter($filter->[1], $fields, $depth+1));
    }
    if (@$filter == 3 && defined($first) && $first =~ /\A(?:eq|neq|gt|gte|lt|lte|in|not_in)\z/) {
        return _comparison($first, $filter->[1], $filter->[2], $fields);
    }
    if (@$filter == 2 && defined($first) && $first =~ /\A(?:is_null|not_null)\z/) {
        return _comparison($first, $filter->[1], undef, $fields);
    }
    if (@$filter == 3) { return _comparison(_operator($filter->[1]) // '', $filter->[0], $filter->[2], $fields) }
    _fail('query_rule_unsupported_predicate', 'query guards require a comparison tuple') unless @$filter == 2;
    return _field_filter($filter->[0], $filter->[1], $fields);
}
sub _field_filter {
    my ($field, $value, $fields) = @_;
    return _comparison('is_null', $field, undef, $fields) unless defined $value;
    my $null = _operator($value);
    return _comparison('not_null', $field, undef, $fields) if ref($value) eq 'HASH' && defined($null) && $null eq 'not_null';
    if (ref($value) eq 'ARRAY' && @$value) {
        my $operator = _operator($value->[0]);
        if (defined($operator) && $operator eq 'between' && @$value == 3) {
            return Selecto::Expression->all(_comparison('gte',$field,$value->[1],$fields), _comparison('lte',$field,$value->[2],$fields));
        }
        if (@$value == 2 && defined($operator) && $operator =~ /\A(?:eq|neq|gt|gte|lt|lte|in|not_in)\z/) {
            return _comparison($operator, $field, $value->[1], $fields);
        }
        return _comparison('in', $field, $value, $fields);
    }
    return _comparison('eq', $field, $value, $fields);
}
sub _filters {
    my ($filters, $fields) = @_;
    _fail('query_rule_unsupported_predicate', 'required query filters must be an array') unless ref($filters) eq 'ARRAY';
    return Selecto::QueryEnforcement::combine(map { _filter($_, $fields, 0) } @$filters);
}

# A native query is admitted in full before any native accessor traverses it.
# This walk never invokes overload, cloning, serialization or tied hooks.
sub _admit_native {
    my ($value, $state, $depth) = @_;
    _fail('invalid_query_enforcement', 'captured query contains unsupported or excessive native data')
        if ++$state->{nodes} > $LIMITS->get('max_expression_nodes') || $depth > $LIMITS->get('max_expression_depth');
    my $type = reftype($value);
    unless (defined $type) {
        $state->{bytes} += defined($value) ? bytes::length(utf8::is_utf8($value) ? encode_utf8($value) : $value) : 0;
        _fail('invalid_query_enforcement', 'captured query exceeds its metadata byte limit') if $state->{bytes} > $LIMITS->get('max_state_bytes');
        return;
    }
    my $class = blessed($value);
    if (defined($class) && $class =~ /\A(?:JSON::PP::Boolean|JSON::XS::Boolean|Types::Serialiser::Boolean)\z/) {
        _fail('invalid_query_enforcement', 'captured query contains an invalid boolean')
            unless $type eq 'SCALAR' && !defined(tied($$value)) && defined($$value) && !defined(reftype($$value)) && "$$value" =~ /\A[01]\z/;
        return;
    }
    _fail('invalid_query_enforcement', 'captured query contains unsupported object metadata')
        if defined($class) && $class !~ /\A(?:Selecto::(?:Query|Expression|Domain|Domain::Association|DataRules|Pattern|Limits)|Math::Big(?:Rat|Int|Int::Calc))\z/;
    _fail('invalid_query_enforcement', 'captured query contains unsupported native references') unless $type eq 'HASH' || $type eq 'ARRAY';
    _fail('invalid_query_enforcement', 'captured query contains tied metadata') if $type eq 'HASH' ? defined(tied(%$value)) : defined(tied(@$value));
    my $id = refaddr($value);
    _fail('invalid_query_enforcement', 'captured query contains a cycle') if $state->{active}{$id};
    local $state->{active}{$id} = 1;
    my $count = $type eq 'HASH' ? scalar(keys %$value) : scalar(@$value);
    _fail('invalid_query_enforcement', 'captured query exceeds its metadata node limit') if $state->{nodes} + $count > $LIMITS->get('max_expression_nodes');
    if ($type eq 'HASH') {
        for my $key (keys %$value) {
            _fail('invalid_query_enforcement', 'captured query contains tied scalar metadata') if defined(tied($value->{$key}));
            _admit_native($key, $state, $depth+1);
            _admit_native($value->{$key}, $state, $depth+1);
        }
    } else {
        for my $index (0..$#$value) {
            _fail('invalid_query_enforcement', 'captured query contains tied scalar metadata') if defined(tied($value->[$index]));
            _admit_native($value->[$index], $state, $depth+1);
        }
    }
}
# Keep the native operator separate from literal strings such as "not_null".
# Public display filters intentionally omit equality and cannot preserve this
# distinction in every language's value representation.
sub _native_filter {
    my ($expression) = @_;
    _fail('query_rule_unsupported_predicate', 'captured predicate must use native root expressions')
        unless (blessed($expression)//'') eq 'Selecto::Expression';
    my ($kind,$args)=($expression->kind,$expression->arguments);
    if ($kind eq 'and' || $kind eq 'or') {
        return [{'$atom'=>$kind},[map {_native_filter($_)} @{$args->[0]}]];
    }
    return [{'$atom'=>'not'},_native_filter($args->[0])] if $kind eq 'not';
    _fail('query_rule_unsupported_predicate', 'captured predicate requires a root field')
        unless (blessed($args->[0])//'') eq 'Selecto::Expression' && $args->[0]->kind eq 'field';
    my $field=$args->[0]->arguments->[0];
    return [{'$atom'=>$kind},$field] if $kind eq 'is_null' || $kind eq 'not_null';
    return [{'$atom'=>'in'},$field,_copy($args->[1])] if $kind eq 'in';
    _fail('query_rule_unsupported_predicate', 'captured predicate requires a literal comparison')
        unless $kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/
            && (blessed($args->[1])//'') eq 'Selecto::Expression' && $args->[1]->kind eq 'literal';
    return [{'$atom'=>$kind},$field,_copy($args->[1]->arguments->[0])];
}
sub capture {
    my ($class, @args) = @_;
    my ($engine, $query) = @args == 1 ? (undef, $args[0]) : @args;
    _fail('invalid_query_enforcement', 'query enforcement requires a genuine configured query')
        unless @args >= 1 && @args <= 2 && (blessed($query) // '') eq 'Selecto::Query'
            && (reftype($query) // '') eq 'HASH';
    my $owner = Selecto::QueryBinding->owner($query);
    _fail('invalid_query_enforcement', 'query enforcement requires a genuine configured query') unless defined $owner;
    $engine //= $owner;
    _fail('query_source_mismatch', 'captured query must belong to the supplied configured engine')
        unless (blessed($engine) // '') eq 'Selecto::Engine' && refaddr($owner) == refaddr($engine);
    _admit_native($query, {nodes=>0,bytes=>0,active=>{}}, 0);
    $engine->assert_domain_identity;
    _fail('invalid_query_enforcement', 'retargeted queries cannot govern root writes') if defined $query->retarget_spec;
    my $domain = $engine->domain;
    my $read_domain = $engine->read_domain;
    _fail('query_source_mismatch', 'prefix-routed queries cannot govern an unqualified portable write', {fields=>['prefix']})
        if defined($read_domain->{_read_prefix});
    my $filters = [map {_native_filter($_)} grep {defined} $read_domain->required_predicate, $query->predicate];
    _fail('query_enforcement_requires_filter', 'an enforced query must contain an effective predicate') unless @$filters;
    return _copy({filters=>$filters, storage_backend=>$engine->adapter->name,
        source=>{domain_name=>$domain->name, relation=>$domain->table, primary_key=>$domain->primary_key,
            fingerprint=>($domain->_contract_view // {})->{domain_fingerprint}}, applied_query_library=>$query->applied_query_library});
}
sub compile {
    my ($class, $state, $contract) = @_;
    my %fields = map { $_=>1 } (@{$contract->{source}{fields}//[]}, keys %{$contract->{source}{columns}//{}});
    my $required = _filters($state->{domain}{required_filters}//[], \%fields);
    my $evidence = $state->{query_enforcement};
    my $captured;
    if (defined $evidence) {
        _fail('invalid_query_enforcement', 'query evidence must be captured by Operation.enforce_query') unless ref($evidence) eq 'HASH' && ref($evidence->{source}) eq 'HASH';
        my $source = $evidence->{source};
        # Published source identity is portable metadata. A write projection
        # need not be an executable read-domain import and can omit unrelated
        # read sections. Its optional declared fingerprint is distinct from
        # the native Engine's private whole-domain configuration digest.
        my %actual = (domain_name=>$state->{domain}{name},
            relation=>$contract->{source}{source_table}//$contract->{source}{table},
            primary_key=>$contract->{source}{primary_key}//$state->{domain}{primary_key}//'id',
            fingerprint=>$contract->{fingerprint});
        my @mismatch = grep { defined($source->{$_}) && defined($actual{$_}) &&
            (ref($source->{$_}) || ref($actual{$_})
                ? JSON::PP->new->canonical->allow_nonref->encode($source->{$_}) ne JSON::PP->new->canonical->allow_nonref->encode($actual{$_})
                : $source->{$_} ne $actual{$_})
            || ($_ eq 'relation' || $_ eq 'primary_key') && (!defined($source->{$_}) || !defined($actual{$_})) } sort keys %actual;
        _fail('query_source_mismatch', 'enforced query and write source identities differ', {fields=>\@mismatch}) if @mismatch;
        _fail('query_enforcement_requires_filter', 'an enforced query must contain an effective predicate') unless ref($evidence->{filters}) eq 'ARRAY' && @{$evidence->{filters}};
        $captured = _filters($evidence->{filters}, \%fields);
    }
    my $predicate = Selecto::QueryEnforcement::combine($required, $captured);
    _fail('query_enforcement_unsupported_operation', 'upsert cannot enforce required or captured query predicates', {operation=>'upsert'})
        if defined($predicate) && ($state->{type}//'') eq 'upsert';
    return $predicate;
}
sub validate_insert {
    my ($class, $state, $values, $predicate, $backend) = @_;
    return unless ($state->{type}//'') eq 'insert' && defined($predicate) && ($backend//'') ne 'sqlite';
    my $result = Selecto::QueryEnforcement::evaluate($predicate, $values);
    _fail('query_rule_violation', 'insert candidate does not satisfy required query predicates', {operation=>'insert'}) unless $result eq 'true';
}

1;

__END__

=head1 NAME

Selecto::Write::QueryEnforcement - captured root query guards for portable writes

=head1 DESCRIPTION

Internal support for Operation.enforce_query and portable command compilation.
Capture admits the whole native query without invoking metadata hooks and binds
its effective root filters to its genuine configured source. Compilation lowers
required and captured filters to native scope predicates. Query projections,
ordering and pagination do not change write eligibility.

=cut
