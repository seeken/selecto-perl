package Selecto::DuckDB;

use Mojo::Base 'Selecto::SQL';
use DBI qw(SQL_VARCHAR);
use Scalar::Util qw(blessed refaddr);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::QueryEnforcement ();

sub name    { return 'duckdb'; }
sub dialect { return __PACKAGE__; }
sub _reuses_parameter_identity { return 1; }

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '$' . int($index);
}

sub _renumber_placeholders {
    my ($self, $sql, $offset) = @_;
    return $self->_renumber_dollar_placeholders($sql, $offset);
}

sub normalize_type {
    my ($self, $name) = @_;
    return {
        integer => 'integer',
        bigint => 'integer',
        decimal => 'decimal',
        date => 'date',
        timestamp => 'naive_datetime',
    }->{lc "$name"} // 'unknown';
}

sub supports {
    my ($self, $feature) = @_;
    return "$feature" eq 'transactions' || "$feature" eq 'returning'
        || "$feature" eq 'rollup' || "$feature" eq 'set_operations'
        || "$feature" eq 'window_functions'
        || "$feature" eq 'cte' || "$feature" eq 'recursive_cte'
        || "$feature" eq 'stream' || "$feature" eq 'value_expressions'
        || "$feature" eq 'json_text' ? 1 : 0;
}

# Value expressions cast to fixed targets; bare DECIMAL would round to three
# places, so computed decimals use a wide fixed scale.
sub _value_type_sql {
    my ($self, $type) = @_;
    return 'DECIMAL(38, 10)' if lc("$type") eq 'decimal';
    return $self->SUPER::_value_type_sql($type);
}

sub _compile_json_text {
    my ($self, $field_sql, $segments, $params) = @_;
    my $path = '$' . join('', map { /\A\d+\z/ ? "[$_]" : ".$_" } @$segments);
    push @$params, $path;
    return 'JSON_EXTRACT_STRING(' . $field_sql . ', ' . $self->placeholder(scalar @$params) . ')';
}

sub _values_cast_types {
    return {
        integer => 'BIGINT', int => 'BIGINT', bigint => 'BIGINT',
        # Bare DECIMAL is DECIMAL(18,3) and would round wider scales.
        decimal => \&Selecto::SQL::_values_decimal_sql,
        numeric => \&Selecto::SQL::_values_decimal_sql,
        string => 'VARCHAR', text => 'VARCHAR', boolean => 'BOOLEAN',
        date => 'DATE', datetime => 'TIMESTAMP', naive_datetime => 'TIMESTAMP',
        utc_datetime => 'TIMESTAMPTZ',
    };
}

sub write_capabilities {
    return { %{$_[0]->SUPER::write_capabilities}, returning => 1, generated_keys => 1, write_graph => 1 };
}

sub _query_transport_sql {
    my ($self, $statement) = @_;
    my @columns = @{$statement->columns};
    my @aliases = map { $self->quote_identifier('__selecto_c' . $_) } 0 .. $#columns;
    my $source = $self->quote_identifier('__selecto_result');
    # Serialize only the final result. Native types must remain intact inside
    # grouping, comparisons, aggregates, CTEs, windows and compound queries.
    # DuckDB's single-source SELECT preserves the input result's row order.
    return 'SELECT ' . join(', ', map {
        $self->_transport_value_sql($source . '.' . $aliases[$_]) .
            ' AS ' . $self->quote_identifier($columns[$_])
    } 0 .. $#columns) . ' FROM (' . $statement->sql . ') AS ' . $source .
        ' (' . join(', ', @aliases) . ')';
}

sub _transport_value_sql {
    my ($self, $sql) = @_;
    my $kind = 'TYPEOF(' . $sql . ')';
    my $exact = '(' . $kind . q{ LIKE 'TIMESTAMP%' OR } . $kind .
        q{ LIKE 'DECIMAL(%' OR } . $kind . q{ = 'DATE')};
    # Use the server's exact scalar rendering, not DBD::DuckDB's lossy time
    # conversion or host timezone. Other native values keep their DBI types,
    # including strings, blobs, lists and structs. No JSON number conversion.
    return 'STRUCT_PACK(kind := ' . $kind . ', exact := CASE WHEN ' . $exact .
        ' THEN CAST(' . $sql . ' AS VARCHAR) ELSE NULL END, native := CASE WHEN ' .
        $exact . ' THEN NULL ELSE ' . $sql . ' END)';
}

sub _column_types {
    my ($self, $sth) = @_;
    Selecto::Error->throw('query_error', 'Invalid DuckDB result metadata')
        unless defined($sth->{NUM_OF_FIELDS}) && $sth->{NUM_OF_FIELDS} =~ /\A[0-9]+\z/;
    return ('selecto_duckdb_transport_v1') x $sth->{NUM_OF_FIELDS};
}

sub _execute_statement {
    my ($self, $sth, $params) = @_;
    for my $index (0 .. $#$params) {
        my $value = $params->[$index];
        # DBD::DuckDB otherwise guesses every numeric-looking scalar as DOUBLE,
        # including exact decimal/integer strings and ordinary text. Let the
        # prepared SQL's native type context convert lossless text instead.
        my $bound = ref($value)
            ? $sth->bind_param($index + 1, $value)
            : $sth->bind_param($index + 1, $value, SQL_VARCHAR);
        Selecto::Error->throw('query_error', 'DuckDB parameter binding failed') unless defined $bound;
    }
    my $executed = $sth->execute;
    unless (defined $executed) {
        my $refusal = $self->_refusal_error(eval { $sth->errstr });
        die $refusal if $refusal;
        Selecto::Error->throw('query_error', 'DuckDB statement execution failed');
    }
    return $executed;
}

sub _returning_field_sql {
    my ($self, $field) = @_;
    my $identifier = $self->quote_identifier($field);
    return $self->_transport_value_sql($identifier) . ' AS ' . $identifier;
}

sub _decode_returning_values {
    my ($self, $sth, @values) = @_;
    return map { $self->_decode($_, 'selecto_duckdb_transport_v1') } @values;
}

