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
    return $self->_returning_available if "$feature" eq 'returning';
    return $self->_sqlite_version_at_least(3, 25) if "$feature" eq 'window_functions';
    return $self->_sqlite_version_at_least(3, 8)
        if "$feature" eq 'cte' || "$feature" eq 'recursive_cte';
    return "$feature" eq 'transactions' || "$feature" eq 'set_operations'
        || "$feature" eq 'stream' ? 1 : 0;
}

sub write_capabilities {
    my ($self) = @_;
    my $capabilities = $self->SUPER::write_capabilities;
    if ($self->_returning_available) {
        $capabilities->{returning} = 1;
        $capabilities->{write_graph} = 1;
    }
    return $capabilities;
}

sub _returning_available {
    my ($self) = @_;
    return $self->_sqlite_version_at_least(3, 35);
}

sub _sqlite_version_at_least {
    my ($self, $required_major, $required_minor) = @_;
    my $key = "_sqlite_version_${required_major}_${required_minor}";
    return $self->{$key} if exists $self->{$key};
    my $version = eval { ($self->dbh->selectrow_array('SELECT sqlite_version()'))[0] };
    my ($major, $minor) = defined($version) && "$version" =~ /\A(\d+)\.(\d+)(?:\.\d+)?\z/
        ? (0 + $1, 0 + $2) : (0, 0);
    return $self->{$key} = (
        $major > $required_major
            || ($major == $required_major && $minor >= $required_minor)
    ) ? 1 : 0;
}

sub _compile_mutation_default {
    Selecto::Error->throw(
        'invalid_write',
        'SQLite does not support DEFAULT as an individual assignment expression',
    );
}

1;
