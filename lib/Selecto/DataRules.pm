package Selecto::DataRules;
use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use JSON::PP ();
use Math::BigRat ();
use Selecto::Error ();
use Selecto::OperationBudget ();
use Selecto::Pattern ();
use Selecto::RuleTest ();
use Selecto::Limits ();
use Unicode::Normalize ();
use bytes ();
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed refaddr reftype);
our $SCHEMA = 'selecto.data_rules.v1';
my %BOOLEAN = map { $_ => 1 } qw(JSON::PP::Boolean JSON::XS::Boolean Types::Serialiser::Boolean);

# Storable may turn an NV-only 1.0 into an IV, or an exact unsigned IV into
# text. Admit and copy the plain tree together, inspecting each delivered
# scalar before any byte/string observation. The explicit stack bounds depth,
# repeated aliases and allocation; active-path references distinguish cycles
# from repeated, independently copied values.
sub _copy_plain {
    _fail($_[2], 'rule input contains tied metadata') if defined(tied($_[0]));
    my ($value, $limits, $code, $label) = @_;
    my $budget = Selecto::OperationBudget->new(limits => $limits, code => $code);
    $budget->consume_count('max_expression_nodes', 1, label => "$label nodes");
    my ($copy, %active);
    my @stack = ([\$value, \$copy, 0]);
    while (@stack) {
        my ($source, $target, $depth, $leave) = @{pop @stack};
        if ($leave) { delete $active{$leave}; next }
        $limits->check_count('max_expression_depth', $depth, $code, "$label depth");
        _fail($code, "$label contains tied metadata") if defined(tied($$source));
        my $node = $$source;
        my $type = reftype($node);
        unless (defined $type) {
            my $boolean = defined($node) && JSON::PP::is_bool($node);
            my $flags = defined($node) ? B::svref_2object(\$node)->FLAGS : 0;
            $budget->consume_count('max_state_bytes', defined($node) ? bytes::length($node) : 0,
                label => "$label bytes");
            if (!defined $node) { $$target = undef }
            elsif ($boolean) { my $bit = $node ? 1 : 0; $$target = bless \$bit, 'JSON::PP::Boolean' }
            elsif ($flags & B::SVf_POK()) { $$target = substr($node, 0) }
            elsif ($flags & B::SVf_IOK()) { $$target = 0 + $node }
            else {
                # Byte accounting may populate a numeric scalar's private
                # string cache. Produce a fresh NV in this build's exact
                # format so downstream literal admission still sees NV-only.
                $$target = unpack('F', pack('F', $node));
            }
            next;
        }
        my $class = blessed($node) // '';
        if ($BOOLEAN{$class} && $type eq 'SCALAR') {
            _fail($code, "$label contains an invalid Boolean") if defined(tied($$node))
                || !defined($$node) || defined(reftype($$node))
                || bytes::length($$node) != 1 || "$$node" !~ /\A[01]\z/;
            my $bit = $$node ? 1 : 0;
            $budget->consume_count('max_state_bytes', 1, label => "$label bytes");
            $$target = bless \$bit, 'JSON::PP::Boolean';
            next;
        }
        _fail($code, "$label contains an unsupported reference")
            if length($class) || ($type ne 'ARRAY' && $type ne 'HASH');
        _fail($code, "$label contains tied metadata")
            if $type eq 'HASH' ? defined(tied(%$node)) : defined(tied(@$node));
        my $address = refaddr($node);
        _fail($code, "$label contains a cycle") if $active{$address};
        $active{$address} = 1;
        my $count = $type eq 'HASH' ? scalar(keys %$node) : scalar(@$node);
        $budget->consume_count('max_expression_nodes', $count, label => "$label nodes");
        push @stack, [undef, undef, undef, $address];
        if ($type eq 'HASH') {
            my $result = {}; $$target = $result;
            for my $key (keys %$node) {
                $budget->consume_count('max_state_bytes', bytes::length($key), label => "$label bytes");
                _fail($code, "$label contains tied metadata") if defined(tied($node->{$key}));
                push @stack, [\$node->{$key}, \$result->{$key}, $depth + 1];
            }
        } else {
            my $result = []; $$target = $result;
            for my $index (reverse 0 .. $#$node) {
                _fail($code, "$label contains tied metadata") if defined(tied($node->[$index]));
                push @stack, [\$node->[$index], \$result->[$index], $depth + 1];
            }
        }
    }
    return $copy;
}
sub _check_untied_arguments {
    _fail('invalid_data_rules_contract', 'rule input contains tied metadata')
        if grep { defined(tied($_[$_])) } 0 .. $#_;
}

