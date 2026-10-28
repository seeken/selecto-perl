package Selecto::PostgreSQL;

use Mojo::Base 'Selecto::SQL';
use Hash::Util::FieldHash ();
use JSON::PP ();
use Mojo::JSON ();
use Scalar::Util qw(blessed refaddr);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::PostgreSQL::StatementCache ();
use Selecto::Statement ();

has rollup_sort_fix => 'auto';
# Perl 5.36 and newer tell a value made as a number from a string.
use constant CREATED_AS_NUMBER => $] >= 5.036 ? 1 : 0;
BEGIN {
    no strict 'refs';
    *_created_as_number = CREATED_AS_NUMBER ? \&{'builtin::created_as_number'} : sub { 0 };
}
# Result values are the driver's unless canonical values are asked for: see
# RESULT VALUES below.
has canonical_values => 0;
# Canonical values are decoded in Perl unless canonical_sql => 1 asks
# PostgreSQL to format them: see Canonical values in SQL.
has canonical_sql => 0;
# Each compiled statement's outermost SELECT list: see Canonical values in SQL.
Hash::Util::FieldHash::fieldhash(my %PROJECTION);
# Opt-in, off by default: see STATEMENT CACHE below.
has statement_cache => 0;
# The host declares that its own session TEMP relations may serve as domain
# relations (R38); otherwise a relation found only in pg_temp is refused.
has temporary_relations => 0;
has statement_cache_size => 256;

sub name    { return 'postgresql'; }
sub dialect { return __PACKAGE__; }
sub edit_transaction_identity {
    my ($self) = @_;
    my $dbh = $self->dbh;
    Selecto::Error->throw('write_capability_missing', 'editable rows require a native PostgreSQL connection')
        unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' };
    Selecto::Error->throw('edit_handle_expired', 'editable rows require an active PostgreSQL transaction')
        unless $dbh->{Active} && (!$dbh->{AutoCommit} || $dbh->pg_ping == 3);
    my $identity = eval { $dbh->selectrow_array("SELECT CAST(pg_catalog.pg_backend_pid() AS pg_catalog.text) OPERATOR(pg_catalog.||) ':' OPERATOR(pg_catalog.||) CAST(pg_catalog.txid_current() AS pg_catalog.text)") };
    die $self->normalize_error($@) if $@;
    Selecto::Error->throw('edit_handle_expired', 'transaction identity is unavailable') unless defined $identity;
    Selecto::Error->throw('edit_handle_expired', 'editable rows require a pinned PostgreSQL transaction')
        unless $dbh->pg_ping == 3;
    return refaddr($dbh) . ':' . $identity;
}
sub _reuses_parameter_identity { return 1; }

sub bounded_stream_supported {
    my ($self) = @_;
    return eval { $self->dbh->isa('DBI::db') && $self->dbh->{Driver}{Name} eq 'Pg' } ? 1 : 0;
}

# A bounded result that its own LIMIT keeps to one fetch batch can run as a plain
# statement inside the host's transaction, under a savepoint budget (see
# Selecto::QueryBudget): no cursor and no extra FETCH.
sub bounded_direct_supported {
    my ($self) = @_;
    return $self->bounded_stream_supported && $self->_transaction_open ? 1 : 0;
}

# $statement with one more column, $alias, holding the single value of $scalar
# (a one-row, one-column statement such as a total), so both run in one round
# trip. The scalar is an uncorrelated subquery, evaluated once. Its placeholders
# follow the outer statement's. The outer rows keep their order, as the bounded
# result guard's own wrapping relies on.
sub scalar_column_statement {
    my ($self, $statement, $scalar, $alias) = @_;
    Selecto::Error->throw('invalid_query', 'scalar columns join two Selecto statements')
        unless blessed($statement) && $statement->isa('Selecto::Statement')
            && blessed($scalar) && $scalar->isa('Selecto::Statement')
            && @{$scalar->columns} == 1;
    Selecto::Error->throw('invalid_query', 'scalar column alias is invalid or taken')
        unless defined($alias) && $alias =~ /\A[a-z][a-z0-9_]*\z/
            && !grep { defined($_) && $_ eq $alias } @{$statement->columns};
    my $scalar_sql = $self->_renumber_dollar_placeholders($scalar->sql, scalar @{$statement->params});
    return _with_relations(Selecto::Statement->new(
        sql => 'SELECT selecto_rows.*, (' . $scalar_sql . ') AS ' . $self->quote_identifier($alias)
            . ' FROM (' . $statement->sql . ') AS selecto_rows',
        params => [@{$statement->params}, @{$scalar->params}],
        columns => [@{$statement->columns}, $alias],
        adapter_name => $self->name,
    ), $statement, $scalar);
}

# A statement derived from compiled ones names their relations: it keeps
# their lists (undef if any source has none, as a hand-built one).
sub _with_relations {
    my ($derived, @sources) = @_;
    my %names;
    for my $source (@sources) {
        my $list = blessed($source) && $source->can('relations') ? $source->relations : undef;
        return $derived unless ref($list) eq 'ARRAY';
        $names{$_} = 1 for @$list;
    }
    $derived->{_selecto_relations} = [sort keys %names];
    my %declared = map { ($_ => 1) } map { @{$_->{_selecto_declared_schemas} // []} } grep { blessed($_) } @sources;
    $derived->{_selecto_declared_schemas} = [sort keys %declared];
    return $derived;
}

sub stream_query {
    my ($self, $statement, %options) = @_;
    if ($ENV{SELECTO_PG_SQL_LINT} && _pg_hand_built($statement)) {
        local $self->{_selecto_pg_host_statement} = $statement->sql;
        return $self->_lint_scope(sub { $self->_stream_query_linted($statement, %options) });
    }
    return $self->_lint_scope(sub { $self->_stream_query_linted($statement, %options) })
        if $ENV{SELECTO_PG_SQL_LINT} && !$self->{dbh}{private_selecto_lint_depth};
    return $self->_stream_query_linted($statement, %options);
}

sub _stream_query_linted {
    my ($self, $statement, %options) = @_;
    unless ($options{bounded}) {
        # DBD::Pg runs the whole statement and buffers its rows at execute,
        # so the session check right after it covers every row.
        my $source = $statement;
        $statement = $self->_canonical_statement($statement)
            if blessed($statement) && !$options{export_scalars} && $self->_canonical_requested(%options);
        return $self->_guarded_read($source, sub { return $self->SUPER::stream_query($statement, %options) });
    }
    Selecto::Error->throw('unsupported_feature', 'bounded streaming requires a real PostgreSQL DBI handle')
        unless $self->supports('stream') && $self->bounded_stream_supported;
    Selecto::Error->throw('invalid_stream', 'stream_query requires a Selecto statement')
        unless blessed($statement) && $statement->isa('Selecto::Statement');
    my $size = $options{fetch_size} // 1;
    Selecto::Error->throw('invalid_stream', 'stream fetch size must be a positive integer')
        unless !ref($size) && "$size" =~ /\A[1-9]\d*\z/;
    my $canonical = $self->_canonical_requested(%options);
    require Selecto::PostgreSQL::Stream;
    return Selecto::PostgreSQL::Stream->new(adapter => $self,
        statement => $canonical && !$options{export_scalars} ? $self->_canonical_statement($statement) : $statement,
        fetch_size => $size, canonical_values => $canonical);
}

# A stream decodes canonical values in Perl, cell by cell, when they are asked
# for; otherwise its rows are the driver's values.
sub _stream_decoder {
    my ($self, %options) = @_;
    return $self->_canonical_requested(%options)
        ? sub { return $self->_decode(@_); }
        : sub { return $_[0]; };
}

sub _canonical_requested {
    my ($self, %options) = @_;
    return 1 if $options{export_scalars};
    return (exists($options{canonical_values}) ? $options{canonical_values} : $self->canonical_values)
        ? 1 : 0;
}

# The guard suppresses an oversized value on the server before DBI receives
# it, and adds a sentinel that the bounded consumer must reject. No truncation
# is presented as a successful value. Placeholders and their order are unchanged.
sub bounded_result_statement {
    my ($self, $statement, %args) = @_;
    my ($cap, $rows) = @args{qw(max_cell_bytes max_rows)};
    Selecto::Error->throw('invalid_query', 'invalid bounded result limits')
        if grep { !defined($_) || ref($_) || "$_" !~ /\A[1-9][0-9]{0,9}\z/ } ($cap, $rows);
    my (@values, @overflow, %seen);
    for my $name (@{$statement->columns}) {
        Selecto::Error->throw('unsupported_feature', 'bounded results require unique named columns')
            unless defined($name) && !ref($name) && length($name) && !$seen{$name}++;
        my $column = 'selecto_bounded.' . $self->quote_identifier($name);
        my $large = "octet_length(CAST($column AS TEXT)) > " . int($cap);
        push @values, "CASE WHEN $large THEN NULL ELSE $column END AS " . $self->quote_identifier($name);
        push @overflow, "($large)";
    }
    Selecto::Error->throw('invalid_query', 'bounded results need columns') unless @values;
    push @values, 'CASE WHEN ' . join(' OR ', @overflow) . ' THEN 1 ELSE 0 END AS selecto_transfer_overflow';
    # Fence the computed projection: volatile expressions must be evaluated
    # once, so the size predicate and emitted cell inspect the same value.
    # Cap materialization at the finite transfer row allowance.
    my $prefix = 'WITH selecto_bounded AS MATERIALIZED (SELECT * FROM (';
    my $guarded = Selecto::Statement->new(sql => $prefix
        . $statement->sql . ') AS selecto_source LIMIT ' . int($rows) . ') SELECT '
        . join(', ', @values) . ' FROM selecto_bounded LIMIT ' . int($rows),
        params => $statement->params, columns => [@{$statement->columns}, 'selecto_transfer_overflow'],
        adapter_name => $self->name);
    _with_relations($guarded, $statement);
    # Canonical values are formatted in the wrapped statement's SELECT list,
    # so the size guard measures the canonical text.
    my $plan = $PROJECTION{$statement};
    $PROJECTION{$guarded} = {%$plan, sql => $guarded->sql, start => length($prefix) + $plan->{start},
        formatted => undef} if $plan && $plan->{sql} eq $statement->sql;
    return $guarded;
}

sub placeholder {
    my ($self, $index) = @_;
    Selecto::Error->throw('invalid_query', 'placeholder index must be positive')
        unless defined($index) && "$index" =~ /\A[1-9]\d*\z/;
    return '$' . int($index);
}

sub normalize_type {
    my ($self, $name) = @_;
    return { int4 => 'integer', numeric => 'decimal', timestamptz => 'utc_datetime' }->{"$name"} // 'unknown';
}

# A managed transaction begins READ COMMITTED explicitly, so a session or
# database default (default_transaction_isolation) cannot weaken the
# guarded-write catalog checks; DBD::Pg sends BEGIN with the first
# statement, so this is the transaction's first statement.
sub _begin_transaction {
    my ($self) = @_;
    $self->SUPER::_begin_transaction;
    my $ok = eval { $self->dbh->do('SET TRANSACTION ISOLATION LEVEL READ COMMITTED'); 1 };
    unless ($ok) {
        my $error = $@;
        eval { $self->dbh->rollback };
        die $error;
    }
    return;
}

sub insert_admission_storage {
    my ($self, $command, $types) = @_;
    my $dbh = $self->dbh;
    my $fail = sub { Selecto::Error->throw('query_rule_not_evaluable',
        'PostgreSQL cannot establish the guarded insert storage contract'); };
    $fail->() unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' };
    my $table = $self->quote_identifier(Selecto::Identifier::checked($command->relation));
    # Keep the inspected table and trigger/type definitions stable until DML.
    $dbh->do("LOCK TABLE ONLY $table IN ROW EXCLUSIVE MODE");
    # The trigger and rule checks below need READ COMMITTED (see
    # Selecto::SQL::_require_read_committed).
    $self->_require_read_committed(Selecto::Identifier::checked($command->relation));
    my $relation = $dbh->selectrow_hashref(q{
        SELECT c.oid, CAST(c.relkind AS pg_catalog.text) AS relkind, CAST(c.relispartition AS pg_catalog.int4) AS relispartition,
          CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t WHERE t.tgrelid OPERATOR(pg_catalog.=) c.oid AND NOT t.tgisinternal
            AND t.tgenabled OPERATOR(pg_catalog.<>) 'D') AS pg_catalog.int4) AS triggers,
          CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_rewrite r WHERE r.ev_class OPERATOR(pg_catalog.=) c.oid) AS pg_catalog.int4) AS rules,
          CAST(EXISTS(SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhrelid OPERATOR(pg_catalog.=) c.oid
            OR i.inhparent OPERATOR(pg_catalog.=) c.oid) AS pg_catalog.int4) AS inheritance
        FROM pg_catalog.pg_class c WHERE c.oid OPERATOR(pg_catalog.=) pg_catalog.to_regclass(CAST(? AS pg_catalog.text))
    }, undef, $table);
    # A guarded insert is re-read by row id under its full guard after the
    # statement (R13), so ordinary row triggers (updated_at, audit) stay
    # allowed; statement-level and deferrable triggers are refused by its
    # target contract. An upsert has no such re-read.
    my $triggers_checked = $command->operation eq 'insert' && $self->_rereads_by_row_id;
    $fail->() unless $relation && $relation->{relkind} eq 'r'
        && !$relation->{relispartition} && ($triggers_checked || !$relation->{triggers}) && !$relation->{rules}
        && !$relation->{inheritance};
    my $rows = $dbh->selectall_arrayref(q{
        SELECT a.attname, t.typname, n.nspname AS type_schema,
          pg_catalog.format_type(a.atttypid,a.atttypmod) AS declaration,
          a.attgenerated, col.collname, cn.nspname AS collation_schema
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) a.atttypid
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
        LEFT JOIN pg_catalog.pg_collation col ON col.oid OPERATOR(pg_catalog.=) a.attcollation
        LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid OPERATOR(pg_catalog.=) col.collnamespace
        WHERE a.attrelid OPERATOR(pg_catalog.=) CAST(? AS pg_catalog.oid) AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
    }, {Slice => {}}, $relation->{oid});
    my %columns = map { $_->{attname} => $_ } @$rows;
    my %storage;
    for my $field (keys %$types) {
        my $column = $columns{$field};
        $fail->() unless $column && $column->{type_schema} eq 'pg_catalog' && !$column->{attgenerated};
        my $type = $types->{$field};
        my $name = $column->{typname};
        my ($cast, $collation);
        if ($type eq 'integer') {
            $fail->() unless $name =~ /\A(?:int2|int4|int8)\z/;
            $cast = {int2 => 'SMALLINT', int4 => 'INTEGER', int8 => 'BIGINT'}->{$name};
        } elsif ($type eq 'boolean') {
            $fail->() unless $name eq 'bool'; $cast = 'BOOLEAN';
        } elsif ($type eq 'decimal') {
            $fail->() unless $name eq 'numeric' && $column->{declaration} =~ /\Anumeric(?:\(\d+,-?\d+\))?\z/;
            $cast = $column->{declaration};
        } else {
            $fail->() unless $name =~ /\A(?:text|varchar)\z/
                && $column->{declaration} =~ /\A(?:text|character varying(?:\(\d+\))?)\z/;
            $cast = $column->{declaration};
            $fail->() unless defined($column->{collname}) && defined($column->{collation_schema});
            $collation = $self->quote_identifier($column->{collation_schema}) . '.' . $self->quote_identifier($column->{collname});
        }
        $storage{$field} = {cast => $cast, defined($collation) ? (collation => $collation) : ()};
    }
    return \%storage;
}

