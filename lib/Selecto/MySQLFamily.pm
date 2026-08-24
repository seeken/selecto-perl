package Selecto::MySQLFamily;

use Mojo::Base 'Selecto::SQL';
use Selecto::Error ();

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '?';
}

sub quote_identifier {
    my ($self, $identifier) = @_;
    my $quoted = defined($identifier) ? "$identifier" : '';
    $quoted =~ s/`/``/g;
    return "`$quoted`";
}

sub normalize_type {
    my ($self, $name) = @_;
    return {
        int => 'integer',
        decimal => 'decimal',
        datetime => 'naive_datetime',
    }->{lc "$name"} // 'unknown';
}

sub supports {
    my ($self, $feature) = @_;
    return "$feature" eq 'transactions' || "$feature" eq 'stream' ? 1 : 0;
}

sub _compile_upsert_clause {
    my ($self, $conflict, $updates) = @_;
    _checked_identifier($_) for @$conflict;
    return ' ON DUPLICATE KEY UPDATE ' . join(', ', map {
        my $field = _checked_identifier($_);
        $self->quote_identifier($field) . ' = VALUES(' . $self->quote_identifier($field) . ')'
    } @$updates);
}

sub _logical_affected_rows {
    my ($self, $operation, $physical) = @_;
    return 1 if $operation eq 'upsert' && ($physical == 1 || $physical == 2);
    return $physical;
}

sub _column_types {
    my ($self, $sth) = @_;
    return eval { @{$sth->{mariadb_type_name} // []} };
}

sub _decode {
    my ($self, $value, $type) = @_;
    return undef unless defined $value;
    $type = uc($type // '');
    return int($value) if $type =~ /\A(?:BIGINT|INT|INTEGER|SMALLINT|TINYINT)\z/ && "$value" =~ /\A-?\d+\z/;
    if ($type =~ /\A(?:DECIMAL|DOUBLE|FLOAT|NUMERIC|REAL)\z/) {
        my $normalized = "$value";
        $normalized =~ s/(\.\d*?)0+\z/$1/;
        $normalized =~ s/\.\z//;
        return $normalized eq '-0' ? '0' : $normalized;
    }
    if ($type =~ /\A(?:DATETIME|TIMESTAMP)\z/) {
        my $normalized = "$value";
        $normalized =~ tr/ /T/;
        $normalized =~ s/\.0+\z//;
        return $normalized;
    }
    return $value;
}

sub _checked_identifier {
    my ($value) = @_;
    my $string = defined($value) ? "$value" : '';
    Selecto::Error->throw('invalid_identifier', 'invalid SQL identifier')
        unless $string =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return $string;
}

1;