# Only the native engine opens this scope. It is not a request option or
# command metadata; nested previews, graph nodes and stages share the counter.
my $PROOF_WORK;
my ($PROOF_ID, $PROOF_ACCEPTED, $PROOF_LIMIT);
fieldhash my %MEASURED_WORK;
sub _with_proof_budget {
    my ($class, $work, %options) = @_;
    if ($PROOF_WORK) {
        $PROOF_LIMIT = $options{limits}->get('max_rule_work')
            if $options{limits} && $options{limits}->get('max_rule_work') < $PROOF_LIMIT;
        $class->_charge_accepted_work($options{accepted_work});
        return $work->();
    }
    my $units = 0;
    $PROOF_WORK = \$units;
    $PROOF_ID = bless \(my $identity = undef), 'Selecto::DataRules::_ProofIdentity';
    fieldhash my %accepted;
    $PROOF_ACCEPTED = \%accepted;
    $PROOF_LIMIT = ($options{limits} // Selecto::Limits->new)->get('max_rule_work');
    my $scope = bless {restore => sub {
        ($PROOF_WORK, $PROOF_ID, $PROOF_ACCEPTED, $PROOF_LIMIT) = (undef, undef, undef, undef);
    }}, 'Selecto::DataRules::_BudgetScope';
    $class->_charge_accepted_work($options{accepted_work});
    return $work->();
}

# Internal first-party evaluators join the same protected counter. The
# reference is never accepted from request options or declaration metadata.
sub _rule_work_context {
    my ($class, $limits) = @_;
    _fail('required_data_rule_pending', 'rule work requires a protected scope') unless $PROOF_WORK;
    return ($PROOF_WORK, ($limits // Selecto::Limits->new)->tightened(max_rule_work => $PROOF_LIMIT));
}

sub _charge_accepted_work {
    my ($class, $tickets) = @_;
    $tickets = [] unless defined $tickets;
    $tickets = [$tickets] unless ref($tickets) eq 'ARRAY';
    for my $ticket (@$tickets) {
        next unless defined $ticket;
        my $record = ref($ticket) ? $MEASURED_WORK{$ticket} : undef;
        Selecto::Error->throw('required_data_rule_pending', 'accepted planning work requires private evidence')
            unless $record;
        next if $PROOF_ACCEPTED->{$ticket};
        # A plan created inside this proof has already spent its measured work.
        $$PROOF_WORK += $record->{units} unless refaddr($record->{scope}) == refaddr($PROOF_ID);
        $PROOF_ACCEPTED->{$ticket} = 1;
    }
    Selecto::Error->throw('evaluation_limit', 'accepted planning work exceeds the protected proof budget')
        if $$PROOF_WORK > $PROOF_LIMIT;
}

sub _measure_proof_work {
    my ($class, $work, %options) = @_;
    return $class->_with_proof_budget(sub {
        my $before = $$PROOF_WORK;
        my $result = $work->();
        my $ticket = bless \(my $identity = undef), 'Selecto::DataRules::_MeasuredWork';
        $MEASURED_WORK{$ticket} = {units => $$PROOF_WORK - $before, scope => $PROOF_ID};
        $PROOF_ACCEPTED->{$ticket} = 1;
        return ($result, $ticket);
    }, limits => $options{limits});
}


sub parse {
    &_check_untied_arguments;
    my ($class, $raw, %options) = @_;
    my $limits = $options{limits} // Selecto::Limits->new;
    $raw = _copy_plain($raw, $limits, 'invalid_data_rules_contract', 'data rules contract');
    _hash($raw, 'invalid_data_rules_contract', 'data rules'); _keys($raw, [qw(schema definitions normalizers bindings)], 'data rules');
    _fail('invalid_data_rules_contract', 'unsupported data-rules schema') unless ($raw->{schema} // '') eq $SCHEMA;
    my (%definitions, %normalizers, %bindings);
    for my $id (keys %{_hash($raw->{definitions}, 'invalid_data_rules_contract', 'definitions')}) {
        _fail('invalid_data_rules_contract', 'definition id is invalid') unless _id($id);
        my $entry = $raw->{definitions}{$id};
        _hash($entry, 'invalid_data_rules_contract', 'definition');
        _keys($entry, [qw(version test message)], 'definition');
        if (exists $entry->{message}) {
            my $message = _hash($entry->{message}, 'invalid_data_rules_contract', 'message');
            _keys($message, [qw(key default)], 'message');
            _fail('invalid_data_rules_contract', 'message metadata must contain nonempty strings')
                if grep { !_id($_) } values %$message;
        }
        _positive($entry->{version});
        my $prepared = _test($entry->{test}, $limits);
        $definitions{$id} = {version => $entry->{version}, test => $entry->{test}, prepared => $prepared};
    }
    for my $id (keys %{_hash($raw->{normalizers}, 'invalid_data_rules_contract', 'normalizers')}) {
        _fail('invalid_data_rules_contract', 'normalizer id is invalid') unless _id($id);
        my $entry = $raw->{normalizers}{$id}; _hash($entry, 'invalid_data_rules_contract', 'normalizer'); _keys($entry, [qw(version steps)], 'normalizer'); _positive($entry->{version});
        _fail('invalid_data_rules_contract', 'normalizer steps are invalid') unless ref($entry->{steps}) eq 'ARRAY' && @{$entry->{steps}};
        for my $step (@{$entry->{steps}}) { _hash($step, 'invalid_data_rules_contract', 'normalizer step'); _keys($step, [qw(op profile)], 'normalizer step'); my $ok = ($step->{op}//'') eq 'text.trim' && (($step->{profile}//'') eq 'ascii_v1' || ($step->{profile}//'') eq 'ascii_whitespace_v1'); $ok ||= (($step->{op}//'') eq 'text.uppercase' || ($step->{op}//'') eq 'text.lowercase') && ($step->{profile}//'') eq 'ascii_v1'; $ok ||= ($step->{op}//'') eq 'text.nfc' && ($step->{profile}//'') eq 'unicode_nfc_v1'; $ok ||= (($step->{op}//'') eq 'text.line_endings' || ($step->{op}//'') eq 'text.empty_to_null') && !exists($step->{profile}); _fail('invalid_data_rules_contract', 'normalizer step is unsupported') unless $ok; }
        $normalizers{$id} = {version => $entry->{version}, steps => $entry->{steps}};
    }
    for my $id (keys %{_hash($raw->{bindings}, 'invalid_data_rules_contract', 'bindings')}) {
        _fail('invalid_data_rules_contract', 'binding id is invalid') unless _id($id);
        my $entry = $raw->{bindings}{$id}; _hash($entry, 'invalid_data_rules_contract', 'binding'); _keys($entry, [qw(subject operations rule normalizer condition enforcement)], 'binding');
        _fail('invalid_data_rules_contract', 'invalid rule enforcement') if exists($entry->{enforcement}) && (!defined($entry->{enforcement}) || ref($entry->{enforcement}) || $entry->{enforcement} !~ /\A(?:required|advisory)\z/);
        my $condition = exists($entry->{condition}) ? _test($entry->{condition}, $limits) : undef;
        my $subject = $entry->{subject}; _hash($subject, 'invalid_data_rules_contract', 'subject'); _keys($subject, [qw(scope path action)], 'subject'); my $scope = $subject->{scope}//''; my $path = _path($subject->{path});
        my $action_ok = defined($subject->{action}) && _id($subject->{action}); _fail('invalid_data_rules_contract', 'subject is invalid') unless $scope =~ /\A(?:input|action_input|candidate|transaction|evidence)\z/ && (($scope eq 'action_input') == $action_ok);
        my $rule = _ref($entry->{rule}); _fail('unresolved_rule_reference', 'rule reference does not resolve') unless exists($definitions{$rule->{id}}) && "$definitions{$rule->{id}}{version}" eq "$rule->{version}";
        my $ops = $entry->{operations}//[]; _fail('invalid_data_rules_contract', 'operations are invalid') unless ref($ops) eq 'ARRAY'; my %seen; _fail('invalid_data_rules_contract', 'operations are invalid') if grep { !defined($_) || !/\A(?:insert|update|delete|upsert)\z/ || $seen{$_}++ } @$ops;
        my $normalizer; if (exists $entry->{normalizer}) { $normalizer = _ref($entry->{normalizer}); _fail('unresolved_rule_reference', 'normalizer reference does not resolve') unless exists($normalizers{$normalizer->{id}}) && "$normalizers{$normalizer->{id}}{version}" eq "$normalizer->{version}"; }
        $bindings{$id} = {enforcement => $entry->{enforcement} // 'required', subject => {scope => $scope, path => $path, (defined($subject->{action}) ? (action => $subject->{action}) : ())}, operations => [@$ops], rule => $rule, (defined($normalizer) ? (normalizer => $normalizer) : ()), (defined($condition) ? (condition => $entry->{condition}, prepared_condition => $condition) : ())};
    }
    return bless {definitions => \%definitions, normalizers => \%normalizers, bindings => \%bindings, limits => $limits}, $class;
}

sub evaluate {
    my ($self, %request) = @_;
    return $self->_evaluate_request(\%request, 0);
}
# Native providers use this only after the already-normalized values have
# been projected again by storage. It cannot perform or replay mutations.
sub _recheck {
    my ($self, %request) = @_;
    return $self->_evaluate_request(\%request, 1);
}
sub _with_native_upsert_values {
    _fail('required_data_rule_pending', 'native decimal scope requires protected rule authority')
        unless caller eq 'Selecto::WriteRules';
    my ($class, $values, $types, $context, $receipt, $limits, $work) = @_;
    return Selecto::RuleTest->_with_native_upsert_values($values, $types, $context, $receipt, $limits, $work);
}
# Resource admission is shared with native replay of compiler-owned INPUT
# evidence. It inspects every applicable binding, including advisory and false
# conditions, without running a normalizer, condition or rule test.
sub _preflight_subject {
    my ($self, $request, $subject, $limits, $work) = @_;
    Selecto::OperationBudget->new(limits => $limits, code => 'evaluation_limit')
        ->check_tree($subject, label => 'rule subject');
    for my $binding (values %{$self->{bindings}}) {
        next unless _applies($binding, $request);
        my ($value, $present) = _at($subject, $binding->{subject}{path});
        Selecto::RuleTest::check_value($value, $limits, $work);
        Selecto::RuleTest->preflight($self->{definitions}{$binding->{rule}{id}}{prepared}, $value, $present, $limits, $subject, $work);
        Selecto::RuleTest->preflight($binding->{prepared_condition}, $value, $present, $limits, $subject, $work)
            if $binding->{prepared_condition};
    }
    return 1;
}
sub _preflight_reused_input {
    my ($class, $raw, $operation, $original, $normalized, $limits) = @_;
    return $class->_with_proof_budget(sub {
        my ($work, $effective) = $class->_rule_work_context($limits);
        # Recompile under the receiving host's actual metadata, numeric and
        # pattern ceilings; a compiler's default ceilings grant no exemption.
        my $rules = $class->parse($raw, limits => $effective);
        for my $subject ($original, $normalized) {
            $rules->_preflight_subject({stage => 'input', operation => $operation},
                _hash($subject, 'invalid_data_rules_request', 'subject'), $effective, $work);
        }
        return 1;
    }, limits => $limits);
}
sub _evaluate_request {
    my ($self, $request, $test_only) = @_;
    my %request = %$request;
    my $stage = $request{stage} // '';
    _fail('invalid_data_rules_request', 'invalid rule evaluation stage or operation')
        unless !ref($stage) && $stage =~ /\A(?:input|action_input|candidate|transaction|evidence)\z/
            && (!defined($request{operation}) || !ref($request{operation}) && $request{operation} =~ /\A(?:insert|update|delete|upsert)\z/)
            && ($stage ne 'action_input' || _id($request{action}));
    my $limits = defined($request{limits}) ? $self->{limits}->intersect($request{limits}) : $self->{limits};
    $limits = $limits->tightened(max_rule_work => $PROOF_LIMIT) if $PROOF_WORK;
    my $subject_value = _hash($request{subject}, 'invalid_data_rules_request', 'subject');
    my $local_work = 0;
    my $work = $PROOF_WORK // \$local_work;
    my $normalized;
    # Refuse oversized/cyclic values before cloning. Check every consumed value
    # before conditions so an advisory or false branch cannot conceal resources.
    my $admitted = eval {
        $normalized = _copy_plain($subject_value, $limits, 'evaluation_limit', 'rule subject');
        $self->_preflight_subject(\%request, $normalized, $limits, $work);
        1;
    };
    unless ($admitted) {
        my $error = $@;
        die $error unless ref($error) && $error->can('code') && $error->code eq 'evaluation_limit';
        return {state => 'error', code => 'evaluation_limit', normalized => {}};
    }
    my $outcome;
    for my $id (sort keys %{$self->{bindings}}) {
        my $binding = $self->{bindings}{$id};
        next unless _applies($binding, \%request);
        my $required = $binding->{enforcement} ne 'advisory';
        my $path = $binding->{subject}{path};
        my $unavailable = ($stage eq 'transaction' || $stage eq 'evidence')
            && ($request{authoritative_stage} // '') ne $stage;
        my ($value, $present) = _at($normalized, $path);
        my ($failed, $code, $resource);
        my $ok = eval {
            if (!$test_only && (my $normalizer = $binding->{normalizer})) {
                my ($next, $error) = _normalize($value, $present, $self->{normalizers}{$normalizer->{id}}, $limits, $work);
                if (defined $error) { $failed = 1; $code = $error }
                else { _set($normalized, $path, $next) unless $unavailable; ($value, $present) = ($next, 1) }
            }
            unless ($failed) {
                my $applies = 1;
                if ($binding->{prepared_condition}) {
                    ($applies) = Selecto::RuleTest->evaluate($binding->{prepared_condition}, $value, $present, $limits, $work, $normalized, $path);
                }
                if ($applies) {
                    my $passed;
                    ($passed, $code) = Selecto::RuleTest->evaluate($self->{definitions}{$binding->{rule}{id}}{prepared}, $value, $present, $limits, $work, $normalized, $path);
                    $failed = !$passed;
                }
            }
            1;
        };
        unless ($ok) {
            my $error = $@;
            die $error unless ref($error) && $error->can('code') && $error->code eq 'evaluation_limit';
            return _result('error', $normalized, 'evaluation_limit', $path);
        }
        $outcome //= ['pending', 'authoritative_stage_required', $path] if $unavailable && $required;
        $outcome //= ['failed', $code, $path] if !$unavailable && $failed && $required;
    }
    return _result($outcome->[0], $normalized, $outcome->[1], $outcome->[2]) if $outcome;
    return _result('passed', $normalized);
}
sub _applies {
    my ($binding, $request) = @_;
    return $binding->{subject}{scope} eq ($request->{stage} // '')
        && (!@{$binding->{operations}} || grep { $_ eq ($request->{operation} // '') } @{$binding->{operations}})
        && (($request->{stage} // '') ne 'action_input' || ($binding->{subject}{action} // '') eq ($request->{action} // ''));
}
sub consumed_paths {
    my ($self, $stage, $operation, $action) = @_;
    my @paths;
    for my $binding (values %{$self->{bindings}}) {
        next unless _applies($binding, {stage => $stage, operation => $operation, action => $action});
        my $root = $binding->{subject}{path};
        push @paths, [@$root];
        for my $prepared ($self->{definitions}{$binding->{rule}{id}}{prepared}, $binding->{prepared_condition} // ()) {
            for my $path (@{Selecto::RuleTest->dependencies($prepared)}) {
                push @paths, ref($path->[0]) eq 'HASH' && $path->[0]{root}
                    ? [@$path[1 .. $#$path]] : [@$root, @$path];
            }
        }
    }
    return \@paths;
}

sub applicable_paths {
    my ($self, $stage, $operation, $action) = @_;
    return [map { [@{$_->{subject}{path}}] } grep {
        $_->{subject}{scope} eq $stage
            && (!@{$_->{operations}} || grep { $_ eq ($operation // '') } @{$_->{operations}})
            && ($stage ne 'action_input' || ($_->{subject}{action} // '') eq ($action // ''))
    } values %{$self->{bindings}}];
}

sub _test { Selecto::RuleTest->compile($_[0], $_[1]) }
sub _evaluate { my ($t, $v, $present, $prepared, $limits, $work) = @_; Selecto::RuleTest->evaluate($prepared, $v, $present, $limits, $work) }

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

sub _normalize {
    my ($value, $present, $normalizer, $limits, $work) = @_;
    return (undef, 'invalid_type') unless $present;
    my $current = $value;
    for my $step (@{$normalizer->{steps}}) {
        return (undef, 'invalid_type') unless Selecto::RuleTest::kind($current) eq 'text';
        Selecto::RuleTest::text($current, $limits, $work);
        my $op = $step->{op};
        if ($op eq 'text.trim') { $current =~ s/\A[ \t\r\n\f\v]+|[ \t\r\n\f\v]+\z//g }
        elsif ($op eq 'text.uppercase' || $op eq 'text.lowercase') {
            return (undef, 'normalization_error') unless $current =~ /\A[\x00-\x7F]*\z/;
            $current = $op eq 'text.uppercase' ? uc($current) : lc($current);
        } elsif ($op eq 'text.nfc') { $current = Unicode::Normalize::NFC($current) }
        elsif ($op eq 'text.line_endings') { $current =~ s/\r\n?/\n/g }
        else { $current = undef if $current eq '' }
        Selecto::RuleTest::check_text($current) if defined $current;
    }
    return ($current, undef);
}
sub _hash { my($v,$code,$label)=@_;_fail($code,"$label must be an object")unless ref$v eq'HASH';return$v } sub _keys {my($v,$a,$l)=@_;my%a=map{$_=>1}@$a;_fail('unknown_rule_option',"unknown member in $l")if grep{!$a{$_}}keys%$v} sub _id{defined($_[0])&&!ref($_[0])&&length($_[0])>0} sub _positive{_fail('invalid_rule_version','version must be a positive integer')unless defined($_[0])&&!ref($_[0])&&$_[0]=~/\A[1-9][0-9]*\z/;$_[0]} sub _nonneg{defined($_[0])&&!ref($_[0])&&$_[0]=~/\A(?:0|[1-9][0-9]*)\z/?$_[0]:undef} sub _ref{my$v=_hash($_[0],'invalid_data_rules_contract','reference');_keys($v,[qw(id version)],'reference');_fail('invalid_data_rules_contract','reference id is invalid')unless _id($v->{id});{id=>$v->{id},version=>_positive($v->{version})}} sub _path{my$v=$_[0];_fail('invalid_data_rules_contract','path is invalid')unless ref$v eq'ARRAY'&&@$v&&!grep{!defined($_)||ref($_)||$_ eq''}@$v;[@$v]} sub _at{my($r,$p)=@_;my$c=$r;for(@$p){return(undef,0)unless ref$c eq'HASH'&&exists$c->{$_};$c=$c->{$_}}($c,1)}sub _set{my($r,$p,$v)=@_;my$c=$r;for my$k(@$p[0..$#$p-1]){$c->{$k}={}unless ref$c->{$k}eq'HASH';$c=$c->{$k}}$c->{$p->[-1]}=$v}sub _decimal{my$v=$_[0];return undef unless defined$v&&!ref$v&&"$v"=~/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/;Math::BigRat->new("$v")}sub _stable{JSON::PP->new->canonical(1)->encode($_[0])}sub _result{my($s,$n,$c,$p)=@_;{state=>$s,normalized=>$n,(defined$c?(code=>$c):()),(defined$p?(path=>[@$p]):())}}sub _fail{Selecto::Error->throw(@_)}
{
    package Selecto::DataRules::_BudgetScope;
    sub DESTROY { $_[0]{restore}->() }
}
1;

__END__

=head1 NAME

Selecto::DataRules - versioned validation rules declared in a domain

=head1 DESCRIPTION

Parses the C<rules> section of a domain contract (schema
C<selecto.data_rules.v1>: rule definitions, normalizers and bindings to write
inputs) and evaluates a subject against the bindings for one stage.

Registry and action identifiers are nonempty strings. Rule and normalizer
versions resolve exactly, including wide canonical digit-string versions.
All 27 v1 operators are supported: presence, type, text, exact numeric,
membership, collection, equality, and C<all>/C<any>/C<not>. Null equality,
Boolean/numeric distinctions and recursive container equality are exact.
The six text normalizers include NFC, line endings and empty-to-null.
Binding conditions use the same supported operators as definitions and inspect
the normalized binding subject. A false condition skips its rule; evaluation
work or numeric limits remain errors and cannot authorize a write. Ordinary
advisory validation failures do not reject an otherwise governed operation;
resource errors remain unconditional across advisory bindings, false
conditions and every logical branch.

Parsing accepts a trusted C<limits> option. Evaluation can further tighten it
with C<limits>; request data must never configure this option. Subject trees
are admitted and copied by an iterative walk before evaluation. Delivered
integer, floating, text and Boolean identity survives copying; authored text
remains text after numeric observation, and exact native unsigned integers
retain every bit. Caller-owned declarations and subjects are never reused as
normalized output. Oversized subjects return C<evaluation_limit>
with an empty normalized object, avoiding a copy of rejected input. Exact
numbers count all integer and fractional digits (default 1024), excluding sign
and decimal separator. Trusted bounds are compiled once. Pattern evaluation
uses L<Selecto::Pattern>, a bounded Thompson NFA preserving C<ascii_v1> regular
language semantics. Pattern subject size is 4096 UTF-8 bytes. Compiled-state
and a shared per-evaluation work budget (default 2,000,000) also apply to
normalizer steps, logical branches and exact arithmetic. NFC output is checked
again for expansion beyond the text bound. Very large counted
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
