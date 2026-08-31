package Selecto::MSSQL;

use Mojo::Base 'Selecto::SQL';
use DBI qw(:sql_types);
use Selecto::Error ();
use Selecto::Identifier ();

sub name    { return 'mssql'; }
sub dialect { return __PACKAGE__; }

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '?';
}

sub quote_identifier {
    my ($self, $identifier) = @_;
    my $quoted = defined($identifier) ? "$identifier" : '';
    $quoted =~ s/\]/\]\]/g;
    return "[$quoted]";
}

sub normalize_type {
    my ($self, $name) = @_;
    return {
        int => 'integer',
        numeric => 'decimal',
        datetime2 => 'naive_datetime',
    }->{lc "$name"} // 'unknown';
}

sub supports {
    my ($self, $feature) = @_;
    return "$feature" eq 'transactions' || "$feature" eq 'set_operations'
        || "$feature" eq 'window_functions' || "$feature" eq 'cte'
        || "$feature" eq 'stream' ? 1 : 0;
}

sub _compile_pagination {
    my ($self, $limit, $offset, $ordered) = @_;
    return '' unless defined($limit) || defined($offset);
    Selecto::Error->throw('invalid_query', 'Microsoft SQL Server pagination requires an order')
        unless $ordered;
    my $sql = ' OFFSET ' . (defined($offset) ? int($offset) : 0) . ' ROWS';
    $sql .= ' FETCH NEXT ' . int($limit) . ' ROWS ONLY' if defined $limit;
    return $sql;
}

sub _compile_write {
    my ($self, $command) = @_;
    return $self->SUPER::_compile_write($command) unless $command->operation eq 'upsert';

    my $relation = Selecto::Identifier::checked($command->relation);
    my $assignments = $command->assignments;
    my @fields = sort keys %$assignments;
    Selecto::Error->throw('invalid_write', 'upsert requires assignments') unless @fields;

    my $metadata = $command->metadata;
    my $conflict = $metadata->{conflict_target};
    my $updates = $metadata->{upsert_update_fields};
    Selecto::Error->throw('invalid_write', 'upsert conflict target must be a non-empty string array')
        unless ref($conflict) eq 'ARRAY' && @$conflict && !grep { ref($_) } @$conflict;
    Selecto::Error->throw('invalid_write', 'upsert update fields must be a non-empty string array')
        unless ref($updates) eq 'ARRAY' && @$updates && !grep { ref($_) } @$updates;

    my %assigned = map { $_ => 1 } @fields;
    for my $field (@$conflict, @$updates) {
        $field = Selecto::Identifier::checked($field);
        Selecto::Error->throw('invalid_write', 'upsert conflict and update fields must be assigned')
            unless $assigned{$field};
    }

    my @quoted = map { $self->quote_identifier(Selecto::Identifier::checked($_)) } @fields;
    my @params;
    my @values = map {
        $self->_compile_assignment_value($assignments->{$_}, \@params, 'upsert', 1)
    } @fields;
    my @source = map { 'source.' . $_ } @quoted;
    my @matches = map {
        my $field = $self->quote_identifier(Selecto::Identifier::checked($_));
        'target.' . $field . ' = source.' . $field
    } @$conflict;
    my @sets = map {
        my $field = $self->quote_identifier(Selecto::Identifier::checked($_));
        'target.' . $field . ' = source.' . $field
    } @$updates;

    my $sql = 'MERGE INTO ' . $self->quote_identifier($relation) . ' WITH (HOLDLOCK) AS target ' .
        'USING (VALUES (' . join(', ', @values) . ')) AS source (' . join(', ', @quoted) . ') ' .
        'ON ' . join(' AND ', @matches) . ' ' .
        'WHEN MATCHED THEN UPDATE SET ' . join(', ', @sets) . ' ' .
        'WHEN NOT MATCHED THEN INSERT (' . join(', ', @quoted) . ') VALUES (' . join(', ', @source) . ');';
    return { sql => $sql, params => \@params };
}

sub _compile_mutation_default {
    my ($self, $operation) = @_;
    Selecto::Error->throw(
        'invalid_write',
        'SQL Server MERGE does not support DEFAULT in its portable source row',
    ) if $operation eq 'upsert';
    return $self->SUPER::_compile_mutation_default($operation);
}

sub _logical_affected_rows {
    my ($self, $operation, $physical) = @_;
    return 1 if $operation eq 'upsert' && $physical > 0;
    return $physical;
}

sub _column_types {
    my ($self, $sth) = @_;
    return eval { @{$sth->{TYPE} // []} };
}

sub _decode {
    my ($self, $value, $type) = @_;
    return undef unless defined $value;
    $type = 0 + ($type // 0);
    return int($value)
        if grep { $type == $_ } (SQL_BIGINT, SQL_INTEGER, SQL_SMALLINT, SQL_TINYINT);
    return $value ? 1 : 0 if $type == SQL_BIT;
    if ($type == SQL_DECIMAL || $type == SQL_NUMERIC) {
        my $normalized = "$value";
        $normalized =~ s/(\.\d*?)0+\z/$1/;
        $normalized =~ s/\.\z//;
        return $normalized eq '-0' ? '0' : $normalized;
    }
    if ($type == SQL_TYPE_TIMESTAMP || $type == SQL_TIMESTAMP) {
        my $normalized = "$value";
        $normalized =~ tr/ /T/;
        $normalized =~ s/\.0+\z//;
        return $normalized;
    }
    return "$value" if $type == SQL_TYPE_DATE || $type == SQL_DATE;
    return $value;
}

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    my $quoted_alias = $spec->{quoted_alias};
    my $projection = join(', ', map {
        $quoted_alias . '.' . $self->quote_identifier($_) . ' AS ' .
            $self->quote_identifier($_)
    } @{$spec->{fields}});
    return "COALESCE((SELECT $projection FROM $spec->{from} " .
        "WHERE $spec->{where}" .
        (defined($spec->{order}) ? " ORDER BY $spec->{order}" : '') .
        " FOR JSON PATH), '[]')";
}

1;