sub normalize_error {
    my ($self, $error) = @_;
    return $error if blessed($error) && $error->isa('Selecto::Error');

    my $text = eval { "$error" } // '';
    my $state = eval { $self->dbh->state } // '';
    if ($state eq '23502' || $text =~ /null value in column "[^"]+"[^\n]*violates not-null constraint/i) {
        my ($field) = $text =~ /null value in column "([A-Za-z_][A-Za-z0-9_]*)"/i;
        my ($relation) = $text =~ /relation "([A-Za-z_][A-Za-z0-9_]*)"/i;
        my %details = (constraint => 'not_null');
        $details{field} = $field if defined $field;
        $details{relation} = $relation if defined $relation;
        return Selecto::Error->new(
            code => 'database_not_null_violation',
            message => defined($field)
                ? "Required field $field was not provided."
                : 'A required database field was not provided.',
            details => \%details,
        );
    }
    if ($state eq '23505' || $text =~ /duplicate key value violates unique constraint/i) {
        my ($field_list) = $text =~ /Key \(([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\)=/i;
        my @fields = defined($field_list) ? split(/\s*,\s*/, $field_list) : ();
        return Selecto::Error->new(
            code => 'database_unique_violation',
            message => 'A value conflicts with an existing record.',
            details => {constraint => 'unique', @fields ? (fields => \@fields) : ()},
        );
    }
    if ($state eq '23503' || $text =~ /violates foreign key constraint/i) {
        return Selecto::Error->new(
            code => 'database_foreign_key_violation',
            message => 'A referenced record does not exist or is not available.',
            details => {constraint => 'foreign_key'},
        );
    }
    if ($state eq '23514' || $text =~ /violates check constraint/i) {
        return Selecto::Error->new(
            code => 'database_check_violation',
            message => 'A database validation constraint was not satisfied.',
            details => {constraint => 'check'},
        );
    }
    return $self->SUPER::normalize_error($error);
}

sub supports {
    my ($self, $feature) = @_;
    # A subclass that replaces execute_query keeps its own signature: engines
    # send it canonical_values only if it says so by overriding supports.
    return $self->can('execute_query') == \&execute_query ? 1 : 0
        if "$feature" eq 'canonical_values';
    return "$feature" eq 'transactions' || "$feature" eq 'returning'
        || "$feature" eq 'rollup' || "$feature" eq 'set_operations'
        || "$feature" eq 'window_functions' || "$feature" eq 'text_search'
        || "$feature" eq 'cte' || "$feature" eq 'recursive_cte'
        || "$feature" eq 'lateral_join' || "$feature" eq 'json_rowset'
        || "$feature" eq 'stream' || "$feature" eq 'projection_sum'
        || "$feature" eq 'row_locks' || "$feature" eq 'value_expressions'
        || "$feature" eq 'json_text' || "$feature" eq 'array_rowset'
        || "$feature" eq 'array_predicates' || "$feature" eq 'json_contains'
        || "$feature" eq 'export_scalars' ? 1 : 0;
}

# Without canonical_values (the default) rows hold exactly what DBD::Pg
# returns. canonical_values => 1 asks for canonical values; see RESULT VALUES
# in the POD. export_scalars => 1 asks for canonical export scalars: NUMERIC
# keeps the text PostgreSQL writes for it (plain notation at the column's
# scale), a boolean is a JSON::PP boolean and json/jsonb is the decoded JSON
# value; every other value is canonical. Export scalars are decoded in Perl.
sub execute_query {
    my ($self, $statement, %options) = @_;
    if ($ENV{SELECTO_PG_SQL_LINT} && _pg_hand_built($statement)) {
        # The host's own statement: Selecto's guard SQL around it is still
        # linted, the host's SQL is not (see _query_transport_sql).
        local $self->{_selecto_pg_host_statement} = $statement->sql;
        return $self->_lint_scope(sub { $self->_execute_query_linted($statement, %options) });
    }
    return $self->_lint_scope(sub { $self->_execute_query_linted($statement, %options) })
        if $ENV{SELECTO_PG_SQL_LINT} && !$self->{dbh}{private_selecto_lint_depth};
    return $self->_execute_query_linted($statement, %options);
}

sub _execute_query_linted {
    my ($self, $statement, %options) = @_;
    # Session state around the read (items 56, 61): see Session state.
    return $self->_guarded_read($statement,
        sub { return $self->_execute_query_unguarded($statement, %options) });
}

sub _execute_query_unguarded {
    my ($self, $statement, %options) = @_;
    if ($options{export_scalars}) {
        local $self->{_selecto_export_scalars} = 1;
        return $self->SUPER::execute_query($statement);
    }
    unless ($self->_canonical_requested(%options)) {
        local $self->{_selecto_raw_values} = 1;
        return $self->SUPER::execute_query($statement);
    }
    return $self->SUPER::execute_query($self->_canonical_statement($statement));
}

# ---- Canonical values in SQL ------------------------------------------------
#
# Opt-in (canonical_sql => 1; by default canonical values are decoded in
# Perl). When canonical values are asked for, each top-level selection of a plain
# stored field whose declared domain type is decimal, date, naive_datetime or
# utc_datetime is formatted by PostgreSQL in the outermost SELECT list (the
# declared type is the source the datetime_format compilers use too). The
# formatted columns arrive as text, which the Perl decode leaves alone; every
# other column (integers, floats, booleans, aggregates, computed fields and
# other expressions) is decoded in Perl from its PostgreSQL result type, as
# before. Within a formatted column the expression's own type picks the
# formatter (see _canonical_format), so a timestamptz declared naive_datetime,
# a utc_datetime localized by a query timezone or a date kept as text all
# come out as the Perl decode gives them:
#
#   numeric       CAST(trim_scale(x) AS TEXT), PostgreSQL 13+ (trim_scale);
#                 before 13 decimal fields are decoded in Perl
#   date          TO_CHAR(x, 'YYYY-MM-DD'), ' BC' for BC dates
#   timestamp     TO_CHAR(x, 'YYYY-MM-DD"T"HH24:MI:SS.US') without trailing
#                 fractional zeros or point; 'TBC' for BC
#   timestamptz   the same in the session TimeZone, plus TO_CHAR(x, 'OF')
#                 unless it is +00 (and an offset's seconds, which OF omits)
#   other types   CAST(x AS TEXT)
#
# Infinities and NULL are the type's own text. The output is the ISO form
# whatever the session DateStyle. No regular expressions, no type learning:
# the SQL depends only on the compiled statement and the server version.
#
# Only the outermost SELECT list changes: ORDER BY and GROUP BY are compiled
# expressions, never output names or positions (a rollup ordered by position
# records no projection), so they still sort and group the underlying values.
# Set operations, projection sums and statements built outside compile carry
# no projection and decode in Perl.

my %CANONICAL_KIND = (decimal => 'numeric', date => 'date', naive_datetime => 'datetime',
    utc_datetime => 'datetime');

# The declared type of a selected stored field, as _field_sql read it while
# compiling the selection (computed, query-source and star-dimension fallback
# fields have none).
sub _canonical_kind {
    my ($self, $domain, $selection) = @_;
    # Without canonical_sql nothing is formatted, so compile records nothing.
    return undef unless $self->canonical_sql
        && $selection->kind eq 'field' && ref($self->{_field_types}) eq 'HASH';
    my $type = $self->{_field_types}{$selection->arguments->[0]};
    return defined($type) && !ref($type) ? $CANONICAL_KIND{$type} : undef;
}

sub _note_projection {
    my ($self, $statement, %projection) = @_;
    return unless grep { defined $_->[2] } @{$projection{items}};
    # A formatted selection keeps its output name (a wrapping statement, such
    # as the bounded-result guard, selects the columns by name).
    $PROJECTION{$statement} = {sql => $statement->{sql}, start => $projection{start},
        items => $projection{items}, columns => $statement->{columns}};
    return;
}

# The statement to run for canonical values: a copy whose outermost SELECT
# list formats the canonical columns, or the statement itself.
sub _canonical_statement {
    my ($self, $statement) = @_;
    return $statement unless $self->canonical_sql;
    my $plan = $PROJECTION{$statement};
    return $statement unless $plan && $plan->{sql} eq $statement->sql;
    my $version = $self->_canonical_server_version or return $statement;
    my $numeric = $version >= 130000 ? 1 : 0;
    my $sql = $plan->{formatted}[$numeric] //= $self->_canonical_sql($plan, $numeric) // '';
    return $statement if $sql eq '';
    return _with_relations(Selecto::Statement->new(sql => $sql, params => $statement->params,
        columns => $statement->columns, adapter_name => $statement->adapter_name), $statement);
}

# The result columns _canonical_statement formats (for tests and diagnostics).
sub _canonical_columns {
    my ($self, $statement) = @_;
    my $plan = $PROJECTION{$statement};
    return () unless $self->canonical_sql && $plan && $plan->{sql} eq $statement->sql;
    my $version = $self->_canonical_server_version or return ();
    my $items = $plan->{items};
    return grep { defined($items->[$_][2]) && ($items->[$_][2] ne 'numeric' || $version >= 130000) } 0 .. $#$items;
}

# The server version of a DBD::Pg handle (libpq reads it once, at connect), or
# undef for any other handle.
sub _canonical_server_version {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' } ? $dbh->{pg_server_version} : undef;
}

sub _canonical_sql {
    my ($self, $plan, $numeric) = @_;
    my ($sql, $position) = ($plan->{sql}, $plan->{start});
    my $text = substr($sql, 0, $position);
    my $formatted = 0;
    for my $index (0 .. $#{$plan->{items}}) {
        my ($expression_length, $item_length, $kind) = @{$plan->{items}[$index]};
        $text .= ', ' if $index;
        $kind = undef if defined($kind) && $kind eq 'numeric' && !$numeric;
        if (defined $kind) {
            $text .= _canonical_format($kind, '(' . substr($sql, $position, $expression_length) . ')')
                . ($item_length == $expression_length ? ' AS ' . $self->quote_identifier($plan->{columns}[$index])
                    : substr($sql, $position + $expression_length, $item_length - $expression_length));
            $formatted++;
        } else {
            $text .= substr($sql, $position, $item_length);
        }
        $position += $item_length + 2;
    }
    return undef unless $formatted;
    return $text . substr($sql, $position - 2);
}

# The canonical text of one value, given the SQL expression x. The declared
# type says which formatters apply; the expression's PostgreSQL type picks
# one: CASE on pg_typeof of a NULL of that type (CASE WHEN FALSE THEN x END
# folds to one, and CASE resolves a domain to its base type), so x is not
# evaluated for it. A column of any other type (a date kept in a VARCHAR, say,
# or a date declared as a datetime) is its own text, which is what the Perl
# decode leaves of it under DateStyle ISO. Untyped literals take the branch's
# type; the timestamptz ones carry an explicit +00, so they do not depend on
# the session TimeZone.
sub _canonical_format {
    my ($kind, $x) = @_;
    my $type = "CAST(pg_catalog.pg_typeof(CASE WHEN FALSE THEN $x END) AS OID)";
    my $text = "CAST($x AS TEXT)";
    return "CASE WHEN $type = 1700 THEN CAST(pg_catalog.trim_scale(CAST($x AS NUMERIC)) AS TEXT) ELSE $text END"
        if $kind eq 'numeric';
    return "CASE WHEN $type = 1082 THEN " . _canonical_date("CAST($x AS DATE)") . " ELSE $text END"
        if $kind eq 'date';
    # A naive_datetime may be a timestamptz column, a utc_datetime a naive
    # one (stored naive_utc, localized by a query timezone, or undeclared).
    return "CASE $type WHEN 1114 THEN " . _canonical_timestamp("CAST($x AS TIMESTAMP)")
        . " WHEN 1184 THEN " . _canonical_timestamptz("CAST($x AS TIMESTAMPTZ)") . " ELSE $text END";
}

# Each formatter names as few functions as it can: parsing and planning a
# function call costs more than running it for a page of rows.
sub _canonical_date {
    my ($x) = @_;
    return "CASE WHEN pg_catalog.isfinite($x) THEN pg_catalog.to_char(CAST($x AS TIMESTAMP), 'YYYY-MM-DD')"
        . " || CASE WHEN $x < '0001-01-01' THEN ' BC' ELSE '' END ELSE CAST($x AS TEXT) END";
}

sub _canonical_local {
    my ($x) = @_;
    return q{pg_catalog.rtrim(pg_catalog.rtrim(pg_catalog.to_char(} . $x
        . q{, 'YYYY-MM-DD"T"HH24:MI:SS.US'), '0'), '.')};
}

sub _canonical_timestamp {
    my ($x) = @_;
    return "CASE WHEN pg_catalog.isfinite($x) THEN " . _canonical_local($x)
        . " || CASE WHEN $x < '0001-01-01' THEN 'TBC' ELSE '' END ELSE CAST($x AS TEXT) END";
}

# TO_CHAR's OF has no seconds. The last tz database offset with seconds
# (Africa/Monrovia's -00:44:30) ended on 1972-01-07, so later values take OF
# as it is, and earlier ones (and BC, where even +00 is kept before the TBC)
# take the exact offset.
sub _canonical_timestamptz {
    my ($x) = @_;
    my $seconds = "CAST(pg_catalog.date_part('timezone', $x) AS INTEGER) % 60";
    my $exact = "pg_catalog.to_char($x, 'OF') || CASE WHEN $seconds = 0 THEN ''"
        . " ELSE pg_catalog.to_char(pg_catalog.abs($seconds), '\":\"FM00') END"
        . " || CASE WHEN $x < '0001-01-02 00:00:00+00' AND pg_catalog.to_char($x, 'BC') = 'BC' THEN 'TBC' ELSE '' END";
    return "CASE WHEN pg_catalog.isfinite($x) THEN " . _canonical_local($x)
        . " || COALESCE(NULLIF(CASE WHEN $x >= '1972-01-08 00:00:00+00' THEN pg_catalog.to_char($x, 'OF')"
        . " ELSE $exact END, '+00'), '') ELSE CAST($x AS TEXT) END";
}

my %ARRAY_SQL_TYPE = (
    string => 'TEXT', integer => 'BIGINT', decimal => 'NUMERIC',
    boolean => 'BOOLEAN', date => 'DATE', uuid => 'UUID',
);
my %ARRAY_OPERATOR = (array_contains => '@>', array_contained => '<@', array_overlap => '&&');

# Each value is its own bound parameter; the list is cast to the declared
# element type, so no driver array encoding is involved.
sub _compile_array_predicate {
    my ($self, $kind, $field_sql, $element, $values, $params) = @_;
    my $type = $ARRAY_SQL_TYPE{$element};
    my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
    return "$field_sql $ARRAY_OPERATOR{$kind} CAST(ARRAY[" . join(', ', @markers) . "] AS $type\[\])";
}

sub _compile_json_contains {
    my ($self, $field_sql, $placeholder) = @_;
    return "CAST($field_sql AS JSONB)" . ' @> ' . "CAST($placeholder AS JSONB)";
}

sub _compile_array_rowset_join {
    my ($self, $spec, $source_sql) = @_;
    my $columns = $self->quote_identifier('value')
        . (defined($spec->{ordinality}) ? ', ' . $self->quote_identifier($spec->{ordinality}) : '');
    my $keyword = $spec->{type} eq 'cross' ? 'CROSS JOIN LATERAL'
        : $spec->{type} eq 'inner' ? 'INNER JOIN LATERAL' : 'LEFT JOIN LATERAL';
    return "$keyword UNNEST($source_sql)"
        . (defined($spec->{ordinality}) ? ' WITH ORDINALITY' : '')
        . ' AS ' . $self->quote_identifier($spec->{name}) . " ($columns)"
        . ($spec->{type} eq 'cross' ? '' : ' ON TRUE');
}

sub _values_cast_types {
    return {
        integer => 'BIGINT', int => 'BIGINT', bigint => 'BIGINT',
        decimal => 'NUMERIC', numeric => 'NUMERIC',
        string => 'TEXT', text => 'TEXT', boolean => 'BOOLEAN',
        date => 'DATE', datetime => 'TIMESTAMP', naive_datetime => 'TIMESTAMP',
        utc_datetime => 'TIMESTAMPTZ',
    };
}

sub _compile_json_text {
    my ($self, $field_sql, $segments, $params) = @_;
    my @markers = map { push @$params, $_; $self->placeholder(scalar @$params) } @$segments;
    return 'JSONB_EXTRACT_PATH_TEXT(CAST(' . $field_sql . ' AS JSONB), ' . join(', ', @markers) . ')';
}

sub _compile_row_lock {
    my ($self, $mode) = @_;
    Selecto::Error->throw('invalid_query', 'unsupported row lock mode')
        unless $mode eq 'share' || $mode eq 'update';
    return ($mode eq 'update' ? ' FOR UPDATE OF ' : ' FOR SHARE OF ') . $self->quote_identifier($self->_root_alias);
}

sub projection_sum_statement {
    my ($self, $statement, $column) = @_;
    Selecto::Error->throw('invalid_query', 'projection sum requires a compiled Selecto statement')
        unless blessed($statement) && $statement->isa('Selecto::Statement');
    Selecto::Identifier::checked($column);
    Selecto::Error->throw('invalid_query', 'projection sum requires a selected result column')
        unless grep { $_ eq $column } @{$statement->columns};
    my $source = $self->quote_identifier('selecto_projection_source');
    my $quoted_column = $self->quote_identifier($column);
    my $sql = 'SELECT COALESCE(SUM(' . $source . '.' . $quoted_column .
        '), 0) AS "selecto_projection_sum" FROM (' . $statement->sql . ') AS ' . $source;
    return _with_relations(Selecto::Statement->new(
        sql => $sql,
        params => $statement->params,
        columns => ['selecto_projection_sum'],
        adapter_name => $self->name,
    ), $statement);
}

sub _rollup_sort_fix_enabled {
    my ($self) = @_;
    my $setting = $self->rollup_sort_fix;
    Selecto::Error->throw('invalid_adapter', 'rollup_sort_fix must be auto, true, or false')
        unless defined($setting) && !ref($setting)
            && ("$setting" eq 'auto' || "$setting" eq '1' || "$setting" eq '0');
    return $setting ? 1 : 0 unless "$setting" eq 'auto';
    return $self->{_rollup_sort_fix_enabled}
        if exists $self->{_rollup_sort_fix_enabled};
    my $version = eval { ($self->dbh->selectrow_array('SHOW server_version_num'))[0] };
    my $major = defined($version) && "$version" =~ /\A\d+\z/
        ? int($version / 10_000) : undef;
    return $self->{_rollup_sort_fix_enabled} = defined($major) && $major >= 18 ? 0 : 1;
}

sub write_capabilities {
    return { %{$_[0]->SUPER::write_capabilities}, returning => 1, generated_keys => 1, write_graph => 1,
        transaction_edit_handles => 1 };
}

sub _renumber_placeholders {
    my ($self, $sql, $offset) = @_;
    return $self->_renumber_dollar_placeholders($sql, $offset);
}

sub _compile_related_collection_sql {
    my ($self, $spec) = @_;
    my @pairs = $self->_related_collection_json_pairs($spec->{fields}, $spec->{quoted_alias}, 1);
    my $aggregate = 'JSON_AGG(JSON_BUILD_OBJECT(' . join(', ', @pairs) . ')' .
        (defined($spec->{order}) ? " ORDER BY $spec->{order}" : '') . ')';
    return $self->_related_collection_aggregate_sql(
        $aggregate, $spec->{from}, $spec->{where}, q{'[]'::json},
    );
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    return $self->_compile_count_bucket($domain, $arguments->[0], $arguments->[1], $params)
        if $kind eq 'count_bucket';
    return $self->_compile_bucket($domain, $arguments->[0], $arguments->[1], $params)
        if $kind eq 'bucket';
    if ($kind eq 'epoch_datetime') {
        my ($field) = @$arguments;
        Selecto::Error->throw('invalid_query', 'epoch datetime requires a governed field')
            unless blessed($field) && $field->isa('Selecto::Expression') && $field->kind eq 'field';
        my ($path) = @{$field->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'epoch datetime requires an epoch datetime field')
            unless $resolved->{type} eq 'epoch_datetime';
        local $self->{_suppress_field_timezone} = 1;
        my $sql = 'TO_TIMESTAMP(' . $self->_compile_expression($domain, $field, $params) . ')';
        return defined($self->{_timezone})
            ? $self->_compile_timezone_sql($sql, 'utc_datetime', $self->{_timezone}, $params)
            : $sql;
    }
    if ($kind eq 'datetime_format') {
        my %formats = (
            day => 'YYYY-MM-DD',
            time => 'HH24:MI:SS',
            day_hour => 'YYYY-MM-DD HH24',
            day_minute => 'YYYY-MM-DD HH24:MI',
            week => 'IYYY-"W"IW',
            iso_week => 'IYYY-"W"IW',
            iso_week_date => 'IYYY-"W"IW-ID',
            month => 'YYYY-MM',
            quarter => 'YYYY-"Q"Q',
            year => 'YYYY',
            month_of_year => 'MM',
            month_day => 'MM-DD',
            day_of_month => 'DD',
            day_of_week => 'FMDay',
            day_of_week_num => 'ID',
            day_of_year => 'DDD',
            hour => 'HH24',
            us_date => 'MM/DD/YYYY',
            us_datetime => 'MM/DD/YYYY FMHH12:MI AM',
        );
        my ($field, $format, $timezone) = @$arguments;
        local $self->{_timezone} = $timezone // $self->{_timezone};
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed temporal field')
            unless blessed($field) && $field->isa('Selecto::Expression')
                && ($field->kind eq 'field' || $field->kind eq 'epoch_datetime');
        Selecto::Error->throw('invalid_query', 'datetime format is not available')
            unless $format =~ /\A(?:iso8601|rfc3339_millis|epoch_seconds|epoch_milliseconds|timezone_offset)\z/
                || exists $formats{$format};
        my $source = $field->kind eq 'epoch_datetime' ? $field->arguments->[0] : $field;
        Selecto::Error->throw('invalid_query', 'datetime format field must be a governed field')
            unless blessed($source) && $source->isa('Selecto::Expression') && $source->kind eq 'field';
        my ($path) = @{$source->arguments};
        my $resolved = $domain->resolve($path);
        Selecto::Error->throw('invalid_query', 'datetime format requires a date or time field')
            unless $resolved->{type} =~ /(?:date|time)/i;
        if ($format eq 'iso8601') {
            if ($resolved->{type} eq 'date') {
                return 'TO_CHAR(' . $self->_compile_expression($domain, $field, $params) .
                    q{, 'YYYY-MM-DD')};
            }
            if ($resolved->{type} eq 'utc_datetime' || $resolved->{type} eq 'epoch_datetime') {
                my $timezone = $self->{_timezone};
                local $self->{_suppress_field_timezone} = 1;
                local $self->{_timezone};
                my $instant_sql = $self->_compile_expression($domain, $field, $params);
                return $self->_compile_iso8601_instant_sql(
                    $instant_sql, $timezone, $params,
                );
            }
            return 'TO_CHAR(' . $self->_compile_expression($domain, $field, $params) .
                q{, 'YYYY-MM-DD"T"HH24:MI:SS')};
        }
        if ($format =~ /\A(?:rfc3339_millis|epoch_seconds|epoch_milliseconds|timezone_offset)\z/) {
            my $timezone = $self->{_timezone};
            local $self->{_suppress_field_timezone} = 1;
            local $self->{_timezone};
            my $instant_sql = $self->_compile_expression($domain, $field, $params);
            if ($resolved->{type} ne 'utc_datetime' && $resolved->{type} ne 'epoch_datetime') {
                # DATE has no time or zone. PostgreSQL otherwise resolves its
                # AT TIME ZONE overload through a session-dependent timestamptz.
                $instant_sql = 'CAST(' . $instant_sql . ' AS TIMESTAMP)'
                    if $resolved->{type} eq 'date';
                if (defined($timezone) && $timezone ne 'UTC') {
                    push @$params, $timezone;
                    $instant_sql = '(' . $instant_sql . ' AT TIME ZONE ' .
                        $self->placeholder(scalar @$params) . ')';
                } else {
                    $instant_sql = '(' . $instant_sql . q{ AT TIME ZONE 'UTC')};
                }
            }
            return 'CAST(FLOOR(EXTRACT(EPOCH FROM ' . $instant_sql . ')) AS BIGINT)'
                if $format eq 'epoch_seconds';
            return 'CAST(FLOOR(EXTRACT(EPOCH FROM ' . $instant_sql . ') * 1000) AS BIGINT)'
                if $format eq 'epoch_milliseconds';
            return $self->_compile_timezone_offset_sql($instant_sql, $timezone, $params)
                if $format eq 'timezone_offset';
            return $self->_compile_rfc3339_instant_sql(
                $instant_sql, $timezone, $params, 1,
            );
        }
        return 'TO_CHAR(' . $self->_compile_expression($domain, $field, $params) .
            ", '" . $formats{$format} . "')";
    }
    if ($kind eq 'text_search' || $kind eq 'text_rank') {
        my ($fields, $query, $options) = @$arguments;
        Selecto::Error->throw('invalid_query', 'text search requires at least one governed field')
            unless ref($fields) eq 'ARRAY' && @$fields;
        Selecto::Error->throw('invalid_query', 'text search options must be an object')
            unless ref($options) eq 'HASH';
        Selecto::Error->throw('invalid_query', 'text search query must be a non-empty scalar')
            unless blessed($query) && $query->isa('Selecto::Expression')
                && $query->kind eq 'literal'
                && defined($query->arguments->[0]) && !ref($query->arguments->[0])
                && "$query->arguments->[0]" ne '';
        my %configurations = map { $_ => 1 } qw(
            simple english danish dutch finnish french german hungarian italian
            norwegian portuguese romanian russian spanish swedish turkish
        );
        my $configuration = lc($options->{configuration} // 'simple');
        Selecto::Error->throw('invalid_query', 'text search configuration is not available')
            unless $configurations{$configuration};
        my %modes = (
            plain => 'PLAINTO_TSQUERY',
            phrase => 'PHRASETO_TSQUERY',
            websearch => 'WEBSEARCH_TO_TSQUERY',
            prefix => 'TO_TSQUERY',
        );
        my $mode = lc($options->{mode} // 'plain');
        Selecto::Error->throw('invalid_query', 'text search mode is not available')
            unless $modes{$mode};
        my $document = join(" || ' ' || ", map {
            'COALESCE(CAST(' . $self->_compile_expression($domain, $_, $params) . " AS TEXT), '')"
        } @$fields);
        my $query_sql = $self->_compile_expression($domain, $query, $params);
        my $vector = "TO_TSVECTOR('$configuration', $document)";
        my $tsquery = "$modes{$mode}('$configuration', $query_sql)";
        return "$vector @@ $tsquery" if $kind eq 'text_search';
        return "TS_RANK($vector, $tsquery)";
    }
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
}

# A naive timestamp holding UTC becomes timestamptz.
sub _compile_naive_utc_instant_sql {
    my ($self, $sql) = @_;
    return '(' . $sql . q{ AT TIME ZONE 'UTC')};
}

