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
# Result values are the driver's unless canonical values are asked for: see
# RESULT VALUES below.
has canonical_values => 0;
has canonical_sql => 1;
# Opt-in, off by default: see STATEMENT CACHE below.
has statement_cache => 0;
has statement_cache_size => 256;

sub name    { return 'postgresql'; }
sub dialect { return __PACKAGE__; }
sub _reuses_parameter_identity { return 1; }

sub bounded_stream_supported {
    my ($self) = @_;
    return eval { $self->dbh->isa('DBI::db') && $self->dbh->{Driver}{Name} eq 'Pg' } ? 1 : 0;
}

sub stream_query {
    my ($self, $statement, %options) = @_;
    return $self->SUPER::stream_query($statement, %options) unless $options{bounded};
    Selecto::Error->throw('unsupported_feature', 'bounded streaming requires a real PostgreSQL DBI handle')
        unless $self->supports('stream') && $self->bounded_stream_supported;
    Selecto::Error->throw('invalid_stream', 'stream_query requires a Selecto statement')
        unless blessed($statement) && $statement->isa('Selecto::Statement');
    my $size = $options{fetch_size} // 1;
    Selecto::Error->throw('invalid_stream', 'stream fetch size must be a positive integer')
        unless !ref($size) && "$size" =~ /\A[1-9]\d*\z/;
    require Selecto::PostgreSQL::Stream;
    return Selecto::PostgreSQL::Stream->new(adapter => $self, statement => $statement,
        fetch_size => $size, canonical_values => $self->_canonical_requested(%options));
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
    return Selecto::Statement->new(sql => 'WITH selecto_bounded AS MATERIALIZED (SELECT * FROM ('
        . $statement->sql . ') AS selecto_source LIMIT ' . int($rows) . ') SELECT '
        . join(', ', @values) . ' FROM selecto_bounded LIMIT ' . int($rows),
        params => $statement->params, columns => [@{$statement->columns}, 'selecto_transfer_overflow'],
        adapter_name => $self->name);
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

sub insert_admission_storage {
    my ($self, $command, $types) = @_;
    my $dbh = $self->dbh;
    my $fail = sub { Selecto::Error->throw('query_rule_not_evaluable',
        'PostgreSQL cannot establish the guarded insert storage contract'); };
    $fail->() unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' };
    my $table = $self->quote_identifier(Selecto::Identifier::checked($command->relation));
    # Keep the inspected table and trigger/type definitions stable until DML.
    $dbh->do("LOCK TABLE ONLY $table IN ROW EXCLUSIVE MODE");
    my $relation = $dbh->selectrow_hashref(q{
        SELECT c.oid, c.relkind, c.relispartition::integer AS relispartition,
          (EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal AND t.tgenabled <> 'D'))::integer AS triggers,
          (EXISTS(SELECT 1 FROM pg_catalog.pg_rewrite r WHERE r.ev_class=c.oid))::integer AS rules,
          (EXISTS(SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhrelid=c.oid OR i.inhparent=c.oid))::integer AS inheritance
        FROM pg_catalog.pg_class c WHERE c.oid = ?::regclass
    }, undef, $table);
    $fail->() unless $relation && $relation->{relkind} eq 'r'
        && !$relation->{relispartition} && !$relation->{triggers} && !$relation->{rules} && !$relation->{inheritance};
    my $rows = $dbh->selectall_arrayref(q{
        SELECT a.attname, t.typname, n.nspname AS type_schema,
          pg_catalog.format_type(a.atttypid,a.atttypmod) AS declaration,
          a.attgenerated, col.collname, cn.nspname AS collation_schema
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_type t ON t.oid=a.atttypid
        JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace
        LEFT JOIN pg_catalog.pg_collation col ON col.oid=a.attcollation
        LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=col.collnamespace
        WHERE a.attrelid=? AND a.attnum>0 AND NOT a.attisdropped
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
    if ($options{export_scalars}) {
        local $self->{_selecto_export_scalars} = 1;
        return $self->SUPER::execute_query($statement);
    }
    unless ($self->_canonical_requested(%options)) {
        local $self->{_selecto_raw_values} = 1;
        return $self->SUPER::execute_query($statement);
    }
    my $plan = $self->_canonical_plan($statement)
        or return $self->SUPER::execute_query($statement);
    my $rows;
    my $ok = eval {
        $rows = $self->_fetch_canonical($statement, $plan);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return { columns => $statement->columns, rows => $rows };
}

# ---- Canonical values in SQL ------------------------------------------------
#
# Canonical formatting is a function of the column's PostgreSQL type, which
# only the server knows for certain (an aggregate, a value expression or a
# domain field declared with another type). So the adapter learns the result
# types of each SQL text on its database handle: the first canonical execution
# of a statement decodes in Perl and records the types; later executions wrap
# each top-level NUMERIC, TIMESTAMP and TIMESTAMPTZ selection in an SQL
# expression that yields the canonical text, and Perl leaves those (now
# text) columns alone. Every other column is decoded in Perl as before.
# Floats stay in Perl: DBD::Pg returns them as Perl numbers, so their
# canonical text is Perl's own number formatting (0.3 for
# 0.30000000000000004, Inf, 10000000000 for 1e+10), which SQL cannot
# reproduce exactly. Integers and booleans already arrive as Perl numbers.
#
# Each formatter starts from the type's own output text (CAST AS TEXT is the
# type's output function, the text DBD::Pg receives), so DateStyle, TimeZone,
# extra_float_digits, BC years, infinities and NaN come out as the Perl decode
# makes them:
#   numeric      trim_scale of the text read back as NUMERIC (PostgreSQL 13+;
#                Perl decode before 13)
#   timestamp    spaces become T; its text never carries a zone suffix
#   timestamptz  spaces become T, then the Perl suffix pattern
#
# Only a statement whose previous execution returned at least
# $CANONICAL_SQL_MIN_ROWS rows runs formatted: below that, parsing and planning
# the longer SQL costs more than the Perl decoding it saves.
#
# The formatter only replaces the outermost SELECT list. ORDER BY and GROUP
# BY are compiled expressions, never output names or positions (a rollup
# ordered by position is not formatted), so they still sort and group the
# underlying values; set operations and other wrapped statements carry no
# projection and decode in Perl.
#
# A learned type is checked on every execution: each formatted column reads
# CASE WHEN pg_typeof(<the expression>) is the learned type THEN <canonical
# text> ELSE '!' END. The expression inside pg_typeof sits in CASE WHEN FALSE,
# which the planner folds away, so it is not evaluated twice. A '!' in the
# first row (no canonical text is '!'; a mismatch gives '!' in every row,
# NULLs included) means the type changed; that column is then never formatted
# for the SQL text, and the statement runs again unformatted and decodes in
# Perl. Every formatter compiles whatever the column's type is now, so a
# changed type is never a parse error. (A domain is checked as its base type:
# CASE resolves domains to their base types.)

Hash::Util::FieldHash::fieldhash(my %PROJECTION);

my %CANONICAL_TYPE_OID = (numeric => 1700, timestamp => 1114, timestamptz => 1184);
my %CANONICAL_SQL = (
    # Through TEXT, so the SQL still compiles if the column's type changed
    # (the guard then answers '!'); numeric text input keeps the scale.
    numeric => sub { "CAST(pg_catalog.trim_scale(CAST(CAST($_[0] AS TEXT) AS NUMERIC)) AS TEXT)" },
    timestamp => sub { "pg_catalog.translate(CAST($_[0] AS TEXT), ' ', 'T')" },
    timestamptz => sub {
        "pg_catalog.regexp_replace(pg_catalog.translate(CAST($_[0] AS TEXT), ' ', 'T'), "
            . q{'([.]0+)?([+]00(:00)?|Z)$', '')};
    },
);
use constant CANONICAL_TYPE_ENTRIES => 1024;
# Formatting in SQL makes the server parse and plan a longer statement (about
# 80 microseconds without the statement cache) and saves about half a
# microsecond per row of Perl decoding, so it pays off from a few hundred
# rows. It is used when the SQL text's previous execution returned this many.
our $CANONICAL_SQL_MIN_ROWS = 256;
use constant CANONICAL_MISMATCH => '!';

sub _note_projection {
    my ($self, $statement, %projection) = @_;
    $PROJECTION{$statement} = {sql => $statement->sql, %projection,
        layout => join(',', $projection{start}, map { @$_ } @{$projection{items}})};
    return;
}

sub _canonical_plan {
    my ($self, $statement) = @_;
    return undef unless $self->canonical_sql;
    my $dbh = $self->{dbh};
    my $pg = $self->{_selecto_canonical_pg} //= [refaddr($dbh) // 0,
        eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' } ? 1 : 0];
    $pg = $self->{_selecto_canonical_pg} = [refaddr($dbh) // 0,
        eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'Pg' } ? 1 : 0]
        unless $pg->[0] == (refaddr($dbh) // 0);
    return $pg->[1] ? $self->_projection($statement) : undef;
}

# The projection compile recorded for this statement object, while the
# statement still holds the SQL text it describes.
sub _projection {
    my ($self, $statement) = @_;
    my $plan = $PROJECTION{$statement} or return undef;
    return $plan->{sql} eq $statement->sql ? $plan : undef;
}

sub _fetch_canonical {
    my ($self, $statement, $plan) = @_;
    my $sql = $plan->{sql};
    my $learned = $self->{dbh}{private_selecto_canonical_types} //= {};
    my $entry = $learned->{$sql};
    my ($rows, $types);
    # The formatted text is built once per learned state and projection layout.
    my $formatted = $entry && ($entry->{rows} // 0) >= $CANONICAL_SQL_MIN_ROWS
        && ($entry->{formatted}{$plan->{layout}} //= $self->_canonical_sql_text($plan, $entry) // 0);
    if ($formatted) {
        ($rows, $types) = $self->_fetch_query($formatted->{sql}, $statement->params);
        my @changed = @$rows
            ? grep { defined($rows->[0][$_]) && $rows->[0][$_] eq CANONICAL_MISMATCH } @{$formatted->{columns}}
            : ();
        unless (@changed) {
            $entry->{rows} = scalar @$rows;
            $self->_decode_rows($rows, $types);
            return $rows;
        }
        $entry->{blocked}{$_} = 1 for @changed;
        $entry->{types} = undef;
        delete $entry->{formatted};
    }
    ($rows, $types) = $self->_fetch_query($sql, $statement->params);
    if (!$entry) {
        %$learned = () if keys(%$learned) >= CANONICAL_TYPE_ENTRIES;
        $entry = $learned->{$sql} = {types => [@$types], blocked => {}};
    } elsif (!$entry->{types}) {
        $entry->{types} = [@$types];
    }
    $entry->{rows} = scalar @$rows;
    $self->_decode_rows($rows, $types);
    return $rows;
}

sub _canonical_sql_text {
    my ($self, $plan, $entry) = @_;
    my ($items, $types, $blocked) = ($plan->{items}, $entry->{types}, $entry->{blocked});
    return undef unless $types && @$types == @$items;
    my $version = eval { $self->{dbh}{pg_server_version} } // 0;
    my $sql = $plan->{sql};
    my $position = $plan->{start};
    my $text = substr($sql, 0, $position);
    my @columns;
    for my $index (0 .. $#$items) {
        my ($expression_length, $item_length) = @{$items->[$index]};
        $text .= ', ' if $index;
        my $type = $types->[$index] // '';
        my $format = $CANONICAL_SQL{$type};
        $format = undef if $blocked->{$index} || ($type eq 'numeric' && $version < 130000);
        if ($format) {
            my $expression = '(' . substr($sql, $position, $expression_length) . ')';
            $text .= 'CASE WHEN CAST(pg_catalog.pg_typeof(CASE WHEN FALSE THEN ' . $expression
                . ' END) AS OID) = ' . $CANONICAL_TYPE_OID{$type} . ' THEN ' . $format->($expression)
                . q{ ELSE '} . CANONICAL_MISMATCH . q{' END}
                . substr($sql, $position + $expression_length, $item_length - $expression_length);
            push @columns, $index;
        } else {
            $text .= substr($sql, $position, $item_length);
        }
        $position += $item_length + 2;
    }
    return undef unless @columns;
    return {sql => $text . substr($sql, $position - 2), columns => \@columns};
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
        unless $mode eq 'share';
    return ' FOR SHARE OF ' . $self->quote_identifier($self->_root_alias);
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
    return Selecto::Statement->new(
        sql => $sql,
        params => $statement->params,
        columns => ['selecto_projection_sum'],
        adapter_name => $self->name,
    );
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
    return { %{$_[0]->SUPER::write_capabilities}, returning => 1, write_graph => 1 };
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
            for my $row (@$rows) {
                next unless defined(my $value = $row->[$i]);
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
# one). Asked only when AutoCommit is on.
sub _server_transaction_open {
    my ($self) = @_;
    my $status = eval { $self->{dbh}->pg_ping };
    return undef unless defined($status) && $status > 0;
    return $status >= 3 ? 1 : 0;
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
      canonical_sql    => 1,           # default 1: format canonical values in SQL
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

=item * C<timestamp>, C<timestamptz>: the driver text with spaces as C<T>,
and a zero UTC offset (C<+00>, C<+00:00> or C<Z>, with any all-zero
fraction before it) removed (C<2024-01-01 10:00:00+00> is
C<2024-01-01T10:00:00>; C<2024-06-01 12:34:56.789+05:30> is
C<2024-06-01T12:34:56.789+05:30>). Other offsets, the session C<TimeZone>
and C<DateStyle>, fractions and C<BC> are kept as the server writes them.

=item * Everything else (text, C<date>, C<json>/C<jsonb> text, UUIDs,
arrays): the driver value.

=back

With C<< canonical_sql => 1 >> (the default) PostgreSQL produces the
numeric and timestamp forms itself for large results; Perl converts
integers, booleans and floats (whose canonical form is Perl's own number
formatting, which SQL cannot reproduce). The adapter learns each SQL text's
result column types from its first canonical execution on a database handle
(decoded in Perl), and later executions that follow one returning at least
256 rows (smaller results decode faster in Perl than the longer SQL parses)
wrap those top-level selections in SQL that turns the
type's own output text into the canonical text: C<trim_scale> for
C<numeric> (PostgreSQL 13 and newer; on 12 numeric stays in Perl), and
C<translate> and the suffix pattern above for timestamps. Each
formatted column checks with C<pg_typeof> that it still has the learned
type; a changed type (or a domain type) is decoded in Perl from then on, and
the execution that found it runs again unformatted. ORDER BY, GROUP BY,
aggregates, window functions and pagination still work on the
underlying values: only the outermost select list changes, and ordered
rollups, set operations and statements built outside C<compile> are always
decoded in Perl. The values are identical either way. At most 1024 SQL texts
are remembered per handle. C<< canonical_sql => 0 >> decodes every
canonical value in Perl.

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

C<1> (the default): canonical values are formatted by PostgreSQL where the
adapter can (see L</RESULT VALUES>). C<0>: they are all decoded in Perl.

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

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>, L<Selecto::Adapter>, L<DBD::Pg>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
