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
    return "$feature" eq 'transactions' || "$feature" eq 'returning' ? 1 : 0;
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