sub _current_date_shortcuts { return 1 }
sub _months_interval_sql { return 'MAKE_INTERVAL(months => ' . int($_[1]) . ')' }
sub _month_day_sql { return "TO_CHAR($_[1], 'MM-DD')" }

sub _compile_timezone_sql {
    my ($self, $sql, $type, $timezone, $params) = @_;
    # Raw epoch fields are numbers; explicit epoch_datetime expressions have
    # already become instants and call this hook with utc_datetime instead.
    $sql = 'TO_TIMESTAMP(' . $sql . ')' if $type eq 'epoch_datetime';
    push @$params, $timezone;
    return '(' . $sql . ' AT TIME ZONE ' . $self->placeholder(scalar @$params) . ')';
}

sub _compile_iso8601_instant_sql {
    my ($self, $sql, $timezone, $params) = @_;
    return $self->_compile_rfc3339_instant_sql($sql, $timezone, $params, 0);
}

sub _compile_rfc3339_instant_sql {
    my ($self, $sql, $timezone, $params, $milliseconds) = @_;
    my $pattern = $milliseconds
        ? 'YYYY-MM-DD"T"HH24:MI:SS.MS'
        : 'YYYY-MM-DD"T"HH24:MI:SS';
    return q{TO_CHAR((} . $sql . q{ AT TIME ZONE 'UTC'), '} . $pattern . q{') || 'Z'}
        unless defined($timezone) && $timezone ne 'UTC';
    push @$params, $timezone;
    my $placeholder = $self->placeholder(scalar @$params);
    my $local = '(' . $sql . ' AT TIME ZONE ' . $placeholder . ')';
    return q{TO_CHAR(} . $local . q{, '} . $pattern . q{') || } .
        $self->_compile_timezone_offset_sql($sql, $timezone, $params, $placeholder);
}

sub _compile_timezone_offset_sql {
    my ($self, $sql, $timezone, $params, $placeholder) = @_;
    return q{CASE WHEN } . $sql . q{ IS NULL THEN NULL ELSE CAST('+00:00' AS TEXT) END}
        unless defined($timezone) && $timezone ne 'UTC';
    unless (defined $placeholder) {
        push @$params, $timezone;
        $placeholder = $self->placeholder(scalar @$params);
    }
    my $local = '(' . $sql . ' AT TIME ZONE ' . $placeholder . ')';
    my $offset = 'CAST(EXTRACT(EPOCH FROM (' . $local . ' - (' . $sql .
        q{ AT TIME ZONE 'UTC'))) AS INTEGER)};
    return
        q{CASE WHEN } . $offset . q{ >= 0 THEN '+' ELSE '-' END || } .
        q{LPAD(CAST(FLOOR(ABS(} . $offset . q{) / 3600) AS TEXT), 2, '0') || ':' || } .
        q{LPAD(CAST(FLOOR(MOD(ABS(} . $offset . q{), 3600) / 60) AS TEXT), 2, '0')};
}

sub _compile_json_rowset_join {
    my ($self, $domain, $spec, $params) = @_;
    my $resolved = $domain->resolve($spec->{source_field});
    Selecto::Error->throw('invalid_query', 'JSON rowset source must be a JSON field')
        unless $resolved->{type} =~ /json/i;
    my $source = $self->_compile_expression(
        $domain,
        Selecto::Expression->field($spec->{source_field}),
        $params,
    ) . '::jsonb';
    if (exists($spec->{path})) {
        my $path = $spec->{path};
        Selecto::Error->throw('invalid_query', 'JSON rowset path must be a non-empty string')
            unless defined($path) && !ref($path) && "$path" ne '';
        push @$params, "$path";
        $source = 'JSONB_PATH_QUERY_ARRAY(' . $source . ', ' .
            $self->placeholder(scalar @$params) . '::jsonpath)';
    }
    my %types = (
        integer => 'BIGINT', int => 'BIGINT', bigint => 'BIGINT',
        decimal => 'NUMERIC', numeric => 'NUMERIC', number => 'NUMERIC',
        string => 'TEXT', text => 'TEXT', boolean => 'BOOLEAN',
        date => 'DATE', datetime => 'TIMESTAMP', utc_datetime => 'TIMESTAMPTZ',
        json => 'JSONB', jsonb => 'JSONB',
    );
    my @columns = map {
        my $type = lc("$spec->{columns}{$_}");
        Selecto::Error->throw('invalid_query', "JSON rowset type $type is not portable")
            unless exists $types{$type};
        $self->quote_identifier($_) . ' ' . $types{$type};
    } sort keys %{$spec->{columns}};
    my $keyword = $spec->{type} eq 'cross' ? 'CROSS JOIN LATERAL'
        : $spec->{type} eq 'inner' ? 'INNER JOIN LATERAL' : 'LEFT JOIN LATERAL';
    return $keyword . ' JSONB_TO_RECORDSET(' . $source . ') AS ' .
        $self->quote_identifier($spec->{name}) . ' (' . join(', ', @columns) . ')' .
        ($spec->{type} eq 'cross' ? '' : ' ON TRUE');
}

sub _compile_count_bucket {
    my ($self, $domain, $field, $specification, $params) = @_;
    Selecto::Error->throw('invalid_query', 'bucket count specification must be an object')
        unless ref($specification) eq 'HASH';
    my $mode = $specification->{mode} // 'numeric';
    Selecto::Error->throw('invalid_query', 'bucket count mode is not available')
        unless $mode eq 'numeric' || $mode eq 'elapsed_days';
    my $field_sql = $self->_compile_expression($domain, $field, $params);
    my $value_sql = $mode eq 'elapsed_days'
        ? "CURRENT_DATE - DATE($field_sql)"
        : $field_sql;
    my ($minimum, $maximum) = @{$specification}{qw(minimum maximum)};
    Selecto::Error->throw('invalid_query', 'bucket count requires at least one boundary')
        unless defined($minimum) || defined($maximum);
    Selecto::Error->throw('invalid_query', 'bucket count boundaries must be integers')
        if (defined($minimum) && "$minimum" !~ /\A\d+\z/)
        || (defined($maximum) && "$maximum" !~ /\A\d+\z/);
    my @predicates;
    if (defined($minimum)) {
        push @$params, int($minimum);
        push @predicates, $value_sql . ' >= ' . $self->placeholder(scalar @$params);
    }
    if (defined($maximum)) {
        push @$params, int($maximum);
        push @predicates, $value_sql . ' <= ' . $self->placeholder(scalar @$params);
    }
    return 'COUNT(CASE WHEN ' . join(' AND ', @predicates) . ' THEN 1 END)';
}

