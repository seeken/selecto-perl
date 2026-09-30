package Selecto::ValueExpression;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();

# A closed, typed AST for governed computed values.
#
# Value expressions are portable data. They never carry SQL text: adapters
# compile each node, bind every literal and JSON path segment, and cast bound
# values to their declared types. The node set is deliberately small; a new
# node needs a certification case before it is added.
#
#   ['field', 'site.name']
#   ['literal', 100] / ['literal', 100, 'decimal']
#   ['coalesce', VALUE, VALUE, ...]
#   ['case', [FILTER, VALUE], [FILTER, VALUE], ..., ['else', VALUE]]
#   ['add' | 'subtract' | 'multiply' | 'divide', VALUE, VALUE]
#   ['cast', VALUE, TYPE]
#   ['json_text', FIELD_PATH, [SEGMENT, ...]]
#   ['lower' | 'upper', VALUE]
#   ['concat', VALUE, VALUE, ...]
#   ['previous', COLUMN]   (recursive member steps only: the previous level's row)
#
# FILTER is the portable filter AST accepted by
# Selecto::Expression->from_filter_ast.

my %ARITHMETIC = map { $_ => 1 } qw(add subtract multiply divide);
my %CASE_FUNCTION = map { $_ => 1 } qw(lower upper);
my %CAST_TYPE = map { $_ => 1 } qw(string integer decimal boolean date utc_datetime);
my $PATH = qr/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
my $SEGMENT = qr/\A(?:[A-Za-z0-9_]+)\z/;

# Maps declared column types onto the categories value expressions check.
sub category {
    my ($class, $type) = @_;
    return 'other' unless defined($type) && !ref($type);
    my $name = lc "$type";
    return 'string' if $name =~ /\A(?:string|text|varchar|char|citext|uuid)\z/;
    return 'integer' if $name =~ /\A(?:integer|int|bigint|smallint)\z/;
    return 'decimal' if $name =~ /\A(?:decimal|numeric|float|double|real|money)\z/;
    return 'boolean' if $name eq 'boolean';
    return 'date' if $name eq 'date';
    return 'datetime' if $name =~ /\A(?:utc_datetime|datetime|naive_datetime|timestamp|timestamptz)\z/;
    return 'json' if $name =~ /\A(?:jsonb|json)\z/;
    return 'other';
}

sub _category_of_cast {
    my ($type) = @_;
    return __PACKAGE__->category($type eq 'utc_datetime' ? 'utc_datetime' : $type);
}

# Structural validation that needs no domain. Returns a normalized deep copy.
our $_ALLOW_PREVIOUS = 0;

sub parse {
    my ($class, $ast, %options) = @_;
    local $_ALLOW_PREVIOUS = $options{allow_previous} ? 1 : 0;
    return _parse($ast, 'value expression');
}


