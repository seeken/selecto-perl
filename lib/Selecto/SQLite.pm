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


# DBD::SQLite begins an AutoCommit => 0 handle's transaction lazily, before
# the next statement, but not before a SAVEPOINT. SQLite would then treat the
# savepoint as a transaction of its own and RELEASE would commit it, past the
# host's rollback. A plain statement first opens the host's transaction; it
# changes nothing when the transaction is already open.
sub _savepoint_command {
    my ($self, $action, $name) = @_;
    if ($action eq 'create') {
        defined($self->dbh->do('SELECT 1'))
            or die Selecto::SQL::_dbi_error($self->dbh, 'database transaction could not begin');
    }
    return $self->SUPER::_savepoint_command($action, $name);
}


# A query's own transaction is deferred: DBD::SQLite otherwise begins with
# BEGIN IMMEDIATE, which takes the write lock and is refused under
# query_only. Reading the host's query_only setting makes DBD::SQLite begin
# it now, while the override is in effect.
sub _begin_query_transaction {
    my ($self, $guard) = @_;
    my $dbh = $self->dbh;
    local $dbh->{sqlite_use_immediate_transaction} = 0;
    $self->_begin_transaction;
    $guard->{query_only} = _query_only($dbh);
    return;
}

# PRAGMA query_only makes the connection refuse every write, DDL included,
# for the query; the host's own setting is restored afterwards.
sub _begin_query_session {
    my ($self, $guard) = @_;
    my $previous = $guard->{query_only} // _query_only($self->dbh);
    $self->_query_control('PRAGMA query_only = ON') unless $previous;
    return { previous => $previous };
}

sub _query_only {
    my ($dbh) = @_;
    my ($value) = $dbh->selectrow_array('PRAGMA query_only');
    return $value ? 1 : 0;
}

sub _end_query_session {
    my ($self, $session) = @_;
    $self->_query_control('PRAGMA query_only = OFF') unless $session->{previous};
    return;
}

# SQLITE_READONLY
sub _read_only_violation {
    my ($self) = @_;
    my $code = eval { $self->dbh->err } // 0;
    return "$code" eq '8' ? 1 : 0;
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
