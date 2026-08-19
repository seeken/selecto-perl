package Selecto::QueryEnforcement;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);
use Selecto::Error ();
use Selecto::Expression ();

sub new {
    my ($class, %args) = @_;
    return bless {
        domain_name => "$args{domain_name}",
        root_relation => "$args{root_relation}",
        primary_key => "$args{primary_key}",
        domain_fingerprint => defined($args{domain_fingerprint}) ? "$args{domain_fingerprint}" : undef,
        predicate => $args{predicate},
        applied_definitions => [@{$args{applied_definitions} // []}],
        predicate_fingerprint => predicate_fingerprint_value($args{predicate}),
    }, $class;
}

sub capture {
    my ($class, $domain, $query) = @_;
    my $predicate = combine($domain->required_predicate, $query->predicate);
    Selecto::Error->throw('query_enforcement_requires_filter', 'query enforcement requires an effective predicate')
        unless $predicate;
    validate($domain, $predicate);
    return $class->new(
        domain_name => $domain->name,
        root_relation => $domain->table,
        primary_key => $domain->primary_key,
        domain_fingerprint => $domain->fingerprint,
        predicate => $predicate,
    );
}

sub validate_source {
    my ($domain, $relation, $evidence) = @_;
    my $mismatch = $evidence->domain_name ne $domain->name
        || $evidence->root_relation ne $domain->table
        || $evidence->root_relation ne $relation
        || $evidence->primary_key ne $domain->primary_key
        || (defined($evidence->domain_fingerprint) && $evidence->domain_fingerprint ne $domain->fingerprint);
    Selecto::Error->throw('query_source_mismatch', 'query and write source identities differ') if $mismatch;
    validate($domain, $evidence->predicate);
}

sub combine {
    my @present = grep { defined } @_;
    return undef unless @present;
    return $present[0] if @present == 1;
    return Selecto::Expression->all(@present);
}

sub validate {
    my ($domain, $expression) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/) {
        _validate_root_field($domain, $arguments->[0]);
        _unsupported() unless blessed($arguments->[1]) && $arguments->[1]->kind eq 'literal';
        return;
    }
    if ($kind eq 'is_null' || $kind eq 'not_null') {
        _validate_root_field($domain, $arguments->[0]);
        return;
    }
    if ($kind eq 'in') {
        _validate_root_field($domain, $arguments->[0]);
        _unsupported() unless ref($arguments->[1]) eq 'ARRAY' && @{$arguments->[1]};
        return;
    }
    if ($kind eq 'and' || $kind eq 'or') {
        _unsupported() unless ref($arguments->[0]) eq 'ARRAY' && @{$arguments->[0]};
        validate($domain, $_) for @{$arguments->[0]};
        return;
    }
    if ($kind eq 'not') {
        validate($domain, $arguments->[0]);
        return;
    }
    _unsupported();
}

sub evaluate {
    my ($expression, $candidate) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/) {
        my ($field, $expected) = _field_literal($expression);
        _not_evaluable() unless exists $candidate->{$field};
        my $actual = $candidate->{$field};
        return 'unknown' unless defined($actual) && defined($expected);
        my $comparison = _compare($actual, $expected);
        my $match = {
            eq => $comparison == 0, ne => $comparison != 0, gt => $comparison > 0,
            gte => $comparison >= 0, lt => $comparison < 0, lte => $comparison <= 0,
        }->{$kind};
        return $match ? 'true' : 'false';
    }
    if ($kind eq 'is_null' || $kind eq 'not_null') {
        my $field = _root_field($arguments->[0]);
        _not_evaluable() unless exists $candidate->{$field};
        my $value = defined($candidate->{$field}) ? 'false' : 'true';
        return $kind eq 'not_null' ? _negate($value) : $value;
    }
    if ($kind eq 'in') {
        my $field = _root_field($arguments->[0]);
        _not_evaluable() unless exists $candidate->{$field};
        my $actual = $candidate->{$field};
        return 'unknown' unless defined $actual;
        my $unknown = 0;
        for my $expected (@{$arguments->[1]}) {
            if (!defined $expected) { $unknown = 1; next; }
            return 'true' if _compare($actual, $expected) == 0;
        }
        return $unknown ? 'unknown' : 'false';
    }
    if ($kind eq 'and' || $kind eq 'or') {
        my @values = map { evaluate($_, $candidate) } @{$arguments->[0]};
        if ($kind eq 'and') {
            return 'false' if grep { $_ eq 'false' } @values;
            return (grep { $_ eq 'unknown' } @values) ? 'unknown' : 'true';
        }
        return 'true' if grep { $_ eq 'true' } @values;
        return (grep { $_ eq 'unknown' } @values) ? 'unknown' : 'false';
    }
    return _negate(evaluate($arguments->[0], $candidate)) if $kind eq 'not';
    _unsupported();
}

