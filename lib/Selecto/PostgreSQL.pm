package Selecto::PostgreSQL;

use Mojo::Base 'Selecto::Adapter';
use Scalar::Util qw(blessed looks_like_number);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Statement ();
use Selecto::Write ();

our @FEATURE_INVENTORY = qw(
    cte recursive_cte window_functions transactions returning rollup stream
    schema_introspection text_search json_rowset lateral_join
);
our %WRITE_CAPABILITIES = map { $_ => 1 } qw(insert update upsert delete transactions atomic_batch);

sub name    { return 'postgresql'; }
sub dialect { return __PACKAGE__; }
sub feature_inventory { return [@FEATURE_INVENTORY]; }
sub write_capabilities { return { %WRITE_CAPABILITIES }; }

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '$' . int($index);
}

sub quote_identifier {
    my ($self, $identifier) = @_;
    my $quoted = defined($identifier) ? "$identifier" : '';
    $quoted =~ s/"/""/g;
    return qq{"$quoted"};
}

sub normalize_type {
    my ($self, $name) = @_;
    return { int4 => 'integer', numeric => 'decimal', timestamptz => 'utc_datetime' }->{"$name"} // 'unknown';
}

sub supports {
    my ($self, $feature) = @_;
    return "$feature" eq 'transactions' || "$feature" eq 'returning' ? 1 : 0;
}

sub compile {
    my ($self, $domain, $query) = @_;
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    my @params;
    my @joins;
    my $associations = $domain->associations;
    for my $name ($self->_referenced_associations($query)) {
        my $association = $associations->{$name};
        Selecto::Error->throw('unknown_association', "unknown association $name") unless $association;
        my $keyword = $association->join_type eq 'inner' ? 'INNER JOIN' : 'LEFT JOIN';
        push @joins,
            $keyword . ' ' . $self->quote_identifier($association->table) .
            ' AS ' . $self->quote_identifier($self->_join_alias($name)) .
            ' ON ' . $self->quote_identifier('s0') . '.' . $self->quote_identifier($association->owner_key) .
            ' = ' . $self->quote_identifier($self->_join_alias($name)) . '.' . $self->quote_identifier($association->related_key);
    }
    my @selection_sql = map { $self->_compile_selection($domain, $_, \@params) } @$selections;
    my @columns = map { $self->_selection_name($_) } @$selections;
    my $sql = 'SELECT ' . join(', ', @selection_sql) .
        ' FROM ' . $self->quote_identifier($domain->table) . ' AS ' . $self->quote_identifier('s0');
    $sql .= ' ' . join(' ', @joins) if @joins;
    $sql .= ' WHERE ' . $self->_compile_expression($domain, $query->predicate, \@params) if $query->predicate;
    my $groups = $query->groups;
    $sql .= ' GROUP BY ' . join(', ', map {
        $self->_compile_expression($domain, $_, \@params)
    } @$groups) if @$groups;
    my $orders = $query->orders;
    $sql .= ' ORDER BY ' . join(', ', map {
        $self->_compile_expression($domain, $_->[0], \@params) . ' ' . uc($_->[1])
    } @$orders) if @$orders;
    $sql .= ' LIMIT ' . $query->limit_value if defined $query->limit_value;
    $sql .= ' OFFSET ' . $query->offset_value if defined $query->offset_value;
    return Selecto::Statement->new(
        sql => $sql,
        params => \@params,
        columns => \@columns,
        adapter_name => $self->name,
    );
}

