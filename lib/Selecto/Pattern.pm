package Selecto::Pattern;

use 5.034;
use strict;
use warnings;
use bytes ();
use Selecto::Error ();
use Selecto::Limits ();

# Thompson NFA for the portable ascii_v1 regular language. Neither compilation
# nor execution delegates caller subjects to Perl's backtracking regex engine.
sub compile {
    my ($class, $pattern, %options) = @_;
    my $limits = $options{limits} // Selecto::Limits->new;
    _invalid('pattern is outside ascii_v1')
        unless defined($pattern) && !ref($pattern) && bytes::length($pattern) >= 1
            && bytes::length($pattern) <= 256 && $pattern =~ /\A[\x00-\x7f]*\z/;
    my $self = bless {pattern => $pattern, position => 0, limits => $limits, states => []}, $class;
    my $ast = $self->_alternation(0);
    _invalid('pattern is malformed') unless $self->{position} == length($pattern);
    my ($start, $end) = $self->_compile($ast);
    $self->{start} = $start;
    $self->{end} = $end;
    delete @{$self}{qw(pattern position)};
    return $self;
}
sub _invalid { Selecto::Error->throw('invalid_text_pattern', $_[0]) }
sub _peek { substr($_[0]->{pattern}, $_[0]->{position}, 1) }
sub _take { my $self = shift; my $c = $self->_peek; $self->{position}++ if length $c; return $c }
sub _alternation {
    my ($self, $depth) = @_;
    _invalid('pattern nesting exceeds its resource limit') if $depth > $self->{limits}->get('max_expression_depth');
    my @parts = ($self->_sequence($depth));
    while ($self->_peek eq '|') { $self->_take; push @parts, $self->_sequence($depth) }
    return @parts == 1 ? $parts[0] : ['or', @parts];
}
sub _sequence {
    my ($self, $depth) = @_;
    my @parts;
    while (length(my $c = $self->_peek)) {
        last if $c eq ')' || $c eq '|';
        my $node = $self->_atom($depth);
        $c = $self->_peek;
        if (length($c) && index('?*+{', $c) >= 0) {
            $self->_take;
            my ($min, $max) = $c eq '?' ? (0, 1) : $c eq '*' ? (0, undef) : $c eq '+' ? (1, undef) : (undef, undef);
            if ($c eq '{') {
                $min = $self->_number;
                if ($self->_peek eq ',') { $self->_take; $max = $self->_peek eq '}' ? undef : $self->_number }
                else { $max = $min }
                _invalid('pattern repetition is malformed') unless $self->_take eq '}' && (!defined($max) || $max >= $min);
            }
            $node = ['repeat', $node, $min, $max];
            my $next = $self->_peek;
            _invalid('stacked, lazy and possessive quantifiers are outside ascii_v1')
                if length($next) && index('?*+{', $next) >= 0;
        }
        push @parts, $node;
    }
    return ['sequence', @parts];
}
sub _number {
    my $self = shift;
    my ($value, $digits) = (0, 0);
    while (length(my $c = $self->_peek)) {
        last unless $c ge '0' && $c le '9';
        $self->_take; $digits++;
        $value = $value * 10 + ord($c) - 48;
        _invalid('pattern repetition exceeds its resource limit') if $value > $self->{limits}->get('max_regex_states');
    }
    _invalid('pattern repetition requires a count') unless $digits;
    return $value;
}
sub _escape {
    my $self = shift;
    my $c = $self->_take;
    _invalid('pattern escape is outside ascii_v1') unless length $c;
    return ['class', $c] if index('dDsSwW', $c) >= 0;
    return ['char', $c eq 't' ? "\t" : $c eq 'r' ? "\r" : "\n"] if index('trn', $c) >= 0;
    return ['char', $c] if index('\\.[]{}()|?*+-^$', $c) >= 0;
    _invalid('pattern escape is outside ascii_v1');
}
sub _class_atom {
    my $self = shift;
    my $c = $self->_take;
    _invalid('pattern character class is malformed') unless length $c;
    return $self->_escape if $c eq '\\';
    _invalid('POSIX and intersected classes are outside ascii_v1') if $c eq '[' || ($c eq '&' && $self->_peek eq '&');
    return ['char', $c];
}
sub _atom {
    my ($self, $depth) = @_;
    my $c = $self->_take;
    if ($c eq '(') {
        _invalid('pattern extensions are outside ascii_v1') if $self->_peek eq '?';
        my $node = $self->_alternation($depth + 1);
        _invalid('pattern group is unclosed') unless $self->_take eq ')';
        return $node;
    }
    if ($c eq '[') {
        my $negated = $self->_peek eq '^' ? ($self->_take, 1) : 0;
        my @members;
        while (length($self->_peek)) {
            last if $self->_peek eq ']' && @members;
            my $first = $self->_class_atom;
            if ($self->_peek eq '-' && substr($self->{pattern}, $self->{position} + 1, 1) ne ']') {
                $self->_take;
                my $last = $self->_class_atom;
                _invalid('pattern class range is malformed') unless $first->[0] eq 'char' && $last->[0] eq 'char' && ord($first->[1]) <= ord($last->[1]);
                push @members, ['range', ord($first->[1]), ord($last->[1])];
            } else { push @members, $first }
        }
        _invalid('pattern character class is unclosed') unless @members && $self->_take eq ']';
        return ['set', $negated, @members];
    }
    return $self->_escape if $c eq '\\';
    return ['dot'] if $c eq '.';
    _invalid('pattern token is outside ascii_v1') if index('^$?*+{}]', $c) >= 0;
    return ['char', $c];
}
sub _state {
    my $self = shift;
    _invalid('compiled pattern exceeds its resource limit') if @{$self->{states}} >= $self->{limits}->get('max_regex_states');
    push @{$self->{states}}, {epsilon => [], edges => []};
    return $#{$self->{states}};
}
sub _link { my ($self, $from, $to) = @_; push @{$self->{states}[$from]{epsilon}}, $to }
sub _compile {
    my ($self, $node) = @_;
    my ($start, $end) = ($self->_state, $self->_state);
    my $kind = $node->[0];
    if ($kind eq 'sequence') {
        my $previous = $start;
        for my $part (@$node[1 .. $#$node]) { my ($a, $b) = $self->_compile($part); $self->_link($previous, $a); $previous = $b }
        $self->_link($previous, $end);
    } elsif ($kind eq 'or') {
        for my $part (@$node[1 .. $#$node]) { my ($a, $b) = $self->_compile($part); $self->_link($start, $a); $self->_link($b, $end) }
    } elsif ($kind eq 'repeat') {
        my ($child, $minimum, $maximum) = @$node[1 .. 3];
        my $previous = $start;
        for (1 .. $minimum) { my ($a, $b) = $self->_compile($child); $self->_link($previous, $a); $previous = $b }
        if (defined $maximum) {
            for (1 .. $maximum - $minimum) {
                $self->_link($previous, $end);
                my ($a, $b) = $self->_compile($child); $self->_link($previous, $a); $previous = $b;
            }
        } else {
            my ($a, $b) = $self->_compile($child);
            $self->_link($previous, $a); $self->_link($b, $previous);
        }
        $self->_link($previous, $end);
    } else { push @{$self->{states}[$start]{edges}}, [$node, $end] }
    return ($start, $end);
}
sub _matches_char {
    my ($test, $char, $work, $limit) = @_;
    return undef if ++$$work > $limit;
    my $kind = $test->[0];
    return $char eq $test->[1] if $kind eq 'char';
    return $char ne "\n" if $kind eq 'dot';
    return ord($char) >= $test->[1] && ord($char) <= $test->[2] if $kind eq 'range';
    if ($kind eq 'set') {
        my $match = 0;
        for my $member (@$test[2 .. $#$test]) {
            my $matched = _matches_char($member, $char, $work, $limit);
            return undef unless defined $matched;
            $match = 1, last if $matched;
        }
        return $test->[1] ? !$match : $match;
    }
    my $class = $test->[1];
    my $match = lc($class) eq 'd' ? $char =~ /\A[0-9]\z/
        : lc($class) eq 'w' ? $char =~ /\A[A-Za-z0-9_]\z/
        : $char =~ /\A[ \t\r\n\f\x0b]\z/;
    return $class eq lc($class) ? !!$match : !$match;
}
sub matches {
    my ($self, $text, %options) = @_;
    return (undef, 'evaluation_limit') if !defined($text) || ref($text) || bytes::length($text) > 4096;
    my $limit = ($options{limits} // $self->{limits})->get('max_rule_work');
    my $local_work = 0;
    my $work = $options{work_ref} // \$local_work;
    my $search = ($options{match} // 'full') eq 'search';
    my $closure = sub {
        my ($seeds) = @_;
        my (%seen, @todo); @todo = @$seeds;
        while (@todo) {
            return undef if ++$$work > $limit;
            my $id = pop @todo; next if $seen{$id}++;
            push @todo, @{$self->{states}[$id]{epsilon}};
        }
        return \%seen;
    };
    my $active = $closure->([$self->{start}]);
    return (undef, 'evaluation_limit') unless $active;
    return (1, undef) if $search && $active->{$self->{end}};
    for my $index (0 .. length($text) - 1) {
        my $char = substr($text, $index, 1);
        my @next;
        for my $id (keys %$active) {
            return (undef, 'evaluation_limit') if ++$$work > $limit;
            for my $edge (@{$self->{states}[$id]{edges}}) {
                my $matched = _matches_char($edge->[0], $char, $work, $limit);
                return (undef, 'evaluation_limit') unless defined $matched;
                push @next, $edge->[1] if $matched;
            }
        }
        push @next, $self->{start} if $search;
        $active = $closure->(\@next);
        return (undef, 'evaluation_limit') unless $active;
        return (1, undef) if $search && $active->{$self->{end}};
        return (0, undef) unless %$active;
    }
    return ($active->{$self->{end}} ? 1 : 0, undef);
}

1;

__END__

=head1 NAME

Selecto::Pattern - bounded non-backtracking ascii_v1 pattern evaluator

=head1 DESCRIPTION

Compiles the portable regular language to a Thompson NFA. Groups, alternation,
character classes and quantifiers retain regular-language full/search matching
semantics. ASCII escapes use ASCII character classes; dot excludes newline.
State and work ceilings bound counted repetitions and matching independently
of subject size. The subject ceiling is 4096 UTF-8 bytes. Exhausted evaluation
returns C<evaluation_limit>; oversized compiled patterns reject at admission.
No native backtracking regex runs on caller text. Captures are not exposed.

=cut