sub predicate_fingerprint_value {
    my ($expression) = @_;
    my $json = JSON::PP->new->canonical(1)->encode(_predicate_value($expression));
    return 'sha256:' . sha256_hex($json);
}

sub shape {
    my ($expression) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $kind . '(' . join(',', map { shape($_) } @{$arguments->[0]}) . ')'
        if $kind eq 'and' || $kind eq 'or';
    return 'not(' . shape($arguments->[0]) . ')' if $kind eq 'not';
    return $kind eq 'ne' ? 'neq' : $kind;
}

sub source_metadata {
    my ($self) = @_;
    my %metadata = (
        domain_name => $self->domain_name,
        root_relation => $self->root_relation,
        primary_key => $self->primary_key,
        predicate_fingerprint => $self->predicate_fingerprint,
        applied_definitions => $self->applied_definitions,
    );
    $metadata{domain_fingerprint} = $self->domain_fingerprint if defined $self->domain_fingerprint;
    return \%metadata;
}

sub domain_name { return $_[0]->{domain_name}; }
sub root_relation { return $_[0]->{root_relation}; }
sub primary_key { return $_[0]->{primary_key}; }
sub domain_fingerprint { return $_[0]->{domain_fingerprint}; }
sub predicate { return $_[0]->{predicate}; }
sub applied_definitions { return [@{$_[0]->{applied_definitions}}]; }
sub predicate_fingerprint { return $_[0]->{predicate_fingerprint}; }

sub _validate_root_field {
    my ($domain, $expression) = @_;
    my $field = _root_field($expression);
    Selecto::Error->throw('query_rule_unsupported_field', 'association fields are not portable write guards')
        if $field =~ /\./;
    my $resolved = eval { $domain->resolve($field) };
    Selecto::Error->throw('query_rule_unsupported_field', 'query rule references an undeclared root field')
        unless $resolved && !defined($resolved->{association});
}

sub _root_field {
    my ($expression) = @_;
    _unsupported() unless blessed($expression) && $expression->kind eq 'field';
    return $expression->arguments->[0];
}

sub _field_literal {
    my ($expression) = @_;
    my $arguments = $expression->arguments;
    _unsupported() unless blessed($arguments->[1]) && $arguments->[1]->kind eq 'literal';
    return (_root_field($arguments->[0]), $arguments->[1]->arguments->[0]);
}

sub _compare {
    my ($left, $right) = @_;
    return $left <=> $right if looks_like_number($left) && looks_like_number($right);
    _not_evaluable() if ref($left) || ref($right);
    return "$left" cmp "$right";
}

sub _negate { return $_[0] eq 'unknown' ? 'unknown' : $_[0] eq 'true' ? 'false' : 'true'; }

sub _predicate_value {
    my ($expression) = @_;
    return $expression unless blessed($expression) && $expression->isa('Selecto::Expression');
    return {
        kind => $expression->kind,
        arguments => [map {
            ref($_) eq 'ARRAY' ? [map { _predicate_value($_) } @$_] : _predicate_value($_)
        } @{$expression->arguments}],
    };
}

sub _unsupported {
    Selecto::Error->throw('query_rule_unsupported_predicate', 'predicate is outside the portable write subset');
}

sub _not_evaluable {
    Selecto::Error->throw('query_rule_not_evaluable', 'query rule cannot be evaluated against insert candidate');
}

1;
