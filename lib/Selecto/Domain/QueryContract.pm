package Selecto::Domain::QueryContract;

use 5.034;
use strict;
use warnings;
no overloading;
use bytes ();
use Encode qw(encode_utf8);
use JSON::PP ();
use Scalar::Util qw(blessed refaddr reftype);
use Selecto::Error ();
use Selecto::Limits ();

my $LIMITS = Selecto::Limits->new;
my %BOOL = map { $_ => 1 } qw(JSON::PP::Boolean JSON::XS::Boolean Types::Serialiser::Boolean);
my %SITE = map { $_ => 1 } qw(select filter order_by group_by join lateral);
my @DEFAULTS = qw(default_selected required_selected required_filters required_order_by required_group_by);
my %COMPARATOR = map { $_ => 1 } qw(eq neq gt gte lt lte between contains starts_with ends_with in not_in is_null not_null);

# The complete plain declaration is admitted before copying or interpreting it.
# Callback markers are ordinary metadata; actual callbacks, tied containers,
# unknown blessed values, cycles and unbounded repeated aliases are refused.
sub _contract {
    my ($value) = @_;
    _walk({nodes => 0, bytes => 0, active => {}}, $value, 0);
    _fail('query contract must be a plain object') unless ref($value) eq 'HASH';
    return $value;
}
sub _walk {
    my ($state, $value, $depth) = @_;
    _fail('query contract exceeds its metadata resource limit')
        if ++$state->{nodes} > $LIMITS->get('max_expression_nodes')
            || $depth > $LIMITS->get('max_expression_depth');
    my $type = reftype($value);
    unless (defined $type) {
        _bytes($state, defined($value) ? $value : '');
        return;
    }
    my $class = blessed($value) // '';
    if ($BOOL{$class} && $type eq 'SCALAR') {
        _fail('query contract contains an invalid boolean') if defined(tied($$value))
            || !defined($$value) || defined(reftype($$value)) || "$$value" !~ /\A[01]\z/;
        return;
    }
    _fail('query contract contains unsupported executable or object metadata')
        if length($class) || ($type ne 'HASH' && $type ne 'ARRAY');
    _fail('query contract contains tied metadata')
        if $type eq 'HASH' ? defined(tied(%$value)) : defined(tied(@$value));
    my $address = refaddr($value);
    _fail('query contract contains a cycle') if $state->{active}{$address};
    local $state->{active}{$address} = 1;
    my $count = $type eq 'HASH' ? scalar(keys %$value) : scalar(@$value);
    _fail('query contract exceeds its metadata node limit')
        if $state->{nodes} + $count > $LIMITS->get('max_expression_nodes');
    if ($type eq 'HASH') {
        for my $key (keys %$value) {
            _fail('query contract contains tied scalar metadata') if defined(tied($value->{$key}));
            _bytes($state, $key);
            _walk($state, $value->{$key}, $depth + 1);
        }
    } else {
        for my $index (0 .. $#$value) {
            _fail('query contract contains tied scalar metadata') if defined(tied($value->[$index]));
            _walk($state, $value->[$index], $depth + 1);
        }
    }
}
sub _bytes {
    my ($state, $value) = @_;
    $state->{bytes} += bytes::length(utf8::is_utf8($value) ? encode_utf8($value) : $value);
    _fail('query contract exceeds its metadata byte limit')
        if $state->{bytes} > $LIMITS->get('max_state_bytes');
}
sub _copy {
    my ($value) = @_;
    return $value unless ref($value);
    return $$value ? JSON::PP::true : JSON::PP::false if $BOOL{blessed($value) // ''};
    return [map { _copy($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _copy($value->{$_}) } keys %$value};
}
sub _fail { Selecto::Error->throw('invalid_query_contract', $_[0]); }
sub _name { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\S/ }
sub _error {
    my ($state, $code, $path, %extra) = @_;
    # Paths and extras may repeat long authored identifiers. Charge actual
    # emitted occurrences before copying or storing another diagnostic.
    _walk($state->{output}, {code => $code, path => $path, %extra}, 0);
    push @{$state->{errors}}, {code => $code, path => [@$path], %extra};
}
sub _field_key {
    my ($state, $prefix, $id) = @_;
    my $output = $state->{output};
    _fail('query contract exceeds its generated field limit')
        if ++$output->{nodes} > $LIMITS->get('max_expression_nodes');
    # Check the concatenated UTF-8 size before allocating it. A compact schema
    # with a long name must not multiply that prefix across thousands of fields.
    _bytes($output, $prefix);
    _bytes($output, $id);
    return $prefix . $id;
}
sub _work {
    my ($state, $count) = @_;
    _fail('query contract exceeds its projection work limit')
        if ($state->{work} += $count // 1) > $LIMITS->get('max_expression_nodes');
}
sub _object {
    my ($state, $value, $path) = @_;
    return $value if ref($value) eq 'HASH';
    _error($state, 'invalid_section_shape', $path, expected => 'object');
    return {};
}
sub _list {
    my ($state, $value, $path) = @_;
    return $value if ref($value) eq 'ARRAY';
    _error($state, 'invalid_section_shape', $path, expected => 'array');
    return [];
}

sub _state {
    my ($contract) = @_;
    my $state = {contract => $contract, errors => [], fields => {}, functions => {}, filters => {}, work => 0, specified_sites => {},
        output => {nodes => 0, bytes => 0, active => {}}};
    my $source = _object($state, $contract->{source} // {}, ['source']);
    _relation($state, $source, '', ['source']);
    my $schemas = _object($state, $contract->{schemas} // {}, ['schemas']);
    for my $id (sort keys %$schemas) {
        _relation($state, _object($state, $schemas->{$id}, ['schemas', $id]), "$id.", ['schemas', $id]);
    }
    my $custom = _object($state, $contract->{custom_columns} // {}, ['custom_columns']);
    for my $id (sort keys %$custom) {
        my $spec = _object($state, $custom->{$id}, ['custom_columns', $id]);
        $state->{fields}{_field_key($state, '', $id)} = $spec->{type};
    }
    _joins($state, $source, $schemas, _object($state, $contract->{joins} // {}, ['joins']), '', ['joins']);
    my $filters = _object($state, $contract->{filters} // {}, ['filters']);
    for my $id (sort keys %$filters) {
        _work($state);
        my $path = ['filters', $id];
        _error($state, 'invalid_filter_id', $path) unless _name($id);
        my $spec = _object($state, $filters->{$id}, $path);
        _error($state, 'invalid_filter_type', [@$path, 'type']) unless _name($spec->{type});
        my $field = exists($spec->{field}) ? $spec->{field} : exists($state->{fields}{$id}) ? $id : undef;
        if (defined $field) {
            _error($state, 'invalid_query_field_reference', [@$path, 'field']) unless _name($field);
            _error($state, 'query_field_not_found', [@$path, 'field'], field => $field)
                if _name($field) && !exists($state->{fields}{$field});
        }
        my $comparators;
        for my $key (qw(comparators operators)) {
            next unless exists $spec->{$key};
            $comparators = _list($state, $spec->{$key}, [@$path, $key]);
            for my $i (0 .. $#$comparators) {
                _error($state, 'invalid_filter_comparator', [@$path, $key, $i])
                    unless _name($comparators->[$i]) && $COMPARATOR{$comparators->[$i]};
            }
            last;
        }
        $state->{filters}{$id} = { %{_copy($spec)}, id => $id, field => $field,
            virtual => defined($field) ? JSON::PP::false : JSON::PP::true,
            comparators => _copy($comparators // (defined($field) ? _comparators($spec->{type}) : []))};
    }
    my $functions = _object($state, $contract->{functions} // {}, ['functions']);
    for my $id (sort keys %$functions) {
        _work($state);
        my $path = ['functions', $id];
        _error($state, 'invalid_function_id', $path) unless _name($id);
        my $spec = _object($state, $functions->{$id}, $path);
        _error($state, 'invalid_function_kind', [@$path, 'kind'])
            unless _name($spec->{kind}) && $spec->{kind} =~ /\A(?:scalar|predicate|table)\z/;
        _error($state, 'invalid_function_sql_name', [@$path, 'sql_name'])
            unless _name($spec->{sql_name}) && $spec->{sql_name} =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
        my $sites = defined($spec->{allowed_in}) ? _list($state, $spec->{allowed_in}, [@$path, 'allowed_in']) : [];
        $state->{specified_sites}{$id} = defined $spec->{allowed_in};
        _work($state, scalar(@$sites) + scalar(@{$spec->{args}})) if ref($spec->{args}) eq 'ARRAY';
        for my $i (0 .. $#$sites) {
            _error($state, 'invalid_function_call_site', [@$path, 'allowed_in', $i]) unless _name($sites->[$i]) && $SITE{$sites->[$i]};
        }
        my $args = defined($spec->{args}) ? _list($state, $spec->{args}, [@$path, 'args']) : [];
        for my $i (0 .. $#$args) {
            my $arg_path = [@$path, 'args', $i];
            my $arg = _object($state, $args->[$i], $arg_path);
            _error($state, 'invalid_function_arg_name', [@$arg_path, 'name']) unless _name($arg->{name});
            _error($state, 'invalid_function_arg_type', [@$arg_path, 'type']) unless _name($arg->{type});
            _error($state, 'invalid_function_arg_source', [@$arg_path, 'source'])
                unless _name($arg->{source}) && $arg->{source} =~ /\A(?:selector|value|literal)\z/;
        }
        my $kind = _name($spec->{kind}) ? $spec->{kind} : '';
        _error($state, 'invalid_function_returns', [@$path, 'returns'])
            unless $kind eq 'table' ? ref($spec->{returns}) eq 'HASH'
                && ref($spec->{returns}{columns}) eq 'HASH' && keys(%{$spec->{returns}{columns}})
                : _name($spec->{returns}) && ($kind ne 'predicate' || $spec->{returns} eq 'boolean');
        $state->{functions}{$id} = {%{_copy($spec)}, id => $id, allowed_in => _copy($sites), args => _copy($args)};
    }
    for my $section (@DEFAULTS) {
        next unless defined $contract->{$section};
        my $entries = _list($state, $contract->{$section}, [$section]);
        for my $i (0 .. $#$entries) {
            my ($entry, $path) = ($entries->[$i], [$section, $i]);
            if ($section eq 'required_filters') { _filter($state, $entry, $path); next; }
            if ($section eq 'required_order_by') {
                if (ref($entry) ne 'ARRAY' || @$entry != 2 || !_name($entry->[1])
                    || $entry->[1] !~ /\A(?:asc|desc)(?:_nulls_(?:first|last))?\z/) {
                    _error($state, 'invalid_query_order', $path); next;
                }
                _selector($state, $entry->[0], 'order_by', [@$path, 0]);
            } else { _selector($state, $entry, $section eq 'required_group_by' ? 'group_by' : 'select', $path); }
        }
    }
    return $state;
}
sub _relation {
    my ($state, $relation, $prefix, $path) = @_;
    my $columns = _object($state, $relation->{columns} // {}, [@$path, 'columns']);
    my $fields = exists($relation->{fields}) ? _list($state, $relation->{fields}, [@$path, 'fields']) : [sort keys %$columns];
    _work($state, scalar(@$fields));
    for my $i (0 .. $#$fields) {
        my $id = $fields->[$i];
        unless (_name($id)) { _error($state, 'invalid_query_field_reference', [@$path, 'fields', $i]); next; }
        unless (exists $columns->{$id}) { _error($state, 'source_field_missing_column', [@$path, 'fields', $i], field => $id); next; }
        my $column = _object($state, $columns->{$id}, [@$path, 'columns', $id]);
        $state->{fields}{_field_key($state, $prefix, $id)} = $column->{type};
    }
}
sub _joins {
    my ($state, $relation, $schemas, $joins, $prefix, $path) = @_;
    my $associations = _object($state, $relation->{associations} // {}, [@$path, 'associations']);
    for my $id (sort keys %$joins) {
        _work($state);
        my $join = _object($state, $joins->{$id}, [@$path, $id]);
        my $association = $associations->{$id};
        next unless ref($association) eq 'HASH' && _name($association->{queryable});
        my $target = $schemas->{$association->{queryable}};
        next unless ref($target) eq 'HASH';
        _relation($state, $target, "$prefix$id.", [@$path, $id]);
        _joins($state, $target, $schemas, _object($state, $join->{joins} // {}, [@$path, $id, 'joins']), "$prefix$id.", [@$path, $id, 'joins']);
    }
}
sub _selector {
    my ($state, $selector, $site, $path) = @_;
    _work($state);
    if (_name($selector)) {
        _error($state, 'query_field_not_found', $path, field => $selector) unless exists $state->{fields}{$selector};
        return $state->{fields}{$selector};
    }
    unless (ref($selector) eq 'ARRAY' && @$selector && _name($selector->[0])) {
        _error($state, 'invalid_query_field_reference', $path); return;
    }
    my ($kind, @args) = @$selector;
    if ($kind eq 'field' && (@args == 1 || @args == 2)) { return _selector($state, $args[0], $site, [@$path, 'field']); }
    if ($kind eq 'rollup' || $kind eq 'grouping_set') {
        unless ($site eq 'group_by' && @args == 1 && ref($args[0]) eq 'ARRAY') { _error($state, 'invalid_query_field_reference', $path); return; }
        _selector($state, $args[0][$_], $site, [@$path, $kind, $_]) for 0 .. $#{$args[0]}; return;
    }
    unless ($kind eq 'udf' && @args == 2 && _name($args[0]) && ref($args[1]) eq 'ARRAY') {
        _error($state, 'invalid_query_field_reference', $path); return;
    }
    my ($id, $values) = @args;
    my $function = $state->{functions}{$id};
    unless ($function) { _error($state, 'query_function_not_found', [@$path, 'function'], function => $id, call_site => $site); return; }
    if ($state->{specified_sites}{$id} && !grep { _name($_) && $_ eq $site } @{$function->{allowed_in}}) {
        _error($state, 'query_function_call_site_not_allowed', [@$path, 'function'], function => $id, call_site => $site, allowed_in => _copy($function->{allowed_in}));
    }
    my $specs = $function->{args};
    _error($state, 'query_function_arg_count_mismatch', [@$path, 'args'], function => $id, expected => scalar(@$specs), actual => scalar(@$values)) if @$values != @$specs;
    for my $i (0 .. ($#$values < $#$specs ? $#$values : $#$specs)) {
        next unless ref($specs->[$i]) eq 'HASH';
        # Selector arguments have their own select context; this does not change
        # the containing invocation's group/filter/order placement above.
        _selector($state, $values->[$i], 'select', [@$path, 'args', $i]) if ($specs->[$i]{source} // '') eq 'selector';
    }
    return $function->{returns};
}
sub _filter {
    my ($state, $filter, $path) = @_;
    _work($state);
    unless (ref($filter) eq 'ARRAY' && @$filter == 2) { _error($state, 'invalid_query_filter', $path); return; }
    my ($field, $value) = @$filter;
    if (_name($field) && $field =~ /\A(?:and|or|nor|xor)\z/) {
        my $children = _list($state, $value, [@$path, $field]);
        _filter($state, $children->[$_], [@$path, $field, $_]) for 0 .. $#$children;
    } elsif (_name($field) && $field eq 'not') { _filter($state, $value, [@$path, 'not']); }
    else { _selector($state, $field, 'filter', [@$path, 0]); }
}
sub _comparators {
    my ($type) = @_;
    $type = defined($type) && !ref($type) ? lc($type) : '';
    return [qw(eq neq contains starts_with ends_with in not_in is_null not_null)] if $type =~ /\A(?:string|text)\z/;
    return [qw(eq neq gt gte lt lte between in not_in is_null not_null)] if $type =~ /\A(?:integer|float|decimal|date|time|datetime|naive_datetime(?:_usec)?|utc_datetime(?:_usec)?)\z/;
    return [qw(eq neq is_null not_null)] if $type eq 'boolean';
    return [qw(eq neq in not_in is_null not_null)];
}
sub validate {
    my ($class, $given) = @_;
    my $state = _state(_contract($given));
    return {valid => @{$state->{errors}} ? JSON::PP::false : JSON::PP::true, errors => $state->{errors}, warnings => []};
}
sub copy_declaration {
    my ($class, $given) = @_;
    return _copy(_contract($given));
}
sub project {
    my ($class, $given) = @_;
    my $contract = _contract($given);
    my $state = _state($contract);
    Selecto::Error->throw('invalid_query_contract', 'query contract declaration failed validation',
        {errors => $state->{errors}, warnings => []}) if @{$state->{errors}};
    my $projection = {projection => 'query_contract',
        defaults => {map { $_ => _copy($contract->{$_} // []) } @DEFAULTS},
        fields => [map { {id => $_, type => _copy($state->{fields}{$_})} } sort keys %{$state->{fields}}],
        filters => [map { _copy($state->{filters}{$_}) } sort keys %{$state->{filters}}],
        functions => [map { _copy($state->{functions}{$_}) } sort keys %{$state->{functions}}],
        # Preserve the rest of the admitted portable declaration as metadata,
        # without implying native callback, lateral, or UDF execution support.
        declaration => _copy($contract), query_library => _copy($contract->{query_library} // {})};
    # Generated identifiers/diagnostics were bounded before storage. This final
    # check bounds the complete returned metadata, including repeated sections.
    _walk({nodes => 0, bytes => 0, active => {}}, $projection, 0);
    return $projection;
}

1;

__END__

=head1 NAME

Selecto::Domain::QueryContract - portable declared query metadata and diagnostics

=head1 METHODS

C<project($plain_contract)> derives defaults and sorted declared field, filter
and function metadata. C<validate($plain_contract)> accumulates structured
query declaration diagnostics, including selector identities, function argument
counts and invocation placement. Inputs are complete plain portable contract
hashes. Both APIs admit bounded callback-free metadata before copying; callback
markers remain inert metadata. Projection copies are independent of the input.
C<copy_declaration($plain_contract)> provides the same complete bounded plain
metadata admission and independent copy without applying query-policy semantic
validation. Other consumer metadata projectors can reuse this input boundary;
they must still bound their generated work and output before amplification.

The existing C<Domain::query_contract> raw identity projection is unchanged.
The class methods C<Selecto::Domain-E<gt>project_query_contract($plain_contract)>
and C<Selecto::Domain-E<gt>validate_query_contract($plain_contract)> are thin
public entry points to these APIs. Constructed native domain objects must be
explicitly converted to plain authored contract data by their trusted owner;
this boundary does not invoke object getters or extension hooks.
This metadata API does not configure a native domain or execute declared
callbacks, laterals or UDFs. Native parsing, required clauses and configured
domain seals continue to establish their separate execution boundaries.

=cut
