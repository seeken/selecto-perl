package Selecto::DuckDB;

use Mojo::Base 'Selecto::SQL';
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
        || "$feature" eq 'set_operations' || "$feature" eq 'window_functions'
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