sub _compile_bucket {
    my ($self, $domain, $field, $specification, $params) = @_;
    Selecto::Error->throw('invalid_query', 'bucket specification must be an object')
        unless ref($specification) eq 'HASH';
    my $kind = $specification->{kind} // '';
    my $field_sql = $self->_compile_expression($domain, $field, $params);
    my ($path) = @{$field->arguments};
    my $resolved = $domain->resolve($path);

    if ($kind eq 'numeric_increment' || $kind eq 'year_increment') {
        Selecto::Error->throw('invalid_query', 'bucket increment must be a positive integer')
            unless defined($specification->{increment})
            && "$specification->{increment}" =~ /\A[1-9]\d*\z/;
        Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
            if $kind eq 'numeric_increment' && $resolved->{type} !~ /(?:int|decimal|number|numeric|float|double|real)/i;
        Selecto::Error->throw('invalid_query', 'year buckets require a date or time field')
            if $kind eq 'year_increment' && $resolved->{type} !~ /(?:date|time)/i;
        my $value_sql = $kind eq 'year_increment' ? "EXTRACT(YEAR FROM $field_sql)" : $field_sql;
        my $increment = int($specification->{increment});
        my $start = "CAST(FLOOR(CAST($value_sql AS NUMERIC) / $increment) AS BIGINT) * $increment";
        return "CASE WHEN $field_sql IS NULL THEN 'Other' ELSE CAST(($start) AS TEXT) || '-' || " .
            'CAST(((' . $start . ') + ' . ($increment - 1) . ') AS TEXT) END';
    }

    if ($kind eq 'text_prefix') {
        Selecto::Error->throw('invalid_query', 'text prefix bucket requires a text field')
            unless $resolved->{type} =~ /(?:string|text|char|citext)/i;
        my $length = $specification->{prefix_length} // 2;
        Selecto::Error->throw('invalid_query', 'text prefix length must be between 1 and 10')
            unless "$length" =~ /\A\d+\z/ && $length >= 1 && $length <= 10;
        my $normalized = "BTRIM(COALESCE(CAST($field_sql AS TEXT), ''))";
        if ($specification->{exclude_articles}) {
            $normalized = "REGEXP_REPLACE($normalized, '^(a|an|the)([[:space:]]+|\$)', '', 'i')";
        }
        $normalized = "LOWER($normalized)" unless exists($specification->{ignore_case}) && !$specification->{ignore_case};
        return "CASE WHEN $normalized = '' THEN 'Other' ELSE UPPER(LEFT($normalized, " . int($length) . ')) END';
    }

    my %range_kinds = map { $_ => 1 } qw(
        numeric_ranges elapsed_days_ranges date_relative_ranges year_ranges
    );
    Selecto::Error->throw('invalid_query', 'bucket kind is not available') unless $range_kinds{$kind};
    Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
        if $kind eq 'numeric_ranges' && $resolved->{type} !~ /(?:int|decimal|number|numeric|float|double|real)/i;
    Selecto::Error->throw('invalid_query', 'temporal buckets require a date or time field')
        if $kind ne 'numeric_ranges' && $resolved->{type} !~ /(?:date|time)/i;
    my $ranges = $specification->{ranges};
    Selecto::Error->throw('invalid_query', 'bucket ranges must be a non-empty array')
        unless ref($ranges) eq 'ARRAY' && @$ranges;
    my $value_sql = $kind eq 'elapsed_days_ranges' ? "CURRENT_DATE - DATE($field_sql)"
        : $kind eq 'year_ranges' ? "EXTRACT(YEAR FROM $field_sql)"
        : $kind eq 'date_relative_ranges' ? "DATE($field_sql)"
        : $field_sql;
    my @clauses;
    for my $range (@$ranges) {
        Selecto::Error->throw('invalid_query', 'bucket range must be an object')
            unless ref($range) eq 'HASH';
        my ($minimum, $maximum, $label) = @{$range}{qw(minimum maximum label)};
        Selecto::Error->throw('invalid_query', 'bucket range label is required')
            unless defined($label) && !ref($label) && length("$label") <= 80;
        my $predicate;
        if ($kind eq 'date_relative_ranges' && defined($minimum) && "$minimum" =~ /\A(?:today|yesterday|tomorrow)\z/) {
            Selecto::Error->throw('invalid_query', 'date keyword bucket boundaries must match')
                unless defined($maximum) && "$maximum" eq "$minimum";
            $predicate = $minimum eq 'today' ? "$value_sql = CURRENT_DATE"
                : $minimum eq 'yesterday' ? "$value_sql = CURRENT_DATE - INTERVAL '1 day'"
                : "$value_sql = CURRENT_DATE + INTERVAL '1 day'";
        } else {
            Selecto::Error->throw('invalid_query', 'bucket range requires at least one boundary')
                unless defined($minimum) || defined($maximum);
            Selecto::Error->throw('invalid_query', 'bucket range boundaries must be integers')
                if (defined($minimum) && "$minimum" !~ /\A\d+\z/)
                || (defined($maximum) && "$maximum" !~ /\A\d+\z/);
            my @predicates;
            if (defined($minimum)) {
                push @$params, int($minimum);
                my $marker = $self->placeholder(scalar @$params);
                push @predicates, $kind eq 'date_relative_ranges'
                    ? "$value_sql <= CURRENT_DATE - ($marker * INTERVAL '1 day')"
                    : "$value_sql >= $marker";
            }
            if (defined($maximum)) {
                push @$params, int($maximum);
                my $marker = $self->placeholder(scalar @$params);
                push @predicates, $kind eq 'date_relative_ranges'
                    ? "$value_sql >= CURRENT_DATE - ($marker * INTERVAL '1 day')"
                    : "$value_sql <= $marker";
            }
            $predicate = join(' AND ', @predicates);
        }
        push @$params, "$label";
        push @clauses, 'WHEN ' . $predicate . ' THEN ' . $self->placeholder(scalar @$params);
    }
    push @$params, 'Other';
    return 'CASE ' . join(' ', @clauses) . ' ELSE ' . $self->placeholder(scalar @$params) . ' END';
}

