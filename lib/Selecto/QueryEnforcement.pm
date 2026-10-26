package Selecto::QueryEnforcement;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Selecto::CanonicalJSON ();
use Scalar::Util qw(blessed);
use Encode ();
use Math::BigInt ();
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
    # A retargeted query's predicate describes the target relation, not the
    # root rows a write would change.
    Selecto::Error->throw('invalid_query', 'query enforcement cannot use a retargeted query')
        if defined $query->retarget_spec;
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

# The in-process candidate evaluator (query_enforced_scalar v2,
# specification 2.37): each comparison is decided by the compared column's
# DECLARED type, never by what the operands look like. $fields maps a field
# to its declared type: a type string, or {type => ..., metadata =>
# 'verified' | 'base_verified' | 'unverified', deterministic => 0|1 (the
# catalog's collation verdict, when known)}. A bare type string, and a spec
# without metadata, are 'unverified' unless $options{metadata} says
# otherwise: a declared domain name alone is unverified (fail closed).
# $options{backend} is 'mysql_family' on MySQL/MariaDB (its binary
# collations are deterministic by name), anything else otherwise.
#
# Results are 'true', 'false' or 'unknown' (SQL three-valued logic); a
# comparison the evaluator cannot decide in process raises
# query_rule_not_evaluable, which callers defer to their verified-storage or
# stored-row check when they have one. Text compares UTF-8 bytes exactly
# (no locale, collation, case folding, normalisation or trimming); text
# ranges are refused; numbers compare as exact decimals; every other type
# decides only byte-identical eq/ne. Operands are the text the write binds.
sub evaluate {
    my ($expression, $candidate, $fields, %options) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte)\z/) {
        my $field = _root_field($arguments->[0]);
        my $right = $arguments->[1];
        # Never read a column operand as a literal, never compare two
        # candidate columns in process (wave-3 9i).
        _not_evaluable() if blessed($right) && $right->isa('Selecto::Expression') && $right->kind eq 'field';
        _unsupported() unless blessed($right) && $right->kind eq 'literal';
        _not_evaluable($field) unless exists $candidate->{$field};
        my $column = column_spec($fields, $field, %options);
        my $actual = _operand_text($candidate->{$field});
        return 'unknown' unless defined $actual;
        _check_stored($column, $actual);
        my $expected = _operand_text($right->arguments->[0]);
        return 'unknown' unless defined $expected;
        return _decide($column, $kind, $actual, $expected);
    }
    if ($kind eq 'is_null' || $kind eq 'not_null') {
        my $field = _root_field($arguments->[0]);
        _not_evaluable($field) unless exists $candidate->{$field};
        my $value = defined($candidate->{$field}) ? 'false' : 'true';
        return $kind eq 'not_null' ? _negate($value) : $value;
    }
    if ($kind eq 'in') {
        my $field = _root_field($arguments->[0]);
        _unsupported() unless ref($arguments->[1]) eq 'ARRAY';
        _not_evaluable($field) unless exists $candidate->{$field};
        my $column = column_spec($fields, $field, %options);
        my $actual = _operand_text($candidate->{$field});
        return 'unknown' unless defined $actual;
        _check_stored($column, $actual);
        # Every element is decided before the answer: one refusal refuses
        # the whole list, even after a match.
        my ($unknown, $matched) = (0, 0);
        for my $element (@{$arguments->[1]}) {
            my $expected = _operand_text($element);
            if (!defined $expected) { $unknown = 1; next; }
            $matched = 1 if _decide($column, 'eq', $actual, $expected) eq 'true';
        }
        return $matched ? 'true' : $unknown ? 'unknown' : 'false';
    }
    if ($kind eq 'and' || $kind eq 'or') {
        my @values = map { evaluate($_, $candidate, $fields, %options) } @{$arguments->[0]};
        if ($kind eq 'and') {
            return 'false' if grep { $_ eq 'false' } @values;
            return (grep { $_ eq 'unknown' } @values) ? 'unknown' : 'true';
        }
        return 'true' if grep { $_ eq 'true' } @values;
        return (grep { $_ eq 'unknown' } @values) ? 'unknown' : 'false';
    }
    return _negate(evaluate($arguments->[0], $candidate, $fields, %options)) if $kind eq 'not';
    _unsupported();
}

