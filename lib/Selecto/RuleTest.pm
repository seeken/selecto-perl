package Selecto::RuleTest;
use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Math::BigRat ();
use Math::BigFloat ();
use Scalar::Util qw(blessed);
use bytes ();
use Selecto::Error ();
use Selecto::Pattern ();

# Closed, driver-free portable AST. Work is shared by every binding, logical
# branch, normalizer and exact arithmetic operation in one evaluation.
sub _fail { Selecto::Error->throw(@_) }
sub spend {
    my ($limits, $work, $amount) = @_;
    $$work += $amount // 1;
    _fail('evaluation_limit', 'portable rule work budget exceeded')
        if $$work > $limits->get('max_rule_work');
}
sub kind {
    my ($value) = @_;
    return 'null' unless defined $value;
    return 'boolean' if JSON::PP::is_bool($value);
    return 'collection' if ref($value) eq 'ARRAY';
    return 'object' if ref($value) eq 'HASH';
    return 'unsupported' if ref $value;
    my $wire = JSON::PP->new->allow_nonref->encode($value);
    return substr($wire, 0, 1) eq '"' ? 'text' : 'number';
}
sub text {
    my ($value, $limits, $work, $code) = @_;
    check_text($value, $code);
    spend($limits, $work, bytes::length($value) + 1);
    return $value;
}
sub check_text {
    my ($value, $code) = @_;
    _fail($code // 'invalid_type', 'rule requires text') unless kind($value) eq 'text';
    _fail('evaluation_limit', 'rule text exceeds its byte limit') if bytes::length($value) > 4096;
    _fail('invalid_data_rules_contract', 'invalid Unicode scalar text') if $value =~ /[\x{D800}-\x{DFFF}]/;
    return $value;
}
sub number {
    my ($value, $limits, $work, $literal) = @_;
    return undef if !defined($value) || ref($value);
    my $kind = kind($value);
    my $maximum = $limits->get('max_rule_numeric_digits');
    if (!$literal && $kind eq 'number' && "$value" =~ /\A(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?)[eE]([+-]?[0-9]+)\z/) {
        _fail('evaluation_limit', 'native number exponent exceeds its digit limit')
            if bytes::length($value) > $maximum + 2 || length($2) > 5 || abs($2) > $maximum;
        $value = Math::BigFloat->new("$value")->bstr;
    }
    _fail($literal ? 'invalid_data_rules_contract' : 'evaluation_limit', 'rule number exceeds its digit limit')
        if bytes::length($value) > $maximum + 2 || ($value =~ tr/0-9/0-9/) > $maximum;
    return undef unless "$value" =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/;
    spend($limits, $work, bytes::length($value) + 1);
    my $number = Math::BigRat->new("$value");
    if ($literal && $kind eq 'number') {
        _fail('invalid_data_rules_contract', 'exact JSON operands must be interoperable integers')
            unless "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/
                && $number->copy->babs->bcmp('9007199254740991') <= 0;
    }
    return $number;
}
sub check_value {
    my ($value, $limits, $work, $depth) = @_;
    $depth //= 0;
    spend($limits, $work);
    _fail('evaluation_limit', 'rule value exceeds its depth limit') if $depth > 32;
    my $kind = kind($value);
    if ($kind eq 'text') { text($value, $limits, $work) }
    elsif ($kind eq 'number') {
        _fail('evaluation_limit', 'rule number exceeds its digit limit')
            if bytes::length($value) > $limits->get('max_rule_numeric_digits') + 2;
    } elsif ($kind eq 'collection' || $kind eq 'object') {
        my $size = $kind eq 'collection' ? @$value : keys %$value;
        _fail('evaluation_limit', 'rule collection exceeds its bound') if $size > 1000;
        if ($kind eq 'collection') { check_value($_, $limits, $work, $depth + 1) for @$value }
        else { for my $key (keys %$value) { text($key, $limits, $work); check_value($value->{$key}, $limits, $work, $depth + 1) } }
    } elsif ($kind eq 'unsupported') { _fail('invalid_data_rules_contract', 'unsupported rule value') }
}
sub _keys {
    my ($test, @keys) = @_;
    _fail('invalid_data_rules_contract', 'rule test must be an object') unless ref($test) eq 'HASH';
    my %allowed = map { ($_ => 1) } @keys;
    _fail('unknown_rule_option', 'unknown rule option') if grep { !$allowed{$_} } keys %$test;
}
sub _path {
    my $path = $_[0];
    _fail('invalid_data_rules_contract', 'invalid semantic path') unless ref($path) eq 'ARRAY' && @$path
        && !grep { !defined($_) || ref($_) || !length($_) } @$path;
    return [@$path];
}
sub _operand {
    my ($value, $limits, $work) = @_;
    my $number = number($value, $limits, $work, 1);
    _fail('invalid_data_rules_contract', 'invalid exact numeric operand') unless defined $number;
    return $number;
}
sub _bounds {
    my ($test, $limits, $work, $count) = @_;
    my %bounds;
    for my $key (qw(exact min max)) {
        next unless exists $test->{$key};
        my $n = _operand($test->{$key}, $limits, $work);
        _fail('invalid_data_rules_contract', 'invalid count bound')
            if $count && ($n->is_neg || !$n->is_int || "$test->{$key}" !~ /\A(?:0|[1-9][0-9]*)\z/);
        $bounds{$key} = $n;
    }
    _fail('invalid_data_rules_contract', 'invalid rule bounds') if !keys(%bounds)
        || exists($bounds{exact}) && keys(%bounds) != 1
        || exists($bounds{min}) && exists($bounds{max}) && $bounds{min}->bcmp($bounds{max}) > 0;
    return \%bounds;
}
sub _literal {
    my ($value, $limits, $work, $depth) = @_;
    check_value($value, $limits, $work, $depth);
    my $kind = kind($value);
    if ($kind eq 'number') { _operand($value, $limits, $work) }
    elsif ($kind eq 'collection') { _literal($_, $limits, $work, $depth + 1) for @$value }
    elsif ($kind eq 'object') { _literal($_, $limits, $work, $depth + 1) for values %$value }
}
sub compile {
    my ($class, $test, $limits, $depth, $work) = @_;
    $depth //= 0; $work //= \(my $counter = 0);
    _fail('invalid_data_rules_contract', 'logical rule depth exceeds 16') if $depth > 16;
    spend($limits, $work);
    _fail('invalid_data_rules_contract', 'rule test must be an object') unless ref($test) eq 'HASH';
    my $op = $test->{op} // '';
    my $prepared = {op => $op, test => $test};
    if ($op =~ /\A(?:presence\.(?:required|non_null|absent)|text\.nonblank|number\.integer)\z/) { _keys($test, 'op') }
    elsif ($op eq 'type.is') {
        _keys($test, qw(op type));
        _fail('invalid_data_rules_contract', 'invalid portable type')
            unless ($test->{type} // '') =~ /\A(?:boolean|integer|decimal|text|string|collection|object)\z/;
    } elsif ($op eq 'text.length' || $op eq 'collection.count' || $op eq 'collection.sum') {
        _keys($test, qw(op exact min max), $op eq 'text.length' ? 'unit' : $op eq 'collection.sum' ? 'path' : ());
        _fail('invalid_data_rules_contract', 'invalid text length unit') if exists($test->{unit}) && $test->{unit} ne 'unicode_scalar';
        $prepared->{bounds} = _bounds($test, $limits, $work, $op ne 'collection.sum');
        $prepared->{path} = _path($test->{path}) if $op eq 'collection.sum';
    } elsif ($op eq 'text.pattern') {
        _keys($test, qw(op profile pattern match flags));
        _fail('invalid_text_pattern', 'invalid ascii_v1 pattern options') unless ($test->{profile} // '') eq 'ascii_v1'
            && ($test->{match} // '') =~ /\A(?:full|search)\z/ && ref($test->{flags}) eq 'ARRAY' && !@{$test->{flags}};
        $prepared->{pattern} = Selecto::Pattern->compile($test->{pattern}, limits => $limits);
    } elsif ($op =~ /\Atext\.(?:prefix|suffix|contains)\z/) {
        _keys($test, qw(op text)); text($test->{text}, $limits, $work, 'invalid_data_rules_contract');
    } elsif ($op =~ /\Anumber\.(?:gt|gte|lt|lte)\z/) {
        _keys($test, qw(op bound)); $prepared->{bound} = _operand($test->{bound}, $limits, $work);
    } elsif ($op eq 'number.range') {
        _keys($test, qw(op min max include_min include_max));
        $prepared->{$_} = _operand($test->{$_}, $limits, $work) for qw(min max);
        _fail('invalid_data_rules_contract', 'reversed range') if $prepared->{min}->bcmp($prepared->{max}) > 0;
        for (qw(include_min include_max)) { _fail('invalid_data_rules_contract', 'range inclusion must be Boolean')
            if exists($test->{$_}) && !JSON::PP::is_bool($test->{$_}) }
    } elsif ($op eq 'number.multiple_of') {
        _keys($test, qw(op factor)); $prepared->{factor} = _operand($test->{factor}, $limits, $work);
        _fail('invalid_data_rules_contract', 'zero multiple factor') if $prepared->{factor}->is_zero;
    } elsif ($op eq 'membership.in' || $op eq 'membership.not_in') {
        _keys($test, qw(op values));
        _fail('invalid_data_rules_contract', 'membership requires bounded values') unless ref($test->{values}) eq 'ARRAY'
            && @{$test->{values}} && @{$test->{values}} <= 1000;
        _literal($_, $limits, $work, 0) for @{$test->{values}};
    } elsif ($op eq 'value.eq' || $op eq 'value.neq') {
        _keys($test, qw(op value)); _fail('invalid_data_rules_contract', 'equality requires a literal') unless exists $test->{value};
        _literal($test->{value}, $limits, $work, 0);
    } elsif ($op eq 'collection.unique_by') {
        _keys($test, qw(op paths));
        _fail('invalid_data_rules_contract', 'unique_by requires bounded paths') unless ref($test->{paths}) eq 'ARRAY'
            && @{$test->{paths}} && @{$test->{paths}} <= 1000;
        my %seen;
        for (@{$test->{paths}}) { my $path = _path($_); my $key = JSON::PP->new->encode($path);
            _fail('invalid_data_rules_contract', 'duplicate unique_by path') if $seen{$key}++ }
    } elsif ($op eq 'all' || $op eq 'any') {
        _keys($test, qw(op rules));
        _fail('invalid_data_rules_contract', 'logical rule requires bounded children') unless ref($test->{rules}) eq 'ARRAY'
            && @{$test->{rules}} && @{$test->{rules}} <= 1000;
        $prepared->{children} = [map { $class->compile($_, $limits, $depth + 1, $work) } @{$test->{rules}}];
    } elsif ($op eq 'not') { _keys($test, qw(op rule)); $prepared->{children} = [$class->compile($test->{rule}, $limits, $depth + 1, $work)] }
    else { _fail('unsupported_rule_operator', 'unsupported portable rule operator') }
    return $prepared;
}
sub at {
    my ($value, $path) = @_;
    for (@$path) { return (undef, 0) unless ref($value) eq 'HASH' && exists $value->{$_}; $value = $value->{$_} }
    return ($value, 1);
}
sub preflight {
    my ($class, $prepared, $value, $present, $limits) = @_;
    my $op = $prepared->{op};
    if ($op =~ /\Anumber\./ && $present && defined($value) && !ref($value)) {
        _fail('evaluation_limit', 'rule number exceeds its digit limit')
            if bytes::length($value) > $limits->get('max_rule_numeric_digits') + 2
                || ($value =~ tr/0-9/0-9/) > $limits->get('max_rule_numeric_digits');
    }
    if ($op eq 'collection.sum' && ref($value) eq 'ARRAY') {
        for (@$value) { my ($part, $found) = at($_, $prepared->{path});
            $class->preflight({op => 'number.gt'}, $part, $found, $limits) }
    }
    $class->preflight($_, $value, $present, $limits) for @{$prepared->{children} // []};
}
sub equal {
    my ($left, $right, $limits, $work) = @_;
    spend($limits, $work);
    my ($a, $b) = (kind($left), kind($right));
    return 0 unless $a eq $b;
    return 1 if $a eq 'null';
    return ($left ? 1 : 0) == ($right ? 1 : 0) if $a eq 'boolean';
    if ($a eq 'number') { my ($x, $y) = map { number($_, $limits, $work, 0) } ($left, $right); return defined($x) && defined($y) && $x->bcmp($y) == 0 }
    if ($a eq 'text') { spend($limits, $work, bytes::length($left) + bytes::length($right)); return $left eq $right }
    if ($a eq 'collection') { return 0 unless @$left == @$right; my $same = 1;
        for (0 .. $#$left) { $same &= equal($left->[$_], $right->[$_], $limits, $work) } return $same }
    if ($a eq 'object') { return 0 unless keys(%$left) == keys(%$right); my $same = 1;
        for (keys %$left) { $same &= exists($right->{$_}) && equal($left->{$_}, $right->{$_}, $limits, $work) } return $same }
    return 0;
}
sub _within {
    my ($bounds, $value) = @_;
    return (!exists($bounds->{exact}) || $value->bcmp($bounds->{exact}) == 0)
        && (!exists($bounds->{min}) || $value->bcmp($bounds->{min}) >= 0)
        && (!exists($bounds->{max}) || $value->bcmp($bounds->{max}) <= 0);
}
sub evaluate {
    my ($class, $prepared, $value, $present, $limits, $work) = @_;
    spend($limits, $work);
    my ($op, $test) = @{$prepared}{qw(op test)};
    if ($op eq 'all' || $op eq 'any') {
        my ($passed, $failure) = (0, undef);
        for my $child (@{$prepared->{children}}) { my ($ok, $code) = $class->evaluate($child, $value, $present, $limits, $work);
            $passed ||= $ok; $failure //= $code unless $ok }
        return $op eq 'all' ? (!defined($failure), $failure) : ($passed, $passed ? undef : 'no_rule_matched');
    }
    if ($op eq 'not') { my ($ok) = $class->evaluate($prepared->{children}[0], $value, $present, $limits, $work);
        return (!$ok, $ok ? 'negated_rule_matched' : undef) }
    return ($present, $present ? undef : 'required') if $op eq 'presence.required';
    return ($present && defined($value), $present && defined($value) ? undef : 'null') if $op eq 'presence.non_null';
    return (!$present, $present ? 'forbidden' : undef) if $op eq 'presence.absent';
    return (0, 'invalid_type') unless $present;
    if ($op eq 'value.eq' || $op eq 'value.neq') { my $same = equal($value, $test->{value}, $limits, $work);
        return $op eq 'value.eq' ? ($same, $same ? undef : 'not_equal') : (!$same, $same ? 'equal_to_excluded' : undef) }
    if ($op eq 'membership.in' || $op eq 'membership.not_in') { my $same = 0;
        for (@{$test->{values}}) { $same |= equal($value, $_, $limits, $work) }
        return $op eq 'membership.in' ? ($same, $same ? undef : 'not_included') : (!$same, $same ? 'excluded' : undef) }
    return (0, 'invalid_type') unless defined $value;
    my $kind = kind($value);
    if ($op eq 'type.is') {
        my $type = $test->{type}; $type = 'text' if $type eq 'string';
        my $numeric = $kind eq 'number' && ($type eq 'integer' || $type eq 'decimal')
            ? number($value, $limits, $work, 0) : undef;
        my $ok = $type eq 'integer' ? defined($numeric) && $numeric->is_int
            : $type eq 'decimal' ? defined($numeric) : $kind eq $type;
        return ($ok, $ok ? undef : 'invalid_type');
    }
    if ($op =~ /\Atext\./) {
        return (0, 'invalid_type') unless $kind eq 'text';
        text($value, $limits, $work);
        my ($ok, $code);
        if ($op eq 'text.nonblank') { $ok = $value =~ /[^\p{White_Space}]/; $code = 'blank' }
        elsif ($op eq 'text.length') { $ok = _within($prepared->{bounds}, Math::BigRat->new(length($value))); $code = 'invalid_text_length' }
        elsif ($op eq 'text.pattern') { my ($match, $error) = $prepared->{pattern}->matches($value,
            match => $test->{match}, limits => $limits, work_ref => $work);
            _fail('evaluation_limit', 'portable pattern budget exceeded') if defined($error) && $error eq 'evaluation_limit';
            return ($match, $error // ($match ? undef : 'pattern_mismatch')) }
        else { my $needle = $test->{text}; $code = 'text_mismatch';
            $ok = $op eq 'text.prefix' ? index($value, $needle) == 0
                : $op eq 'text.suffix' ? length($needle) <= length($value) && substr($value, length($value) - length($needle)) eq $needle
                : index($value, $needle) >= 0 }
        return ($ok ? 1 : 0, $ok ? undef : $code);
    }
    if ($op =~ /\Anumber\./) {
        my $number = number($value, $limits, $work, 0); return (0, 'invalid_type') unless defined $number;
        my ($ok, $code);
        if ($op eq 'number.integer') { $ok = $number->is_int; $code = 'not_integer' }
        elsif ($op eq 'number.range') { my ($min, $max) = ($number->bcmp($prepared->{min}), $number->bcmp($prepared->{max}));
            $ok = (!exists($test->{include_min}) || $test->{include_min} ? $min >= 0 : $min > 0)
                && (!exists($test->{include_max}) || $test->{include_max} ? $max <= 0 : $max < 0); $code = 'numeric_range' }
        elsif ($op eq 'number.multiple_of') { my $factor = $prepared->{factor};
            spend($limits, $work, (length($number->numerator->bstr) + length($number->denominator->bstr))
                * (length($factor->numerator->bstr) + length($factor->denominator->bstr)));
            $ok = $number->copy->bdiv($factor)->is_int; $code = 'not_multiple' }
        else { my $cmp = $number->bcmp($prepared->{bound}); $code = 'numeric_bound';
            $ok = $op eq 'number.gt' ? $cmp > 0 : $op eq 'number.gte' ? $cmp >= 0 : $op eq 'number.lt' ? $cmp < 0 : $cmp <= 0 }
        return ($ok ? 1 : 0, $ok ? undef : $code);
    }
    return (0, 'invalid_type') unless $kind eq 'collection';
    if ($op eq 'collection.count') { my $ok = _within($prepared->{bounds}, Math::BigRat->new(scalar @$value)); return ($ok, $ok ? undef : 'invalid_collection_count') }
    if ($op eq 'collection.sum') {
        my $total = Math::BigRat->new(0);
        for (@$value) { my ($part, $found) = at($_, $prepared->{path}); return (0, 'missing_sum_field') unless $found;
            my $number = number($part, $limits, $work, 0); return (0, 'invalid_type') unless defined $number;
            spend($limits, $work, length($total->numerator->bstr) + length($total->denominator->bstr)
                + length($number->numerator->bstr) + length($number->denominator->bstr)); $total->badd($number) }
        my $ok = _within($prepared->{bounds}, $total); return ($ok, $ok ? undef : 'invalid_collection_sum');
    }
    my @seen;
    for my $row (@$value) { return (0, 'invalid_collection_item') unless ref($row) eq 'HASH'; my @tuple;
        for my $path (@{$test->{paths}}) { my ($part, $found) = at($row, $path); return (0, 'invalid_collection_item') unless $found; push @tuple, $part }
        for my $prior (@seen) { return (0, 'duplicate_collection_value') if equal(\@tuple, $prior, $limits, $work) }
        push @seen, \@tuple;
    }
    return (1, undef);
}
sub dependencies {
    my ($class, $prepared) = @_;
    my $op = $prepared->{op};
    my @paths;
    if ($op eq 'collection.sum') { push @paths, [{each => 1}, @{$prepared->{path}}] }
    elsif ($op eq 'collection.unique_by') { push @paths, [{each => 1}, @$_] for @{$prepared->{test}{paths}} }
    elsif ($op =~ /\A(?:value\.|membership\.)/) { push @paths, [{complete => 1}] }
    push @paths, @{$class->dependencies($_)} for @{$prepared->{children} // []};
    return \@paths;
}
1;