sub _decode {
    my ($self, $value, $type) = @_;
    if (($type // '') eq 'selecto_duckdb_transport_v1') {
        Selecto::Error->throw('query_error', 'Invalid DuckDB result transport')
            unless ref($value) eq 'HASH' && keys(%$value) == 3
                && exists($value->{exact}) && exists($value->{native})
                && defined($value->{kind}) && !ref($value->{kind});
        my $kind = $value->{kind};
        if ($kind =~ /\A(?:TIMESTAMP|DECIMAL\()/ || $kind eq 'DATE') {
            Selecto::Error->throw('query_error', 'Invalid DuckDB result transport')
                if defined($value->{native}) || ref($value->{exact});
            return undef unless defined $value->{exact};
            my $normalized = "$value->{exact}";
            if ($kind =~ /\ADECIMAL\(/) {
                $normalized =~ s/(\.\d*?)0+\z/$1/;
                $normalized =~ s/\.\z//;
                return $normalized eq '-0' ? '0' : $normalized;
            }
            if ($kind =~ /\ATIMESTAMP/) {
                $normalized =~ s/ /T/;
                $normalized =~ s/(?:\.0+)?(?:\+00(?::00)?|Z)\z//;
            }
            return $normalized;
        }
        Selecto::Error->throw('query_error', 'Invalid DuckDB result transport')
            if defined($value->{exact});
        $value = $value->{native};
        return defined($value) ? ($value ? 1 : 0) : undef if $kind eq 'BOOLEAN';
    }
    return $value unless defined($value) && !ref($value);
    if (!utf8::is_utf8($value) && $value =~ /[\x80-\xFF]/) {
        my $decoded = $value;
        utf8::decode($decoded);
        return $decoded;
    }
    return $value;
}

sub _compile_expression {
    my ($self, $domain, $expression, $params, $selections) = @_;
    return $self->SUPER::_compile_expression($domain, $expression, $params, $selections)
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    # Below a node of a host-trusted predicate, a referenced computed field
    # compiles its comparisons as host identity too.
    my $host_nodes = $self->{_selecto_host_nodes};
    local $self->{_selecto_in_host} = $self->{_selecto_in_host}
        || ($host_nodes && $host_nodes->{refaddr($expression)} ? 1 : 0);
    my $identity = $self->_identity_predicate_sql($domain, $expression, $params);
    return $identity if defined $identity;
    my $kind = $expression->kind;
    my $args = $expression->arguments;
    my %operators = (eq=>'=', ne=>'<>', gt=>'>', gte=>'>=', lt=>'<', lte=>'<=');
    if (exists($operators{$kind}) &&
        ($self->_numeric_field($domain, $args->[0]) || $self->_numeric_field($domain, $args->[1]))) {
        return $self->_numeric_operand($domain, $args->[0], $params) . ' ' . $operators{$kind} . ' ' .
            $self->_numeric_operand($domain, $args->[1], $params);
    }
    if ($kind eq 'between' && $self->_numeric_field($domain, $args->[0])) {
        return $self->_compile_expression($domain, $args->[0], $params) . ' BETWEEN ' .
            $self->_numeric_operand($domain, $args->[1], $params) . ' AND ' .
            $self->_numeric_operand($domain, $args->[2], $params);
    }
    if ($kind eq 'in' && $self->_numeric_field($domain, $args->[0])) {
        Selecto::Error->throw('invalid_query', 'IN requires at least one value')
            unless ref($args->[1]) eq 'ARRAY' && @{$args->[1]};
        return $self->_compile_expression($domain, $args->[0], $params) . ' IN (' .
            join(', ', map { $self->_numeric_parameter($_, $params) } @{$args->[1]}) . ')';
    }
    return $self->SUPER::_compile_expression($domain, $expression, $params, $selections);
}

# ---- Tenant, trusted and host-scope identity ---------------------------------
#
# DuckDB compares VARCHAR under the column's or the session's collation
# (COLLATE NOCASE, SET default_collation), casts a bound text value to a
# numeric column's type with rounding ('1.4' and '1e0' equal INTEGER 1,
# '1.005' equals DECIMAL(18,2) 1.01) and converts DECIMAL to DOUBLE through
# the wrong neighbour. None of that may decide who sees a row. A column that
# decides tenant, trusted or host-scope identity (the engine tenant, the
# writes.scope tenant, tenant-pin required conjuncts, the host's scope and
# trusted predicates, association and bridge where pins, scope keys, tenant
# pairs and member correlations) must therefore have one of these catalog
# types, read from the statement itself (typeof), so the check binds the
# relation and column exactly as the statement does:
#   - an integer type (TINYINT .. HUGEINT, UTINYINT .. UHUGEINT), compared by
#     exact value with a canonical integer literal only ('01' and '+1' as
#     PostgreSQL reads them; '1.0', '1e0' and '1.4' are refused);
#   - VARCHAR, compared by its UTF-8 bytes (encode), which no collation
#     touches;
#   - UUID, by value;
#   - BOOLEAN, with a boolean literal only.
# Any other type (DECIMAL, DOUBLE, REAL, DATE, TIMESTAMP, BLOB, ENUM, ...)
# raises in the statement and is refused with query_rule_not_evaluable,
# reason identity_column_type. Every form is exact under NOT as well (<>,
# NOT IN), unlike a text image of a number.
#
# Ranges (<, <=, >, >=, BETWEEN) in that scope are not identity compares
# but must be exact: a VARCHAR column by its bytes, an integer or DECIMAL
# (scale up to 18) column by exact value with a plain decimal literal, a
# column of a declared temporal or boolean type by its own cast (as
# PostgreSQL casts a literal); anything else, a floating column or a DECIMAL
# of scale above 18, is refused (reasons inexact_text, decimal_scale).
#
# Ordinary caller filters on other columns keep DuckDB's own semantics,
# collation included, for = and ranges alike.

my $INTEGER_TYPES = q{('TINYINT', 'SMALLINT', 'INTEGER', 'BIGINT', 'HUGEINT', 'UTINYINT', 'USMALLINT', 'UINTEGER', 'UBIGINT', 'UHUGEINT')};
my $IDENTITY_TYPES = q{('VARCHAR', 'UUID', 'BOOLEAN', 'TINYINT', 'SMALLINT', 'INTEGER', 'BIGINT', 'HUGEINT', 'UTINYINT', 'USMALLINT', 'UINTEGER', 'UBIGINT', 'UHUGEINT')};

sub _refusal_sql {
    my ($reason, $message) = @_;
    return "error('selecto-refusal:$reason: $message')";
}
my $REFUSED_IDENTITY = _refusal_sql('identity_column_type',
    'a tenant, trusted or host-scope column must be an integer, VARCHAR, UUID or BOOLEAN column on DuckDB');
my $REFUSED_NUMBER = _refusal_sql('inexact_number', 'an integer identity column takes only canonical integer literals');
my $REFUSED_BOOLEAN = _refusal_sql('identity_column_type', 'a BOOLEAN identity column takes only boolean literals');
my $REFUSED_TEXT = _refusal_sql('inexact_text', 'this value cannot be compared exactly with this column');
my $REFUSED_SCALE = _refusal_sql('decimal_scale', 'a DECIMAL of scale above 18 cannot be compared exactly');

sub _exact_identity_compare { return 1; }

sub _identity_bytes_sql { return "encode(CAST($_[1] AS VARCHAR))"; }

# Declared types decide nothing here: the column's catalog type does, in the
# statement. Every identity comparison is classified 2 (decided by the
# server); 0 still means "not identity" (an ordinary member join or filter).
sub _association_identity_exact { return 2; }
sub _guard_identity_exact { return 2; }

sub _identity_field_exact {
    my ($self, $domain, $path) = @_;
    return 0 unless blessed($domain) && $domain->can('resolve') && defined($path) && !ref($path);
    my $resolved = eval { $domain->resolve("$path") };
    return 0 unless ref($resolved) eq 'HASH' && defined $resolved->{field};
    my %names = map { ($_ => 1) } $self->_identity_root_columns($domain);
    if (my $association = $resolved->{association}) {
        my $target = eval { $association->target_tenant_field };
        $names{$target} = 1 if defined $target;
    }
    return 0 unless $names{$resolved->{field}};
    my $metadata = eval { $domain->_field_metadata_view("$path") } // {};
    return 0 if ref($metadata) eq 'HASH' && ref($metadata->{computed}) eq 'HASH';
    return 2;
}

sub _member_pair_exact {
    my ($self, @sides) = @_;
    for my $side (@sides) {
        my ($domain, $path) = @$side;
        next unless defined $domain;
        my $resolved = eval { $domain->resolve("$path") };
        next unless ref($resolved) eq 'HASH' && defined($resolved->{field}) && !$resolved->{association};
        my %names = map { ($_ => 1) } $self->_identity_root_columns($domain),
            Selecto::SQL::_comparison_fields(eval { $domain->required_predicate }, @{$self->{_selecto_trusted_predicates} // []});
        return 2 if $names{$resolved->{field}};
    }
    return 0;
}

# An association's fixed where policy (on its target or a through bridge) is
# domain-authored scope: every pin compares as identity.
sub _constant_join_predicates {
    my ($self, $alias, $where, $params, $types) = @_;
    return () unless ref($where) eq 'HASH' && keys %$where;
    return map {
        my $column = $self->_qualified($alias, $_);
        defined($where->{$_}) ? $self->_identity_values_sql($column, [$where->{$_}], $params, 2) : "$column IS NULL"
    } sort keys %$where;
}

# The identity comparison of $column with one bound value.
sub _identity_value_term {
    my ($self, $column, $value, $params) = @_;
    unless (defined $value) {
        push @$params, undef;
        return "$column = " . $self->placeholder(scalar @$params);
    }
    Selecto::Error->throw('query_rule_not_evaluable', 'an identity comparison requires a scalar value',
        {reason => 'identity_column_type'}) if ref($value) && !_boolean_object($value);
    my $boolean = _boolean_literal($value);
    my $text = _boolean_object($value) ? ($value ? 'true' : 'false') : "$value";
    push @$params, $value;
    my $marker = $self->placeholder(scalar @$params);
    my $type = "typeof($column)";
    my $integer = _canonical_integer($text);
    # R26: a column declared integer over VARCHAR storage compares the
    # canonical integer text by bytes (so '01', ' 1' and '1x' never equal 1);
    # a value that is no integer is refused.
    my $varchar_sql = !$self->{_selecto_declared_integer}
        ? $self->_identity_bytes_sql($column) . ' = ' . $self->_identity_bytes_sql($marker)
        : defined($integer) ? $self->_identity_bytes_sql($column) . " = encode('$integer')" : $REFUSED_NUMBER;
    return "(CASE WHEN $type = 'VARCHAR' THEN $varchar_sql ELSE $column = $marker END)" if $self->{_selecto_required_only};
    my $integer_sql = defined($integer)
        ? "TRY_CAST($column AS DECIMAL(38,0)) = CAST('$integer' AS DECIMAL(38,0))" : $REFUSED_NUMBER;
    my $boolean_sql = defined($boolean) ? "TRY_CAST($column AS BOOLEAN) = $boolean" : $REFUSED_BOOLEAN;
    return "(CASE WHEN $type = 'VARCHAR' THEN $varchar_sql"
        . " WHEN $type IN $INTEGER_TYPES THEN $integer_sql"
        . " WHEN $type = 'UUID' THEN CAST($column AS VARCHAR) = CAST(TRY_CAST(CAST($marker AS VARCHAR) AS UUID) AS VARCHAR)"
        . " WHEN $type = 'BOOLEAN' THEN $boolean_sql"
        . " ELSE $REFUSED_IDENTITY END)";
}

sub _boolean_object {
    my ($value) = @_;
    return 1 if blessed($value) && ($value->isa('JSON::PP::Boolean') || $value->isa('Mojo::JSON::_Bool'));
    return 1 if !ref($value) && defined(&builtin::is_bool) && do { no warnings; builtin::is_bool($value) };
    return 0;
}

# TRUE or FALSE for a value PostgreSQL reads as a boolean literal, else undef.
sub _boolean_literal {
    my ($value) = @_;
    return undef unless defined $value;
    return $value ? 'TRUE' : 'FALSE' if _boolean_object($value);
    return undef if ref $value;
    my $text = lc("$value");
    $text =~ s/\A\s+|\s+\z//g;
    return 'TRUE' if $text =~ /\A(?:t|tr|tru|true|y|ye|yes|on|1)\z/;
    return 'FALSE' if $text =~ /\A(?:f|fa|fal|fals|false|n|no|off|of|0)\z/;
    return undef;
}

# The canonical digits of an integer literal (optional sign, leading zeros
# allowed as PostgreSQL reads them), or undef.
sub _canonical_integer {
    my ($text) = @_;
    return undef unless defined($text) && $text =~ /\A\s*([+-]?)0*(\d+)\s*\z/a;
    my ($sign, $digits) = ($1, $2);
    return undef if length($digits) > 38;
    return $digits eq '0' ? '0' : ($sign eq '-' ? '-' : '') . $digits;
}

# The plain decimal text of a value DECIMAL(38,18) holds exactly, or undef.
sub _exact_decimal {
    my ($text) = @_;
    return undef unless defined($text) && !ref($text) && "$text" =~ /\A\s*([+-]?)(\d*)(?:\.(\d*))?\s*\z/a;
    my ($sign, $whole, $fraction) = ($1, $2, $3 // '');
    return undef unless length($whole) || length($fraction);
    $whole =~ s/\A0+//;
    $fraction =~ s/0+\z//;
    return undef if length($whole) > 20 || length($fraction) > 18;
    my $number = (length($whole) ? $whole : '0') . (length($fraction) ? ".$fraction" : '');
    return $number eq '0' ? '0' : ($sign eq '-' ? '-' : '') . $number;
}

sub _identity_values_sql {
    my ($self, $column, $values, $params, $exact) = @_;
    return $self->SUPER::_identity_values_sql($column, $values, $params) unless $exact;
    Selecto::Error->throw('query_rule_not_evaluable', 'an identity comparison requires values',
        {reason => 'identity_column_type'}) unless ref($values) eq 'ARRAY' && @$values;
    my @terms = map { $self->_identity_value_term($column, $_, $params) } @$values;
    return @terms == 1 ? $terms[0] : '(' . join(' OR ', @terms) . ')';
}

# Two identity columns: both of an identity type; two integers compare by
# value, anything else by the bytes of its text (an INTEGER 7 never matches
# a VARCHAR '07' or ' 7').
sub _identity_pair_sql {
    my ($self, $left, $right) = @_;
    my ($lt, $rt) = ("typeof($left)", "typeof($right)");
    return "(CASE WHEN $lt NOT IN $IDENTITY_TYPES OR $rt NOT IN $IDENTITY_TYPES THEN $REFUSED_IDENTITY"
        . " WHEN $lt IN $INTEGER_TYPES AND $rt IN $INTEGER_TYPES"
        . " THEN TRY_CAST($left AS DECIMAL(38,0)) = TRY_CAST($right AS DECIMAL(38,0))"
        . ' ELSE ' . $self->_identity_bytes_sql($left) . ' = ' . $self->_identity_bytes_sql($right) . ' END)';
}

sub _identity_equal_sql {
    my ($self, $left, $right, $exact) = @_;
    return "$left = $right" unless $exact;
    return $self->_identity_pair_sql($left, $right);
}

sub _identity_correlation_sql {
    my ($self, $inner, $outer, $exact) = @_;
    return $self->SUPER::_identity_correlation_sql($inner, $outer) unless $exact;
    return '(' . $self->_identity_pair_sql($inner, $outer) . " OR ($inner IS NULL AND $outer IS NULL))";
}

my %RANGE = (gt => '>', gte => '>=', lt => '<', lte => '<=');
my %FLIP = (gt => 'lt', gte => 'lte', lt => 'gt', lte => 'gte');

# Declared types whose own cast of a text literal PostgreSQL shares.
sub _known_cast_type {
    my ($type) = @_;
    return 0 unless defined($type) && !ref($type);
    return lc("$type") =~ /\A(?:date|time|datetime|timestamp|naive_datetime|utc_datetime|boolean|bool)\z/ ? 1 : 0;
}

sub _identity_range_sql {
    my ($self, $column, $operator, $value, $type, $params) = @_;
    my $kind = "typeof($column)";
    if ($self->{_selecto_required_only} && defined($value) && !ref($value)) {
        push @$params, "$value";
        my $marker = $self->placeholder(scalar @$params);
        my $varchar = $self->{_selecto_declared_integer} ? $REFUSED_TEXT
            : $self->_identity_bytes_sql($column) . " $operator " . $self->_identity_bytes_sql($marker);
        return "(CASE WHEN $kind = 'VARCHAR' THEN $varchar ELSE $column $operator $marker END)";
    }
    my ($text_sql, $number_sql, $other_sql) = ($REFUSED_TEXT, $REFUSED_TEXT, $REFUSED_TEXT);
    if (defined($value) && !ref($value)) {
        push @$params, "$value";
        my $marker = $self->placeholder(scalar @$params);
        $text_sql = $self->_identity_bytes_sql($column) . " $operator " . $self->_identity_bytes_sql($marker)
            unless $self->{_selecto_declared_integer};
        my $number = _exact_decimal("$value");
        $number_sql = "TRY_CAST($column AS DECIMAL(38,18)) $operator CAST('$number' AS DECIMAL(38,18))" if defined $number;
        $other_sql = "$column $operator $marker" if _known_cast_type($type);
    }
    return "(CASE WHEN $kind = 'VARCHAR' THEN $text_sql"
        . " WHEN $kind IN ('DOUBLE', 'FLOAT', 'REAL') THEN $REFUSED_TEXT"
        . " WHEN regexp_matches($kind, '^DECIMAL\\([0-9]+,(19|[2-9][0-9])\\)\$') THEN $REFUSED_SCALE"
        . " WHEN $kind IN $INTEGER_TYPES OR $kind LIKE 'DECIMAL(%' THEN $number_sql"
        . " ELSE $other_sql END)";
}

# Whether $operand is an identity column of this compile: a tenant or scope
# column of its relation (whatever the comparison's origin, so a caller = and
# a caller range on it agree), or any field compared by a host-trusted
# predicate.
sub _identity_operand {
    my ($self, $domain, $operand, $host) = @_;
    return 0 unless blessed($operand) && $operand->isa('Selecto::Expression');
    return $host ? 2 : 0 unless $operand->kind eq 'field' && !ref($operand->arguments->[0]);
    return 2 if $self->_identity_field_exact($domain, $operand->arguments->[0]);
    return $host ? 2 : 0;
}

sub _declared_type {
    my ($self, $domain, $operand) = @_;
    return undef unless blessed($operand) && $operand->kind eq 'field' && !ref($operand->arguments->[0]);
    my $resolved = eval { $domain->resolve($operand->arguments->[0]) };
    return ref($resolved) eq 'HASH' ? $resolved->{type} : undef;
}

# Whether $expression decides tenant, trusted or host-scope identity in the
# strict sense of item 49: it compares a tenant or scope column, or it is a
# node of a trusted predicate (host scope, canned page or co-domain scope,
# write scope) or of an authored member query.
sub _strict_identity_node {
    my ($self, $domain, $expression) = @_;
    for my $operand (grep { blessed($_) && $_->isa('Selecto::Expression') } @{$expression->arguments}) {
        return 1 if $operand->kind eq 'field' && !ref($operand->arguments->[0])
            && $self->_identity_field_exact($domain, $operand->arguments->[0]);
    }
    my %strict = map { (refaddr($_) => 1) } Selecto::SQL::_expression_nodes(@{$self->{_selecto_trusted_predicates} // []},
        @{(blessed($domain) ? $domain->{_selecto_authored_predicates} : undef) // []});
    return $strict{refaddr($expression)} ? 1 : 0;
}

# A comparison (eq, ne, IN, a range or BETWEEN) that decides identity, as
# SQL, or undef for an ordinary one.
sub _identity_predicate_sql {
    my ($self, $domain, $expression, $params) = @_;
    my $kind = $expression->kind;
    my $text_match = $kind =~ /\A(?:starts_with|text_contains|ends_with)(?:_ci)?\z/ ? 1 : 0;
    return undef unless $text_match || $kind =~ /\A(?:eq|ne|in|gt|gte|lt|lte|between)\z/;
    my $host = ($self->{_selecto_host_conjuncts} && $self->{_selecto_host_conjuncts}{refaddr($expression)})
        || ($self->{_selecto_host_nodes} && $self->{_selecto_host_nodes}{refaddr($expression)})
        || $self->{_selecto_in_host} ? 1 : 0;
    my $arguments = $expression->arguments;
    # A plain required filter (R3 clarification) on a column that is not a
    # tenant or scope column, outside the trusted and authored predicates,
    # compares a VARCHAR by its bytes but every other type natively: the
    # identity-type refusal (item 49) is not extended to it.
    local $self->{_selecto_required_only} = $host && !$self->_strict_identity_node($domain, $expression) ? 1 : 0;
    my ($subject) = @$arguments;
    $subject = $arguments->[1] if !(blessed($subject) && $subject->isa('Selecto::Expression') && $subject->kind eq 'field')
        && blessed($arguments->[1]) && $arguments->[1]->isa('Selecto::Expression') && $arguments->[1]->kind eq 'field';
    my $declared = $self->_declared_type($domain, $subject);
    local $self->{_selecto_declared_integer} = defined($declared) && !ref($declared)
        && "$declared" =~ /\A(?:integer|int|bigint|smallint|tinyint|mediumint|serial|bigserial)\z/i ? 1 : 0;
    return $self->_identity_text_match_sql($domain, $expression, $params, $host) if $text_match;
    my $literal = sub { blessed($_[0]) && $_[0]->isa('Selecto::Expression') && $_[0]->kind eq 'literal' };
    my $field = sub { blessed($_[0]) && $_[0]->isa('Selecto::Expression') && $_[0]->kind ne 'literal' };
    if ($kind eq 'in') {
        my ($left, $values) = @$arguments;
        return undef unless ref($values) eq 'ARRAY' && $self->_identity_operand($domain, $left, $host);
        return $self->_identity_values_sql($self->_compile_expression($domain, $left, $params), [@$values], $params, 2);
    }
    if ($kind eq 'between') {
        my ($operand, $low, $high) = @$arguments;
        return undef unless $self->_identity_operand($domain, $operand, $host);
        my $type = $self->_declared_type($domain, $operand);
        my $column = $self->_compile_expression($domain, $operand, $params);
        my @bounds = map { $literal->($_) ? $_->arguments->[0] : $_ } $low, $high;
        return undef if grep { ref($_) } @bounds;
        return '(' . $self->_identity_range_sql($column, '>=', $bounds[0], $type, $params) . ' AND '
            . $self->_identity_range_sql($column, '<=', $bounds[1], $type, $params) . ')';
    }
    my ($left, $right) = @$arguments;
    my ($left_identity, $right_identity) = map { $self->_identity_operand($domain, $_, $host) } $left, $right;
    return undef unless $left_identity || $right_identity;
    if ($kind eq 'eq' || $kind eq 'ne') {
        my $sql;
        if ($field->($left) && $field->($right)) {
            $sql = $self->_identity_pair_sql($self->_compile_expression($domain, $left, $params),
                $self->_compile_expression($domain, $right, $params));
        } else {
            my ($operand, $value) = $literal->($right) ? ($left, $right) : $literal->($left) ? ($right, $left) : return undef;
            $sql = $self->_identity_values_sql($self->_compile_expression($domain, $operand, $params),
                [$value->arguments->[0]], $params, 2);
        }
        return $kind eq 'ne' ? "NOT $sql" : $sql;
    }
    # A range against a literal; a range between two columns stays plain.
    my ($operand, $value, $operator) = $literal->($right) ? ($left, $right, $kind)
        : $literal->($left) ? ($right, $left, $FLIP{$kind}) : return undef;
    return undef unless $field->($operand);
    return $self->_identity_range_sql($self->_compile_expression($domain, $operand, $params), $RANGE{$operator},
        $value->arguments->[0], $self->_declared_type($domain, $operand), $params);
}

# A prefix, substring or suffix match on an identity column (brief item R3)
# matches the VARCHAR's bytes, under COLLATE posix, whatever the column's or
# the session's collation (NOCASE would let tenant t1 match T1); on any other
# column type it is refused. The case-insensitive matches cannot be made
# exact there and are refused. Ordinary caller matches keep DuckDB's own.
sub _identity_text_match_sql {
    my ($self, $domain, $expression, $params, $host) = @_;
    my ($operand, $literal) = @{$expression->arguments};
    return undef unless $self->_identity_operand($domain, $operand, $host);
    my $kind = $expression->kind;
    Selecto::Error->throw('query_rule_not_evaluable',
        'a case-insensitive match on a tenant or scope column cannot be compared exactly',
        {reason => 'inexact_text'}) if $kind =~ /_ci\z/;
    my $text = blessed($literal) && $literal->isa('Selecto::Expression') && $literal->kind eq 'literal'
        ? $literal->arguments->[0] : undef;
    Selecto::Error->throw('invalid_query', "$kind requires a literal string value") if !defined($text) || ref($text);
    my $column = $self->_compile_expression($domain, $operand, $params);
    $text = $self->_escape_like("$text");
    push @$params, $kind eq 'text_contains' ? "%$text%" : $kind eq 'ends_with' ? "%$text" : "$text%";
    my $marker = $self->placeholder(scalar @$params);
    my $other = $self->{_selecto_required_only} ? "CAST($column AS VARCHAR) LIKE $marker ESCAPE '!'" : $REFUSED_TEXT;
    my $varchar = $self->{_selecto_declared_integer} ? $REFUSED_TEXT : "(CAST($column AS VARCHAR) COLLATE posix) LIKE $marker ESCAPE '!'";
    return "(CASE WHEN typeof($column) = 'VARCHAR' THEN $varchar"
        . " ELSE $other END)";
}

# A computed field (a predicate body, a value expression's condition, a
# nested computed field) referenced by a host-trusted predicate is host scope
# as well; referenced by a caller filter it stays plain.
sub _compile_authored_condition {
    my ($self, $domain, $ast, $params) = @_;
    return $self->SUPER::_compile_authored_condition($domain, $ast, $params) unless $self->{_selecto_in_host};
    my $expression = $self->_authored_condition($ast);
    local $self->{_selecto_host_nodes} = {%{$self->{_selecto_host_nodes} // {}},
        map { (refaddr($_) => 1) } Selecto::SQL::_expression_nodes($expression)};
    return $self->_compile_expression($domain, $expression, $params);
}

# A member's group keys, when one of its outputs is joined or correlated
# with its root as identity, group by their UTF-8 bytes as well as their
# value, so collation-equal keys of other tenants ('T1' under NOCASE or
# default_collation) are not merged into the root's group; the value stays
# in GROUP BY, so selecting it remains valid. Numbered parameters let both
# copies share one binding.
sub _compile_group_expression {
    my ($self, $domain, $expression, $params, $byte_groups) = @_;
    my $sql = $self->SUPER::_compile_group_expression($domain, $expression, $params);
    return $sql unless ref($byte_groups) eq 'HASH' && $byte_groups->{all} && blessed($expression);
    return $self->_identity_bytes_sql($sql) . ", $sql";
}

sub _reused_group_sql {
    my ($self, $sql, $expression, $byte_groups) = @_;
    return $sql unless ref($byte_groups) eq 'HASH' && $byte_groups->{all} && blessed($expression);
    return $self->_identity_bytes_sql($sql) . ", $sql";
}

# Write predicates, foreign-key guards and stored-row checks compare the
# command's identity columns (the engine's __selecto_tenant_fields, and
# every field its scope predicate or query enforcement reads) the same way.
sub _write_identity_columns {
    my ($self, $command) = @_;
    my $metadata = blessed($command) && $command->can('metadata') ? $command->metadata : {};
    my $fields = ref($metadata->{__selecto_tenant_fields}) eq 'ARRAY' ? $metadata->{__selecto_tenant_fields} : [];
    my $types = ref($metadata->{__selecto_insert_types}) eq 'HASH' ? $metadata->{__selecto_insert_types}
        : ref($metadata->{field_types}) eq 'HASH' ? $metadata->{field_types} : {};
    my @host = blessed($command) && $command->can('scope_predicate')
        ? map { Selecto::Expression->field_references($_) } grep { defined } $command->scope_predicate,
            defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef
        : ();
    my %tenant = map { ($_ => 1) } grep { defined($_) && !ref($_) } @$fields;
    return {map { ($_ => {type => $types->{$_}, tenant => $tenant{$_} ? 1 : 0}) } grep { defined($_) && !ref($_) && !/\./ } @$fields, @host};
}

# Every expression node of a write's scope (scope predicate, query
# enforcement, post-image scope): only these, and the tenant columns, take
# the identity compare; the caller's own predicate keeps DuckDB's semantics
# (item 55, R25).
sub _write_scope_nodes {
    my ($command) = @_;
    return {} unless blessed($command) && $command->can('scope_predicate');
    my $metadata = $command->can('metadata') ? $command->metadata : {};
    return {map { (refaddr($_) => 1) } Selecto::SQL::_expression_nodes($command->scope_predicate,
        defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef,
        ref($metadata) eq 'HASH' ? $metadata->{__selecto_post_image_scope} : undef)};
}

sub _compile_write {
    my ($self, $command) = @_;
    local $self->{_selecto_identity_columns} = $self->_write_identity_columns($command);
    local $self->{_selecto_write_scope_nodes} = _write_scope_nodes($command);
    return $self->SUPER::_compile_write($command);
}

sub _execute_compiled_write_in_transaction {
    my ($self, $command, @rest) = @_;
    local $self->{_selecto_identity_columns} = $self->_write_identity_columns($command);
    local $self->{_selecto_write_scope_nodes} = _write_scope_nodes($command);
    return $self->SUPER::_execute_compiled_write_in_transaction($command, @rest);
}

sub _compile_write_predicate {
    my ($self, $expression, $params) = @_;
    my $columns = $self->{_selecto_identity_columns};
    if ($columns && %$columns && blessed($expression) && $expression->isa('Selecto::Expression')
        && $expression->kind =~ /\A(?:eq|ne|in|gt|gte|lt|lte)\z/) {
        my $kind = $expression->kind;
        my ($left, $right) = @{$expression->arguments};
        my $field = blessed($left) && $left->isa('Selecto::Expression') && $left->kind eq 'field'
            ? $left->arguments->[0] : undef;
        my $scoped = $self->{_selecto_write_scope_nodes} && $self->{_selecto_write_scope_nodes}{refaddr($expression)};
        if (defined($field) && !ref($field) && $columns->{$field} && ($scoped || $columns->{$field}{tenant})) {
            my $column = $self->quote_identifier(Selecto::Identifier::checked($field));
            if ($kind eq 'in') {
                Selecto::Error->throw('query_rule_unsupported_predicate', 'query-enforced IN requires values')
                    unless ref($right) eq 'ARRAY' && @$right;
                return $self->_identity_values_sql($column, [@$right], $params, 2);
            }
            my $value = Selecto::SQL::_write_literal($right);
            return $self->_identity_range_sql($column, $RANGE{$kind}, $value, $columns->{$field}{type}, $params)
                if $RANGE{$kind};
            my $sql = $self->_identity_values_sql($column, [$value], $params, 2);
            return $kind eq 'ne' ? "NOT $sql" : $sql;
        }
    }
    return $self->SUPER::_compile_write_predicate($expression, $params);
}

# A refusal raised in a statement (error('selecto-refusal:<reason>: ...'))
# is the typed query_rule_not_evaluable it stands for.
sub _refusal_error {
    my ($self, @texts) = @_;
    for my $text (@texts) {
        next unless defined($text) && "$text" =~ /selecto-refusal:([a-z_]+):/;
        return Selecto::Error->new(code => 'query_rule_not_evaluable',
            message => 'this comparison cannot be decided exactly on DuckDB', details => {reason => $1});
    }
    return undef;
}

sub normalize_error {
    my ($self, $error) = @_;
    return $error if blessed($error) && $error->isa('Selecto::Error');
    my $refusal = $self->_refusal_error(eval { "$error" }, eval { $self->{dbh}->errstr });
    return $refusal // $self->SUPER::normalize_error($error);
}

sub _compile_single {
    my ($self, $domain, $query, %options) = @_;
    my %sources;
    for my $spec (@{$query->ctes}, @{$query->lateral_joins}) {
        my $source_query = $spec->{query} // $spec->{anchor};
        my $selections = $source_query->selections;
        for my $index (0 .. $#{$spec->{columns}}) {
            $sources{$spec->{name} . '.' . $spec->{columns}[$index]} =
                $self->_expression_numeric_type($spec->{domain}, $selections->[$index]);
        }
    }
    local $self->{_numeric_source_types} = \%sources;
    return $self->SUPER::_compile_single($domain, $query, %options);
}

sub _expression_numeric_type {
    my ($self, $domain, $expression) = @_;
    return '' unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    return 'integer' if $kind =~ /\A(?:count|count_field|count_distinct|true_count|false_count)\z/;
    return 'decimal' if $kind eq 'true_percentage';
    return $self->_expression_numeric_type($domain, $expression->arguments->[0])
        if $kind =~ /\A(?:min|max|sum|sum_zero|avg)\z/;
    return '' unless $kind eq 'field';
    my $resolved = eval { $domain->resolve($expression->arguments->[0]) };
    return $resolved ? $resolved->{type} : '';
}

sub _numeric_field {
    my ($self, $domain, $expression) = @_;
    return 0 unless blessed($expression) && $expression->isa('Selecto::Expression')
        && $expression->kind eq 'field';
    my $type = $self->{_numeric_source_types}{$expression->arguments->[0]} //
        $self->_expression_numeric_type($domain, $expression);
    return $type =~ /\A(?:integer|bigint|decimal|numeric|epoch_datetime)\z/
        && !($type eq 'epoch_datetime' && defined $self->{_timezone});
}

sub _numeric_operand {
    my ($self, $domain, $expression, $params) = @_;
    return $self->_numeric_parameter($expression->arguments->[0], $params)
        if $expression->kind eq 'literal';
    return $self->_compile_expression($domain, $expression, $params);
}

sub _numeric_parameter {
    my ($self, $value, $params) = @_;
    if (!defined $value) { push @$params, undef; return $self->placeholder(scalar @$params); }
    Selecto::Error->throw('invalid_query', 'numeric parameter must be exact base-10 text')
        if ref($value) || "$value" !~ /\A-?\d+(?:\.\d+)?\z/;
    my $unsigned = "$value";
    $unsigned =~ s/\A-//;
    my ($whole, $fraction) = split /\./, $unsigned, 2;
    $whole =~ s/\A0+//;
    $fraction //= '';
    $fraction =~ s/0+\z//;
    my $scale = length($fraction);
    my $precision = length($whole) + $scale;
    $precision ||= 1;
    Selecto::Error->throw('unsupported_precision', 'numeric parameter exceeds DuckDB precision')
        if $precision > 38;
    push @$params, $value;
    # Establish the parameter's own scale before comparison. An untyped text
    # value would otherwise round to the column scale (20.2501 equals 20.25).
    return 'CAST(' . $self->placeholder(scalar @$params) . ' AS DECIMAL(' . $precision . ',' . $scale . '))';
}

sub _compile_mutation_expression {
    my ($self, $expression, $params, $operation, $top_level) = @_;
    local $self->{_numeric_mutation} = $self->{_numeric_mutation} ||
        (blessed($expression) && $expression->kind =~ /\A(?:add|subtract|multiply|divide)\z/);
    return $self->_numeric_parameter($expression->arguments->[0], $params)
        if $self->{_numeric_mutation} && blessed($expression) && $expression->kind eq 'literal';
    return $self->SUPER::_compile_mutation_expression($expression, $params, $operation, $top_level);
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind eq 'epoch_datetime') {
        my ($field) = @$arguments;
        Selecto::Error->throw('invalid_query', 'epoch datetime requires a governed field')
            unless blessed($field) && $field->isa('Selecto::Expression')
                && $field->kind eq 'field';
        my ($path) = @{$field->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'epoch datetime requires an epoch datetime field')
            unless $resolved->{type} eq 'epoch_datetime';
        local $self->{_suppress_field_timezone} = 1;
        my $sql = 'TO_TIMESTAMP(' . $self->_compile_expression($domain, $field, $params) . ')';
        return defined($self->{_timezone})
            ? $self->_compile_timezone_sql($sql, 'utc_datetime', $self->{_timezone}, $params)
            : $sql;
    }
    if ($kind eq 'datetime_format') {
        my %formats = (
            day => '%Y-%m-%d', time => '%H:%M:%S', day_hour => '%Y-%m-%d %H',
            day_minute => '%Y-%m-%d %H:%M',
            week => '%G-W%V', iso_week => '%G-W%V',
            iso_week_date => '%G-W%V-%u', month => '%Y-%m', year => '%Y',
            month_of_year => '%m', month_day => '%m-%d', day_of_month => '%d',
            day_of_week => '%A', day_of_week_num => '%u', day_of_year => '%j', hour => '%H',
            us_date => '%m/%d/%Y', us_datetime => '%m/%d/%Y %-I:%M %p',
        );
        my ($field, $format, $timezone) = @$arguments;
        local $self->{_timezone} = $timezone // $self->{_timezone};
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed temporal field')
            unless blessed($field) && $field->isa('Selecto::Expression')
                && ($field->kind eq 'field' || $field->kind eq 'epoch_datetime');
        Selecto::Error->throw('invalid_query', 'datetime format is not available')
            unless $format eq 'quarter'
                || $format =~ /\A(?:iso8601|rfc3339_millis|epoch_seconds|epoch_milliseconds|timezone_offset)\z/
                || exists $formats{$format};
        my $source = $field->kind eq 'epoch_datetime' ? $field->arguments->[0] : $field;
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed field')
            unless blessed($source) && $source->isa('Selecto::Expression')
                && $source->kind eq 'field';
        my ($path) = @{$source->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'datetime format requires a date or time field')
            unless $resolved->{type} =~ /(?:date|time)/i;
        if ($format eq 'iso8601') {
            if ($resolved->{type} eq 'date') {
                return 'STRFTIME(' . $self->_compile_expression($domain, $field, $params) .
                    q{, '%Y-%m-%d')};
            }
            if ($resolved->{type} eq 'utc_datetime' || $resolved->{type} eq 'epoch_datetime') {
                my $timezone = $self->{_timezone};
                local $self->{_suppress_field_timezone} = 1;
                local $self->{_timezone};
                my $instant_sql = sub { $self->_compile_expression($domain, $field, $params) };
                return $self->_compile_iso8601_instant_sql(
                    $instant_sql, $timezone, $params,
                );
            }
            return 'STRFTIME(' . $self->_compile_expression($domain, $field, $params) .
                q{, '%Y-%m-%dT%H:%M:%S')};
        }
        if ($format =~ /\A(?:rfc3339_millis|epoch_seconds|epoch_milliseconds|timezone_offset)\z/) {
            my $timezone = $self->{_timezone};
            local $self->{_suppress_field_timezone} = 1;
            local $self->{_timezone};
            # Each occurrence is compiled with its own ordered bindings.
            # Group-expression reuse is handled by the shared compiler.
            my $instant_sql = sub {
                my $sql = $self->_compile_expression($domain, $field, $params);
                if ($resolved->{type} ne 'utc_datetime' && $resolved->{type} ne 'epoch_datetime') {
                    if (defined($timezone) && $timezone ne 'UTC') {
                        push @$params, $timezone;
                        $sql = '(' . $sql . ' AT TIME ZONE ' . $self->placeholder(scalar @$params) . ')';
                    } else {
                        $sql = '(' . $sql . q{ AT TIME ZONE 'UTC')};
                    }
                }
                return $sql;
            };
            return 'CAST(FLOOR(EPOCH(' . $instant_sql->() . ')) AS BIGINT)'
                if $format eq 'epoch_seconds';
            return 'CAST(FLOOR(EPOCH(' . $instant_sql->() . ') * 1000) AS BIGINT)'
                if $format eq 'epoch_milliseconds';
            return $self->_compile_timezone_offset_sql($instant_sql, $timezone, $params)
                if $format eq 'timezone_offset';
            return $self->_compile_rfc3339_instant_sql(
                $instant_sql, $timezone, $params, 1,
            );
        }
        my $field_sql = $self->_compile_expression($domain, $field, $params);
        if ($format eq 'quarter') {
            my $quarter_sql = $self->_compile_expression($domain, $field, $params);
            return "STRFTIME($field_sql, '%Y') || '-Q' || QUARTER($quarter_sql)";
        }
        return "STRFTIME($field_sql, '$formats{$format}')";
    }
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
}

# A naive TIMESTAMP holding UTC becomes TIMESTAMPTZ.
sub _compile_naive_utc_instant_sql {
    my ($self, $sql) = @_;
    return '(' . $sql . q{ AT TIME ZONE 'UTC')};
}

sub _current_date_shortcuts { return 1 }
sub _months_interval_sql { return 'TO_MONTHS(' . int($_[1]) . ')' }
sub _month_day_sql { return "STRFTIME($_[1], '%m-%d')" }

sub _compile_timezone_sql {
    my ($self, $sql, $type, $timezone, $params) = @_;
    # Keep storage conversion separate from presentation-zone conversion.
    $sql = 'TO_TIMESTAMP(' . $sql . ')' if $type eq 'epoch_datetime';
    push @$params, $timezone;
    return '(' . $sql . ' AT TIME ZONE ' . $self->placeholder(scalar @$params) . ')';
}

sub _compile_iso8601_instant_sql {
    my ($self, $sql, $timezone, $params) = @_;
    return $self->_compile_rfc3339_instant_sql($sql, $timezone, $params, 0);
}

sub _compile_rfc3339_instant_sql {
    my ($self, $sql, $timezone, $params, $milliseconds) = @_;
    my $pattern = $milliseconds ? '%Y-%m-%dT%H:%M:%S.%g' : '%Y-%m-%dT%H:%M:%S';
    return q{STRFTIME((} . $sql->() . q{ AT TIME ZONE 'UTC'), '} . $pattern . q{') || 'Z'}
        unless defined($timezone) && $timezone ne 'UTC';
    my $localized = sub {
        my $instant = $sql->();
        push @$params, $timezone;
        return '(' . $instant . ' AT TIME ZONE ' . $self->placeholder(scalar @$params) . ')';
    };
    return 'STRFTIME(' . $localized->() . q{, '} . $pattern . q{') || } .
        $self->_compile_timezone_offset_sql($sql, $timezone, $params);
}

sub _compile_timezone_offset_sql {
    my ($self, $sql, $timezone, $params) = @_;
    unless (defined($timezone) && $timezone ne 'UTC') {
        my $instant = $sql->();
        return q{CASE WHEN } . $instant . q{ IS NULL THEN NULL ELSE CAST('+00:00' AS TEXT) END};
    }
    my $localized = sub {
        my $instant = $sql->();
        push @$params, $timezone;
        return '(' . $instant . ' AT TIME ZONE ' . $self->placeholder(scalar @$params) . ')';
    };
    my $offset = sub {
        return 'EPOCH(' . $localized->() . ' - (' . $sql->() . q{ AT TIME ZONE 'UTC'))};
    };
    my $sign_offset = $offset->();
    return q{CASE WHEN } . $sign_offset . q{ >= 0 THEN '+' ELSE '-' END || } .
        q{PRINTF('%02d:%02d', CAST(TRUNC(ABS(} . $offset->() . q{)/3600) AS BIGINT), } .
        q{CAST(TRUNC(ABS(} . $offset->() . q{) % 3600 / 60) AS BIGINT))};
}

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    my @pairs = $self->_related_collection_json_pairs($spec->{fields}, $spec->{quoted_alias});
    my $aggregate = 'JSON_GROUP_ARRAY(JSON_OBJECT(' . join(', ', @pairs) . '))';
    return $self->_related_collection_aggregate_sql(
        $aggregate, $spec->{from}, $spec->{where}, q{'[]'},
    );
}

sub _related_collection_text_sql {
    my ($self, $sql) = @_;
    return "CAST($sql AS VARCHAR)";
}

# DuckDB's own BEGIN, COMMIT and ROLLBACK statements control a managed
# write. A BEGIN that fails (the host opened a transaction with raw SQL) is
# not rolled back.
sub _begin_transaction    { return $_[0]->_transaction_statement('BEGIN'); }
sub _commit_transaction   { return $_[0]->_transaction_statement('COMMIT'); }
sub _rollback_transaction { return $_[0]->_transaction_statement('ROLLBACK'); }

sub _transaction_statement {
    my ($self, $sql) = @_;
    defined($self->dbh->do($sql))
        or die Selecto::SQL::_dbi_error($self->dbh, "database $sql failed");
    return;
}

# DuckDB has no savepoints, so a managed write cannot run inside a
# transaction the host holds open without committing or discarding the
# host's work. It is refused instead.
# External mode runs the write directly: DuckDB has no savepoints, so a
# write that Selecto could refuse after its statement changed rows would
# leave that DML for the host to commit. Such writes are refused before any
# DML (_refuse_unverifiable_external); the rest run directly.
sub _external_transaction {
    my ($self, $operation) = @_;
    return $operation->();
}

# Whether a refusal could follow DML that changed rows. Selecto's
# post-statement checks on this adapter are the cardinality check (an
# expected count or declared cardinality, and the engine's row ceiling), the
# foreign-key guard check and the RETURNING row check; the last two refuse
# only when nothing was affected. A count check is harmless only when no
# affected row count from 1 up to the most the write can reach could fail
# it: an insert or upsert reaches one row, an update or delete the identity
# bound of its predicate on the governing primary key (unbounded without
# one).
sub _post_statement_refusable {
    my ($self, $command) = @_;
    my $bounds = $self->_validate_write_cardinality($command);
    my ($minimum, $maximum) = ($bounds->{minimum} // 0, $bounds->{maximum});
    my $operation = $command->operation;
    my $reach;
    if ($operation eq 'insert' || $operation eq 'upsert') {
        $reach = 1;
    } elsif (exists $command->metadata->{__selecto_primary_key}
        && $self->_enforced_unique_key_duckdb($command->relation, $command->metadata->{__selecto_primary_key})) {
        my $primary = $command->metadata->{__selecto_primary_key};
        my @keys = ref($primary) eq 'ARRAY' ? @$primary : ($primary);
        my $predicate = Selecto::QueryEnforcement::combine($command->predicate, $command->scope_predicate,
            defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef);
        $reach = 1;
        for my $key (@keys) {
            my $bound = Selecto::SQL::_write_identity_bound($predicate, $key);
            if (!defined $bound) { $reach = undef; last }
            $reach *= $bound;
        }
    }
    return 1 if $minimum > 1 && (!defined($reach) || $reach >= 1);
    return 1 if defined($maximum) && (!defined($reach) || $reach > $maximum);
    return 0;
}

# True when the declared key contains every column of an enforced PRIMARY
# KEY, or of a UNIQUE constraint whose columns are all NOT NULL, on the
# relation the write resolves to: a session temporary table shadows first,
# then the current database's current schema; other schemas and ATTACHed
# databases never match, and a view or unknown relation is not keyed. Any
# catalog failure counts as not enforced (the write's reach is then
# unbounded).
sub _enforced_unique_key_duckdb {
    my ($self, $relation, $primary) = @_;
    my @keys = grep { defined && !ref } ref($primary) eq 'ARRAY' ? @$primary : ($primary);
    return 0 unless @keys && defined($relation) && !ref($relation);
    my %want = map { (lc($_) => 1) } @keys;
    my $dbh = $self->dbh;
    my $enforced = eval {
        my ($database, $schema, $table) = $dbh->selectrow_array(q{
            SELECT database_name, schema_name, table_name FROM duckdb_tables()
            WHERE lower(table_name) = lower(?)
              AND ((database_name = 'temp' AND schema_name = 'main')
                OR (database_name = current_database() AND schema_name = current_schema()))
            ORDER BY CASE WHEN database_name = 'temp' THEN 0 ELSE 1 END LIMIT 1}, undef, "$relation");
        return 0 unless defined $table;
        # A schema search path other than the default can resolve the name
        # elsewhere: not proven.
        my ($search_path) = $dbh->selectrow_array(q{SELECT current_setting('search_path')});
        return 0 if defined($search_path) && $search_path ne '';
        my (%nullable, %text);
        for my $row (@{$dbh->selectall_arrayref(q{
            SELECT column_name, is_nullable, data_type FROM duckdb_columns()
            WHERE database_name = ? AND schema_name = ? AND table_name = ?}, undef, $database, $schema, $table)}) {
            $nullable{lc $row->[0]} = $row->[1] ? 1 : 0;
            # DuckDB compares a text key under its collation (COLLATE NOCASE,
            # default_collation) and casts it to a literal's type ('01' = 1),
            # so a text key never identifies at most one row per value.
            $text{lc $row->[0]} = ($row->[2] // '') =~ /CHAR|TEXT|STRING|BLOB|BYTEA|BINARY|BIT|JSON|ENUM/i ? 1 : 0;
        }
        my %constraints;
        for my $row (@{$dbh->selectall_arrayref(q{
            SELECT constraint_index, constraint_type, unnest(constraint_column_names) FROM duckdb_constraints()
            WHERE database_name = ? AND schema_name = ? AND table_name = ?
              AND constraint_type IN ('PRIMARY KEY', 'UNIQUE')}, undef, $database, $schema, $table)}) {
            my ($index, $type, $column) = @$row;
            my $entry = $constraints{$index} //= {primary => $type eq 'PRIMARY KEY', columns => []};
            push @{$entry->{columns}}, lc($column // '');
        }
        for my $entry (values %constraints) {
            my @columns = @{$entry->{columns}};
            next unless @columns;
            return 1 unless grep { !$want{$_} || ($text{$_} // 1) || (!$entry->{primary} && ($nullable{$_} // 1)) } @columns;
        }
        0;
    };
    return $enforced ? 1 : 0;
}

# Any check at all: in a batch or graph a later command's refusal, even one
# that changes nothing itself, leaves the earlier commands' DML behind.
sub _post_statement_checked {
    my ($command) = @_;
    return defined($command->expected_count) || exists($command->metadata->{expected_cardinality})
        || @{$command->foreign_key_guards} || exists($command->metadata->{__selecto_primary_key})
        || @{$command->metadata->{returning} // []};
}

# External mode and a transaction_handler run the write directly in a
# transaction Selecto does not own, with no savepoint to undo it.
sub _writes_without_savepoint {
    my ($self) = @_;
    return ($self->transaction_mode // '') eq 'external' || defined($self->transaction_handler);
}

sub _refuse_unverifiable_external {
    my ($self, @commands) = @_;
    return unless $self->_writes_without_savepoint;
    my $refusable = @commands > 1 ? grep { _post_statement_checked($_) } @commands
        : grep { $self->_post_statement_refusable($_) } @commands;
    Selecto::Error->throw('transaction_unavailable',
        'DuckDB has no savepoints: in external or handler mode a write that could be refused after its statement cannot undo its DML',
        {reason => 'no_savepoints'}) if $refusable;
    return;
}

sub execute_write_unsafe {
    my ($self, $command) = @_;
    $self->_refuse_unverifiable_external($command)
        if blessed($command) && $command->isa('Selecto::Write::Command');
    return $self->SUPER::execute_write_unsafe($command);
}

sub execute_batch_unsafe {
    my ($self, $batch) = @_;
    $self->_refuse_unverifiable_external(@{$batch->commands}) if blessed($batch) && $batch->can('commands');
    return $self->SUPER::execute_batch_unsafe($batch);
}

sub execute_graph_unsafe {
    my ($self, $graph) = @_;
    if (blessed($graph) && $graph->can('nodes') && $self->_writes_without_savepoint) {
        my @nodes = @{$graph->nodes};
        # A later node's binding or check can fail after an earlier node ran.
        Selecto::Error->throw('transaction_unavailable',
            'DuckDB has no savepoints: in external or handler mode a multi-node graph cannot undo its own DML',
            {reason => 'no_savepoints'}) if @nodes > 1;
        $self->_refuse_unverifiable_external(map { $_->{command} } @nodes);
    }
    return $self->SUPER::execute_graph_unsafe($graph);
}

# A transaction_handler's work runs directly: DuckDB has no savepoints.
sub _handler_unit {
    my ($self, $operation) = @_;
    return $operation->();
}

sub _savepoint_transaction {
    Selecto::Error->throw(
        'invalid_adapter',
        'DuckDB has no savepoints; inside an open transaction use transaction_mode external',
    );
}

1;

__END__

=head1 NAME

Selecto::DuckDB - DuckDB adapter

=head1 SYNOPSIS

  my $dbh = DBI->connect('dbi:DuckDB:dbname=:memory:', '', '',
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});
  my $adapter = Selecto->adapter(duckdb => (dbh => $dbh));

=head1 DESCRIPTION

Registered as C<duckdb>; needs L<DBD::DuckDB> 0.16 or newer. It uses
double-quoted identifiers and numbered C<$1> parameters.

Supported: transactions, CTEs and recursive CTEs, window functions, set
operations, C<ROLLUP>, streaming, computed value expressions and
C<json_text>, and writes with C<RETURNING> and write graphs. Lateral joins,
JSON and array rowsets, array predicates, full-text search and row locks fail
closed.

DuckDB has no savepoints. A managed write on a handle with C<AutoCommit> off
fails with C<invalid_adapter> instead of committing or discarding the host's
work; use C<< transaction_mode => 'external' >> there (see
L<Selecto::SQL/transaction_mode>). In external mode, and under a
C<transaction_handler>, a write runs directly in the host's transaction, so one that Selecto could refuse after its statement
changed rows is refused before any DML with C<transaction_unavailable>
(details C<< {reason => 'no_savepoints'} >>): a single write whose expected
count or declared C<expected_cardinality> (or the engine's row ceiling)
could fail for some affected count from 1 up to the rows it can reach (one
for an insert or upsert, the primary-key identity bound of an update's or
delete's predicate when that key is an enforced PRIMARY KEY or NOT NULL
UNIQUE constraint of the resolved table whose columns are all non-text
(a text key is compared under its collation and cast to a literal's type)
and the schema search path is the default; unbounded otherwise), a batch of more than one
command when any carries an expected count, declared cardinality,
foreign-key guards, RETURNING or engine governance, and any graph of more
than one node. Foreign-key guard and RETURNING checks refuse only when
nothing was affected, so a single guarded write still runs. Writes that
cannot be refused after their statement run directly as before; for
example C<expected_count => 1> on an update by primary key.

Tenant, trusted and host-scope identity is decided by the catalog type of
the column the statement binds (C<typeof>, so a temporary table, the
search path and case folding resolve as in the statement itself): an
integer column compares by exact value with a canonical integer literal
only, VARCHAR by its UTF-8 bytes (no column collation or
C<default_collation> applies), UUID by value and BOOLEAN with a boolean
literal. Any other type is refused with C<query_rule_not_evaluable>
(details C<< {reason => 'identity_column_type'} >>); a fractional or
exponent literal on an integer column with reason C<inexact_number>. This
covers the engine tenant, writes.scope tenants, required tenant pins, the
host's scope and trusted predicates, association and bridge where pins,
scope keys, tenant pairs and member correlations, for reads and writes,
under C<=>, C<< <> >>, C<IN> and C<NOT IN>. Ranges in that scope compare
VARCHAR by bytes and integer or DECIMAL (scale up to 18) columns by exact
value; a floating column, a wider DECIMAL or a non-numeric literal is
refused (C<inexact_text>, C<decimal_scale>). A query member whose output is
joined or correlated with its root as identity groups its keys by their
bytes too. Ordinary caller filters on other columns keep DuckDB's own
semantics, collation included.

DBD::DuckDB 0.16 decodes some timestamps and decimals inexactly and infers
numeric-looking strings as floating point. The adapter works around this
without patching the driver: scalar parameters are bound as C<VARCHAR>,
governed numeric comparisons cast each parameter to its own exact
C<DECIMAL> scale, and results pass through an adapter-owned final projection
that carries dates, timestamps and decimals as server-rendered text. Scalar
booleans are returned as 0 or 1. Values inside nested list or struct values
are not repaired. The
details are in F<docs/duckdb-result-transport.md> in the distribution.

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>, L<DBD::DuckDB>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
