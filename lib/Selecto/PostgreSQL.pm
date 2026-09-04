package Selecto::PostgreSQL;

use Mojo::Base 'Selecto::SQL';
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Selecto::Expression ();

has rollup_sort_fix => 'auto';

sub name    { return 'postgresql'; }
sub dialect { return __PACKAGE__; }

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '$' . int($index);
}

sub normalize_type {
    my ($self, $name) = @_;
    return { int4 => 'integer', numeric => 'decimal', timestamptz => 'utc_datetime' }->{"$name"} // 'unknown';
}

sub supports {
    my ($self, $feature) = @_;
    return "$feature" eq 'transactions' || "$feature" eq 'returning'
        || "$feature" eq 'rollup' || "$feature" eq 'set_operations'
        || "$feature" eq 'window_functions' || "$feature" eq 'text_search'
        || "$feature" eq 'cte' || "$feature" eq 'recursive_cte'
        || "$feature" eq 'lateral_join' || "$feature" eq 'json_rowset'
        || "$feature" eq 'stream' ? 1 : 0;
}

sub _rollup_sort_fix_enabled {
    my ($self) = @_;
    my $setting = $self->rollup_sort_fix;
    Selecto::Error->throw('invalid_adapter', 'rollup_sort_fix must be auto, true, or false')
        unless defined($setting) && !ref($setting)
            && ("$setting" eq 'auto' || "$setting" eq '1' || "$setting" eq '0');
    return $setting ? 1 : 0 unless "$setting" eq 'auto';
    return $self->{_rollup_sort_fix_enabled}
        if exists $self->{_rollup_sort_fix_enabled};
    my $version = eval { ($self->dbh->selectrow_array('SHOW server_version_num'))[0] };
    my $major = defined($version) && "$version" =~ /\A\d+\z/
        ? int($version / 10_000) : undef;
    return $self->{_rollup_sort_fix_enabled} = defined($major) && $major >= 18 ? 0 : 1;
}

sub write_capabilities {
    return { %{$_[0]->SUPER::write_capabilities}, returning => 1, write_graph => 1 };
}

