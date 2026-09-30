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

# SQLite stores bound text as TEXT; only integer affinity changes ordering.
sub _values_cast_types {
    return { integer => 'INTEGER', int => 'INTEGER', bigint => 'INTEGER' };
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

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    my @pairs = $self->_related_collection_json_pairs($spec->{fields}, $spec->{quoted_alias});
    my $aggregate = 'JSON_GROUP_ARRAY(JSON_OBJECT(' . join(', ', @pairs) . '))';
    return $self->_related_collection_aggregate_sql(
        $aggregate, $spec->{from}, $spec->{where}, q{'[]'},
    );
}

1;

__END__

=head1 NAME

Selecto::SQLite - SQLite adapter

=head1 SYNOPSIS

  my $dbh = DBI->connect('dbi:SQLite:dbname=app.db', '', '',
      {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1});
  my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));

=head1 DESCRIPTION

Registered as C<sqlite>; needs L<DBD::SQLite> 1.64 or newer. It uses
double-quoted identifiers and C<?> parameters. Features depend on the SQLite
library version, which the adapter checks once per feature:

=over 4

=item *

CTEs and recursive CTEs need SQLite 3.8, window functions 3.25, and
C<RETURNING> and write graphs 3.35. Older libraries report the feature as
unsupported rather than emulating it.

=item *

Transactions, set operations and streaming are always available.

=item *

Rollups, lateral joins, JSON and array rowsets, full-text search, value
expressions, row locks and the PostgreSQL date/time format expressions fail
closed.

=item *

C<DEFAULT> cannot be used as an individual assignment expression.

=back

Related collections use C<JSON_GROUP_ARRAY>, so the SQLite JSON functions
must be available (they are built in to modern DBD::SQLite).

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>, L<DBD::SQLite>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