sub _parse {
    my ($node, $label) = @_;
    _fail("$label must be a non-empty array") unless ref($node) eq 'ARRAY' && @$node;
    my ($operator, @arguments) = @$node;
    _fail("$label operator must be a string") if !defined($operator) || ref($operator);
    $operator = lc "$operator";
    if ($operator eq 'field') {
        _fail("$label field requires one governed path")
            unless @arguments == 1 && defined($arguments[0]) && !ref($arguments[0])
                && "$arguments[0]" =~ $PATH;
        return ['field', "$arguments[0]"];
    }
    if ($operator eq 'previous') {
        _fail("$label previous is available only in a recursive member step")
            unless $_ALLOW_PREVIOUS;
        _fail("$label previous requires one column name")
            unless @arguments == 1 && defined($arguments[0]) && !ref($arguments[0])
                && "$arguments[0]" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        return ['previous', "$arguments[0]"];
    }
    if ($operator eq 'literal') {
        _fail("$label literal requires a value and an optional type")
            unless @arguments == 1 || @arguments == 2;
        my ($value, $type) = @arguments;
        if (JSON::PP::is_bool($value)) {
            $type //= 'boolean';
            $value = $value ? 1 : 0;
        }
        _fail("$label literal value must be a scalar") if ref($value);
        _fail("$label literal value must not be null; use a nullable field or case")
            unless defined $value;
        if (defined $type) {
            _fail("$label literal type must be one of " . join(', ', sort keys %CAST_TYPE))
                unless !ref($type) && $CAST_TYPE{$type};
        } else {
            # The same rule in every runtime: digits are integer, digits with a
            # fractional part are decimal, and anything else is a string.
            $type = "$value" =~ /\A-?\d+\z/ ? 'integer'
                : "$value" =~ /\A-?\d+\.\d+\z/ ? 'decimal'
                : 'string';
        }
        return ['literal', $value, "$type"];
    }
    if ($operator eq 'coalesce' || $operator eq 'concat') {
        _fail("$label $operator requires at least two values") unless @arguments >= 2;
        return [$operator, map { _parse($_, "$label $operator argument") } @arguments];
    }
    if ($ARITHMETIC{$operator}) {
        _fail("$label $operator requires exactly two values") unless @arguments == 2;
        return [$operator, map { _parse($_, "$label $operator operand") } @arguments];
    }
    if ($CASE_FUNCTION{$operator}) {
        _fail("$label $operator requires exactly one value") unless @arguments == 1;
        return [$operator, _parse($arguments[0], "$label $operator argument")];
    }
    if ($operator eq 'cast') {
        _fail("$label cast requires a value and a target type") unless @arguments == 2;
        my $type = $arguments[1];
        _fail("$label cast type must be one of " . join(', ', sort keys %CAST_TYPE))
            unless defined($type) && !ref($type) && $CAST_TYPE{$type};
        return ['cast', _parse($arguments[0], "$label cast value"), "$type"];
    }
    if ($operator eq 'json_text') {
        my ($field, $segments) = @arguments;
        _fail("$label json_text requires a field path and a non-empty segment list")
            unless @arguments == 2 && defined($field) && !ref($field) && "$field" =~ $PATH
                && ref($segments) eq 'ARRAY' && @$segments;
        for my $segment (@$segments) {
            _fail("$label json_text segments must be letters, digits, or underscores")
                unless defined($segment) && !ref($segment) && "$segment" =~ $SEGMENT;
        }
        return ['json_text', "$field", [map { "$_" } @$segments]];
    }
    if ($operator eq 'case') {
        _fail("$label case requires at least one condition") unless @arguments;
        my @branches;
        my $else;
        for my $index (0 .. $#arguments) {
            my $branch = $arguments[$index];
            _fail("$label case branches must be arrays") unless ref($branch) eq 'ARRAY';
            if (@$branch == 2 && !ref($branch->[0]) && defined($branch->[0])
                && lc("$branch->[0]") eq 'else') {
                _fail("$label case else must be the last branch") unless $index == $#arguments;
                $else = _parse($branch->[1], "$label case else");
                next;
            }
            _fail("$label case branches must be [condition, value]") unless @$branch == 2;
            require Selecto::Expression;
            my $ok = eval { Selecto::Expression->from_filter_ast($branch->[0]); 1 };
            _fail("$label case condition is not a valid filter") unless $ok;
            push @branches, [dclone($branch->[0]), _parse($branch->[1], "$label case value")];
        }
        _fail("$label case requires at least one condition") unless @branches;
        return ['case', @branches, (defined($else) ? (['else', $else]) : ())];
    }
    _fail("unsupported value expression operator $operator");
}

# Every governed field path a value expression reads, including case conditions.
sub dependencies {
    my ($class, $ast) = @_;
    my %seen;
    return grep { !$seen{$_}++ } _dependencies($ast);
}

sub _dependencies {
    my ($node) = @_;
    my ($operator, @arguments) = @$node;
    return ($arguments[0]) if $operator eq 'field' || $operator eq 'json_text';
    return () if $operator eq 'literal' || $operator eq 'previous';
    if ($operator eq 'case') {
        my @paths;
        for my $branch (@arguments) {
            if ($branch->[0] eq 'else') {
                push @paths, _dependencies($branch->[1]);
            } else {
                require Selecto::Expression;
                push @paths, _filter_fields(Selecto::Expression->from_filter_ast($branch->[0]));
                push @paths, _dependencies($branch->[1]);
            }
        }
        return @paths;
    }
    if ($operator eq 'cast') {
        return _dependencies($arguments[0]);
    }
    return map { _dependencies($_) } @arguments;
}

sub _filter_fields {
    my ($expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    return ("$arguments->[0]") if $expression->kind eq 'field';
    my @fields;
    for my $argument (@$arguments) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            push @fields, _filter_fields($argument);
        } elsif (ref($argument) eq 'ARRAY') {
            push @fields, map { _filter_fields($_) } @$argument;
        }
    }
    return @fields;
}

# Type inference against a resolver that returns the declared type of a field
# path (and dies for unknown paths). Returns the result category.
sub infer {
    my ($class, $ast, %options) = @_;
    my $resolve = $options{resolve}
        // Selecto::Error->throw('invalid_domain', 'value expression inference requires a resolver');
    return _infer($ast, $resolve);
}

