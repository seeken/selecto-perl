package Selecto::DuckDB;

use Mojo::Base 'Selecto::SQL';
use DBI qw(SQL_VARCHAR);
use Scalar::Util qw(blessed);
use Selecto::Error ();

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
        || "$feature" eq 'stream' ? 1 : 0;
}

sub write_capabilities {
    return { %{$_[0]->SUPER::write_capabilities}, returning => 1, write_graph => 1 };
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
    Selecto::Error->throw('query_error', 'DuckDB statement execution failed') unless defined $executed;
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
            week => '%G-W%V', iso_week => '%G-W%V',
            iso_week_date => '%G-W%V-%u', month => '%Y-%m', year => '%Y',
            month_of_year => '%m', month_day => '%m-%d', day_of_month => '%d',
            day_of_week => '%A', day_of_week_num => '%u', day_of_year => '%j', hour => '%H',
        );
        my ($field, $format) = @$arguments;
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

sub _transaction {
    my ($self, $operation) = @_;
    my $value;
    my $ok = eval {
        $self->dbh->do('BEGIN');
        $value = $operation->();
        $self->dbh->do('COMMIT');
        1;
    };
    if (!$ok) {
        my $error = $@;
        eval { $self->dbh->do('ROLLBACK') };
        die $error;
    }
    return $value;
}

1;