sub execute_query {
    my ($self, $statement) = @_;
    my ($sth, @rows);
    my $ok = eval {
        $sth = $self->{dbh}->prepare($statement->sql);
        $sth->execute(@{$statement->params});
        my @types = eval { @{$sth->{pg_type} // []} };
        while (my @row = $sth->fetchrow_array) {
            push @rows, [map { $self->_decode($row[$_], $types[$_]) } 0 .. $#row];
        }
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return { columns => $statement->columns, rows => \@rows };
}

sub preview_write {
    my ($self, $command) = @_;
    my $statement = $self->_compile_write($command);
    return { sql => $statement->{sql}, params => [@{$statement->{params}}] };
}

sub execute_write {
    my ($self, $command) = @_;
    return $self->_transaction(sub { return $self->_execute_write_in_transaction($command); });
}

sub execute_batch {
    my ($self, $batch) = @_;
    return $self->_transaction(sub {
        my @results = map { $self->_execute_write_in_transaction($_) } @{$batch->commands};
        return \@results;
    });
}

sub _compile_selection {
    my ($self, $domain, $expression, $params) = @_;
    my $sql = $self->_compile_expression($domain, $expression, $params);
    return defined($expression->alias_name)
        ? $sql . ' AS ' . $self->quote_identifier($expression->alias_name)
        : $sql;
}

sub _selection_name {
    my ($self, $expression) = @_;
    return $expression->alias_name if defined $expression->alias_name;
    if ($expression->kind eq 'field') {
        my ($field) = @{$expression->arguments};
        my @segments = split /\./, $field;
        return $segments[-1];
    }
    return $expression->kind;
}

sub _compile_expression {
    my ($self, $domain, $expression, $params) = @_;
    Selecto::Error->throw('invalid_query', 'expected an expression')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $self->_field_sql($domain, $arguments->[0]) if $kind eq 'field';
    if ($kind eq 'literal') {
        push @$params, $arguments->[0];
        return $self->placeholder(scalar @$params);
    }
    if ($kind eq 'eq' || $kind eq 'gt' || $kind eq 'gte') {
        my $operator = { eq => '=', gt => '>', gte => '>=' }->{$kind};
        return $self->_compile_expression($domain, $arguments->[0], $params) . " $operator " .
            $self->_compile_expression($domain, $arguments->[1], $params);
    }
    return $self->_compile_expression($domain, $arguments->[0], $params) . ' IS NULL' if $kind eq 'is_null';
    return $self->_compile_expression($domain, $arguments->[0], $params) . ' IS NOT NULL' if $kind eq 'not_null';
    if ($kind eq 'in') {
        my $values = $arguments->[1];
        Selecto::Error->throw('invalid_query', 'IN requires at least one value') unless ref($values) eq 'ARRAY' && @$values;
        my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
        return $self->_compile_expression($domain, $arguments->[0], $params) . ' IN (' . join(', ', @markers) . ')';
    }
    if ($kind eq 'and') {
        my $expressions = $arguments->[0];
        Selecto::Error->throw('invalid_query', 'AND requires expressions')
            unless ref($expressions) eq 'ARRAY' && @$expressions;
        return join(' AND ', map { '(' . $self->_compile_expression($domain, $_, $params) . ')' } @$expressions);
    }
    return 'COUNT(*)' if $kind eq 'count';
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
    if ($kind eq 'sum' || $kind eq 'min' || $kind eq 'max') {
        return uc($kind) . '(' . $self->_compile_expression($domain, $arguments->[0], $params) . ')';
    }
    Selecto::Error->throw('invalid_query', "unsupported expression $kind");
}

sub _field_sql {
    my ($self, $domain, $path) = @_;
    my $resolved = $domain->resolve($path);
    my $table_alias = $resolved->{association}
        ? $self->_join_alias($resolved->{association}->name)
        : 's0';
    return $self->quote_identifier($table_alias) . '.' . $self->quote_identifier($resolved->{field});
}

sub _referenced_associations {
    my ($self, $query) = @_;
    my @expressions = (@{$query->selections});
    push @expressions, $query->predicate if $query->predicate;
    push @expressions, @{$query->groups};
    push @expressions, map { $_->[0] } @{$query->orders};
    my %names;
    $names{$_} = 1 for map { $self->_expression_associations($_) } @expressions;
    return sort keys %names;
}

sub _expression_associations {
    my ($self, $expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    if ($expression->kind eq 'field') {
        my @segments = split /\./, $arguments->[0];
        return @segments == 2 ? ($segments[0]) : ();
    }
    my @names;
    for my $argument (@$arguments) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            push @names, $self->_expression_associations($argument);
        } elsif (ref($argument) eq 'ARRAY') {
            push @names, map { $self->_expression_associations($_) } @$argument;
        }
    }
    return @names;
}

sub _join_alias { return 'j_' . $_[1]; }

sub _compile_write {
    my ($self, $command) = @_;
    my $relation = _checked_identifier($command->relation);
    my $operation = $command->operation;
    my $assignments = $command->assignments;
    if ($operation eq 'insert' || $operation eq 'upsert') {
        my @fields = sort keys %$assignments;
        Selecto::Error->throw('invalid_write', 'insert requires assignments') unless @fields;
        my @params = map { $assignments->{$_} } @fields;
        my $sql = 'INSERT INTO ' . $self->quote_identifier($relation) .
            ' (' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @fields) . ')' .
            ' VALUES (' . join(', ', map { $self->placeholder($_ + 1) } 0 .. $#fields) . ')';
        if ($operation eq 'upsert') {
            my $metadata = $command->metadata;
            my $conflict = $metadata->{conflict_target};
            my $updates = $metadata->{upsert_update_fields};
            Selecto::Error->throw('invalid_write', 'upsert conflict target must be a non-empty string array')
                unless ref($conflict) eq 'ARRAY' && @$conflict && !grep { ref($_) } @$conflict;
            Selecto::Error->throw('invalid_write', 'upsert update fields must be a non-empty string array')
                unless ref($updates) eq 'ARRAY' && @$updates && !grep { ref($_) } @$updates;
            $sql .= ' ON CONFLICT (' . join(', ', map { $self->quote_identifier(_checked_identifier($_)) } @$conflict) .
                ') DO UPDATE SET ' . join(', ', map {
                    my $field = _checked_identifier($_);
                    $self->quote_identifier($field) . ' = EXCLUDED.' . $self->quote_identifier($field)
                } @$updates);
        }
        return { sql => $sql, params => \@params };
    }
    if ($operation eq 'update') {
        my @fields = sort keys %$assignments;
        Selecto::Error->throw('invalid_write', 'update requires assignments') unless @fields;
        my @params;
        my @set = map {
            push @params, $assignments->{$_};
            $self->quote_identifier(_checked_identifier($_)) . ' = ' . $self->placeholder(scalar @params)
        } @fields;
        my $predicate = $self->_compile_write_predicate($command->predicate, \@params);
        return { sql => 'UPDATE ' . $self->quote_identifier($relation) . ' SET ' . join(', ', @set) . " WHERE $predicate", params => \@params };
    }
    if ($operation eq 'delete') {
        my @params;
        my $predicate = $self->_compile_write_predicate($command->predicate, \@params);
        return { sql => 'DELETE FROM ' . $self->quote_identifier($relation) . " WHERE $predicate", params => \@params };
    }
    Selecto::Error->throw('invalid_write', "unsupported operation $operation");
}

sub _compile_write_predicate {
    my ($self, $expression, $params) = @_;
    Selecto::Error->throw('invalid_write', 'write predicate is required')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    Selecto::Error->throw('invalid_write', 'only equality write predicates are portable in protocol v1')
        unless $expression->kind eq 'eq'
        && blessed($arguments->[0]) && $arguments->[0]->kind eq 'field'
        && blessed($arguments->[1]) && $arguments->[1]->kind eq 'literal';
    my $field_args = $arguments->[0]->arguments;
    my $literal_args = $arguments->[1]->arguments;
    my $field = _checked_identifier($field_args->[0]);
    push @$params, $literal_args->[0];
    return $self->quote_identifier($field) . ' = ' . $self->placeholder(scalar @$params);
}

sub _execute_write_in_transaction {
    my ($self, $command) = @_;
    my $compiled = $self->_compile_write($command);
    my ($sth, $affected);
    my $ok = eval {
        $sth = $self->{dbh}->prepare($compiled->{sql});
        $sth->execute(@{$compiled->{params}});
        $affected = 0 + $sth->rows;
        1;
    };
    die $self->normalize_error($@) unless $ok;
    if (defined($command->expected_count) && $affected != $command->expected_count) {
        Selecto::Error->throw('cardinality_mismatch', 'write affected an unexpected number of rows', {
            expected => $command->expected_count,
            actual => $affected,
        });
    }
    return Selecto::Write::Result->new(operation => $command->operation, affected_rows => $affected);
}

sub _transaction {
    my ($self, $operation) = @_;
    my $value;
    my $ok = eval {
        $self->{dbh}->begin_work;
        $value = $operation->();
        $self->{dbh}->commit;
        1;
    };
    if (!$ok) {
        my $error = $@;
        eval { $self->{dbh}->rollback };
        die $error;
    }
    return $value;
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

sub _checked_identifier {
    my ($value) = @_;
    my $string = defined($value) ? "$value" : '';
    Selecto::Error->throw('invalid_identifier', 'invalid SQL identifier')
        unless $string =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return $string;
}

package Selecto::PostgreSQL::Statement;

use Mojo::Base 'Selecto::Statement';

1;
