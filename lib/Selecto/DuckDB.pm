package Selecto::DuckDB;

use Mojo::Base 'Selecto::SQL';
use Scalar::Util qw(blessed);
use Selecto::Error ();

sub name    { return 'duckdb'; }
sub dialect { return __PACKAGE__; }

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '?';
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

sub _decode {
    my ($self, $value, $type) = @_;
    return $value unless defined($value) && !ref($value);
    if (!utf8::is_utf8($value) && $value =~ /[\x80-\xFF]/) {
        my $decoded = $value;
        utf8::decode($decoded);
        return $decoded;
    }
    return $value;
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
            ? $self->_compile_timezone_sql($sql, 'epoch_datetime', $self->{_timezone}, $params)
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
                my $instant_sql = $self->_compile_expression($domain, $field, $params);
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
            my $instant_sql = $self->_compile_expression($domain, $field, $params);
            if ($resolved->{type} ne 'utc_datetime' && $resolved->{type} ne 'epoch_datetime') {
                if (defined($timezone) && $timezone ne 'UTC') {
                    push @$params, $timezone;
                    $instant_sql = '(' . $instant_sql . ' AT TIME ZONE ?)';
                } else {
                    $instant_sql = '(' . $instant_sql . q{ AT TIME ZONE 'UTC')};
                }
            }
            return 'CAST(FLOOR(EPOCH(' . $instant_sql . ')) AS BIGINT)'
                if $format eq 'epoch_seconds';
            return 'CAST(FLOOR(EPOCH(' . $instant_sql . ') * 1000) AS BIGINT)'
                if $format eq 'epoch_milliseconds';
            return $self->_compile_timezone_offset_sql($instant_sql, $timezone, $params)
                if $format eq 'timezone_offset';
            return $self->_compile_rfc3339_instant_sql(
                $instant_sql, $timezone, $params, 1,
            );
        }
        my $field_sql = $self->_compile_expression($domain, $field, $params);
        return "STRFTIME($field_sql, '%Y') || '-Q' || QUARTER($field_sql)"
            if $format eq 'quarter';
        return "STRFTIME($field_sql, '$formats{$format}')";
    }
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
}

sub _compile_timezone_sql {
    my ($self, $sql, $type, $timezone, $params) = @_;
    push @$params, $timezone;
    return '(' . $sql . ' AT TIME ZONE ?)';
}

sub _compile_iso8601_instant_sql {
    my ($self, $sql, $timezone, $params) = @_;
    return $self->_compile_rfc3339_instant_sql($sql, $timezone, $params, 0);
}

sub _compile_rfc3339_instant_sql {
    my ($self, $sql, $timezone, $params, $milliseconds) = @_;
    my $pattern = $milliseconds ? '%Y-%m-%dT%H:%M:%S.%g' : '%Y-%m-%dT%H:%M:%S';
    return q{STRFTIME((} . $sql . q{ AT TIME ZONE 'UTC'), '} . $pattern . q{') || 'Z'}
        unless defined($timezone) && $timezone ne 'UTC';
    my $localized = sub {
        push @$params, $timezone;
        return '(' . $sql . ' AT TIME ZONE ?)';
    };
    return 'STRFTIME(' . $localized->() . q{, '} . $pattern . q{') || } .
        $self->_compile_timezone_offset_sql($sql, $timezone, $params);
}

sub _compile_timezone_offset_sql {
    my ($self, $sql, $timezone, $params) = @_;
    return q{'+00:00'} unless defined($timezone) && $timezone ne 'UTC';
    my $localized = sub {
        push @$params, $timezone;
        return '(' . $sql . ' AT TIME ZONE ?)';
    };
    my $offset = sub {
        return 'EPOCH(' . $localized->() . ' - (' . $sql . q{ AT TIME ZONE 'UTC'))};
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