sub predicate_fingerprint_value {
    my ($expression) = @_;
    my $json = Selecto::CanonicalJSON->encode_utf8(_predicate_value($expression));
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

# --- v2 declared-type classification -------------------------------------

my %TEXT = map { ($_ => 1) } ('string', 'text', 'varchar', 'character varying', 'nvarchar', 'tinytext',
    'mediumtext', 'longtext', 'clob');
my %CHAR_FAMILY = map { ($_ => 1) } qw(char character nchar bpchar);
my %INTEGER = (
    tinyint => ['-128', '127'], smallint => ['-32768', '32767'], int2 => ['-32768', '32767'],
    smallserial => ['-32768', '32767'], mediumint => ['-8388608', '8388607'],
    integer => ['-2147483648', '2147483647'], int => ['-2147483648', '2147483647'],
    int4 => ['-2147483648', '2147483647'], serial => ['-2147483648', '2147483647'],
    bigint => ['-9223372036854775808', '9223372036854775807'], int8 => ['-9223372036854775808', '9223372036854775807'],
    bigserial => ['-9223372036854775808', '9223372036854775807'],
);
my %DECIMAL = map { ($_ => 1) } qw(decimal numeric);
my %TEMPORAL = map { ($_ => 1) } ('date', 'time', 'timetz', 'datetime', 'naive_datetime', 'naive_datetime_usec',
    'utc_datetime', 'utc_datetime_usec', 'timestamp', 'timestamptz', 'timestamp with time zone',
    'timestamp without time zone', 'time with time zone', 'time without time zone', 'epoch_datetime');
my %BASE_VERIFIED_IDENTITY = map { ($_ => 1) } qw(uuid citext boolean bool enum);
my %TIME_DEPENDENT = map { ($_ => 1) } qw(now today tomorrow yesterday);
my %DETERMINISTIC = map { ($_ => 1) } qw(c posix ucs_basic pg_c_utf8);
my %MYSQL_CHARSETS = map { ($_ => 1) } qw(armscii8 ascii big5 binary cp1250 cp1251 cp1256 cp1257 cp850 cp852
    cp866 cp932 dec8 eucjpms euckr gb18030 gb2312 gbk geostd8 greek hebrew hp8 keybcs2 koi8r koi8u latin1
    latin2 latin5 latin7 macce macroman sjis swe7 tis620 ucs2 ujis utf16 utf16le utf32 utf8 utf8mb3 utf8mb4);
my %METADATA = map { ($_ => 1) } qw(verified base_verified unverified);

# A declared type name, parsed: {base, params (array), unbounded, invalid,
# collation, class ('text' | 'numeric' | 'identity'), undeclared}.
sub classify_type {
    my ($type, %options) = @_;
    return {class => 'identity', undeclared => 1, params => []} unless defined($type) && !ref($type);
    my $name = lc("$type");
    $name =~ s/\A\s+|\s+\z//g;
    $name =~ s/\s+(?:character\s+set|charset)\s+[^\s()]+//g;
    my $collation;
    if ($name =~ s/\s+collate\s+("[^"]*"|`[^`]*`|'[^']*'|[^\s()]+)//) {
        $collation = $1;
        $collation =~ s/\A["`']|["`']\z//g;
    }
    my ($params, $unbounded, $invalid) = ([], 0, 0);
    if ($name =~ /\(([^()]*)\)/) {
        my $group = $1;
        if ($group =~ /\A\s*-?[0-9]+\s*(?:,\s*-?[0-9]+\s*)*\z/) {
            $params = [map { 0 + $_ } map { s/\s+//gr } split /,/, $group];
        } elsif ($group =~ /\A\s*max\s*\z/) {
            $unbounded = 1;
        } else {
            $invalid = 1;
        }
    } elsif ($name =~ /[()]/) {
        $invalid = 1;
    }
    1 while $name =~ s/\([^()]*\)//;
    $invalid = 1 if $name =~ /[()]/;
    $name =~ s/\s+/ /g;
    $name =~ s/\A\s+|\s+\z//g;
    my %spec = (base => $name, params => $params, unbounded => $unbounded, invalid => $invalid,
        defined($collation) ? (collation => $collation) : ());
    # 'max' means unbounded only on a text base.
    $spec{invalid} = 1 if $unbounded && !$TEXT{$name};
    my $deterministic = !defined($collation) ? 1 : _deterministic_collation($collation, %options);
    $deterministic = $options{deterministic} ? 1 : 0 if defined $options{deterministic};
    $spec{class} = $spec{invalid} || !$deterministic ? 'identity'
        : $TEXT{$name} ? 'text'
        : ($INTEGER{$name} || $DECIMAL{$name}) ? 'numeric'
        : 'identity';
    return \%spec;
}

sub _deterministic_collation {
    my ($collation, %options) = @_;
    return 1 if $DETERMINISTIC{$collation};
    return 0 unless ($options{backend} // '') eq 'mysql_family';
    return $collation =~ /\A([a-z0-9]+)_(?:nopad_|0900_)?bin\z/ && $MYSQL_CHARSETS{$1} ? 1 : 0;
}

# The declared column of $field: its parsed type plus its metadata level.
sub column_spec {
    my ($fields, $field, %options) = @_;
    my $declared = ref($fields) eq 'HASH' ? $fields->{$field} : undef;
    my %given = ref($declared) eq 'HASH' ? %$declared : (type => $declared);
    my $metadata = $given{metadata} // $options{metadata} // 'unverified';
    $metadata = 'unverified' unless $METADATA{$metadata};
    my $spec = classify_type($given{type}, backend => $given{backend} // $options{backend},
        (defined($given{deterministic}) ? (deterministic => $given{deterministic}) : ()));
    return {%$spec, metadata => $metadata};
}

# A candidate or expected operand as the exact text the write binds. NULL
# is undef. Native references (JSON booleans, objects) have no canonical
# bound text the evaluator can reproduce: they are refused.
sub _operand_text {
    my ($value) = @_;
    return undef unless defined $value;
    _not_evaluable() if ref $value;
    return "$value";
}

# Step 3: the candidate must be a value the column stores unchanged.
sub _check_stored {
    my ($column, $actual) = @_;
    my $base = $column->{base} // '';
    _not_evaluable() if $column->{undeclared} || $column->{invalid};
    _not_evaluable() if $column->{metadata} eq 'unverified';
    if ($column->{metadata} eq 'base_verified') {
        _not_evaluable() unless $INTEGER{$base} || $TEXT{$base} || $CHAR_FAMILY{$base} || $BASE_VERIFIED_IDENTITY{$base};
        _not_evaluable() if !$INTEGER{$base} && $actual =~ / \z/;
    }
    my @params = @{$column->{params}};
    if ($TEXT{$base} || $CHAR_FAMILY{$base}) {
        _not_evaluable() if index($actual, "\0") >= 0;
        if (@params) {
            _not_evaluable() if @params > 1;
            _not_evaluable() if length($actual) > $params[0];
        }
    } elsif ($INTEGER{$base} || $DECIMAL{$base}) {
        my $number = _finite_decimal($actual) or _not_evaluable();
        if ($INTEGER{$base}) {
            _not_evaluable() if $number->{fraction_digits};
            my ($low, $high) = @{$INTEGER{$base}};
            _not_evaluable() if _order($number, _finite_decimal($low)) < 0 || _order($number, _finite_decimal($high)) > 0;
        } elsif (@params) {
            _not_evaluable() if @params > 2;
            my ($precision, $scale) = (@params, 0);
            _not_evaluable() if $precision < 1 || $scale < 0 || $scale > $precision;
            _not_evaluable() if $number->{fraction_digits} > $scale
                || $number->{integer_digits}->bcmp($precision - $scale) > 0;
        }
    } elsif ($column->{metadata} eq 'verified' && @params) {
        # timestamp(0), time(3), float(24), bit(4) transform the stored value.
        _not_evaluable();
    }
    if ($TEMPORAL{$base}) {
        my $input = lc($actual);
        $input =~ s/\A\s+|\s+\z//g;
        _not_evaluable() if $TIME_DEPENDENT{$input};
    }
    return;
}

# Steps 4-8 for one comparison with a non-NULL expected operand.
sub _decide {
    my ($column, $kind, $actual, $expected) = @_;
    my $base = $column->{base} // '';
    my $class = $column->{metadata} eq 'base_verified' && !$INTEGER{$base} ? 'identity' : $column->{class};
    if ($class eq 'text') {
        _not_evaluable() if index($expected, "\0") >= 0;
        _not_evaluable() unless $kind eq 'eq' || $kind eq 'ne';
        my $same = _bytes($actual) eq _bytes($expected);
        return ($kind eq 'eq' ? $same : !$same) ? 'true' : 'false';
    }
    if ($class eq 'numeric') {
        my $left = _finite_decimal($actual) or _not_evaluable();
        my $right = _finite_decimal($expected) or _not_evaluable();
        my $comparison = _order($left, $right);
        my $match = {
            eq => $comparison == 0, ne => $comparison != 0, gt => $comparison > 0,
            gte => $comparison >= 0, lt => $comparison < 0, lte => $comparison <= 0,
        }->{$kind};
        return $match ? 'true' : 'false';
    }
    # identity: only byte-identical operands are decided.
    _not_evaluable() unless ($kind eq 'eq' || $kind eq 'ne') && _bytes($actual) eq _bytes($expected);
    return $kind eq 'eq' ? 'true' : 'false';
}

sub _bytes { my ($text) = @_; return Encode::encode('UTF-8', $text); }

# A finite ASCII decimal (optional ASCII whitespace, sign, digits with an
# optional point, an exponent of any size), exactly: {sign, digits (no
# leading or trailing zeros), point (BigInt: digits before the point),
# integer_digits (BigInt), fraction_digits}. Anything else is undef; no
# platform number parsing is used.
sub _finite_decimal {
    my ($value) = @_;
    return undef unless defined($value) && !ref($value);
    return undef unless "$value" =~ /\A[ \t\r\n\f\x0b]*([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?[ \t\r\n\f\x0b]*\z/;
    my ($sign, $whole, $fraction, $leading_fraction, $exponent) = ($1, $2 // '', $3, $4, $5);
    $fraction = $leading_fraction // $fraction // '';
    my $digits = $whole . $fraction;
    # Host BigInt rounding defaults must not affect policy decisions.
    local $Math::BigInt::accuracy;
    local $Math::BigInt::precision;
    my $point = Math::BigInt->new($exponent // '0')->badd(length($whole));
    $digits =~ /\A(0*)/;
    $point->bsub(length($1));
    $digits =~ s/\A0+//;
    $digits =~ s/0+\z//;
    return {sign => 0, digits => '', point => Math::BigInt->bzero, integer_digits => Math::BigInt->bzero,
        fraction_digits => 0} unless length $digits;
    my $integer_digits = $point->is_pos ? $point->copy : Math::BigInt->bzero;
    my $fraction_digits = Math::BigInt->new(length($digits))->bsub($point);
    $fraction_digits = Math::BigInt->bzero if $fraction_digits->is_neg;
    # A fraction this long is never stored unchanged by any declared scale.
    return {sign => $sign eq '-' ? -1 : 1, digits => $digits, point => $point,
        integer_digits => $integer_digits,
        fraction_digits => $fraction_digits->bcmp(1_000_000) > 0 ? 1_000_000 : $fraction_digits->numify};
}

# Exact decimal order of two parsed finite decimals.
sub _order {
    my ($left, $right) = @_;
    return $left->{sign} <=> $right->{sign} if $left->{sign} != $right->{sign};
    return 0 unless $left->{sign};
    local $Math::BigInt::accuracy;
    local $Math::BigInt::precision;
    my $order = $left->{point}->bcmp($right->{point});
    unless ($order) {
        my $length = length($left->{digits}) > length($right->{digits}) ? length($left->{digits}) : length($right->{digits});
        $order = ($left->{digits} . ('0' x ($length - length($left->{digits}))))
            cmp ($right->{digits} . ('0' x ($length - length($right->{digits}))));
    }
    return $left->{sign} * $order;
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
    my ($field) = @_;
    Selecto::Error->throw(
        'query_rule_not_evaluable',
        defined($field)
            ? "query rule requires insert field $field"
            : 'query rule cannot be evaluated against insert candidate',
        defined($field) ? {field => $field, missing_fields => [$field]} : {},
    );
}

1;

__END__

=head1 NAME

Selecto::QueryEnforcement - query-derived evidence that guards a later write

=head1 DESCRIPTION

Captures the predicate of a governed query so that
L<Selecto::Engine/enforce_query> can require it again, in the same statement,
when a write executes. For inserts it evaluates the candidate row against the
captured rule with SQL three-valued logic, by each field's declared type
(query_enforced_scalar v2): exact UTF-8 bytes for text, exact decimals for
numbers, byte identity otherwise; whatever it cannot decide raises
C<query_rule_not_evaluable> for the verified-storage check.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Engine>, L<Selecto::Write>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
