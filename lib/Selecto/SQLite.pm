package Selecto::SQLite;

use Mojo::Base 'Selecto::SQL';
use Selecto::Error ();

sub name    { return 'sqlite'; }
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
        decimal => 'decimal',
        datetime => 'naive_datetime',
    }->{lc "$name"} // 'unknown';
}

sub supports {
    my ($self, $feature) = @_;
    return "$feature" eq 'transactions' ? 1 : 0;
}

1;
