package Selecto::MySQLFamily;

use Mojo::Base 'Selecto::SQL';
use Selecto::Error ();
use Selecto::Identifier ();

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

# ON DUPLICATE KEY UPDATE fires on every unique key, not the declared
# conflict target, so a scoped upsert could update another tenant's row
# through its primary key. Refuse it, as the Go MySQL adapter does.
sub _compile_write {
    my ($self, $command) = @_;
    Selecto::Error->throw(
        'unsupported_scope_predicate',
        'MySQL-family adapters cannot apply write scope predicates to upserts',
    ) if $command->operation eq 'upsert' && defined $command->scope_predicate;
    return $self->SUPER::_compile_write($command);
}

# A WHERE needs FROM DUAL, and a parent read through a derived table may be
# the updated table itself (MySQL error 1093); LIMIT keeps it materialized.
sub _guarded_insert_source {
    my ($self, $values, $guard) = @_;
    return 'SELECT ' . join(', ', @$values) . " FROM DUAL WHERE $guard";
}

sub _foreign_key_exists_sql {
    my ($self, $select) = @_;
    return 'EXISTS (SELECT 1 FROM (' . $select . ' LIMIT 1) AS ' . $self->quote_identifier('selecto_fk_check') . ')';
}

sub _compile_upsert_clause {
    my ($self, $conflict, $updates) = @_;
    Selecto::Identifier::checked($_) for @$conflict;
    return ' ON DUPLICATE KEY UPDATE ' . join(', ', map {
        my $field = Selecto::Identifier::checked($_);
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

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    my @pairs = $self->_related_collection_json_pairs($spec->{fields}, $spec->{quoted_alias});
    my $aggregate = 'JSON_ARRAYAGG(JSON_OBJECT(' . join(', ', @pairs) . '))';
    return $self->_related_collection_aggregate_sql(
        $aggregate, $spec->{from}, $spec->{where}, 'JSON_ARRAY()',
    );
}

sub _related_collection_text_sql {
    my ($self, $sql) = @_;
    return "CAST($sql AS CHAR)";
}


# MySQL 5.7+ and MariaDB report a transaction opened by a raw START
# TRANSACTION in @@in_transaction; without it the answer is unknown. Asked
# only when AutoCommit is on.
sub _server_transaction_open {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    my ($value) = eval {
        local $dbh->{PrintError} = 0;
        $dbh->selectrow_array('SELECT @@in_transaction');
    };
    return defined($value) && "$value" =~ /\A[01]\z/ ? 0 + $value : undef;
}


# The query's own transaction is opened read-only with SQL, so it refuses
# writes; DBI's begin_work would cost two more round trips. Inside the
# host's transaction the characteristic cannot change, so the query's
# savepoint is only rolled back.
sub _begin_query_transaction { return $_[0]->_query_control('START TRANSACTION READ ONLY'); }
sub _end_query_transaction { return $_[0]->_query_control('ROLLBACK'); }

# DBD::MariaDB stores the whole result client-side unless use_result is on.
sub _stream_result_buffered {
    my ($self, $sth) = @_;
    my $use_result = eval { $sth->{mariadb_use_result} } || eval { $self->{dbh}{mariadb_use_result} };
    return $use_result ? 0 : 1;
}

# ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION
sub _read_only_violation {
    my ($self) = @_;
    my $code = eval { $self->{dbh}->err } // 0;
    return "$code" eq '1792' ? 1 : 0;
}
1;

__END__

=head1 NAME

Selecto::MySQLFamily - shared DBD::MariaDB mechanics for the MySQL and MariaDB adapters

=head1 DESCRIPTION

Common base class of L<Selecto::MySQL> and L<Selecto::MariaDB>: placeholders,
backtick quoting, C<ON DUPLICATE KEY UPDATE> upserts and value decoding. The
two public adapters stay separate classes with separate identities.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::MySQL>, L<Selecto::MariaDB>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