sub _infer {
    my ($node, $resolve) = @_;
    my ($operator, @arguments) = @$node;
    if ($operator eq 'field') {
        return __PACKAGE__->category($resolve->($arguments[0]));
    }
    if ($operator eq 'literal') {
        return _category_of_cast($arguments[1]);
    }
    if ($operator eq 'previous') {
        return __PACKAGE__->category($resolve->(['previous', $arguments[0]]));
    }
    if ($operator eq 'coalesce') {
        my @categories = map { _infer($_, $resolve) } @arguments;
        return _common(\@categories, 'coalesce');
    }
    if ($ARITHMETIC{$operator}) {
        my @categories = map { _infer($_, $resolve) } @arguments;
        for my $category (@categories) {
            _type_error("$operator requires numeric operands, found $category")
                unless $category eq 'integer' || $category eq 'decimal';
        }
        return 'decimal' if $operator eq 'divide';
        return (grep { $_ eq 'decimal' } @categories) ? 'decimal' : 'integer';
    }
    if ($CASE_FUNCTION{$operator}) {
        my $category = _infer($arguments[0], $resolve);
        _type_error("$operator requires a string, found $category") unless $category eq 'string';
        return 'string';
    }
    if ($operator eq 'concat') {
        _infer($_, $resolve) for @arguments;
        return 'string';
    }
    if ($operator eq 'cast') {
        _infer($arguments[0], $resolve);
        return _category_of_cast($arguments[1]);
    }
    if ($operator eq 'json_text') {
        my $category = __PACKAGE__->category($resolve->($arguments[0]));
        _type_error("json_text requires a JSON field, found $category") unless $category eq 'json';
        return 'string';
    }
    if ($operator eq 'case') {
        my @categories;
        for my $branch (@arguments) {
            if ($branch->[0] eq 'else') {
                push @categories, _infer($branch->[1], $resolve);
            } else {
                require Selecto::Expression;
                $resolve->($_) for _filter_fields(Selecto::Expression->from_filter_ast($branch->[0]));
                push @categories, _infer($branch->[1], $resolve);
            }
        }
        return _common(\@categories, 'case');
    }
    _type_error("unsupported value expression operator $operator");
}

sub _common {
    my ($categories, $label) = @_;
    my %distinct = map { $_ => 1 } @$categories;
    return $categories->[0] if keys(%distinct) == 1;
    return 'decimal' if keys(%distinct) == 2 && $distinct{integer} && $distinct{decimal};
    _type_error("$label values must share one type, found " . join(', ', sort keys %distinct));
}

# Whether an inferred category satisfies a declared column type.
sub compatible {
    my ($class, $declared, $inferred) = @_;
    my $expected = $class->category($declared);
    return 1 if $expected eq $inferred;
    return 1 if $expected eq 'decimal' && $inferred eq 'integer';
    return 0;
}

sub _fail { Selecto::Error->throw('invalid_value_expression', $_[0]); }
sub _type_error { Selecto::Error->throw('invalid_value_expression', $_[0]); }

1;

__END__

=head1 NAME

Selecto::ValueExpression - closed, typed AST for governed computed values

=head1 SYNOPSIS

  # A computed domain column:
  hourly_rate_dollars => {
      type => 'decimal',
      computed => {kind => 'expression',
          expression => ['divide', ['field', 'hourly_rate_cents'], ['literal', 100]]},
  },

  # The same AST in a single query:
  $engine->query->select('id',
      Selecto::Expression->value(['upper', ['field', 'name']])->as('shout'));

=head1 DESCRIPTION

Computed value expressions are written in a small, closed AST rather than SQL.
The AST is parsed and type-checked against the finished domain, every
literal and JSON path segment is bound, and adapters compile it to their own
dialect. Anything outside the node set is rejected when the domain is
parsed.

=head1 NODES

  ['field', PATH]                      a governed field, may cross associations
  ['literal', VALUE]                   bound; optionally ['literal', VALUE, TYPE]
  ['coalesce', NODE, NODE, ...]
  ['case', [CONDITION, NODE], ..., ['else', NODE]]   conditions use the filter AST
  ['add' | 'subtract' | 'multiply' | 'divide', NODE, NODE]
  ['cast', NODE, TYPE]                 string integer decimal boolean date utc_datetime
  ['json_text', FIELD, [SEGMENT, ...]] segments of letters, digits and underscores
  ['lower' | 'upper', NODE]
  ['concat', NODE, NODE, ...]
  ['previous', COLUMN]                 only in recursive query-member steps

=head1 RULES

=over 4

=item *

Using a computed field in a selection, filter, grouping or ordering adds the
joins its expression reads. Computed fields may build on other computed
fields; cycles are rejected.

=item *

The result type must match the declared column type (an integer result
satisfies a declared C<decimal>).

=item *

C<divide> always produces a decimal, so integer operands never truncate.
C<concat> casts each operand to text and treats null as empty.

=item *

Computed fields are read-only; write contracts cannot grant them.

=item *

The adapter needs the C<value_expressions> capability (and C<json_text> for
that node): PostgreSQL and DuckDB. Others fail with C<unsupported_feature>.

=back

The Perl interface (C<parse>, C<infer>, C<dependencies>, C<category>,
C<compatible>) is used by L<Selecto::Domain> and the adapters and may change;
the AST is the public contract.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain/Computed columns>, L<Selecto::Expression/value>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