sub _column_types {
    my ($self, $sth) = @_;
    return eval { @{$sth->{pg_type} // []} };
}

sub _decode {
    my ($self, $value, $type) = @_;
    return undef unless defined $value;
    $type //= '';
    return _export_scalar($value, $type)
        if $self->{_selecto_export_scalars} && $type =~ /\A(?:numeric|bool|json|jsonb)\z/;
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

# Column-wise _decode: the type branch is chosen once per column rather than
# once per cell, and each cell gets exactly the transformation _decode gives
# it. A subclass that redefines _decode keeps the per-cell path.
sub _decode_rows {
    my ($self, $rows, $types) = @_;
    return if $self->{_selecto_raw_values};
    return $self->SUPER::_decode_rows($rows, $types)
        unless $self->can('_decode') == \&_decode;
    my $export = $self->{_selecto_export_scalars};
    my $driver_numbers;
    for my $i (0 .. $#$types) {
        my $type = $types->[$i] // '';
        if ($export && $type =~ /\A(?:numeric|bool|json|jsonb)\z/) {
            for my $row (@$rows) {
                $row->[$i] = _export_scalar($row->[$i], $type) if defined $row->[$i];
            }
        } elsif ($type eq 'bool') {
            for my $row (@$rows) {
                my $value = $row->[$i];
                $row->[$i] = ($value eq 't' || "$value" eq '1') ? 1 : 0 if defined $value;
            }
        } elsif ($type eq 'int2' || $type eq 'int4' || $type eq 'int8') {
            # DBD::Pg fetches integers as Perl integers (IVs), for which int()
            # returns the same IV, so a value it made as a number is kept.
            # It never makes one any other way, but other handles (and Perl
            # before 5.36, without builtin::created_as_number) take the
            # check below.
            BEGIN { warnings->unimport('experimental::builtin') if CREATED_AS_NUMBER }
            $driver_numbers //= CREATED_AS_NUMBER && defined($self->_canonical_server_version) ? 1 : 0;
            for my $row (@$rows) {
                next unless defined(my $value = $row->[$i]);
                next if $driver_numbers && _created_as_number($value);
                if (ref $value) {
                    $row->[$i] = int($value) if "$value" =~ /\A-?\d+\z/;
                    next;
                }
                # $value is a private copy, so reading it as a string reads
                # what "$value" would. A non-empty run of ASCII digits (what
                # DBD::Pg's integers stringify to) matches /\A-?\d+\z/
                # without starting the regex engine; anything else asks the
                # regex itself.
                $row->[$i] = int($value)
                    if (($value =~ tr/0-9//) == length($value) && length($value))
                    || $value =~ /\A-?\d+\z/;
            }
        } elsif ($type eq 'numeric' || $type eq 'float4' || $type eq 'float8') {
            for my $row (@$rows) {
                next unless defined(my $value = $row->[$i]);
                my $normalized = "$value";
                $normalized =~ s/(\.\d*?)0+\z/$1/;
                $normalized =~ s/\.\z//;
                $row->[$i] = $normalized eq '-0' ? '0' : $normalized;
            }
        } elsif ($type eq 'timestamp' || $type eq 'timestamptz') {
            for my $row (@$rows) {
                next unless defined(my $value = $row->[$i]);
                my $normalized = "$value";
                $normalized =~ tr/ /T/;
                # The suffix pattern cannot match without a '+' or a 'Z', and
                # its alternation defeats the regex optimizer, so a value
                # holding neither (a timestamp without time zone) skips it.
                $normalized =~ s/(?:\.0+)?(?:\+00(?::00)?|Z)\z// if $normalized =~ tr/+Z//;
                $row->[$i] = $normalized;
            }
        }
    }
    return;
}

# One canonical export scalar for a NUMERIC, boolean or JSON cell. JSON text
# is decoded with Mojo::JSON (JSON::PP::Boolean booleans, as JSON::PP gives),
# which is several times faster than JSON::PP on wide exports.
sub _export_scalar {
    my ($value, $type) = @_;
    return "$value" if $type eq 'numeric';
    return ($value eq 't' || "$value" eq '1') ? JSON::PP::true : JSON::PP::false if $type eq 'bool';
    return $value if ref $value;
    return Mojo::JSON::from_json("$value");
}

sub _statement_cache_enabled {
    my ($self) = @_;
    return 0 unless $self->statement_cache;
    my $size = $self->statement_cache_size;
    Selecto::Error->throw('invalid_adapter', 'statement_cache_size must be a positive integer')
        unless defined($size) && !ref($size) && "$size" =~ /\A[1-9]\d{0,5}\z/;
    return 1;
}

sub _cached_execute {
    my ($self, $sql, $params, $failure) = @_;
    return Selecto::PostgreSQL::StatementCache->execute($self->{dbh}, $sql, $params,
        size => 0 + $self->statement_cache_size,
        execute => sub { return $self->_execute_statement(@_); },
        normalize => sub { return $self->normalize_error($_[0]); },
        failure => $failure,
    );
}

# A raw BEGIN leaves AutoCommit on, but the server still reports the
# transaction: pg_ping answers 3 (idle in a transaction) or 4 (in a failed
# one). Asked only when AutoCommit is on. A connection busy with the host's
# own statement (2) is refused: Selecto never begins, rolls back or creates a
# savepoint around a result it does not own.
sub _server_transaction_open {
    my ($self) = @_;
    my $status = eval { $self->{dbh}->pg_ping };
    return undef unless defined($status) && $status > 0;
    _refuse_connection_state('active') if $status == 2;
    return $status >= 3 ? 1 : 0;
}

# DBD::Pg holds the host's asynchronous query (pg_async) until the host takes
# its result. Its rollback would silently discard that result and the host's
# transaction with it, so nothing Selecto runs may start while one is pending.
sub _transaction_open {
    my ($self) = @_;
    $self->_refuse_pending_result;
    return $self->SUPER::_transaction_open;
}

sub _refuse_pending_result {
    my ($self) = @_;
    _refuse_connection_state('active') if eval { $self->{dbh}{pg_async_status} };
    return;
}

# The connection state, as libpq reports it, before a read guard (a bounded
# stream or a savepoint query budget) sends anything: 'idle', 'intrans',
# 'active', 'inerror' or 'unknown'. A pending asynchronous result is
# 'active' whatever pg_ping says.
sub _connection_state {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return 'active' if eval { $dbh->{pg_async_status} };
    my $status = eval { $dbh->pg_ping };
    return 'unknown' unless defined $status;
    return {1 => 'idle', 2 => 'active', 3 => 'intrans', 4 => 'inerror'}->{$status} // 'unknown';
}

# Where a read guard may run: 'own' (an idle handle: the guard begins and
# rolls back its own transaction) or 'host' (the host's healthy transaction,
# or an AutoCommit => 0 handle DBD::Pg has not begun yet: a savepoint).
# Anything else (a pending result, an aborted transaction, an unknown or
# broken connection) is refused before a single statement is sent.
sub _read_guard_scope {
    my ($self) = @_;
    my $state = $self->_connection_state;
    my $auto_commit = eval { $self->{dbh}{AutoCommit} };
    return $auto_commit ? 'own' : 'host' if $state eq 'idle' && defined $auto_commit;
    return 'host' if $state eq 'intrans';
    _refuse_connection_state($state);
}

sub _refuse_connection_state {
    my ($state) = @_;
    my %reason = (
        active => 'the database connection is busy with another statement or a pending result',
        inerror => 'the host transaction has already failed',
    );
    Selecto::Error->throw('transaction_state_unsafe',
        ($reason{$state} // 'the database connection state is unknown')
            . '; Selecto will not open a transaction or savepoint on it',
        {state => exists($reason{$state}) ? $state : 'unknown'});
}

# ---- Session state (brief items 54, 54a, 54b, 56, 56b, 56c, 59, 61) --------
#
# An allowed row trigger, or a function a domain view calls, can change the
# session state that later SQL resolves or parses through:
# set_config('search_path' | 'TimeZone' | 'DateStyle' | ..., ..., true|false),
# a TEMP relation or type (pg_temp is searched first, whatever search_path
# says), or a rule on one. Every Selecto write and read compares a snapshot of
# that state taken before its statement with one taken as the first statement
# after it, read with SQL that names only pg_catalog objects so a hijacked
# search_path cannot answer it; on any change the work is rolled back (its
# savepoint, or its own transaction) and refused with query_rule_violation,
# reason session_state_changed. In autocommit a read restores the settings
# it saw before. Selecto keeps no GUC of its own to prove ownership (item 57):
# a bounded stream proves its own transaction by its virtual transaction id.
#
# What a trigger does beyond this (other settings, role changes, writes to
# unrelated tables, DDL outside the temp schema) is the schema owner's
# responsibility, like a trigger's effects on other rows (item 56a).
my @SESSION_SETTINGS = qw(search_path TimeZone DateStyle IntervalStyle extra_float_digits timezone_abbreviations bytea_output standard_conforming_strings);
my $TEMP_SCHEMA = 'pg_catalog.pg_my_temp_schema()';
# The count of enabled deferrable triggers that can run user code at COMMIT
# (R23, R32, R32a, R37): every user-defined one, and an internal foreign-key
# or unique/exclusion recheck unless all of these are pg_catalog's own: its
# function; its index (the constraint's, or the referenced one for a foreign
# key) with no expressions or predicate and only default or pg_catalog
# collations and operator classes; its exclusion and foreign-key operators
# and their functions; and every key column's type (a base type, or a
# domain over one, or a pg_catalog range or multirange over one, R37b).
my $PGC = q{CAST('pg_catalog' AS pg_catalog.regnamespace)};
my $OPS_BAD = join ' OR ', map {
    "EXISTS (SELECT 1 FROM pg_catalog.unnest(c.$_) AS e(op) JOIN pg_catalog.pg_operator p ON p.oid OPERATOR(pg_catalog.=) e.op "
        . "JOIN pg_catalog.pg_proc pf ON pf.oid OPERATOR(pg_catalog.=) p.oprcode "
        . "WHERE p.oprnamespace OPERATOR(pg_catalog.<>) $PGC OR pf.pronamespace OPERATOR(pg_catalog.<>) $PGC)"
} qw(conexclop conpfeqop conppeqop conffeqop);
my $INDEX_BAD = "EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indexrelid OPERATOR(pg_catalog.=) c.conindid AND ("
    . 'i.indexprs IS NOT NULL OR i.indpred IS NOT NULL '
    . 'OR EXISTS (SELECT 1 FROM pg_catalog.unnest(CAST(i.indcollation AS pg_catalog.oid[])) AS l(coll) '
    . 'LEFT JOIN pg_catalog.pg_collation co ON co.oid OPERATOR(pg_catalog.=) l.coll '
    . "WHERE l.coll OPERATOR(pg_catalog.<>) CAST(0 AS pg_catalog.oid) AND (co.oid IS NULL OR co.collnamespace OPERATOR(pg_catalog.<>) $PGC)) "
    . 'OR EXISTS (SELECT 1 FROM pg_catalog.unnest(CAST(i.indclass AS pg_catalog.oid[])) AS k(opclass) '
    . 'LEFT JOIN pg_catalog.pg_opclass o ON o.oid OPERATOR(pg_catalog.=) k.opclass '
    . "WHERE o.oid IS NULL OR o.opcnamespace OPERATOR(pg_catalog.<>) $PGC)))";
# A range or multirange key column (R37b): pg_catalog's own type whose
# pg_range entry names a pg_catalog base subtype, operator class and
# collation (or none) and no canonical or subtype-difference function outside
# pg_catalog. A range type defined outside pg_catalog still counts.
my $RANGE_OK = 'EXISTS (SELECT 1 FROM pg_catalog.pg_range rg '
    . 'JOIN pg_catalog.pg_type st ON st.oid OPERATOR(pg_catalog.=) rg.rngsubtype '
    . 'JOIN pg_catalog.pg_opclass oc ON oc.oid OPERATOR(pg_catalog.=) rg.rngsubopc '
    . 'WHERE (rg.rngtypid OPERATOR(pg_catalog.=) b.oid OR rg.rngmultitypid OPERATOR(pg_catalog.=) b.oid) '
    . "AND st.typnamespace OPERATOR(pg_catalog.=) $PGC AND st.typtype OPERATOR(pg_catalog.=) 'b' "
    . "AND oc.opcnamespace OPERATOR(pg_catalog.=) $PGC "
    . 'AND (rg.rngcollation OPERATOR(pg_catalog.=) CAST(0 AS pg_catalog.oid) OR EXISTS (SELECT 1 FROM pg_catalog.pg_collation co '
    . "WHERE co.oid OPERATOR(pg_catalog.=) rg.rngcollation AND co.collnamespace OPERATOR(pg_catalog.=) $PGC)) "
    . join(' ', map { "AND (CAST(rg.$_ AS pg_catalog.oid) OPERATOR(pg_catalog.=) CAST(0 AS pg_catalog.oid) "
        . "OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc rp WHERE rp.oid OPERATOR(pg_catalog.=) CAST(rg.$_ AS pg_catalog.oid) "
        . "AND rp.pronamespace OPERATOR(pg_catalog.=) $PGC))" } qw(rngcanonical rngsubdiff)) . ')';
my $TYPES_BAD = join ' OR ', map {
    my ($rel, $keys) = @$_;
    "EXISTS (SELECT 1 FROM pg_catalog.unnest(c.$keys) AS kk(attnum) JOIN pg_catalog.pg_attribute a "
        . "ON a.attrelid OPERATOR(pg_catalog.=) c.$rel AND a.attnum OPERATOR(pg_catalog.=) kk.attnum "
        . 'JOIN pg_catalog.pg_type ty ON ty.oid OPERATOR(pg_catalog.=) a.atttypid '
        . "LEFT JOIN pg_catalog.pg_type b ON b.oid OPERATOR(pg_catalog.=) (CASE WHEN ty.typtype OPERATOR(pg_catalog.=) 'd' THEN ty.typbasetype ELSE ty.oid END) "
        . "WHERE b.oid IS NULL OR b.typnamespace OPERATOR(pg_catalog.<>) $PGC OR NOT (b.typtype OPERATOR(pg_catalog.=) 'b' "
        . "OR ((b.typtype OPERATOR(pg_catalog.=) 'r' OR b.typtype OPERATOR(pg_catalog.=) 'm') AND $RANGE_OK)))"
} [conrelid => 'conkey'], [confrelid => 'confkey'];
my $DEFERRABLE_COUNT = '(SELECT pg_catalog.count(*) FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc f ON f.oid OPERATOR(pg_catalog.=) t.tgfoid '
    . "WHERE t.tgenabled OPERATOR(pg_catalog.<>) 'D' AND t.tgdeferrable AND NOT (t.tgisinternal "
    . "AND f.pronamespace OPERATOR(pg_catalog.=) $PGC "
    . "AND (pg_catalog.starts_with(CAST(f.proname AS pg_catalog.text), 'RI_FKey_') "
    . "OR f.proname OPERATOR(pg_catalog.=) CAST('unique_key_recheck' AS pg_catalog.name)) "
    . 'AND EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c WHERE c.oid OPERATOR(pg_catalog.=) t.tgconstraint '
    . "AND NOT ($INDEX_BAD) AND NOT ($OPS_BAD) AND NOT ($TYPES_BAD))))";

my $SESSION_SNAPSHOT_COLUMNS = join(', ',
    q{pg_catalog.concat_ws(' | ', } . join(', ', map { "pg_catalog.current_setting('$_')" } @SESSION_SETTINGS) . ', '
        . q{COALESCE((SELECT pg_catalog.string_agg(pg_catalog.concat_ws(':', c.oid, c.xmin, c.relname), ',' ORDER BY c.oid) }
        . qq{FROM pg_catalog.pg_class c WHERE c.relnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA), ''), }
        . q{COALESCE((SELECT pg_catalog.string_agg(pg_catalog.concat_ws(':', r.oid, r.xmin), ',' ORDER BY r.oid) }
        . q{FROM pg_catalog.pg_rewrite r JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) r.ev_class }
        . qq{WHERE c.relnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA), ''), }
        . q{COALESCE((SELECT pg_catalog.string_agg(pg_catalog.concat_ws(':', t.oid, t.xmin, t.typname), ',' ORDER BY t.oid) }
        . qq{FROM pg_catalog.pg_type t WHERE t.typnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA), ''), 'end')},
    (map { "pg_catalog.current_setting('$_')" } @SESSION_SETTINGS));
# Deferrable triggers that can run user code at COMMIT (R23): a write is
# refused while any exists. Not part of the compared snapshot, and a read
# never asks (its plan alone is a large part of a read's guard cost).
my $SESSION_COLUMNS = "$SESSION_SNAPSHOT_COLUMNS, $DEFERRABLE_COUNT";
my $READ_SESSION_COLUMNS = "$SESSION_SNAPSHOT_COLUMNS, 0";

# A relation the statement names that resolves into this session's temp
# schema while a same-named relation exists in a schema of the search path
# (current_schemas(false)) shadows it: refused. A temp relation with no such
# namesake is the host's own (a TEMP domain table) and allowed. A temp type
# that is not a relation's row type (or its array) and is named like a type
# of pg_catalog or of the search path would answer an unqualified type name
# in the statement: refused (item 56c).
my $SHADOW_PREFIX = 'SELECT (SELECT pg_catalog.count(*) FROM pg_catalog.unnest(CAST($1 AS pg_catalog.text[])) AS r(name) '
    . 'JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) pg_catalog.to_regclass(r.name) '
    . "WHERE c.relnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA AND EXISTS (SELECT 1 FROM pg_catalog.pg_class o "
    . 'JOIN pg_catalog.pg_namespace s ON s.oid OPERATOR(pg_catalog.=) o.relnamespace '
    . 'WHERE o.relname OPERATOR(pg_catalog.=) c.relname AND o.relnamespace OPERATOR(pg_catalog.<>) c.relnamespace '
    . 'AND s.nspname OPERATOR(pg_catalog.=) ANY (pg_catalog.current_schemas(false)))), '
    . "(SELECT pg_catalog.count(*) FROM pg_catalog.pg_type t WHERE t.typnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA "
    . 'AND t.typrelid OPERATOR(pg_catalog.=) 0 AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type e '
    . 'WHERE e.oid OPERATOR(pg_catalog.=) t.typelem AND e.typrelid OPERATOR(pg_catalog.<>) 0) '
    . 'AND EXISTS (SELECT 1 FROM pg_catalog.pg_type p JOIN pg_catalog.pg_namespace s ON s.oid OPERATOR(pg_catalog.=) p.typnamespace '
    . 'WHERE p.typname OPERATOR(pg_catalog.=) t.typname AND p.typnamespace OPERATOR(pg_catalog.<>) t.typnamespace '
    . "AND (s.nspname OPERATOR(pg_catalog.=) 'pg_catalog' OR s.nspname OPERATOR(pg_catalog.=) ANY (pg_catalog.current_schemas(false))))), "
;
my $SHADOW_SQL = $SHADOW_PREFIX . $SESSION_COLUMNS;
my $READ_SHADOW_SQL = $SHADOW_PREFIX . $READ_SESSION_COLUMNS;

# The relation names a statement reads or writes, as its SQL spells them,
# for the shadow check (items 56b, R2, R10). A statement Selecto compiled
# (or derived from compiled ones) and a compiled write carry the list their
# compile recorded: the root, joined and through-bridge relations, member,
# retarget and co-domain sources, collection and association_exists
# subqueries, the write target and reference-guard parents. The SQL text is
# scanned as well, and is all a host's hand-built statement has: every name
# after FROM, JOIN, INTO, UPDATE or USING, including inside parenthesised
# joins and an INSERT target followed by its column list. A name that is not
# a relation resolves to nothing and is ignored by the check.
sub _pg_statement_relations {
    my ($source) = @_;
    my ($sql, $recorded);
    if (blessed($source) && $source->can('sql')) {
        ($sql, $recorded) = ($source->sql, $source->can('relations') ? $source->relations : undef);
    } elsif (ref($source) eq 'HASH') {
        ($sql, $recorded) = ($source->{sql}, ref($source->{relations}) eq 'ARRAY' ? $source->{relations} : undef);
    } else {
        $sql = $source;
    }
    Selecto::Error->throw('query_rule_not_evaluable', 'the statement has no relation list to check',
        {reason => 'relations_unknown'}) unless defined($sql) && !ref($sql) && length($sql);
    my $part = q{(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_\$]*+)};
    # A compiled statement's list is complete and names relations only (R28,
    # R33, R34): its relations are schema-qualified, so the scan below is for
    # a host's hand-built statement alone.
    return [sort grep { defined && !ref } @$recorded] if ref($recorded) eq 'ARRAY';
    my %names;
    while ($sql =~ /\b(FROM|JOIN|INTO|UPDATE|USING)\s+(?:ONLY\s+)?(?:\(\s*)*($part(?:\.$part)?)(?![A-Za-z0-9_\$".])(\s*\()?/gi) {
        my ($keyword, $name, $call) = ($1, $2, $3);
        # A function call (FROM unnest(...)), except an INSERT target's
        # column list; SQL keywords opening a subquery are not names.
        next if defined($call) && uc($keyword) ne 'INTO';
        next if $name =~ /\A(?:SELECT|LATERAL|VALUES|WITH|ROWS)\z/i;
        $names{$name} = 1;
    }
    return [sort keys %names];
}

# R23b / R29 (item 58): generated reads and writes name every relation by
# its schema, resolved when the statement is compiled against a search path
# the session cannot hijack with set_config: the host-pinned read prefix
# when there is one, otherwise the session's search_path reset value
# (pg_settings.reset_val, from server, database, role or connection
# configuration; "$user" is the current user, pg_temp and pg_catalog are
# skipped). The current search_path is never consulted. A TEMP relation
# named like one found there shadows it and is refused (temporary_shadow);
# a TEMP relation with no such namesake is the host's own and is named by
# its temp schema. Query sources (CTE, VALUES) are never rendered through
# here, so a CTE named like a real relation never hides it (R33). A
# relation found nowhere, or a reset path that cannot be read, fails closed
# (query_rule_not_evaluable, reason relation_unresolved): no unqualified
# relation is ever sent. Hosts that SET search_path to reach other schemas
# must pin the schema (the engine's tenant prefix). Resolved once per
# relation per compile, with pg_catalog-only SQL.
# R36: PostgreSQL itself parses the reset search_path (quoting, case
# folding, "$user" as current_user, missing schemas skipped): it is applied
# with set_config(..., true) and read back with current_schemas(false), in
# one statement whose CTE runs first. On an idle autocommit handle that
# statement is its own transaction, so the setting ends with it; inside a
# transaction it runs under a savepoint that is rolled back.
my $RESET_SCHEMAS_SQL = q{WITH s AS MATERIALIZED (SELECT pg_catalog.set_config('search_path', }
    . q{(SELECT r.reset_val FROM pg_catalog.pg_settings r WHERE r.name OPERATOR(pg_catalog.=) 'search_path'), true) AS v) }
    . q{SELECT CAST(pg_catalog.current_schemas(false) AS pg_catalog.text[]) FROM s};
# The pinned resolution (first schema of the reset path holding the name),
# the session's temp relation of that name, and what the host's current
# search_path resolves the name to; all as oids.
my $QUALIFY_SQL = 'SELECT (SELECT c.oid FROM pg_catalog.unnest(CAST($1 AS pg_catalog.text[])) WITH ORDINALITY AS p(name, ord) '
    . 'JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) p.name '
    . 'JOIN pg_catalog.pg_class c ON c.relnamespace OPERATOR(pg_catalog.=) n.oid AND c.relname OPERATOR(pg_catalog.=) $2 '
    . 'ORDER BY p.ord LIMIT 1), '
    . "(SELECT c.oid FROM pg_catalog.pg_class c WHERE c.relnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA AND c.relname OPERATOR(pg_catalog.=) \$2), "
    . 'CAST(pg_catalog.to_regclass($3) AS pg_catalog.oid)';
my $NAME_SQL = 'SELECT pg_catalog.quote_ident(n.nspname) OPERATOR(pg_catalog.||) \'.\' OPERATOR(pg_catalog.||) pg_catalog.quote_ident(c.relname) '
    . 'FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace '
    . 'WHERE c.oid OPERATOR(pg_catalog.=) CAST($1 AS pg_catalog.oid)';

# The reset search path's schemas, once per compile (or per call).
sub _pg_reset_schemas {
    my ($self) = @_;
    # Shared by one operation's relation check and pin (they run back to
    # back, in the same session), never across operations (R38).
    my $operation = $self->{_selecto_reset_operation};
    return @{$operation->{schemas}} if ref($operation) eq 'HASH' && $operation->{schemas};
    my $cache = $self->{_selecto_relation_schemas};
    return @{$cache->{"\0reset"}} if ref($cache) eq 'HASH' && $cache->{"\0reset"};
    my $dbh = $self->{dbh};
    my $inside = !$dbh->{AutoCommit} || $self->_connection_state eq 'intrans';
    my $savepoint = $inside ? Selecto::SQL::_savepoint_name('selecto_path') : undef;
    my ($schemas, $error);
    my $ok = eval {
        $self->_savepoint_command(create => $savepoint) if $savepoint;
        ($schemas) = $dbh->selectrow_array($RESET_SCHEMAS_SQL);
        1;
    };
    $error = $@ unless $ok;
    if ($savepoint) {
        my $restored = eval {
            $self->_savepoint_command(rollback => $savepoint);
            $self->_savepoint_command(release => $savepoint);
            1;
        };
        $error //= $@ unless $restored;
    }
    Selecto::Error->throw('query_rule_not_evaluable', "the session's reset search_path could not be resolved",
        {reason => 'relation_unresolved'}) if defined($error) || ref($schemas) ne 'ARRAY';
    my @schemas = grep { defined && !/\Apg_temp/ && $_ ne 'pg_catalog' } @$schemas;
    $cache->{"\0reset"} = \@schemas if ref($cache) eq 'HASH';
    $operation->{schemas} = [@schemas] if ref($operation) eq 'HASH';
    return @schemas;
}

# R38, R39, R41, R42: run before every statement's pin, never cached. A
# compiled statement names schema-qualified relations: each must still be
# what the reset search_path resolves its name to now (a SET ROLE, or a
# reset value changed since the statement was compiled, refuses), and the
# host's current search_path must not name another non-temp relation by it.
# A hand-built statement (no recorded list) fails closed: every unqualified
# name in a relation position must resolve as above, and no undeclared TEMP
# relation of the session may be named anywhere in its SQL.
my $CHECK_SQL = 'SELECT r.ord, CAST(CASE WHEN r.s IS NULL THEN NULL ELSE pg_catalog.to_regclass(pg_catalog.concat(pg_catalog.quote_ident(r.s), \'.\', pg_catalog.quote_ident(r.t))) END AS pg_catalog.oid), '
    . '(SELECT c.oid FROM pg_catalog.unnest(CAST($3 AS pg_catalog.text[])) WITH ORDINALITY AS p(name, o) '
    . 'JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) p.name '
    . 'JOIN pg_catalog.pg_class c ON c.relnamespace OPERATOR(pg_catalog.=) n.oid AND c.relname OPERATOR(pg_catalog.=) r.t ORDER BY p.o LIMIT 1), '
    . "(SELECT c.oid FROM pg_catalog.pg_class c WHERE c.relnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA AND c.relname OPERATOR(pg_catalog.=) r.t), "
    . 'CAST(pg_catalog.to_regclass(pg_catalog.quote_ident(r.t)) AS pg_catalog.oid), '
    . "(r.s IS NOT NULL AND pg_catalog.starts_with(r.s, 'pg_temp'))::pg_catalog.int4 "
    . 'FROM ROWS FROM (pg_catalog.unnest(CAST($1 AS pg_catalog.text[])), pg_catalog.unnest(CAST($2 AS pg_catalog.text[]))) WITH ORDINALITY AS r(s, t, ord) ORDER BY r.ord';
my $TEMP_NAMES_SQL = "SELECT CAST(c.relname AS pg_catalog.text) FROM pg_catalog.pg_class c WHERE c.relnamespace OPERATOR(pg_catalog.=) $TEMP_SCHEMA";
my $IDENT = q{(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_\$]*)};
sub _unquote_identifier {
    my ($text) = @_;
    if ($text =~ /\A"((?:[^"]|"")+)"\z/) { (my $name = $1) =~ s/""/"/g; return $name }
    return lc $text;
}

# The schemas a compiled statement's read declared (a tenant prefix).
sub _pg_declared_schemas {
    my ($source) = @_;
    my $list = blessed($source) ? $source->{_selecto_declared_schemas} : ref($source) eq 'HASH' ? $source->{declared_schemas} : undef;
    return ref($list) eq 'ARRAY' ? grep { defined && length } @$list : ();
}

sub _pg_check_relations {
    my ($self, $source) = @_;
    my $recorded = blessed($source) && $source->can('relations') ? $source->relations
        : ref($source) eq 'HASH' ? $source->{relations} : undef;
    my (@schemas, @tables);
    if (ref($recorded) eq 'ARRAY') {
        for my $name (@$recorded) {
            next unless defined($name) && !ref($name);
            if ($name =~ /\A($IDENT)\.($IDENT)\z/) {
                push @schemas, _unquote_identifier($1);
                push @tables, _unquote_identifier($2);
            } else {
                push @schemas, undef;
                push @tables, _unquote_identifier($name);
            }
        }
    } else {
        my $sql = blessed($source) && $source->can('sql') ? $source->sql : ref($source) eq 'HASH' ? $source->{sql} : $source;
        # Every identifier the SQL holds is checked, whatever its position
        # (comma FROM lists, USING lists, subqueries: R42); one that names no
        # relation on either path is ignored. A name written qualified binds
        # its schema and is not looked up by the search path.
        my %seen;
        my $scan = $sql;
        $scan =~ s/'(?:[^']|'')*'//g;
        while ($scan =~ /((?:$IDENT\s*\.\s*)*)($IDENT)/g) {
            my ($qualifier, $name) = ($1, $2);
            next if length $qualifier;
            next if pos($scan) < length($scan) && substr($scan, pos($scan)) =~ /\A\s*\./;
            my $bare = _unquote_identifier($name);
            next if $seen{$bare}++;
            push @schemas, undef;
            push @tables, $bare;
        }
        # R42 FINAL: no scanner of hand-built SQL is complete, so while the
        # session has any TEMP relation such a statement is refused unless
        # the adapter declares temp relations.
        unless ($self->temporary_relations) {
            my $temps;
            my $ok = eval { $temps = $self->{dbh}->selectcol_arrayref($TEMP_NAMES_SQL); 1 };
            die $self->normalize_error($@) unless $ok;
            Selecto::Error->throw('query_rule_not_evaluable',
                'a hand-built statement cannot run while the session has temporary relations the adapter does not declare',
                {reason => 'temporary_shadow'}) if @{$temps // []};
        }
    }
    return unless @tables;
    local $self->{_selecto_relation_schemas} = {};
    # Declared (prefix) schemas first: the host's explicit choice (R43).
    my @declared = _pg_declared_schemas($source);
    my %declared = map { ($_ => 1) } @declared;
    my @reset = (@declared, $self->_pg_reset_schemas);
    my $rows;
    my $ok = eval { $rows = $self->{dbh}->selectall_arrayref($CHECK_SQL, undef, \@schemas, \@tables, \@reset); 1 };
    die $self->normalize_error($@) unless $ok && ref($rows) eq 'ARRAY';
    my $refuse = sub {
        Selecto::Error->throw('query_rule_not_evaluable', $_[1], {reason => $_[0], relation => $_[2]});
    };
    for my $row (@$rows) {
        my ($ord, $fixed, $pinned, $temp, $current, $temp_schema) = @$row;
        my $table = $tables[$ord - 1];
        if (defined $schemas[$ord - 1]) {
            # A compiled relation: still the pinned resolution (or a declared
            # TEMP relation with no reset-path namesake).
            if ($temp_schema) {
                $refuse->('relation_unresolved', 'the relation exists only as a temporary relation of the session, which the adapter does not declare', $table)
                    unless $self->temporary_relations && !defined($pinned) && defined($temp) && defined($fixed) && "$fixed" eq "$temp";
            } else {
                $refuse->('relation_ambiguous', 'the relation no longer resolves where the statement was compiled to read it', $table)
                    unless defined($fixed) && defined($pinned) && "$fixed" eq "$pinned";
            }
            my $target = $fixed;
            # A relation in a declared schema is the host's explicit choice:
            # the host's current search_path does not decide it.
            $refuse->('relation_ambiguous', "the host's search_path resolves the relation differently from Selecto's pinned resolution", $table)
                if !$declared{$schemas[$ord - 1]}
                    && defined($current) && defined($target) && "$current" ne "$target" && !(defined($temp) && "$current" eq "$temp");
        } else {
            $refuse->('relation_ambiguous', "the host's search_path resolves the relation differently from Selecto's pinned resolution", $table)
                if defined($current) && defined($pinned) && "$current" ne "$pinned" && !(defined($temp) && "$current" eq "$temp");
            $refuse->('relation_unresolved', 'the relation exists only as a temporary relation of the session, which the adapter does not declare', $table)
                if !defined($pinned) && defined($temp) && !$self->temporary_relations;
        }
    }
    return;
}

sub _relation_sql {
    my ($self, $prefix, $table) = @_;
    my $plain = $self->SUPER::_relation_sql($prefix, $table);
    return $plain if defined($prefix) || !defined($table) || ref($table) || !$self->_pg_session_checked;
    my $cache = $self->{_selecto_relation_schemas};
    return $cache->{$plain} if ref($cache) eq 'HASH' && exists $cache->{$plain};
    # Nothing is sent on a busy, failed or unknown connection: the guard that
    # would run the statement refuses it (transaction_state_unsafe) before
    # anything reaches the server.
    my $state = ref($cache) eq 'HASH' ? ($cache->{"\0state"} //= $self->_connection_state) : $self->_connection_state;
    return $plain unless $state =~ /\A(?:idle|intrans)\z/;
    my @schemas = $self->_pg_reset_schemas;
    my ($pinned, $temp, $current, $name);
    my $ok = eval {
        ($pinned, $temp, $current) = $self->{dbh}->selectrow_array($QUALIFY_SQL, undef, \@schemas, "$table", $plain);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    my $refuse = sub {
        Selecto::Error->throw('query_rule_not_evaluable', $_[1], {reason => $_[0], relation => "$table"});
    };
    # Resolution never prefers pg_temp (R38a): a relation of the reset path
    # is named by its schema, so a TEMP namesake cannot affect it; only the
    # host's declared TEMP relations may serve when the reset path has none.
    my $target = $pinned // ($self->temporary_relations ? $temp : undef);
    $refuse->('relation_unresolved', defined($temp)
        ? 'the relation exists only as a temporary relation of the session, which the adapter does not declare'
        : 'the relation is not in a schema of the reset search_path') unless defined $target;
    # R38: the host's current search_path must not name another non-temp
    # relation (pg_temp, searched first by the host's path, is not counted:
    # the qualified name never reaches it).
    $refuse->('relation_ambiguous', "the host's search_path resolves the relation differently from Selecto's pinned resolution")
        if defined($current) && "$current" ne "$target" && !(defined($temp) && "$current" eq "$temp");
    $ok = eval { ($name) = $self->{dbh}->selectrow_array($NAME_SQL, undef, $target); 1 };
    die $self->normalize_error($@) unless $ok && defined $name;
    $cache->{$plain} = $name if ref($cache) eq 'HASH';
    return $name;
}

# R30, R35: Selecto pins search_path, and every setting that changes how
# its SQL parses literals or renders results, for each of its statements,
# inside its own transaction or savepoint: search_path is pg_catalog first
# (operators, functions and types resolve there before anything else), then
# the reset search path's schemas, pg_temp last; TimeZone, DateStyle,
# IntervalStyle, extra_float_digits, bytea_output and
# standard_conforming_strings take their reset values (pg_settings.reset_val:
# server, database, role or connection configuration), so the host's
# configured semantics hold while a session-level switch does not. A switch that persisted
# before the call (including one masked by a local set_config) cannot
# redirect a name or change a scope literal's meaning. The host's values
# are restored with set_config(..., true) before control returns (a
# rollback reverts them too); on an idle autocommit handle a read sets them
# for the session and restores them right after.
my @PINNED_SETTINGS = map { [$_ => undef] }
    qw(TimeZone DateStyle IntervalStyle extra_float_digits bytea_output standard_conforming_strings timezone_abbreviations);
sub _pg_pin_search_path {
    my ($self, $session, $source) = @_;
    my $local = $session ? 'false' : 'true';
    local $self->{_selecto_relation_schemas} = {};
    my @declared = _pg_declared_schemas($source);
    my %seen;
    my @schemas = grep { !$seen{$_}++ } @declared, $self->_pg_reset_schemas;
    my $pinned = join(', ', 'pg_catalog', (map { _quote_path_schema($_) } @schemas), 'pg_temp');
    my @pins = (['search_path' => $pinned], @PINNED_SETTINGS);
    # search_path takes the resolved pin; every other setting its reset
    # value (R35 amendment), read through pg_catalog in the same statement,
    # from one scan of pg_settings (each scan builds every setting's row).
    my @reset = map { $_->[0] } grep { !defined $_->[1] } @pins;
    my @set = map {
        my $name = $pins[$_][0];
        defined($pins[$_][1])
            ? "pg_catalog.set_config('$name', \$" . ($_ + 1) . ", $local)"
            : "pg_catalog.set_config('$name', (SELECT r.reset_val FROM r WHERE r.name OPERATOR(pg_catalog.=) '$name'), $local)"
    } 0 .. $#pins;
    my $current = join ', ', map { "pg_catalog.current_setting('$pins[$_][0]') AS s$_" } 0 .. $#pins;
    my $names = '{' . join(',', @reset) . '}';
    my @host;
    my $ok = eval {
        @host = $self->{dbh}->selectrow_array("WITH h AS MATERIALIZED (SELECT $current), "
            . 'r AS MATERIALIZED (SELECT s.name, s.reset_val FROM pg_catalog.pg_settings s '
            . "WHERE s.name OPERATOR(pg_catalog.=) ANY (CAST('$names' AS pg_catalog.text[]))) SELECT "
            . join(', ', (map { "h.s$_" } 0 .. $#pins), @set) . ' FROM h', undef, $pins[0][1]);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    Selecto::Error->throw('query_rule_not_evaluable', "the session's reset settings could not be read",
        {reason => 'session_state_unknown'}) unless @host == 2 * @pins && !grep { !defined } @host;
    return {host => [map { [$pins[$_][0], $host[$_]] } 0 .. $#pins], pinned => $pinned, session => $session ? 1 : 0};
}

sub _pg_restore_search_path {
    my ($self, $pin) = @_;
    return unless ref($pin) eq 'HASH';
    my ($set, @binds) = _pg_restore_columns($pin);
    my $ok = eval { $self->{dbh}->selectrow_array("SELECT $set", undef, @binds); 1 };
    die $self->normalize_error($@) unless $ok;
    return;
}

# The set_config list that puts the host's settings back, and its binds.
sub _pg_restore_columns {
    my ($pin) = @_;
    my $local = $pin->{session} ? 'false' : 'true';
    my @host = @{$pin->{host}};
    return (join(', ', map { "pg_catalog.set_config('$host[$_][0]', \$" . ($_ + 1) . ", $local)" } 0 .. $#host),
        map { $_->[1] } @host);
}

sub _quote_path_schema {
    my ($name) = @_;
    (my $quoted = $name) =~ s/"/""/g;
    return qq{"$quoted"};
}

# True when the handle is a live DBD::Pg handle (the session checks need
# one; adapter tests with other handles run unchecked).
sub _pg_session_checked {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' } ? 1 : 0;
}

sub _pg_state_row {
    my ($row) = @_;
    my ($snapshot, @settings) = @$row;
    my $deferrable = $settings[@SESSION_SETTINGS];
    return {snapshot => $snapshot, deferrable => (defined($deferrable) && $deferrable ? 1 : 0),
        settings => {map { ($SESSION_SETTINGS[$_] => $settings[$_]) } 0 .. $#SESSION_SETTINGS}};
}

# The session snapshot, or a typed refusal when it cannot be read.
#
# With a pin, the same statement then restores the host's settings (see
# _pg_restore_search_path): the snapshot is materialized before any
# set_config in the outer list runs.
sub _pg_session_state {
    my ($self, $pin, %options) = @_;
    my $width = 1 + @SESSION_SETTINGS + 1;
    my ($sql, @binds) = ("SELECT " . ($options{read} ? $READ_SESSION_COLUMNS : $SESSION_COLUMNS));
    if (ref($pin) eq 'HASH') {
        my ($set, @values) = _pg_restore_columns($pin);
        my @names = map { "c$_" } 0 .. $width - 1;
        $sql = 'WITH st(' . join(', ', @names) . ") AS MATERIALIZED ($sql) SELECT "
            . join(', ', (map { "st.$_" } @names), $set) . ' FROM st';
        @binds = @values;
    }
    my @row;
    my $ok = eval { @row = $self->{dbh}->selectrow_array($sql, undef, @binds); 1 };
    Selecto::Error->throw('query_rule_not_evaluable', "the session's state could not be read",
        {reason => 'session_state_unknown'}) unless $ok && @row && defined $row[0];
    return _pg_state_row([@row[0 .. $width - 1]]);
}

# Refuses temp shadows of the statement's relations and of type names, and
# returns the session snapshot, in one round trip. A read (option read)
# leaves out the deferrable-trigger count only writes refuse on.
sub _pg_admit_session {
    my ($self, $source, %options) = @_;
    my $names = _pg_statement_relations($source);
    my @row;
    my $ok = eval { @row = $self->{dbh}->selectrow_array($options{read} ? $READ_SHADOW_SQL : $SHADOW_SQL, undef, $names); 1 };
    Selecto::Error->throw('query_rule_not_evaluable', "the session's state could not be read",
        {reason => 'session_state_unknown'}) unless $ok && @row == 2 + 1 + @SESSION_SETTINGS + 1 && defined $row[2];
    my ($relations, $types, @state) = @row;
    Selecto::Error->throw('query_rule_not_evaluable', 'a temporary relation of the session shadows a relation the statement names',
        {reason => 'temporary_shadow'}) if $relations;
    Selecto::Error->throw('query_rule_not_evaluable', 'a temporary type of the session shadows a type name',
        {reason => 'temporary_shadow'}) if $types;
    return _pg_state_row(\@state);
}

sub _session_changed {
    Selecto::Error->throw('query_rule_violation',
        "the statement changed the session's settings, temporary relations or temporary types",
        {reason => 'session_state_changed'});
}

# Writes (see Selecto::SQL::_execute_compiled_write_in_transaction): before
# the DML, refuse temp shadows and snapshot; the first statement after the
# DML compares. The transaction wrapper rolls the write back on refusal.
#
# Deferrable constraint triggers (R8, R14, R23) fire at COMMIT, after that
# check, and can change the session for every later statement; one can
# even be created by the write's own row trigger, or committed by another
# session while the write waits for a lock. Every PostgreSQL write (own or
# host transaction, guarded or not) is therefore refused while any enabled
# user-defined (non-internal) deferrable trigger exists in the database,
# checked before the DML and again in the first statement after it.
# Internal foreign-key triggers are not counted: deferred foreign keys keep
# working. Selecto never runs SET CONSTRAINTS.
sub _write_session_open {
    my ($self, $command, $compiled) = @_;
    return undef unless $self->_pg_session_checked;
    # The write runs inside its own transaction or savepoint: check its
    # relations (R41), pin search_path for it (R30), then snapshot under the
    # pin.
    my $pin = do {
        local $self->{_selecto_reset_operation} = {};
        $self->_pg_check_relations($compiled) if ref($compiled) eq 'HASH';
        $self->_pg_pin_search_path;
    };
    my $state = $self->_pg_admit_session(ref($compiled) eq 'HASH' ? $compiled : undef);
    $state->{pin} = $pin;
    _refuse_deferred_triggers() if $state->{deferrable};
    return $state;
}

# After the write's last post-statement check: the host's search_path again.
sub _write_session_close {
    my ($self, $state) = @_;
    $self->_pg_restore_search_path($state->{pin}) if ref($state) eq 'HASH';
    return;
}

sub _write_session_check {
    my ($self, $before) = @_;
    return unless defined $before;
    my $after = eval { $self->_pg_session_state };
    _session_changed() unless $after && $after->{snapshot} eq $before->{snapshot};
    _refuse_deferred_triggers() if $after->{deferrable};
    return;
}

sub _refuse_deferred_triggers {
    Selecto::Error->throw('query_rule_not_evaluable',
        'a user-defined deferrable constraint trigger exists in the database; it would fire at COMMIT, '
            . "after Selecto's session check (make it NOT DEFERRABLE)",
        {reason => 'deferred_triggers'});
}

# Post-statement re-reads name the written rows by (tableoid, ctid) (R9).
sub _rereads_by_row_id { return $_[0]->_pg_session_checked; }

sub _with_row_ids {
    my ($self, $compiled) = @_;
    return $compiled unless ref($compiled) eq 'HASH';
    my $columns = 'CAST(tableoid AS pg_catalog.text), CAST(ctid AS pg_catalog.text)';
    return {%$compiled, row_ids => 1,
        sql => $compiled->{sql} . (@{$compiled->{returning} // []} ? ', ' : ' RETURNING ') . $columns};
}

# Reads: the statement runs under its own savepoint in a host transaction
# (rolling back to it reverts local and session-level set_config, and any
# temp object the statement made), and in autocommit restores the settings
# it saw before. Nested guarded reads (a read inside a guarded read) run
# under the outer guard.
sub _guarded_read {
    my ($self, $source, $work) = @_;
    return $work->() if !$self->_pg_session_checked || $self->{_selecto_pg_read_guard};
    local $self->{_selecto_pg_read_guard} = 1;
    my $scope = $self->_read_guard_scope;
    # In the host's transaction the read runs under its own savepoint, with
    # search_path pinned for it locally (R30); a rollback to the savepoint
    # undoes the pin and anything the statement changed. On an idle
    # (autocommit) handle the pin is set for the session and restored right
    # after, with every setting the statement changed.
    my $savepoint;
    if ($scope eq 'host') {
        $savepoint = Selecto::SQL::_savepoint_name('selecto_read');
        eval { $self->_savepoint_command(create => $savepoint); 1 }
            or die $self->_transaction_control_error($@);
    }
    my ($pin, $before, $result);
    my $ok = eval {
        {
            local $self->{_selecto_reset_operation} = {};
            $self->_pg_check_relations($source);
            $pin = $self->_pg_pin_search_path(!$savepoint, $source);
        }
        $before = $self->_pg_admit_session($source, read => 1);
        $result = $work->();
        1;
    };
    my $error = $ok ? undef : $@;
    # The after-snapshot and the host's settings again, in one round trip:
    # the snapshot is read before the restore runs.
    my $after = $ok && $before ? eval { $self->_pg_session_state($pin, read => 1) } : undef;
    my $restored = $after ? 1 : 0;
    my $changed = $ok && $before && !($after && $after->{snapshot} eq $before->{snapshot});
    my $finished = eval {
        if ($savepoint) {
            if (!$ok || $changed) {
                $self->_savepoint_command(rollback => $savepoint);
            } elsif (!$restored) {
                $self->_pg_restore_search_path($pin);
            }
            $self->_savepoint_command(release => $savepoint);
        } else {
            if ($changed) {
                for my $name (@SESSION_SETTINGS) {
                    eval { $self->{dbh}->selectrow_array('SELECT pg_catalog.set_config($1, $2, false)', undef,
                        $name, $before->{settings}{$name}) };
                }
                $restored = 0;
            }
            $self->_pg_restore_search_path($pin) if $pin && !$restored;
        }
        1;
    };
    die $self->_transaction_control_error($@) if !$finished && $ok && !$changed;
    _session_changed() if $changed;
    die $error unless $ok;
    return $result;
}

# This transaction's virtual transaction id: setting-independent, and no
# statement can forge it (item 57).
sub _virtual_transaction_id {
    my ($self) = @_;
    my ($id) = $self->{dbh}->selectrow_array(q{SELECT l.virtualxid FROM pg_catalog.pg_locks l
        WHERE l.locktype OPERATOR(pg_catalog.=) 'virtualxid' AND l.pid OPERATOR(pg_catalog.=) pg_catalog.pg_backend_pid()
          AND l.granted AND l.mode OPERATOR(pg_catalog.=) 'ExclusiveLock'});
    return $id;
}

# Item 51/51a: the relation a write's post-statement SQL addresses, resolved
# before the statement (under its lock): its oid, its schema-qualified name
# and the oids its rows may live in (itself and its partitions). Rechecks
# use the oid and re-reads the qualified name with tableoid = ANY(oids),
# never a search_path lookup a trigger could redirect.
sub _pg_resolve_write_target {
    my ($self, $table) = @_;
    my $context = $self->{_selecto_write_target};
    return $context->{$table} if ref($context) eq 'HASH' && $context->{$table};
    my @row = $self->dbh->selectrow_array(q{
        SELECT c.oid, pg_catalog.quote_ident(n.nspname) OPERATOR(pg_catalog.||) '.' OPERATOR(pg_catalog.||) pg_catalog.quote_ident(c.relname),
          ARRAY(SELECT CAST(t.relid AS pg_catalog.oid) FROM pg_catalog.pg_partition_tree(c.oid) t
                UNION SELECT c.oid)
        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        WHERE c.oid OPERATOR(pg_catalog.=) pg_catalog.to_regclass($1)}, undef, $self->quote_identifier($table));
    Selecto::Error->throw('query_rule_not_evaluable', 'the written relation could not be resolved',
        {reason => 'relation_unresolved', relation => $table}) unless @row && defined $row[0];
    my $target = {oid => $row[0], qualified => $row[1], oids => $row[2]};
    $context->{$table} = $target if ref($context) eq 'HASH';
    return $target;
}

# The target resolved before the statement; a post-statement check without
# one fails closed.
sub _pg_write_target {
    my ($self, $table) = @_;
    my $context = $self->{_selecto_write_target};
    my $target = ref($context) eq 'HASH' ? $context->{$table} : undef;
    Selecto::Error->throw('query_rule_not_evaluable', 'the written relation was not resolved before the statement',
        {reason => 'relation_unresolved', relation => $table}) unless $target;
    return $target;
}

sub _identity_correlation_sql { return "$_[1] IS NOT DISTINCT FROM $_[2]"; }

# A statement Selecto compiled (or derived from one) carries its recorded
# relations and is qualified; a host's hand-built Statement is the host's
# own SQL and is sent exactly as written (R48), outside the lint.
sub _query_transport_sql {
    my ($self, $statement) = @_;
    return $statement->sql if _pg_hand_built($statement);
    return $self->_statement_sql($statement->sql);
}

sub _pg_hand_built {
    my ($statement) = @_;
    return blessed($statement) && $statement->can('relations') && !defined($statement->relations) ? 1 : 0;
}

# The statement as executed: every operator and pg_catalog function
# qualified (R46/R47). SELECTO_PG_SQL_LINT=1 makes any construct left to the
# session's lookup a hard error (the lint the test suite runs under).
sub _statement_sql {
    my ($self, $sql) = @_;
    return $sql unless defined($sql) && !ref($sql) && $self->_pg_session_checked;
    require Selecto::PostgreSQL::Qualify;
    my $functions = $self->_pg_catalog_functions;
    my $qualified = Selecto::PostgreSQL::Qualify::qualify($sql, $functions, $self->_pg_extension_operators($sql));
    if ($ENV{SELECTO_PG_SQL_LINT}) {
        my @problems = Selecto::PostgreSQL::Qualify::lint($qualified, $functions);
        die "SELECTO_PG_SQL_LINT: @problems in: $qualified\n" if @problems;
    }
    return $qualified;
}

# ---- SQL lint (SELECTO_PG_SQL_LINT=1, the test suite's corpus check) ------
#
# Under the lint, every statement Selecto itself executes on the handle,
# business SQL and its guard and catalog SQL alike (R48), must resolve no
# operator or pg_catalog function through the session; any that does dies.
# Only Selecto's own work is inspected: the host's statements, including
# those a transaction callback or transaction_handler runs, never are.
my %LINT_SKIP = map { ($_ => 1) } qw(SAVEPOINT RELEASE ROLLBACK BEGIN COMMIT SET LOCK DECLARE FETCH CLOSE DEALLOCATE);
sub _lint_scope {
    my ($self, $work) = @_;
    my $dbh = $self->{dbh};
    return $work->() unless $ENV{SELECTO_PG_SQL_LINT} && $self->_pg_session_checked;
    unless ($dbh->{private_selecto_lint_hooked}) {
        $dbh->{private_selecto_lint_hooked} = 1;
        my $adapter = $self;
        Scalar::Util::weaken($adapter);
        my $check = sub {
            my ($handle, $sql) = @_;
            return unless $handle->{private_selecto_lint_depth};
            return unless defined($sql) && !ref($sql) && $adapter;
            my ($first) = $sql =~ /\A\s*([A-Za-z]+)/;
            return if $first && $LINT_SKIP{uc $first};
            # The host's own statement (raw, or inside a stream's cursor).
            my $host = $adapter->{_selecto_pg_host_statement};
            return if defined($host) && index($sql, $host) >= 0;
            require Selecto::PostgreSQL::Qualify;
            local $handle->{private_selecto_lint_depth} = 0;
            my @problems = Selecto::PostgreSQL::Qualify::lint($sql, $adapter->_pg_catalog_functions);
            die "SELECTO_PG_SQL_LINT: @problems in: $sql\n" if @problems;
        };
        # prepare sees every statement (selectrow_array and friends prepare
        # internally; a ChildCallbacks execute hook would miss those), and do
        # without parameters runs without one.
        my %callbacks = %{$dbh->{Callbacks} // {}};
        for my $method (qw(prepare do)) {
            my $prior = $callbacks{$method};
            $callbacks{$method} = sub { $check->($_[0], $_[1]); return $prior ? $prior->(@_) : () };
        }
        $dbh->{Callbacks} = \%callbacks;
    }
    local $dbh->{private_selecto_lint_depth} = 1;
    return $work->();
}

sub _host_code_begin {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return undef unless eval { $dbh->isa('DBI::db') };
    my $depth = $dbh->{private_selecto_lint_depth};
    $dbh->{private_selecto_lint_depth} = 0;
    return $depth;
}

sub _host_code_end {
    my ($self, $depth) = @_;
    my $dbh = $self->{dbh};
    $dbh->{private_selecto_lint_depth} = $depth if eval { $dbh->isa('DBI::db') };
    return;
}

for my $method (qw(compile preview_write execute_write execute_batch execute_graph execute_transaction
    execute_write_unsafe execute_batch_unsafe execute_graph_unsafe)) {
    no strict 'refs';
    my $inherited = Selecto::SQL->can($method) or next;
    next if defined &{"Selecto::PostgreSQL::$method"};
    *{"Selecto::PostgreSQL::$method"} = sub {
        my ($self, @args) = @_;
        return $self->_lint_scope(sub { $self->$inherited(@args) });
    };
}

# pg_catalog's function names, once per connection (pg_catalog is fixed for
# a server; nothing a session does can change it).
sub _pg_catalog_functions {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return $dbh->{private_selecto_pg_functions} if ref($dbh->{private_selecto_pg_functions}) eq 'HASH';
    my $names;
    my $ok = eval {
        $names = $dbh->selectcol_arrayref(q{SELECT DISTINCT CAST(p.proname AS pg_catalog.text) FROM pg_catalog.pg_proc p
            WHERE p.pronamespace OPERATOR(pg_catalog.=) CAST('pg_catalog' AS pg_catalog.regnamespace)});
        1;
    };
    die $self->normalize_error($@) unless $ok;
    my %names = map { (lc($_) => 1) } @{$names // []};
    $dbh->{private_selecto_pg_functions} = \%names;
    return \%names;
}

# Columns of extension member types (citext and the like), or of domains
# over one (the typbasetype chain is followed down to the base type), of the
# relations the statement names, with the schema of each operator their own
# extension defines for the type (never a user operator someone added beside
# it), so their comparisons keep the extension's semantics:
# {relations => {"schema.table" => {column => {op => schema}}}}. Read per
# statement; nothing is cached. One recursive CTE over the columns (rather
# than a recursive LATERAL per column) keeps its planning cheap. A column
# whose domain chain is still a domain after 16 steps comes back with no
# operator, and the statement is refused.
my $EXTENSION_OPERATORS_SQL = q{WITH RECURSIVE c(rel, att, oid, depth) AS (
      SELECT r.rel, a.attname, a.atttypid, 0 FROM pg_catalog.unnest(CAST($1 AS pg_catalog.text[])) AS r(rel)
      JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) pg_catalog.to_regclass(r.rel)
        AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
      UNION ALL
      SELECT c.rel, c.att, t.typbasetype, c.depth OPERATOR(pg_catalog.+) 1 FROM c JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) c.oid
      WHERE t.typtype OPERATOR(pg_catalog.=) 'd' AND c.depth OPERATOR(pg_catalog.<) 16)
    SELECT CAST(c.rel AS pg_catalog.text), CAST(c.att AS pg_catalog.text), NULL, NULL
    FROM c JOIN pg_catalog.pg_type ty ON ty.oid OPERATOR(pg_catalog.=) c.oid AND ty.typtype OPERATOR(pg_catalog.=) 'd'
    WHERE c.depth OPERATOR(pg_catalog.=) 16
    UNION ALL
    SELECT CAST(c.rel AS pg_catalog.text), CAST(c.att AS pg_catalog.text),
      CAST(o.oprname AS pg_catalog.text), CAST(n.nspname AS pg_catalog.text)
    FROM c JOIN pg_catalog.pg_type ty ON ty.oid OPERATOR(pg_catalog.=) c.oid AND ty.typtype OPERATOR(pg_catalog.<>) 'd'
    JOIN pg_catalog.pg_depend d ON d.classid OPERATOR(pg_catalog.=) CAST('pg_catalog.pg_type' AS pg_catalog.regclass)
      AND d.objid OPERATOR(pg_catalog.=) ty.oid AND d.deptype OPERATOR(pg_catalog.=) 'e'
    JOIN pg_catalog.pg_operator o ON o.oprleft OPERATOR(pg_catalog.=) ty.oid AND o.oprright OPERATOR(pg_catalog.=) ty.oid
    JOIN pg_catalog.pg_depend od ON od.classid OPERATOR(pg_catalog.=) CAST('pg_catalog.pg_operator' AS pg_catalog.regclass)
      AND od.objid OPERATOR(pg_catalog.=) o.oid AND od.deptype OPERATOR(pg_catalog.=) 'e'
      AND od.refobjid OPERATOR(pg_catalog.=) d.refobjid
    JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) o.oprnamespace};
sub _pg_extension_operators {
    my ($self, $sql) = @_;
    require Selecto::PostgreSQL::Qualify;
    my $tokens = eval { Selecto::PostgreSQL::Qualify::tokenize($sql) } or return {};
    # Every schema-qualified relation the SQL names (generated SQL always
    # qualifies them, R23b); the qualifier resolves column references to
    # these by query scope.
    my %rels;
    for my $k (0 .. $#$tokens - 2) {
        next unless $tokens->[$k][0] =~ /\A(?:id|qid)\z/ && $tokens->[$k + 1][1] eq '.' && $tokens->[$k + 2][0] =~ /\A(?:id|qid)\z/;
        next if $k > 0 && $tokens->[$k - 1][1] eq '.';
        my $after = $k + 3 < @$tokens ? $tokens->[$k + 3] : undef;
        next if $after && ($after->[1] eq '(' || $after->[1] eq '.') && !($k > 0 && uc($tokens->[$k - 1][1]) eq 'INTO');
        my $prev = $k > 0 ? uc($tokens->[$k - 1][1]) : '';
        next unless $prev =~ /\A(?:FROM|JOIN|INTO|UPDATE|ONLY|\(|,)\z/;
        $rels{"$tokens->[$k][1].$tokens->[$k + 2][1]"} = 1;
    }
    return {} unless %rels;
    my @rels = sort keys %rels;
    my $rows;
    my $ok = eval { $rows = $self->{dbh}->selectall_arrayref($EXTENSION_OPERATORS_SQL, undef, \@rels); 1 };
    die $self->normalize_error($@) unless $ok;
    my %relations;
    for my $row (@{$rows // []}) {
        my ($rel, $column, $op, $schema) = @$row;
        # A domain chain deeper than the walk follows: its base type, and so
        # its operators, are unknown (review LOW).
        Selecto::Error->throw('query_rule_not_evaluable', 'a column is a domain chain too deep to resolve its base type',
            {reason => 'domain_chain_too_deep', relation => $rel, column => $column}) unless defined $op;
        my $key = lc join '.', map { s/\A"((?:[^"]|"")*)"\z/$1/r =~ s/""/"/gr } split /\.(?=(?:[^"]*"[^"]*")*[^"]*\z)/, $rel;
        $relations{$key}{lc $column}{$op} = '"' . ($schema =~ s/"/""/gr) . '"';
    }
    return %relations ? {relations => \%relations} : {};
}

1;

__END__

=head1 NAME

Selecto::PostgreSQL - PostgreSQL adapter

=head1 SYNOPSIS

  use DBI;
  use Selecto;

  my $dbh = DBI->connect('dbi:Pg:dbname=app;host=db', $user, $password,
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});
  my $adapter = Selecto->adapter(postgresql => (dbh => $dbh));

  # Optional attributes:
  my $adapter = Selecto->adapter(postgresql => (
      dbh              => $dbh,
      transaction_mode => 'external',  # see Selecto::SQL
      rollup_sort_fix  => 'auto',      # 'auto' (default), 1 or 0
      statement_cache  => 1,           # opt-in, default 0; see below
      statement_cache_size => 256,     # handles kept per connection
      canonical_values => 1,           # default 0: driver values; see RESULT VALUES
      canonical_sql    => 0,           # default 0: decode canonical values in Perl
  ));

  # Or per call:
  my $rows = $engine->all($query, canonical_values => 1)->{rows};

=head1 DESCRIPTION

The reference adapter, registered as C<postgresql>. It needs L<DBD::Pg>
3.016 or newer and is the adapter certified against the shared Selecto
specification suite.

It compiles to double-quoted identifiers and numbered C<$1> parameters, and
reuses a parameter's identity when the same governed expression appears in
selections, grouping and ordering. It supports every query feature in this
distribution: CTEs and recursive CTEs, window functions, set operations,
C<ROLLUP>, lateral joins, JSON rowsets, array rowsets and array predicates,
JSON containment, full-text search, computed value expressions, C<FOR SHARE>
row locks, streaming and projection sums. Writes support C<RETURNING> and
write graphs.

For bounded result buffering, pass C<< bounded => 1 >> to C<stream>. A real
DBD::Pg handle then uses a server cursor, not a C<RowCacheSize> hint, and
buffers at most C<fetch_size> rows (default 1) per round trip. See
L<Selecto::PostgreSQL::Stream> for transaction ownership and cleanup rules.

=head1 RESULT VALUES

By default (C<< canonical_values => 0 >>) C<execute_query>, and so
C<< $engine->all >>, C<< $engine->stream >> and C<projection_sum>, return
exactly the values DBD::Pg fetched: Selecto does not touch them.

Ask for I<canonical values> per call with C<< canonical_values => 1 >>
(C<< $engine->all($query, canonical_values => 1) >>, likewise C<stream> and
C<projection_sum>), or for every call with the adapter attribute
C<< canonical_values => 1 >>; a call's C<< canonical_values => 0 >> then asks
for driver values again. Canonical values are what this adapter returned by
default up to version 0.2.2 (the API, canned pages, co-domain lookups and
certification ask for them):

=over 4

=item * C<smallint>, C<integer>, C<bigint>: Perl numbers (C<int()>), so they
encode as JSON numbers. DBD::Pg 3 already returns them as numbers.

=item * C<boolean>: C<1> or C<0>, as DBD::Pg returns them.

=item * C<numeric>: the driver text without trailing fractional zeros or a
trailing point, and C<-0> as C<0> (C<10.500> is C<10.5>, C<7152.00> is
C<7152>; C<NaN> and the infinities are unchanged).

=item * C<real>, C<double precision>: DBD::Pg returns Perl numbers; the
canonical value is their Perl string, with the same trimming (C<1.5>,
C<10000000000> for C<1e+10>, C<0.3> for C<0.30000000000000004>, C<Inf>), so
it encodes as a JSON string.

=item * C<timestamp>, C<timestamptz>: the ISO form in the session
C<TimeZone>, with C<T> between date and time, the fraction without trailing
zeros, and the session's UTC offset unless it is zero (C<2024-01-01T10:00:00>,
C<2024-06-01T12:34:56.789+05:30>, C<2024-01-01T04:00:00-06>; historic offsets
keep their seconds, C<1849-12-31T18:09:24-05:50:36>). A BC value ends in
C<TBC> (after its offset, zero included), and the infinities are
C<infinity> and C<-infinity>.

=item * C<date>: C<YYYY-MM-DD>, C<0044-03-15 BC>, C<infinity>.

=item * Everything else (text, C<json>/C<jsonb> text, UUIDs, arrays): the
driver value.

=back

By default (C<< canonical_sql => 0 >>) canonical values are decoded in Perl
from the driver's values and result types, exactly as up to 0.2.2. Dates and
timestamps are therefore the session C<DateStyle>'s text: under the default
C<ISO> they are the forms above, and under a non-ISO C<DateStyle> (C<SQL>,
C<Postgres>, C<German>) that style shows through, as it always has.

=head2 Canonical values in SQL (opt-in)

With C<< canonical_sql => 1 >> PostgreSQL formats some canonical values
itself, and their dates and timestamps are always the ISO form, whatever the
session C<DateStyle> (under C<ISO> the values are the same as the Perl
decode's). It is off by default because the Perl decode measured faster at
every result size (100,000 rows: about 154 ms in Perl against 213 ms in SQL),
and the longer statement costs every small query its parse and plan time. With
it on, each top-level selection of a stored field whose declared domain type
is C<decimal>, C<date>, C<naive_datetime> or C<utc_datetime> is wrapped, in
the outermost select list only, in SQL that gives the canonical text. The
declared type chooses the columns and the formatters that may apply; the
column's PostgreSQL type picks one (C<CASE> on C<pg_typeof> of a constant, so
the value is not evaluated for it): C<CAST(trim_scale(x) AS TEXT)> for
C<numeric> (PostgreSQL 13 and newer; on 12 decimal fields stay in Perl), and
C<TO_CHAR> for C<date>, C<timestamp> and C<timestamptz> (with C<TO_CHAR(x,
'OF')> for the offset, and the offset's seconds, which C<OF> omits, for values
before 1972). So a timestamptz declared C<naive_datetime>, a C<utc_datetime>
localized by a query timezone or stored C<naive_utc> (or without the hint),
and a C<date> column declared as a datetime come out as before. A column of
any other type is its PostgreSQL text: exact for text columns (a date or
decimal kept in a C<VARCHAR>); a C<timestamp> declared C<date> is its server
text (C<2024-01-01 10:00:00>); a C<real> or C<double precision> column
declared C<decimal> is the server's text (C<1e+20>, C<Infinity>) rather than
its Perl string (C<1e+20>, C<Inf>), and an C<integer> column declared
C<decimal> is a string (C<"7">) rather than a number. A date or datetime field
must be a column PostgreSQL can cast to C<date>, C<timestamp> and
C<timestamptz> (a date, timestamp or text type).

The formatted statement is longer: PostgreSQL parses and plans each datetime
column's formatter in roughly 30 to 50 microseconds, a date's or decimal's in
about 10 to 20, every time the statement is prepared. That is paid on every
call without the statement cache (see L</statement_cache>), and only once per
connection and SQL text with it. Per row, C<TO_CHAR> costs PostgreSQL about
0.2 (date) to 0.6 (timestamptz) microseconds.

With C<< canonical_sql => 1 >>, Perl decodes every other column from its
PostgreSQL result type: integers, booleans and floats (whose canonical form is
Perl's own number formatting, which SQL cannot reproduce), aggregates and
other expressions, computed fields, and every column of an ordered rollup, a
set operation or a statement built outside C<compile>. ORDER BY, GROUP BY,
window functions and pagination use the underlying values, never output names
or positions. Streams, bounded streams and L<Selecto::BoundedQuery> format the
same columns. With the default C<< canonical_sql => 0 >> every canonical value
is decoded in Perl, from the result types, and compile records nothing for
formatting.

=head2 Moving from 0.2.2

With DBD::Pg 3, a host that does not ask for canonical values sees these
differences: C<numeric> keeps its scale (C<10.500>, not C<10.5>);
C<real> and C<double precision> are Perl numbers, which encode as JSON
numbers, instead of strings; C<timestamp> and C<timestamptz> are the server
text (C<2024-01-01 10:00:00+00>, or another offset under the session
C<TimeZone>), not C<2024-01-01T10:00:00>. Integers, booleans, text, dates
and JSON text are the same either way.

Versions up to 0.2.2 returned canonical values by default. To keep that
behaviour for a whole host, construct the adapter with
C<< canonical_values => 1 >>; to keep it for particular reads, pass
C<< canonical_values => 1 >> to C<all>, C<stream> or C<projection_sum>.
Code that already uses C<export_scalars> is unaffected. A subclass that
overrides C<execute_query> is not sent C<canonical_values> unless its
C<supports('canonical_values')> says so.

=head1 EXPORT SCALARS

C<< $engine->all($query, export_scalars => 1) >> returns canonical export
scalars for API exports: a NUMERIC is the text PostgreSQL writes for it,
which is plain notation at the column's scale (C<533.10>, C<7152.00>,
C<-0.0001>, C<42> for C<NUMERIC(10,0)>); a boolean is C<JSON::PP::true> or
C<JSON::PP::false>; C<json> and C<jsonb> are decoded JSON values. Integers,
text, C<DATE> (C<YYYY-MM-DD>), C<TIMESTAMP> (C<YYYY-MM-DDTHH:MM:SS>) and
floats are canonical values (see L</RESULT VALUES>), whatever the adapter's
C<canonical_values>. Export scalars are decoded in Perl. Canonical values
without the option differ: decimals lose trailing zeros (C<533.1>), booleans
are C<1> or C<0> and JSON columns are text.

=head1 ATTRIBUTES

=head2 rollup_sort_fix

Selecto sorts rollup results so the grand total precedes the values of a
one-level rollup while a real C<NULL> bucket stays last, using
C<NULLS FIRST> ordering for multi-level hierarchies. PostgreSQL 17 and older
need that ordering and pagination wrapped around a C<rollupfix> subquery.
With C<auto> the adapter reads C<server_version_num> once and disables the
wrapper on PostgreSQL 18 and newer; C<1> or C<0> force it on or off.

=head2 canonical_values

C<0> (the default): results hold the driver's values. C<1>: results hold
canonical values unless a call passes C<< canonical_values => 0 >>. See
L</RESULT VALUES>.

=head2 canonical_sql

C<0> (the default): every canonical value is decoded in Perl from the result
types, and dates and timestamps follow the session C<DateStyle>. C<1>
(opt-in): canonical decimal, date and timestamp fields are formatted by
PostgreSQL, always in the ISO form (see L</Canonical values in SQL (opt-in)>).

=head2 statement_cache

Off (C<0>) by default, and then every query and write prepares a new DBI
statement handle exactly as before: DBD::Pg sends it unnamed, so the server
parses and plans each call.

With C<< statement_cache => 1 >>, query execution (C<execute_query>, so
C<all> and friends) and executed writes reuse one statement handle per
distinct SQL text and database handle (L<Selecto::PostgreSQL::StatementCache>).
DBD::Pg prepares a reused handle on the server as a named statement on its
second execution, and later executions send only Bind/Execute. Streams,
insert admission and bounded-write probes still prepare afresh. Results,
types and errors are unchanged, including C<details.sqlstate>.

The cache belongs to the database handle: it is kept in the handle's
C<CachedKids> (under keys C<prepare_cached> never uses) and freed with it.
It is keyed by the SQL text alone; parameter values are always bound. At
most C<statement_cache_size> (default 256) handles are kept per connection,
least recently used first out, and an evicted handle is deallocated. A
statement the server lost (26000) or whose result type changed (0A000) is
prepared again once outside a transaction; inside one the error stands, as
it has aborted the transaction. After running C<DISCARD ALL> or
C<DEALLOCATE ALL> yourself, call
C<< Selecto::PostgreSQL::StatementCache->forget($dbh) >>.

Leave it off behind a transaction-mode pooler: PgBouncer before 1.21 (or
without C<max_prepared_statements>) cannot route named statements to the
server connection that prepared them.

=head1 ERRORS

Constraint failures are reported with portable codes and without the
driver's message: C<database_not_null_violation> (with the field when
known), C<database_unique_violation> (with the key fields),
C<database_foreign_key_violation> and C<database_check_violation>. Other
failures become C<query_error>.

=head1 TRANSACTION STATE

Selecto opens a transaction or savepoint (a bounded stream, a savepoint
query budget, a direct bounded read, a managed write) only on a connection
whose state it can account for: idle (it then owns the transaction), or
inside the host's healthy transaction (it then owns a uniquely named
savepoint). A connection with the host's pending asynchronous result
(C<pg_async>, before C<pg_result>), busy with another statement, inside an
already aborted transaction, or in an unknown state is refused with
C<transaction_state_unsafe> (details C<state>: C<active>, C<inerror> or
C<unknown>) before anything is sent. A read inside the host's transaction
runs under its own savepoint (see L</SESSION STATE>): a read that fails is
rolled back to it, so the host's transaction stays healthy and keeps its
earlier work, and the read's error is raised. Otherwise a rollback could discard the
host's pending result and its transaction, and the host's next statement
would autocommit. Checking costs one C<pg_ping> round trip where none was
made before (a stream or a savepoint budget on an C<< AutoCommit => 0 >>
handle). A bounded stream also refuses, after it opened, to roll back
anything it cannot prove is its own; see L<Selecto::PostgreSQL::Stream>.

=head1 SESSION STATE

PostgreSQL resolves names through the session: C<search_path>, then the
session's temporary schema, which is searched first for relations and types
whatever C<search_path> says. Literals parse through C<TimeZone>,
C<DateStyle>, C<IntervalStyle> and C<extra_float_digits>. A row trigger on
a written table, or a function a domain view calls, can change all of these
(C<set_config(..., true|false)>, C<CREATE TEMP VIEW>, C<CREATE TYPE pg_temp...>),
and the change would steer Selecto's own later SQL: a re-read could count
another relation's rows, and the next read in the host's transaction could
read another tenant's rows through a TEMP view.

=over 4

=item *

Every Selecto write (bound or not, single, batch or graph, in every
transaction mode) reads a snapshot of that state before its DML: the
settings above, and the (oid, xmin, name) of every relation, rewrite rule
and type of the temporary schema. The first statement after each DML reads
it again. Any change rolls the write back (its own transaction, or its
savepoint in a host's transaction) and refuses it with
C<query_rule_violation>, reason C<session_state_changed>. Both reads name
only C<pg_catalog> objects. Behaviour change: a row trigger that creates or
alters any temporary relation or type (including
C<CREATE TEMP TABLE IF NOT EXISTS>, on every call, since the table it
creates is dropped with the refused write) or changes any of those settings
makes every write to its table refuse.

=item *

A deferrable constraint trigger fires at COMMIT, after that check, and one
can even be created during the write (by its own row trigger, or by another
session while the write waits for a lock). So every write (own or host
transaction, guarded or not) is refused while any enabled deferrable
trigger that can run user code exists in the database (every user-defined
one, and internal unique or exclusion rechecks with a non-pg_catalog
operator class or operator), checked before
the DML and in the first statement after it (C<query_rule_not_evaluable>,
reason C<deferred_triggers>). Selecto never runs C<SET CONSTRAINTS>.
Internal foreign-key triggers are not counted: deferred foreign keys keep
working. A database with user-defined deferrable triggers cannot take
Selecto writes.

=item *

Every relation a generated read or write names is schema-qualified, with
the schema resolved when the statement is compiled from the engine's tenant
prefix or else the session's C<search_path> reset value
(C<pg_settings.reset_val>, parsed by PostgreSQL itself), never from the
current C<search_path>. A relation found in neither is refused
(C<query_rule_not_evaluable>, reason C<relation_unresolved>); so is one
found only in the session's temporary schema unless the adapter is built
with C<< temporary_relations => 1 >>. A relation the host's current
C<search_path> resolves to a different relation is refused (reason
C<relation_ambiguous>), for compiled statements and a host's hand-built
statements alike. Each Selecto statement runs with C<search_path>
pinned to C<pg_catalog>, the reset path's schemas and C<pg_temp> (last),
inside its own transaction or savepoint (on an idle autocommit handle, a
read sets it for the session), and the host's value is restored
afterwards; so a C<search_path> switch that persisted before the call
redirects neither relations nor operators. C<TimeZone>, C<DateStyle>,
C<IntervalStyle>, C<extra_float_digits>, C<bytea_output> and
C<standard_conforming_strings> are pinned the same way, to their reset
values (server, database, role or connection configuration): a host that
C<SET>s one of them for its session loses that inside Selecto statements.
Hosts that C<SET search_path> to reach other schemas must pin the schema
instead. Row triggers fired by
Selecto writes run under the pinned C<search_path>. Functions, operators and
types in Selecto's own catalog and guard SQL are C<pg_catalog>-qualified.

=item *

Every read (C<all>, streams, bounded results, canned pages, co-domain
lookups, retargets, anchors) does the same around its statement. Inside a
host transaction it runs under its own savepoint, rolled back on a change;
in autocommit the settings it saw are restored. A bounded stream compares
after every C<FETCH> before it hands out the batch.

=item *

The relations a statement names are recorded while it is compiled (the
root, joined and through-association bridge relations, member, retarget
and co-domain sources, collection and C<association_exists> subqueries, a
write's target and reference-guard parents; see
L<Selecto::Statement/relations>), and its SQL text is scanned as well. A
relation a statement names that resolves into the temporary schema while
a same-named relation exists in a schema of C<search_path> is refused
(C<query_rule_not_evaluable>, reason C<temporary_shadow>), on reads and
writes; so is a temporary type named like a type of C<pg_catalog> or of the
search path. A TEMP table that is itself the domain relation (no namesake)
is the host's own and works.

=item *

Post-statement SQL of a governed write (the post-image re-read and the
trigger, rule and deferrable rechecks) addresses the relation by the oid
and schema-qualified name resolved under its lock before the DML, with
C<tableoid = ANY(...)>. A bound-scope update locks its rows and names
them by (tableoid, ctid), and both a bound-scope update and a guarded
insert return the (tableoid, ctid) of every row they wrote and re-read
exactly those rows after every trigger has run, under the update's trusted
scope or the insert's full guard. No key is needed, so keys of any type
(composite, temporal, float, citext, partitioned) work, and a trigger that
renumbers a row behind a decoy cannot pass; a row a later trigger updates
again has a new row id and is refused. A guarded insert therefore keeps
ordinary row triggers (C<updated_at>, audit); statement-level triggers,
rules and deferrable triggers for the event stay refused.

=back

What a trigger or view function does beyond this (other settings, role
changes, writes to unrelated tables, DDL outside the temporary schema) is
host-owned schema behaviour and the schema owner's responsibility, like a
row trigger's effects on other rows. Selecto keeps no session variable of
its own to prove ownership; a bounded stream identifies its own transaction
by its virtual transaction id.

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>, L<Selecto::Adapter>, L<DBD::Pg>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
