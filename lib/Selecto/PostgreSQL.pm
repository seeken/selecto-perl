package Selecto::PostgreSQL;

use Mojo::Base 'Selecto::SQL';
use Scalar::Util qw(blessed);
use Selecto::Error ();

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
    return "$feature" eq 'transactions' || "$feature" eq 'returning' ? 1 : 0;
}

sub write_capabilities {
    return { %{$_[0]->SUPER::write_capabilities}, returning => 1, write_graph => 1 };
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $self->_compile_count_bucket($domain, $arguments->[0], $arguments->[1], $params)
        if $kind eq 'count_bucket';
    return $self->_compile_bucket($domain, $arguments->[0], $arguments->[1], $params)
        if $kind eq 'bucket';
    if ($kind eq 'datetime_format') {
        my %formats = (
            day => 'YYYY-MM-DD',
            day_hour => 'YYYY-MM-DD HH24',
            week => 'IYYY-IW',
            month => 'YYYY-MM',
            quarter => 'YYYY-"Q"Q',
            year => 'YYYY',
            month_of_year => 'MM',
            day_of_month => 'DD',
            day_of_week => 'ID',
            hour => 'HH24',
        );
        my ($field, $format) = @$arguments;
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed field')
            unless blessed($field) && $field->isa('Selecto::Expression') && $field->kind eq 'field';
        Selecto::Error->throw('invalid_query', 'datetime format is not available')
            unless exists $formats{$format};
        my ($path) = @{$field->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'datetime format requires a date or time field')
            unless $resolved->{type} =~ /(?:date|time)/i;
        return 'TO_CHAR(' . $self->_compile_expression($domain, $field, $params) .
            ", '" . $formats{$format} . "')";
    }
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
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
