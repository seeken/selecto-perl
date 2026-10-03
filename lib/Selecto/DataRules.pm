package Selecto::DataRules;
use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Math::BigRat ();
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::OperationBudget ();
use Selecto::Pattern ();
use bytes ();
our $SCHEMA = 'selecto.data_rules.v1';

sub parse {
    my ($class, $raw, %options) = @_;
    my $limits = $options{limits} // Selecto::Limits->new;
    Selecto::OperationBudget->new(limits => $limits, code => 'invalid_data_rules_contract')->check_tree($raw, label => 'data rules contract');
    _hash($raw, 'invalid_data_rules_contract', 'data rules'); _keys($raw, [qw(schema definitions normalizers bindings)], 'data rules');
    _fail('invalid_data_rules_contract', 'unsupported data-rules schema') unless ($raw->{schema} // '') eq $SCHEMA;
    my (%definitions, %normalizers, %bindings);
    for my $id (keys %{_hash($raw->{definitions}, 'invalid_data_rules_contract', 'definitions')}) {
        _fail('invalid_data_rules_contract', 'definition id is invalid') unless _id($id);
        my $entry = $raw->{definitions}{$id}; _hash($entry, 'invalid_data_rules_contract', 'definition'); _keys($entry, [qw(version test message)], 'definition'); _positive($entry->{version}); my $prepared = _test($entry->{test}, $limits);
        $definitions{$id} = {version => $entry->{version}, test => dclone($entry->{test}), prepared => $prepared};
    }
    for my $id (keys %{_hash($raw->{normalizers}, 'invalid_data_rules_contract', 'normalizers')}) {
        _fail('invalid_data_rules_contract', 'normalizer id is invalid') unless _id($id);
        my $entry = $raw->{normalizers}{$id}; _hash($entry, 'invalid_data_rules_contract', 'normalizer'); _keys($entry, [qw(version steps)], 'normalizer'); _positive($entry->{version});
        _fail('invalid_data_rules_contract', 'normalizer steps are invalid') unless ref($entry->{steps}) eq 'ARRAY' && @{$entry->{steps}};
        for my $step (@{$entry->{steps}}) { _hash($step, 'invalid_data_rules_contract', 'normalizer step'); _keys($step, [qw(op profile)], 'normalizer step'); my $ok = ($step->{op}//'') eq 'text.trim' && (($step->{profile}//'') eq 'ascii_v1' || ($step->{profile}//'') eq 'ascii_whitespace_v1'); $ok ||= (($step->{op}//'') eq 'text.uppercase' || ($step->{op}//'') eq 'text.lowercase') && ($step->{profile}//'') eq 'ascii_v1'; _fail('invalid_data_rules_contract', 'normalizer step is unsupported') unless $ok; }
        $normalizers{$id} = {version => $entry->{version}, steps => dclone($entry->{steps})};
    }
    for my $id (keys %{_hash($raw->{bindings}, 'invalid_data_rules_contract', 'bindings')}) {
        _fail('invalid_data_rules_contract', 'binding id is invalid') unless _id($id);
        my $entry = $raw->{bindings}{$id}; _hash($entry, 'invalid_data_rules_contract', 'binding'); _keys($entry, [qw(subject operations rule normalizer condition enforcement)], 'binding');
        _fail('unsupported_rule_operator', 'binding condition is unsupported') if exists $entry->{condition};
        my $subject = $entry->{subject}; _hash($subject, 'invalid_data_rules_contract', 'subject'); _keys($subject, [qw(scope path action)], 'subject'); my $scope = $subject->{scope}//''; my $path = _path($subject->{path});
        my $action_ok = defined($subject->{action}) && _id($subject->{action}); _fail('invalid_data_rules_contract', 'subject is invalid') unless $scope =~ /\A(?:input|action_input|candidate|transaction|evidence)\z/ && (($scope eq 'action_input') == $action_ok);
        my $rule = _ref($entry->{rule}); _fail('unresolved_rule_reference', 'rule reference does not resolve') unless exists($definitions{$rule->{id}}) && $definitions{$rule->{id}}{version} == $rule->{version};
        my $ops = $entry->{operations}//[]; _fail('invalid_data_rules_contract', 'operations are invalid') unless ref($ops) eq 'ARRAY'; my %seen; _fail('invalid_data_rules_contract', 'operations are invalid') if grep { !defined($_) || !/\A(?:insert|update|delete|upsert)\z/ || $seen{$_}++ } @$ops;
        my $normalizer; if (exists $entry->{normalizer}) { $normalizer = _ref($entry->{normalizer}); _fail('unresolved_rule_reference', 'normalizer reference does not resolve') unless exists($normalizers{$normalizer->{id}}) && $normalizers{$normalizer->{id}}{version} == $normalizer->{version}; }
        $bindings{$id} = {subject => {scope => $scope, path => $path, (defined($subject->{action}) ? (action => $subject->{action}) : ())}, operations => [@$ops], rule => $rule, (defined($normalizer) ? (normalizer => $normalizer) : ())};
    }
    return bless {definitions => \%definitions, normalizers => \%normalizers, bindings => \%bindings, limits => $limits}, $class;
}

sub evaluate {
    my ($self, %request) = @_;
    my $stage = $request{stage} // '';
    my $limits = defined($request{limits}) ? $self->{limits}->intersect($request{limits}) : $self->{limits};
    my $subject_value = _hash($request{subject}, 'invalid_data_rules_request', 'subject');
    # Admission must precede dclone. On failure do not echo or clone the rejected
    # tree into an error response.
    my $admitted = eval {
        Selecto::OperationBudget->new(limits => $limits, code => 'evaluation_limit')
            ->check_tree($subject_value, label => 'rule subject');
        1;
    };
    return {state => 'failed', code => 'evaluation_limit', normalized => {}} unless $admitted;
    for my $binding (values %{$self->{bindings}}) {
        next unless $binding->{subject}{scope} eq $stage;
        next if @{$binding->{operations}} && !grep { $_ eq ($request{operation} // '') } @{$binding->{operations}};
        next if $stage eq 'action_input' && ($binding->{subject}{action} // '') ne ($request{action} // '');
        my ($value, $present) = _at($subject_value, $binding->{subject}{path});
        next unless $present && defined($value) && !ref($value);
        my $test = $self->{definitions}{$binding->{rule}{id}}{test};
        if (($test->{op} eq 'text.pattern' && bytes::length($value) > 4096)
            || ($test->{op} eq 'number.gt' && _decimal_limit($value, $limits))) {
            return {state => 'failed', code => 'evaluation_limit', normalized => {}, path => [@{$binding->{subject}{path}}]};
        }
    }
    my $normalized = dclone($subject_value);
    my $work = 0;
    for my $id (sort keys %{$self->{bindings}}) {
        my $binding = $self->{bindings}{$id};
        my $subject = $binding->{subject};
        next unless $subject->{scope} eq $stage;
        next if @{$binding->{operations}} && !grep { $_ eq ($request{operation} // '') } @{$binding->{operations}};
        next if $stage eq 'action_input' && ($subject->{action} // '') ne ($request{action} // '');
        my $path = $subject->{path};
        return _result('pending', $normalized, 'authoritative_stage_required', $path)
            if ($stage eq 'transaction' || $stage eq 'evidence') && ($request{authoritative_stage} // '') ne $stage;
        my ($value, $present) = _at($normalized, $path);
        if (my $normalizer = $binding->{normalizer}) {
            my ($next, $code) = _normalize($value, $present, $self->{normalizers}{$normalizer->{id}});
            return _result('failed', $normalized, $code, $path) if defined $code;
            _set($normalized, $path, $next); ($value, $present) = ($next, 1);
        }
        my $definition = $self->{definitions}{$binding->{rule}{id}};
        my ($passed, $code) = _evaluate($definition->{test}, $value, $present, $definition->{prepared}, $limits, \$work);
        return _result('failed', $normalized, $code, $path) unless $passed;
    }
    return _result('passed', $normalized);
}

sub _test {
    my ($t, $limits) = @_;
    _hash($t, 'invalid_data_rules_contract', 'definition test');
    my $op = $t->{op} // '';
    _fail('unsupported_rule_operator', 'rule operator is unsupported')
        unless $op =~ /\A(?:number\.gt|text\.pattern|collection\.count|collection\.unique_by|value\.eq)\z/;
    if ($op eq 'number.gt') {
        _keys($t, [qw(op bound)], 'number rule');
        _fail('invalid_data_rules_contract', 'number bound exceeds its digit budget') if _decimal_limit($t->{bound}, $limits);
        my $bound = _decimal($t->{bound});
        _fail('invalid_data_rules_contract', 'number bound is invalid') unless defined $bound;
        return {bound => $bound};
    }
    if ($op eq 'text.pattern') {
        _keys($t, [qw(op profile pattern match flags)], 'pattern rule');
        _fail('invalid_text_pattern', 'pattern is outside ascii_v1')
            unless ($t->{profile} // '') eq 'ascii_v1' && ($t->{match} // '') =~ /\A(?:full|search)\z/
                && ref($t->{flags}) eq 'ARRAY' && !@{$t->{flags}};
        return {pattern => Selecto::Pattern->compile($t->{pattern}, limits => $limits)};
    }
    if ($op eq 'collection.count') {
        _keys($t, [qw(op exact min max)], 'collection count rule');
        my ($e, $n, $x) = map { _nonneg($t->{$_}) } qw(exact min max);
        _fail('invalid_data_rules_contract', 'collection bounds are invalid')
            if (!defined($e) && !defined($n) && !defined($x))
                || (defined($e) && (defined($n) || defined($x))) || (defined($n) && defined($x) && $n > $x);
    } elsif ($op eq 'collection.unique_by') {
        _keys($t, [qw(op paths)], 'collection uniqueness rule');
        _fail('invalid_data_rules_contract', 'collection paths are invalid') unless ref($t->{paths}) eq 'ARRAY' && @{$t->{paths}};
        my %seen;
        for (@{$t->{paths}}) { my $key = join("\0", @{_path($_)}); _fail('invalid_data_rules_contract', 'collection paths are invalid') if $seen{$key}++ }
    } else { _keys($t, [qw(op value)], 'equality rule') }
    return {};
}

sub _evaluate {
    my ($t, $v, $present, $prepared, $limits, $work) = @_;
    return (0, 'evaluation_limit') if ++$$work > $limits->get('max_rule_work');
    return (0, 'invalid_type') unless $present && defined $v;
    my $op = $t->{op};
    if ($op eq 'number.gt') {
        return (0, 'evaluation_limit') if _decimal_limit($v, $limits) || _decimal_limit($t->{bound}, $limits);
        $$work += !ref($v) ? bytes::length($v) : 0;
        return (0, 'evaluation_limit') if $$work > $limits->get('max_rule_work');
        my $a = _decimal($v);
        return (0, 'invalid_type') unless defined $a;
        return ($a > $prepared->{bound} ? 1 : 0, 'numeric_bound');
    }
    if ($op eq 'text.pattern') {
        return (0, 'invalid_type') if ref $v;
        my ($match, $code) = $prepared->{pattern}->matches($v, match => $t->{match}, limits => $limits, work_ref => $work);
        return (0, $code) if defined $code;
        return ($match ? 1 : 0, 'pattern_mismatch');
    }
    if ($op eq 'collection.count') {
        return (0, 'invalid_type') unless ref($v) eq 'ARRAY';
        my ($e, $n, $x) = map { _nonneg($t->{$_}) } qw(exact min max);
        return ((!defined($e) || @$v == $e) && (!defined($n) || @$v >= $n) && (!defined($x) || @$v <= $x) ? 1 : 0, 'invalid_collection_count');
    }
    if ($op eq 'collection.unique_by') {
        return (0, 'invalid_type') unless ref($v) eq 'ARRAY';
        $$work += @$v * @{$t->{paths}};
        return (0, 'evaluation_limit') if $$work > $limits->get('max_rule_work');
        my %seen;
        for my $item (@$v) {
            return (0, 'invalid_collection_item') unless ref($item) eq 'HASH';
            my @tuple;
            for (@{$t->{paths}}) { my ($part, $found) = _at($item, _path($_)); return (0, 'invalid_collection_item') unless $found; push @tuple, $part }
            my $key = _stable(\@tuple);
            return (0, 'duplicate_collection_value') if $seen{$key}++;
        }
        return (1, undef);
    }
    return (_stable($v) eq _stable($t->{value}) ? 1 : 0, 'not_equal');
}

# Count every integer/fraction digit as work, including fractional leading
# zeros; signs and decimal separators do not consume the digit allowance.
# Bound bytes first so no attacker-sized syntax check or BigRat allocation runs.
sub _decimal_limit {
    my ($value, $limits) = @_;
    return 0 if !defined($value) || ref($value);
    my $maximum = $limits->get('max_rule_numeric_digits');
    return 1 if bytes::length($value) > $maximum + 2;
    my $digits = $value =~ tr/0-9/0-9/;
    return $digits > $maximum;
}

sub _normalize { my($v,$present,$n)=@_;return(undef,'invalid_type')unless$present;my$c=$v;for my$s(@{$n->{steps}}){return(undef,'invalid_type')if ref$c;if($s->{op}eq'text.trim'){$c=~s/\A[ \t\r\n\f\v]+|[ \t\r\n\f\v]+\z//g}else{return(undef,'normalization_error')unless$c=~/\A[\x00-\x7F]*\z/;$c=$s->{op}eq'text.uppercase'?uc$c:lc$c}}return($c,undef) }
sub _hash { my($v,$code,$label)=@_;_fail($code,"$label must be an object")unless ref$v eq'HASH';return$v } sub _keys {my($v,$a,$l)=@_;my%a=map{$_=>1}@$a;_fail('unknown_rule_option',"unknown member in $l")if grep{!$a{$_}}keys%$v} sub _id{defined($_[0])&&!ref($_[0])&&$_[0]=~/\A[A-Za-z_][A-Za-z0-9_]*\z/} sub _positive{_fail('invalid_rule_version','version must be a positive integer')unless defined($_[0])&&!ref($_[0])&&$_[0]=~/\A[1-9][0-9]*\z/;$_[0]} sub _nonneg{defined($_[0])&&!ref($_[0])&&$_[0]=~/\A(?:0|[1-9][0-9]*)\z/?$_[0]:undef} sub _ref{my$v=_hash($_[0],'invalid_data_rules_contract','reference');_keys($v,[qw(id version)],'reference');_fail('invalid_data_rules_contract','reference id is invalid')unless _id($v->{id});{id=>$v->{id},version=>_positive($v->{version})}} sub _path{my$v=$_[0];_fail('invalid_data_rules_contract','path is invalid')unless ref$v eq'ARRAY'&&@$v&&!grep{!defined($_)||ref($_)||$_ eq''}@$v;[@$v]} sub _at{my($r,$p)=@_;my$c=$r;for(@$p){return(undef,0)unless ref$c eq'HASH'&&exists$c->{$_};$c=$c->{$_}}($c,1)}sub _set{my($r,$p,$v)=@_;my$c=$r;for my$k(@$p[0..$#$p-1]){$c->{$k}={}unless ref$c->{$k}eq'HASH';$c=$c->{$k}}$c->{$p->[-1]}=$v}sub _decimal{my$v=$_[0];return undef unless defined$v&&!ref$v&&"$v"=~/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/;Math::BigRat->new("$v")}sub _stable{JSON::PP->new->canonical(1)->encode($_[0])}sub _result{my($s,$n,$c,$p)=@_;{state=>$s,normalized=>dclone($n),(defined$c?(code=>$c):()),(defined$p?(path=>[@$p]):())}}sub _fail{Selecto::Error->throw(@_)}
1;

__END__

=head1 NAME

Selecto::DataRules - versioned validation rules declared in a domain

=head1 DESCRIPTION

Parses the C<rules> section of a domain contract (schema
C<selecto.data_rules.v1>: rule definitions, normalizers and bindings to write
inputs) and evaluates a subject against the bindings for one stage.

Parsing accepts a trusted C<limits> option. Evaluation can further tighten it
with C<limits>; request data must never configure this option. Subject trees
are admitted before cloning. Oversized subjects return C<evaluation_limit>
with an empty normalized object, avoiding a copy of rejected input. Exact
numbers count all integer and fractional digits (default 1024), excluding sign
and decimal separator. Trusted bounds are compiled once. Pattern evaluation
uses L<Selecto::Pattern>, a bounded Thompson NFA preserving C<ascii_v1> regular
language semantics. Pattern subject size is 4096 UTF-8 bytes. Compiled-state
and shared per-evaluation work budgets also apply; very large counted
repetitions can fail contract admission even when syntactically regular.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
