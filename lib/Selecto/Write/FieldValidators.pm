package Selecto::Write::FieldValidators;

use 5.034;
use strict;
use warnings;
no overloading;
use bytes ();
use Scalar::Util qw(blessed reftype refaddr);
use Hash::Util::FieldHash qw(fieldhash);
use B ();
use JSON::PP ();
use Selecto::Error ();
use Selecto::Limits ();
use Selecto::RuleTest ();
use Selecto::DataRules ();

my %BOOL = map { $_ => 1 } qw(JSON::PP::Boolean JSON::XS::Boolean Types::Serialiser::Boolean);
my %NUMBER = (greater_than => 'number.gt', greater_than_or_equal_to => 'number.gte',
    less_than => 'number.lt', less_than_or_equal_to => 'number.lte');
fieldhash my %BUNDLES;
my $BUDGET;

sub _fail {
    my ($code, $message, $field, $index, $reason) = @_;
    Selecto::Error->throw($code, $message, {
        (defined($field) ? (path => [$field]) : ()),
        (defined($index) ? (validator_index => $index) : ()),
        (defined($reason) ? (rule_code => $reason) : ()),
    });
}
sub _unsupported { _fail('unsupported_write_rule', 'write field validator is unsupported', @_) }
sub _check_args {
    # Called with & so Perl preserves the original argument aliases; copying
    # a tied root scalar into a lexical would already invoke FETCH.
    for my $index (0 .. $#_) { _unsupported() if defined(tied($_[$index])) }
}
sub _limits {
    my ($limits) = @_;
    return Selecto::Limits->new unless defined $limits;
    _unsupported() unless ref($limits) eq 'Selecto::Limits';
    return $limits;
}

# This is a trusted execution scope, never an option in a write declaration.
# All child operations reuse its counter; a nested scope may only tighten it.
# Bundles retain no consumed counter, so repeating a standalone public request
# cannot inherit state from an earlier request.
sub with_budget {
    &_check_args;
    my ($class, $callback, %opts) = @_;
    _unsupported() unless ref($callback) eq 'CODE' && !grep { $_ ne 'limits' } keys %opts;
    my $limits = _limits($opts{limits});
    return Selecto::DataRules->_with_proof_budget(sub {
        if ($BUDGET) {
            $BUDGET->{limits} = $BUDGET->{limits}->intersect($limits);
            _spend(0);
            return $callback->();
        }
        my ($work, $effective) = Selecto::DataRules->_rule_work_context($limits);
        $BUDGET = {limits => $effective, work => $work};
        my $scope = bless {}, 'Selecto::Write::FieldValidators::_Scope';
        return $callback->();
    }, limits => $limits);
}
sub _scope_end { $BUDGET = undef }
sub _current_limits {
    my (undef, $limits) = Selecto::DataRules->_rule_work_context($BUDGET->{limits});
    return $limits;
}
sub _spend { Selecto::RuleTest::spend(_current_limits(), $BUDGET->{work}, $_[0] // 1) }

# Admission precedes every copy, fetch from a container, or RuleTest call.
# Count occurrences, rather than unique references, to bound repeated aliases.
sub _walk {
    my ($state, $value, $depth) = @_;
    my $limits = $BUDGET->{limits};
    _fail('evaluation_limit', 'field validator metadata exceeds its node or depth limit')
        if ++$state->{nodes} > $limits->get('max_expression_nodes') || $depth > $limits->get('max_expression_depth');
    _spend();
    my $type = reftype($value);
    unless (defined $type) { _bytes($state, defined($value) ? $value : ''); return }
    my $class = blessed($value) // '';
    if ($BOOL{$class} && $type eq 'SCALAR') {
        _unsupported() if defined(tied($$value)) || !defined($$value)
            || defined(reftype($$value)) || "$$value" !~ /\A[01]\z/;
        return;
    }
    _unsupported() if length($class) || ($type ne 'HASH' && $type ne 'ARRAY');
    _unsupported() if $type eq 'HASH' ? defined(tied(%$value)) : defined(tied(@$value));
    my $address = refaddr($value);
    _unsupported() if $state->{active}{$address};
    local $state->{active}{$address} = 1;
    my $count = $type eq 'HASH' ? scalar(keys %$value) : scalar(@$value);
    _fail('evaluation_limit', 'field validator metadata exceeds its node limit')
        if $state->{nodes} + $count > $limits->get('max_expression_nodes');
    if ($type eq 'HASH') {
        for my $key (keys %$value) {
            _unsupported() if defined(tied($value->{$key}));
            _bytes($state, $key); _walk($state, $value->{$key}, $depth + 1);
        }
    } else {
        for my $index (0 .. $#$value) {
            _unsupported() if defined(tied($value->[$index]));
            _walk($state, $value->[$index], $depth + 1);
        }
    }
}
sub _bytes {
    my ($state, $value) = @_;
    my $size = do { use bytes; length($value) };
    _fail('evaluation_limit', 'field validator metadata exceeds its byte limit')
        if ($state->{bytes} += $size) > $BUDGET->{limits}->get('max_state_bytes');
    _spend($size);
}
sub _copy {
    my ($value) = @_;
    # Perl's native comparison booleans are non-reference scalars and can
    # carry POK/IOK flags. Preserve Boolean identity before text restoration,
    # and use a private scalar ref so numeric RuleTest cannot coerce it.
    if (JSON::PP::is_bool($value) || $BOOL{blessed($value) // ''}) {
        my $bit = defined(reftype($value)) ? ($$value ? 1 : 0) : ($value ? 1 : 0);
        return bless \$bit, 'JSON::PP::Boolean';
    }
    # Preserve authored binary identity even when a harmless numeric
    # observation has added IOK/NOK flags to the same Perl scalar. RuleTest's
    # JSON-kind classifier must receive pure text, not that ambiguous dual SV.
    return _binary_scalar($value) ? substr($value, 0) : $value unless defined reftype($value);
    return [map { _copy($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { $_ => _copy($value->{$_}) } keys %$value};
}
sub _plain {
    &_check_args;
    my ($value) = @_;
    _walk({nodes => 0, bytes => 0, active => {}}, $value, 0);
    return _copy($value);
}
sub _options {
    my ($opts, @allowed) = @_;
    my %allowed = map { $_ => 1 } @allowed;
    _unsupported() if grep { !$allowed{$_} } keys %$opts;
}
sub _integer_scalar {
    my ($value) = @_;
    return 0 unless defined($value) && !defined(reftype($value));
    return 0 if JSON::PP::is_bool($value);
    # A native floating value 1.0 may stringify as "1". Preserve the delivered
    # integer/string distinction before RuleTest or stringification can coerce
    # it; an NV-only scalar is not an Elixir integer.
    my $flags = B::svref_2object(\$value)->FLAGS;
    return 0 unless $flags & B::SVp_IOK();
    return 0 if $flags & B::SVp_POK();
    return "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/ ? 1 : 0;
}
sub _binary_scalar {
    return 0 unless defined($_[0]) && !defined(reftype($_[0]));
    return 0 if JSON::PP::is_bool($_[0]);
    return B::svref_2object(\$_[0])->FLAGS & B::SVp_POK() ? 1 : 0;
}

# Complete declaration admission is separate from assignment-sensitive syntax.
# Unsupported validators on wholly unassigned fields are not interpreted by
# the highest runtime either. Nested domains are covered by the same walk.
sub prepare_contract {
    &_check_args;
    my ($class, $contract, %opts) = @_;
    _options(\%opts, 'limits');
    return $class->with_budget(sub {
        my $copy = _plain($contract); _unsupported() unless ref($copy) eq 'HASH'; return $copy;
    }, limits => $opts{limits});
}
sub admit_domain { &_check_args; shift->prepare_contract(@_) }

sub _portable_literal {
    my ($value, $field, $index) = @_;
    _spend();
    return if !defined($value) || JSON::PP::is_bool($value);
    unless (defined(reftype($value))) {
        return if _integer_scalar($value) || _binary_scalar($value);
        _unsupported($field, $index);
    }
    # The complete plain walk has already rejected hooks, cycles and unknown
    # classes. This narrower declaration grammar excludes native floats at
    # every depth; RuleTest's general literal grammar also supports decimals.
    if (ref($value) eq 'ARRAY') {
        _portable_literal($_, $field, $index) for @$value;
        return;
    }
    if (ref($value) eq 'HASH') {
        _portable_literal($_, $field, $index) for values %$value;
        return;
    }
    _unsupported($field, $index);
}
sub _translate {
    my ($validator, $field, $index) = @_;
    _unsupported($field, $index) unless ref($validator) eq 'ARRAY' && @$validator == 2
        && defined($validator->[0]) && !defined(reftype($validator->[0]));
    my ($kind, $payload) = @$validator;
    if ($kind eq 'number') {
        _unsupported($field, $index) unless ref($payload) eq 'ARRAY' && @$payload;
        my @tests;
        for my $pair (@$payload) {
            _spend();
            _unsupported($field, $index) unless ref($pair) eq 'ARRAY' && @$pair == 2
                && defined($pair->[0]) && !defined(reftype($pair->[0])) && exists($NUMBER{$pair->[0]});
            my $bound = $pair->[1];
            _unsupported($field, $index) unless defined($bound) && !defined(reftype($bound))
                && (_integer_scalar($bound) || _binary_scalar($bound));
            # Preserve an authored binary operand after harmless caller-side
            # numeric observation has added an integer flag to the same SV.
            $bound = substr($bound, 0) if _binary_scalar($bound);
            push @tests, {op => $NUMBER{$pair->[0]}, bound => $bound};
        }
        return @tests == 1 ? $tests[0] : {op => 'all', rules => \@tests};
    }
    if ($kind eq 'length') {
        _unsupported($field, $index) unless ref($payload) eq 'ARRAY';
        my $test = {op => 'text.length', unit => 'unicode_scalar'};
        my %keys = (is => 'exact', min => 'min', max => 'max');
        for my $pair (@$payload) {
            _spend();
            _unsupported($field, $index) unless ref($pair) eq 'ARRAY' && @$pair == 2
                && defined($pair->[0]) && !defined(reftype($pair->[0])) && exists($keys{$pair->[0]})
                && _integer_scalar($pair->[1]);
            $test->{$keys{$pair->[0]}} = $pair->[1]; # Elixir Keyword reduction: last value wins.
        }
        return $test;
    }
    if ($kind eq 'format') {
        _unsupported($field, $index) unless ref($payload) eq 'HASH'
            && !grep { $_ ne 'source' && $_ ne 'opts' } keys %$payload;
        _unsupported($field, $index) unless exists($payload->{source}) && exists($payload->{opts})
            && defined($payload->{source}) && !defined(reftype($payload->{source}))
            && Selecto::RuleTest::kind($payload->{source}) eq 'text'
            && (defined($payload->{opts}) && !defined(reftype($payload->{opts})) && $payload->{opts} eq ''
                || ref($payload->{opts}) eq 'ARRAY' && !@{$payload->{opts}});
        return {op => 'text.pattern', profile => 'ascii_v1', pattern => $payload->{source}, match => 'full', flags => []};
    }
    if ($kind eq 'inclusion' || $kind eq 'exclusion') {
        _unsupported($field, $index) unless ref($payload) eq 'ARRAY' && @$payload;
        _portable_literal($_, $field, $index) for @$payload;
        return {op => $kind eq 'inclusion' ? 'membership.in' : 'membership.not_in', values => $payload};
    }
    _unsupported($field, $index);
}
sub _compile_test {
    my ($test, $field, $index) = @_;
    my $compiled;
    my $ok = eval { $compiled = Selecto::RuleTest->compile($test, _current_limits(), 0, $BUDGET->{work}); 1 };
    unless ($ok) {
        my $error = $@;
        die $error unless ref($error) eq 'Selecto::Error';
        die $error if $error->code eq 'evaluation_limit';
        _unsupported($field, $index);
    }
    return $compiled;
}
sub _compile_fields {
    my ($specs, $fields) = @_;
    my (%tests, %prepared);
    my $output = {nodes => 1, bytes => 0, active => {}};
    for my $field (@$fields) {
        next unless exists $specs->{$field};
        my $spec = $specs->{$field};
        _unsupported($field) unless ref($spec) eq 'HASH';
        my $validators = exists($spec->{validators}) ? $spec->{validators} : [];
        _unsupported($field) unless ref($validators) eq 'ARRAY';
        for my $index (0 .. $#$validators) {
            my $test = _translate($validators->[$index], $field, $index);
            # Charge emitted occurrences before storing another generated AST.
            _walk($output, {$field => []}, 0) unless exists $tests{$field};
            _walk($output, $test, 0);
            my $compiled = _compile_test($test, $field, $index);
            $compiled->{legacy_number} = 1 if $validators->[$index][0] eq 'number';
            push @{$prepared{$field}}, $compiled;
            push @{$tests{$field}}, $test;
        }
    }
    return (\%tests, \%prepared);
}
sub _fields {
    my ($specs, $opts) = @_;
    _unsupported() if exists($opts->{fields}) && exists($opts->{assigned_fields});
    my $fields = exists($opts->{fields}) ? $opts->{fields}
        : exists($opts->{assigned_fields}) ? $opts->{assigned_fields} : [sort keys %$specs];
    _unsupported() unless ref($fields) eq 'ARRAY';
    my %seen;
    _unsupported() if grep { !defined($_) || defined(reftype($_)) || !length($_) || $seen{$_}++ } @$fields;
    return $fields;
}
sub admit {
    &_check_args;
    my ($class, $specs, %opts) = @_;
    _options(\%opts, qw(limits fields assigned_fields));
    return $class->with_budget(sub {
        my $copy = _plain({specs => $specs, map { $_ => $opts{$_} } grep { $_ ne 'limits' } keys %opts});
        $specs = $copy->{specs}; _unsupported() unless ref($specs) eq 'HASH';
        my ($tests) = _compile_fields($specs, _fields($specs, $copy));
        my $bundle = bless \(my $identity = undef), 'Selecto::Write::FieldValidators::Bundle';
        $BUNDLES{$bundle} = {specs => $specs, tests => $tests};
        return $bundle;
    }, limits => $opts{limits});
}
sub tests {
    &_check_args;
    my ($class, $bundle) = @_;
    _unsupported() unless ref($bundle) eq 'Selecto::Write::FieldValidators::Bundle' && exists $BUNDLES{$bundle};
    return _copy($BUNDLES{$bundle}{tests});
}
sub compile {
    &_check_args;
    my ($class, $validators, %opts) = @_;
    my $bundle = $class->admit({value => {validators => $validators}}, %opts);
    return $class->tests($bundle)->{value} // [];
}
sub validate_values {
    &_check_args;
    my ($class, $given, $values, %opts) = @_;
    _options(\%opts, qw(limits nonliteral_fields));
    return $class->with_budget(sub {
        my $specs = ref($given) eq 'Selecto::Write::FieldValidators::Bundle' && exists($BUNDLES{$given})
            ? $BUNDLES{$given}{specs} : $given;
        my $copy = _plain({specs => $specs, values => $values, nonliteral_fields => $opts{nonliteral_fields} // []});
        ($specs, $values) = @{$copy}{qw(specs values)};
        _unsupported() unless ref($specs) eq 'HASH' && ref($values) eq 'HASH';
        my $nonliteral = _fields({}, {fields => $copy->{nonliteral_fields}});
        my %fields = map { $_ => 1 } (keys %$values, @$nonliteral);
        my (undef, $prepared) = _compile_fields($specs, [sort keys %fields]);
        for my $field (@$nonliteral) {
            _fail('required_data_rule_pending', 'field validator requires a submitted literal value', $field)
                if @{$prepared->{$field} // []};
        }
        # Preflight every consumed value before the first result can fail.
        for my $field (sort keys %$prepared) {
            next unless exists $values->{$field};
            Selecto::RuleTest::check_value($values->{$field}, _current_limits(), $BUDGET->{work});
            Selecto::RuleTest->preflight($_, $values->{$field}, 1, _current_limits()) for @{$prepared->{$field}};
        }
        for my $field (sort keys %$prepared) {
            next unless exists $values->{$field};
            for my $index (0 .. $#{$prepared->{$field}}) {
                my $test = $prepared->{$field}[$index];
                # Legacy number subjects admit integer or decimal text, not
                # native floats. Delay this type failure until after the
                # complete consumed-value resource preflight above.
                _fail('data_rule_failed', 'write field validation failed', $field, $index, 'invalid_type')
                    if $test->{legacy_number} && !_integer_scalar($values->{$field}) && !_binary_scalar($values->{$field});
                my ($passed, $reason) = Selecto::RuleTest->evaluate($prepared->{$field}[$index], $values->{$field}, 1,
                    _current_limits(), $BUDGET->{work});
                _fail('data_rule_failed', 'write field validation failed', $field, $index, $reason) unless $passed;
            }
        }
        return $values;
    }, limits => $opts{limits});
}
sub evaluate { &_check_args; shift->validate_values(@_) }

package Selecto::Write::FieldValidators::_Scope;
sub DESTROY { Selecto::Write::FieldValidators::_scope_end() }

package Selecto::Write::FieldValidators::Bundle;
sub tests { Selecto::Write::FieldValidators->tests($_[0]) }

1;

__END__

=head1 NAME

Selecto::Write::FieldValidators - bounded legacy write validator translation

=head1 DESCRIPTION

Declarations use ordered C<[kind, payload]> tuples. C<number> accepts ordered
pairs for C<greater_than>, C<greater_than_or_equal_to>, C<less_than>, and
C<less_than_or_equal_to>; all comparisons apply. C<length> accepts integer
C<is>, C<min>, and C<max> pairs, with duplicate keys taking the last value.
C<format> accepts only C<< {source => 'ascii_v1 pattern', opts => ''} >> (or
an empty options array), compiled by the bounded portable NFA, never Perl regex.
C<inclusion> and C<exclusion> require a nonempty plain literal array.

C<prepare_contract> and C<admit_domain> admit and copy the entire recursive plain
declaration without interpreting inactive validators. C<admit(fields,
assigned_fields =E<gt> [...])> compiles every selected field before returning an
opaque owned bundle; omitting the selection explicitly inspects all fields.
C<compile(validators)> and C<bundle-E<gt>tests> return independent canonical ASTs.

C<validate_values(bundle_or_fields, normalized_assignments)> compiles all
effective assigned tests before evaluation and returns independent unchanged
values. It runs after INPUT and domain field normalization, before candidate
hydration/storage projection. Unassigned stored fields are ignored. Callers
unwrap genuine native literals; active expression fields must be named in
C<nonliteral_fields> and fail pending rather than silently bypass validation.

Trusted compiler/engine entry points use C<with_budget(sub {...}, limits =E<gt>
$limits)> around complete nested/graph/batch work. All bundles and nested scopes
share one cumulative RuleTest work counter; standalone calls start fresh.
Plain admission rejects hooks, ties, object metadata, cycles and amplification
before copying. Invalid forms fail C<unsupported_write_rule>, false tests fail
C<data_rule_failed>, and resource exhaustion fails C<evaluation_limit>.

=cut