sub _renumber_placeholders {
    my ($self, $sql, $offset) = @_;
    $sql =~ s/\$(\d+)/q{$} . ($1 + $offset)/ge;
    return $sql;
}

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    my @pairs = $self->_related_collection_json_pairs($spec->{fields}, $spec->{quoted_alias});
    my $aggregate = 'JSON_AGG(JSON_BUILD_OBJECT(' . join(', ', @pairs) . ')' .
        (defined($spec->{order}) ? " ORDER BY $spec->{order}" : '') . ')';
    return $self->_related_collection_aggregate_sql(
        $aggregate, $spec->{from}, $spec->{where}, q{'[]'::json},
    );
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $self->_compile_count_bucket($domain, $arguments->[0], $arguments->[1], $params)
        if $kind eq 'count_bucket';
    return $self->_compile_bucket($domain, $arguments->[0], $arguments->[1], $params)
        if $kind eq 'bucket';
    if ($kind eq 'epoch_datetime') {
        my ($field) = @$arguments;
        Selecto::Error->throw('invalid_query', 'epoch datetime requires a governed field')
            unless blessed($field) && $field->isa('Selecto::Expression') && $field->kind eq 'field';
        my ($path) = @{$field->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'epoch datetime requires an epoch datetime field')
            unless $resolved->{type} eq 'epoch_datetime';
        return 'TO_TIMESTAMP(' . $self->_compile_expression($domain, $field, $params) . ')';
    }
    if ($kind eq 'datetime_format') {
        my %formats = (
            day => 'YYYY-MM-DD',
            time => 'HH24:MI:SS',
            day_hour => 'YYYY-MM-DD HH24',
            week => 'IYYY-IW',
            month => 'YYYY-MM',
            quarter => 'YYYY-"Q"Q',
            year => 'YYYY',
            month_of_year => 'MM',
            month_day => 'MM-DD',
            day_of_month => 'DD',
            day_of_week => 'ID',
            hour => 'HH24',
        );
        my ($field, $format) = @$arguments;
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed temporal field')
            unless blessed($field) && $field->isa('Selecto::Expression')
                && ($field->kind eq 'field' || $field->kind eq 'epoch_datetime');
        Selecto::Error->throw('invalid_query', 'datetime format is not available')
            unless exists $formats{$format};
        my $source = $field->kind eq 'epoch_datetime' ? $field->arguments->[0] : $field;
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed field')
            unless blessed($source) && $source->isa('Selecto::Expression') && $source->kind eq 'field';
        my ($path) = @{$source->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'datetime format requires a date or time field')
            unless $resolved->{type} =~ /(?:date|time)/i;
        return 'TO_CHAR(' . $self->_compile_expression($domain, $field, $params) .
            ", '" . $formats{$format} . "')";
    }
    if ($kind eq 'text_search' || $kind eq 'text_rank') {
        my ($fields, $query, $options) = @$arguments;
        Selecto::Error->throw('invalid_query', 'text search requires at least one governed field')
            unless ref($fields) eq 'ARRAY' && @$fields;
        Selecto::Error->throw('invalid_query', 'text search options must be an object')
            unless ref($options) eq 'HASH';
        Selecto::Error->throw('invalid_query', 'text search query must be a non-empty scalar')
            unless blessed($query) && $query->isa('Selecto::Expression')
                && $query->kind eq 'literal'
                && defined($query->arguments->[0]) && !ref($query->arguments->[0])
                && "$query->arguments->[0]" ne '';
        my %configurations = map { $_ => 1 } qw(
            simple english danish dutch finnish french german hungarian italian
            norwegian portuguese romanian russian spanish swedish turkish
        );
        my $configuration = lc($options->{configuration} // 'simple');
        Selecto::Error->throw('invalid_query', 'text search configuration is not available')
            unless $configurations{$configuration};
        my %modes = (
            plain => 'PLAINTO_TSQUERY',
            phrase => 'PHRASETO_TSQUERY',
            websearch => 'WEBSEARCH_TO_TSQUERY',
            prefix => 'TO_TSQUERY',
        );
        my $mode = lc($options->{mode} // 'plain');
        Selecto::Error->throw('invalid_query', 'text search mode is not available')
            unless $modes{$mode};
        my $document = join(" || ' ' || ", map {
            'COALESCE(CAST(' . $self->_compile_expression($domain, $_, $params) . " AS TEXT), '')"
        } @$fields);
        my $query_sql = $self->_compile_expression($domain, $query, $params);
        my $vector = "TO_TSVECTOR('$configuration', $document)";
        my $tsquery = "$modes{$mode}('$configuration', $query_sql)";
        return "$vector @@ $tsquery" if $kind eq 'text_search';
        return "TS_RANK($vector, $tsquery)";
    }
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
}

sub _compile_json_rowset_join {
    my ($self, $domain, $spec, $params) = @_;
    my $resolved = $domain->resolve($spec->{source_field});
    Selecto::Error->throw('invalid_query', 'JSON rowset source must be a JSON field')
        unless $resolved->{type} =~ /json/i;
    my $source = $self->_compile_expression(
        $domain,
        Selecto::Expression->field($spec->{source_field}),
        $params,
    ) . '::jsonb';
    if (exists($spec->{path})) {
        my $path = $spec->{path};
        Selecto::Error->throw('invalid_query', 'JSON rowset path must be a non-empty string')
            unless defined($path) && !ref($path) && "$path" ne '';
        push @$params, "$path";
        $source = 'JSONB_PATH_QUERY_ARRAY(' . $source . ', ' .
            $self->placeholder(scalar @$params) . '::jsonpath)';
    }
    my %types = (
        integer => 'BIGINT', int => 'BIGINT', bigint => 'BIGINT',
        decimal => 'NUMERIC', numeric => 'NUMERIC', number => 'NUMERIC',
        string => 'TEXT', text => 'TEXT', boolean => 'BOOLEAN',
        date => 'DATE', datetime => 'TIMESTAMP', utc_datetime => 'TIMESTAMPTZ',
        json => 'JSONB', jsonb => 'JSONB',
    );
    my @columns = map {
        my $type = lc("$spec->{columns}{$_}");
        Selecto::Error->throw('invalid_query', "JSON rowset type $type is not portable")
            unless exists $types{$type};
        $self->quote_identifier($_) . ' ' . $types{$type};
    } sort keys %{$spec->{columns}};
    my $keyword = $spec->{type} eq 'cross' ? 'CROSS JOIN LATERAL'
        : $spec->{type} eq 'inner' ? 'INNER JOIN LATERAL' : 'LEFT JOIN LATERAL';
    return $keyword . ' JSONB_TO_RECORDSET(' . $source . ') AS ' .
        $self->quote_identifier($spec->{name}) . ' (' . join(', ', @columns) . ')' .
        ($spec->{type} eq 'cross' ? '' : ' ON TRUE');
}

sub _compile_count_bucket {
    my ($self, $domain, $field, $specification, $params) = @_;
    Selecto::Error->throw('invalid_query', 'bucket count specification must be an object')
        unless ref($specification) eq 'HASH';
    my $mode = $specification->{mode} // 'numeric';
    Selecto::Error->throw('invalid_query', 'bucket count mode is not available')
        unless $mode eq 'numeric' || $mode eq 'elapsed_days';
    my $field_sql = $self->_compile_expression($domain, $field, $params);
    my $value_sql = $mode eq 'elapsed_days'
        ? "CURRENT_DATE - DATE($field_sql)"
        : $field_sql;
    my ($minimum, $maximum) = @{$specification}{qw(minimum maximum)};
    Selecto::Error->throw('invalid_query', 'bucket count requires at least one boundary')
        unless defined($minimum) || defined($maximum);
    Selecto::Error->throw('invalid_query', 'bucket count boundaries must be integers')
        if (defined($minimum) && "$minimum" !~ /\A\d+\z/)
        || (defined($maximum) && "$maximum" !~ /\A\d+\z/);
    my @predicates;
    if (defined($minimum)) {
        push @$params, int($minimum);
        push @predicates, $value_sql . ' >= ' . $self->placeholder(scalar @$params);
    }
    if (defined($maximum)) {
        push @$params, int($maximum);
        push @predicates, $value_sql . ' <= ' . $self->placeholder(scalar @$params);
    }
    return 'COUNT(CASE WHEN ' . join(' AND ', @predicates) . ' THEN 1 END)';
}

sub _compile_bucket {
    my ($self, $domain, $field, $specification, $params) = @_;
    Selecto::Error->throw('invalid_query', 'bucket specification must be an object')
        unless ref($specification) eq 'HASH';
    my $kind = $specification->{kind} // '';
    my $field_sql = $self->_compile_expression($domain, $field, $params);
    my ($path) = @{$field->arguments};
    my $resolved = $domain->resolve($path);

    if ($kind eq 'numeric_increment' || $kind eq 'year_increment') {
        Selecto::Error->throw('invalid_query', 'bucket increment must be a positive integer')
            unless defined($specification->{increment})
            && "$specification->{increment}" =~ /\A[1-9]\d*\z/;
        Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
            if $kind eq 'numeric_increment' && $resolved->{type} !~ /(?:int|decimal|number|numeric|float|double|real)/i;
        Selecto::Error->throw('invalid_query', 'year buckets require a date or time field')
            if $kind eq 'year_increment' && $resolved->{type} !~ /(?:date|time)/i;
        my $value_sql = $kind eq 'year_increment' ? "EXTRACT(YEAR FROM $field_sql)" : $field_sql;
        my $increment = int($specification->{increment});
        my $start = "CAST(FLOOR(CAST($value_sql AS NUMERIC) / $increment) AS BIGINT) * $increment";
        return "CASE WHEN $field_sql IS NULL THEN 'Other' ELSE CAST(($start) AS TEXT) || '-' || " .
            'CAST(((' . $start . ') + ' . ($increment - 1) . ') AS TEXT) END';
    }

    if ($kind eq 'text_prefix') {
        Selecto::Error->throw('invalid_query', 'text prefix bucket requires a text field')
            unless $resolved->{type} =~ /(?:string|text|char|citext)/i;
        my $length = $specification->{prefix_length} // 2;
        Selecto::Error->throw('invalid_query', 'text prefix length must be between 1 and 10')
            unless "$length" =~ /\A\d+\z/ && $length >= 1 && $length <= 10;
        my $normalized = "BTRIM(COALESCE(CAST($field_sql AS TEXT), ''))";
        if ($specification->{exclude_articles}) {
            $normalized = "REGEXP_REPLACE($normalized, '^(a|an|the)([[:space:]]+|$)', '', 'i')";
        }
        $normalized = "LOWER($normalized)" unless exists($specification->{ignore_case}) && !$specification->{ignore_case};
        return "CASE WHEN $normalized = '' THEN 'Other' ELSE UPPER(LEFT($normalized, " . int($length) . ')) END';
    }

    my %range_kinds = map { $_ => 1 } qw(
        numeric_ranges elapsed_days_ranges date_relative_ranges year_ranges
    );
    Selecto::Error->throw('invalid_query', 'bucket kind is not available') unless $range_kinds{$kind};
    Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
        if $kind eq 'numeric_ranges' && $resolved->{type} !~ /(?:int|decimal|number|numeric|float|double|real)/i;
    Selecto::Error->throw('invalid_query', 'temporal buckets require a date or time field')
        if $kind ne 'numeric_ranges' && $resolved->{type} !~ /(?:date|time)/i;
    my $ranges = $specification->{ranges};
    Selecto::Error->throw('invalid_query', 'bucket ranges must be a non-empty array')
        unless ref($ranges) eq 'ARRAY' && @$ranges;
    my $value_sql = $kind eq 'elapsed_days_ranges' ? "CURRENT_DATE - DATE($field_sql)"
        : $kind eq 'year_ranges' ? "EXTRACT(YEAR FROM $field_sql)"
        : $kind eq 'date_relative_ranges' ? "DATE($field_sql)"
        : $field_sql;
    my @clauses;
    for my $range (@$ranges) {
        Selecto::Error->throw('invalid_query', 'bucket range must be an object')
            unless ref($range) eq 'HASH';
        my ($minimum, $maximum, $label) = @{$range}{qw(minimum maximum label)};
        Selecto::Error->throw('invalid_query', 'bucket range label is required')
            unless defined($label) && !ref($label) && length("$label") <= 80;
        my $predicate;
        if ($kind eq 'date_relative_ranges' && defined($minimum) && "$minimum" =~ /\A(?:today|yesterday|tomorrow)\z/) {
            Selecto::Error->throw('invalid_query', 'date keyword bucket boundaries must match')
                unless defined($maximum) && "$maximum" eq "$minimum";
            $predicate = $minimum eq 'today' ? "$value_sql = CURRENT_DATE"
                : $minimum eq 'yesterday' ? "$value_sql = CURRENT_DATE - INTERVAL '1 day'"
                : "$value_sql = CURRENT_DATE + INTERVAL '1 day'";
        } else {
            Selecto::Error->throw('invalid_query', 'bucket range requires at least one boundary')
                unless defined($minimum) || defined($maximum);
            Selecto::Error->throw('invalid_query', 'bucket range boundaries must be integers')
                if (defined($minimum) && "$minimum" !~ /\A\d+\z/)
                || (defined($maximum) && "$maximum" !~ /\A\d+\z/);
            my @predicates;
            if (defined($minimum)) {
                push @$params, int($minimum);
                my $marker = $self->placeholder(scalar @$params);
                push @predicates, $kind eq 'date_relative_ranges'
                    ? "$value_sql <= CURRENT_DATE - ($marker * INTERVAL '1 day')"
                    : "$value_sql >= $marker";
            }
            if (defined($maximum)) {
                push @$params, int($maximum);
                my $marker = $self->placeholder(scalar @$params);
                push @predicates, $kind eq 'date_relative_ranges'
                    ? "$value_sql >= CURRENT_DATE - ($marker * INTERVAL '1 day')"
                    : "$value_sql <= $marker";
            }
            $predicate = join(' AND ', @predicates);
        }
        push @$params, "$label";
        push @clauses, 'WHEN ' . $predicate . ' THEN ' . $self->placeholder(scalar @$params);
    }
    push @$params, 'Other';
    return 'CASE ' . join(' ', @clauses) . ' ELSE ' . $self->placeholder(scalar @$params) . ' END';
}

sub _column_types {
    my ($self, $sth) = @_;
    return eval { @{$sth->{pg_type} // []} };
}

sub _decode {
    my ($self, $value, $type) = @_;
    return undef unless defined $value;
    $type //= '';
    return ($value eq 't' || "$value" eq '1') ? 1 : 0 if $type eq 'bool';
    return int($value) if $type =~ /\A(?:int2|int4|int8)\z/ && "$value" =~ /\A-?\d+\z/;
    if ($type =~ /\A(?:numeric|float4|float8)\z/) {
        my $normalized = "$value";
        $normalized =~ s/(\.\d*?)0+\z/$1/;
        $normalized =~ s/\.\z//;
        return $normalized eq '-0' ? '0' : $normalized;
    }
    if ($type eq 'timestamp' || $type eq 'timestamptz') {
        my $normalized = "$value";
        $normalized =~ tr/ /T/;
        $normalized =~ s/(?:\.0+)?(?:\+00(?::00)?|Z)\z//;
        return $normalized;
    }
    return $value;
}

1;
