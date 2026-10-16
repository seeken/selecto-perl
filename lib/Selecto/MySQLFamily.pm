package Selecto::MySQLFamily;

use Mojo::Base 'Selecto::SQL';
use Selecto::Error ();
use Selecto::Identifier ();
use Selecto::QueryEnforcement ();
use Selecto::Write ();
use JSON::PP ();
use Selecto::Expression ();
use Selecto::InsertAdmission ();
use Selecto::SQL::RollupEmulation ();
use Scalar::Util qw(blessed refaddr);

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

# Minimum server versions per feature: [MySQL, MariaDB]. A feature whose
# entry is undef for this server is not available on it at all.
my %FEATURE_VERSIONS = (
    cte => [[8, 0, 1], [10, 2, 2]],
    recursive_cte => [[8, 0, 1], [10, 2, 2]],
    window_functions => [[8, 0, 2], [10, 2, 0]],
    # INTERSECT and EXCEPT; UNION is older.
    set_operations => [[8, 0, 31], [10, 3, 0]],
    rollup => [[8, 0, 1], [10, 2, 2]],
    value_expressions => [[8, 0, 17], [10, 4, 0]],
    # MariaDB has no LATERAL; its lateral joins are lowered (window functions).
    lateral_join => [[8, 0, 14], [10, 2, 0]],
    # JSON_TABLE, also used for array elements and exact containment.
    json_rowset => [[8, 0, 4], [10, 6, 0]],
    array_rowset => [[8, 0, 4], [10, 6, 0]],
    array_predicates => [[8, 0, 4], [10, 6, 0]],
    json_contains => [[8, 0, 4], [10, 6, 0]],
    json_text => [[5, 7, 0], [10, 2, 3]],
    # MySQL: JSON_ARRAYAGG as a window aggregate and correlated derived
    # tables; MariaDB: JSON_ARRAYAGG with ORDER BY and LIMIT.
    ordered_related_collections => [[8, 0, 14], [10, 5, 0]],
    bounded_related_collections => [[8, 0, 14], [10, 5, 0]],
    # InnoDB FULLTEXT indexes in boolean mode.
    text_search => [[5, 7, 0], [10, 2, 0]],
);

sub supports {
    my ($self, $feature) = @_;
    return 1 if "$feature" eq 'transactions' || "$feature" eq 'stream' || "$feature" eq 'export_scalars';
    my $versions = $FEATURE_VERSIONS{"$feature"} or return 0;
    my $minimum = $versions->[$self->name eq 'mariadb' ? 1 : 0] or return 0;
    return $self->_server_version_at_least(@$minimum);
}

# The connected server's version, read once per handle. Feature checks fail
# closed when it cannot be read or does not belong to this adapter's server.
sub _server_version {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    return $self->{_selecto_server_version}
        if $self->{_selecto_server_version} && ($self->{_selecto_server_dbh} // 0) == ($dbh // 0);
    my ($text) = eval {
        local $dbh->{PrintError} = 0;
        $dbh->selectrow_array('SELECT VERSION()');
    };
    my @version = defined($text) && "$text" =~ /\A(\d+)\.(\d+)\.(\d+)/ ? ($1, $2, $3) : ();
    my $mariadb = defined($text) && "$text" =~ /mariadb/i ? 1 : 0;
    @version = () if @version && $mariadb != ($self->name eq 'mariadb' ? 1 : 0);
    $self->{_selecto_server_dbh} = $dbh;
    return $self->{_selecto_server_version} = \@version;
}

sub _server_version_at_least {
    my ($self, @minimum) = @_;
    my $version = $self->_server_version;
    return 0 unless @$version;
    for my $index (0 .. 2) {
        return 1 if $version->[$index] > $minimum[$index];
        return 0 if $version->[$index] < $minimum[$index];
    }
    return 1;
}

# Neither server orders rollup NULLs with NULLS FIRST/LAST, and MariaDB has
# no GROUPING(): rollups compile as UNION ALL grouping branches.
sub _emulates_rollup { return 1; }

# Both servers sort NULL first ascending; results order NULLs as PostgreSQL.
sub _null_ordered_terms { return 1; }

# An untyped NULL (even inside the CASE of the empty grouping set) would make
# UNION ALL type the rolled-up column as text.
sub _rollup_typed_nulls { return 1; }

sub _compile_rollup {
    my ($self, $domain, $query, %options) = @_;
    return Selecto::SQL::RollupEmulation::compile($self, $domain, $query, sub {
        my ($position, $column, $direction, $nulls) = @_;
        # Qualified by the derived table, never a caller-named FROM column.
        my $quoted = $self->quote_identifier('__selecto_rollup') . '.' . $self->quote_identifier($column);
        return "$position $direction" unless defined $nulls;
        # Both servers sort NULL first ascending and last descending.
        return ($quoted . ' IS NULL ' . ($nulls eq 'first' ? 'DESC' : 'ASC')) . ", $position $direction";
    }, %options);
}

sub _compile_selection_expression {
    my ($self, $domain, $expression, $params, $compiled_selections, $options) = @_;
    my $formats = $self->{_selecto_formats_active};
    my $position = $formats ? $self->{_selecto_selection_index}++ : undef;
    local $self->{_selecto_format_slot} = $formats && blessed($expression)
        && $expression->kind eq 'datetime_format' ? $position : undef;
    return Selecto::SQL::RollupEmulation::selection_expression($self, $options, sub {
        return $self->_compile_expression($domain, $expression, $params, $compiled_selections);
    });
}

# Date and time formats are applied in Perl with DateTime::TimeZone: the
# servers' CONVERT_TZ silently leaves pre-1970 (and, on MariaDB, post-2038)
# values unconverted and stops DST after 2037. A format is therefore allowed
# only as a selection of the outermost statement, which selects the stored
# value with a marker and has its column formatted after execution; anywhere
# else (filters, grouping, ordering, nested sources, set operands, rollups)
# it is refused with unsupported_feature.
sub compile {
    my ($self, $domain, $query) = @_;
    my $top = !$self->{_selecto_in_compile};
    local $self->{_selecto_in_compile} = 1;
    my $scope = $top && blessed($query) && !@{$query->set_operations} && $query->grouping_mode ne 'rollup'
        ? {pending => 1, formatters => {}} : undef;
    local $self->{_selecto_format_scope} = $scope;
    local $self->{_selecto_formats_active};
    my $statement = $self->SUPER::compile($domain, $query);
    $statement->{_selecto_formatters} = $scope->{formatters} if $scope && %{$scope->{formatters}};
    return $statement;
}

sub _compile_single {
    my ($self, $domain, $query, %options) = @_;
    my $scope = $self->{_selecto_format_scope};
    # A retargeted query compiles its selections in the inner call.
    return $self->SUPER::_compile_single($domain, $query, %options)
        if $scope && $scope->{pending} && defined $query->retarget_spec;
    if ($scope && $scope->{pending} && !$options{rollup_projection}) {
        local $scope->{pending} = 0;
        local $self->{_selecto_formats_active} = $scope;
        local $self->{_selecto_selection_index} = 0;
        return $self->SUPER::_compile_single($domain, $query, %options);
    }
    local $self->{_selecto_formats_active};
    return $self->SUPER::_compile_single($domain, $query, %options);
}

my $FORMAT_MARKER = 'selecto-format:';

sub _compile_datetime_format {
    my ($self, $domain, $expression, $params) = @_;
    my ($field, $format, $timezone) = @{$expression->arguments};
    require Selecto::DateFormat;
    Selecto::Error->throw('invalid_query', 'datetime format is not available')
        unless Selecto::DateFormat::valid($format);
    Selecto::Error->throw('invalid_query', 'datetime format field must be a governed temporal field')
        unless blessed($field) && $field->isa('Selecto::Expression')
            && ($field->kind eq 'field' || $field->kind eq 'epoch_datetime');
    my $source = $field->kind eq 'epoch_datetime' ? $field->arguments->[0] : $field;
    Selecto::Error->throw('invalid_query', 'datetime format field must be a governed field')
        unless blessed($source) && $source->isa('Selecto::Expression') && $source->kind eq 'field';
    my $type = $domain->resolve($source->arguments->[0])->{type} // '';
    Selecto::Error->throw('invalid_query', 'datetime format requires a date or time field')
        unless $type =~ /\A(?:date|naive_datetime|datetime|utc_datetime|epoch_datetime)\z/;
    my $position = $self->{_selecto_format_slot};
    Selecto::Error->throw('unsupported_feature',
        'MySQL-family date formats are available only as selected values of the outermost query')
        unless defined($position) && $self->{_selecto_formats_active};
    local $self->{_selecto_format_slot};
    $timezone //= $self->{_timezone};
    require Selecto::MySQLFamily::DateFormat;
    Selecto::Error->throw('invalid_query', 'timezone must be a valid IANA timezone name')
        if defined($timezone) && !Selecto::MySQLFamily::DateFormat::valid_zone($timezone);
    $self->{_selecto_formats_active}{formatters}{$position} = {
        format => "$format", type => $type, (defined($timezone) ? (timezone => "$timezone") : ()),
    };
    local $self->{_suppress_field_timezone} = 1;
    local $self->{_timezone};
    my $sql = $self->_compile_expression($domain, $source, $params);
    my $raw = $type eq 'date' ? "DATE_FORMAT($sql, '%Y-%m-%d')"
        : $type eq 'epoch_datetime' ? "CAST($sql AS CHAR)"
        : "DATE_FORMAT($sql, '%Y-%m-%d %H:%i:%s.%f')";
    return "CONCAT('$FORMAT_MARKER', $raw)";
}

sub _apply_formatters {
    my ($self, $statement, $result) = @_;
    my $formatters = $statement->{_selecto_formatters} or return $result;
    require Selecto::MySQLFamily::DateFormat;
    for my $row (@{$result->{rows}}) {
        for my $index (keys %$formatters) {
            next unless defined $row->[$index];
            my $value = "$row->[$index]";
            Selecto::Error->throw('query_error', 'date format value is not marked')
                unless $value =~ s/\A\Q$FORMAT_MARKER\E//;
            $row->[$index] = Selecto::MySQLFamily::DateFormat::format_value($formatters->{$index}, $value);
        }
    }
    return $result;
}

sub stream_query {
    my ($self, $statement, %options) = @_;
    Selecto::Error->throw('unsupported_feature', 'MySQL-family date formats cannot be streamed')
        if blessed($statement) && $statement->{_selecto_formatters};
    $self->_require_session;
    return $self->SUPER::stream_query($statement, %options);
}

# DBD::MariaDB binds client-side, quoting every value, and both servers need
# the LAG/LEAD offset, NTILE count and NTH_VALUE position as integers: they are
# rendered as validated integer literals.
my %WINDOW_INTEGER_ARGUMENT = (lag => 1, lead => 1, ntile => 0, nth_value => 1);

sub _compile_window {
    my ($self, $domain, $expression, $params) = @_;
    my ($function, $arguments) = @{$expression->arguments};
    my %inline;
    # MariaDB's LAG/LEAD take no default argument.
    Selecto::Error->throw('unsupported_feature', 'MariaDB LAG and LEAD do not accept a default argument')
        if $self->name eq 'mariadb' && defined($function) && !ref($function) && ($function eq 'lag' || $function eq 'lead')
            && ref($arguments) eq 'ARRAY' && @$arguments > 2;
    if (defined($function) && !ref($function) && exists($WINDOW_INTEGER_ARGUMENT{$function})
        && ref($arguments) eq 'ARRAY') {
        my $argument = $arguments->[$WINDOW_INTEGER_ARGUMENT{$function}];
        if (defined $argument) {
            my $value = blessed($argument) && $argument->isa('Selecto::Expression') && $argument->kind eq 'literal'
                ? $argument->arguments->[0] : undef;
            Selecto::Error->throw('invalid_query', "window function $function requires an integer literal argument")
                unless defined($value) && !ref($value) && "$value" =~ /\A\d{1,18}\z/;
            $inline{refaddr($argument)} = 0 + "$value";
        }
    }
    local $self->{_selecto_inline_integers} = \%inline;
    return $self->SUPER::_compile_window($domain, $expression, $params);
}

sub _compile_expression {
    my ($self, $domain, $expression, $params, $compiled_selections) = @_;
    my $inline = $self->{_selecto_inline_integers};
    return '' . $inline->{refaddr($expression)}
        if $inline && blessed($expression) && exists $inline->{refaddr($expression)};
    my $sql = Selecto::SQL::RollupEmulation::branch_expression(
        $self, $domain, $expression, $params, $compiled_selections,
        sub { return $self->SUPER::_compile_expression(@_); },
    );
    return $sql if defined $sql;
    $sql = $self->_identity_predicate_sql($domain, $expression, $params);
    return $sql if defined $sql;
    Selecto::Error->throw('unsupported_feature', 'MySQL-family grouping markers require a rollup projection')
        if blessed($expression) && $expression->isa('Selecto::Expression')
            && ($expression->kind eq 'grouping' || $expression->kind eq 'dimension_display');
    return $self->SUPER::_compile_expression($domain, $expression, $params, $compiled_selections);
}

# Tenant and site identity compares exactly, as in PostgreSQL. The servers'
# default collations (utf8mb4_0900_ai_ci, MariaDB's utf8mb4_uca1400_ai_ci,
# *_general_ci, *_unicode_ci) fold case and accents, and PAD SPACE ones
# ignore trailing spaces, so tenant 't1' would otherwise match 'T1', 't1 '
# and 'tı'. A text tenant comparison keeps the collated equality (which can
# use the column's index) and adds a byte comparison:
#   (col = ? AND CAST(col AS BINARY) = CAST(? AS BINARY))
# with the value bound twice in SQL-text order; IN lists and column pairs
# take the same form. Numeric tenant columns compile as before.
sub _exact_identity_compare { return 1; }

sub _identity_equal_sql {
    my ($self, $left, $right, $exact) = @_;
    return "$left = $right" unless $exact;
    return "($left = $right AND CAST($left AS BINARY) = CAST($right AS BINARY))";
}

sub _identity_values_sql {
    my ($self, $column, $values, $params, $exact) = @_;
    return $self->SUPER::_identity_values_sql($column, $values, $params)
        unless $exact && ref($values) eq 'ARRAY' && @$values && !grep { !defined($_) || ref($_) } @$values;
    my @collated = map { push @$params, $_; $self->placeholder(scalar @$params) } @$values;
    my @binary = map { push @$params, $_; 'CAST(' . $self->placeholder(scalar @$params) . ' AS BINARY)' } @$values;
    return "($column = $collated[0] AND CAST($column AS BINARY) = $binary[0])" if @$values == 1;
    return "($column IN (" . join(', ', @collated) . ") AND CAST($column AS BINARY) IN ("
        . join(', ', @binary) . '))';
}

# A read predicate (eq or IN) on a text tenant or site column: the root's,
# a joined relation's, a member's or a retarget hop's, wherever it came from
# (engine tenant, required predicate, carried tenant set, caller filter).
sub _identity_predicate_sql {
    my ($self, $domain, $expression, $params) = @_;
    return undef unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    return undef unless $kind eq 'eq' || $kind eq 'in';
    my ($left, $right) = @{$expression->arguments};
    return undef unless blessed($left) && $left->isa('Selecto::Expression') && $left->kind eq 'field'
        && $self->_identity_field_exact($domain, $left->arguments->[0]);
    my @values;
    if ($kind eq 'in') {
        return undef unless ref($right) eq 'ARRAY' && @$right && !grep { !defined($_) || ref($_) } @$right;
        @values = @$right;
    } elsif (blessed($right) && $right->isa('Selecto::Expression') && $right->kind eq 'literal') {
        my $value = $right->arguments->[0];
        return undef if !defined($value) || ref($value);
        @values = ($value);
    } elsif (blessed($right) && $right->isa('Selecto::Expression') && $right->kind eq 'field') {
        my $column = $self->_compile_expression($domain, $left, $params);
        return $self->_identity_equal_sql($column, $self->_compile_expression($domain, $right, $params), 1);
    } else {
        return undef;
    }
    my $column = $self->_compile_expression($domain, $left, $params);
    return $self->_identity_values_sql($column, \@values, $params, 1);
}

# Write predicates, storage re-reads and guarded-insert probes of a governed
# command compare its text tenant columns (the engine's __selecto_tenant_fields:
# tenant_field, writes.scope.tenant, pins and stored root tenant columns) the
# same way. The set is taken from the command being compiled or executed.
sub _write_identity_columns {
    my ($self, $command) = @_;
    my $metadata = blessed($command) && $command->can('metadata') ? $command->metadata : {};
    my $fields = ref($metadata->{__selecto_tenant_fields}) eq 'ARRAY' ? $metadata->{__selecto_tenant_fields} : [];
    my $types = ref($metadata->{__selecto_insert_types}) eq 'HASH' ? $metadata->{__selecto_insert_types} : {};
    return {map { ($_ => 1) } grep { defined($_) && !ref($_) && Selecto::SQL::_identity_text_type($types->{$_}) } @$fields};
}

sub _compile_write_predicate {
    my ($self, $expression, $params) = @_;
    my $columns = $self->{_selecto_identity_columns};
    if ($columns && %$columns && blessed($expression) && $expression->isa('Selecto::Expression')
        && ($expression->kind eq 'eq' || $expression->kind eq 'in')) {
        my ($left, $right) = @{$expression->arguments};
        my $field = blessed($left) && $left->isa('Selecto::Expression') && $left->kind eq 'field'
            ? $left->arguments->[0] : undef;
        if (defined($field) && !ref($field) && $columns->{$field}) {
            my @values = $expression->kind eq 'in'
                ? (ref($right) eq 'ARRAY' ? @$right : ())
                : (blessed($right) && $right->isa('Selecto::Expression') && $right->kind eq 'literal'
                    ? ($right->arguments->[0]) : ());
            return $self->_identity_values_sql($self->quote_identifier(Selecto::Identifier::checked($field)),
                \@values, $params, 1) if @values && !grep { !defined($_) || ref($_) } @values;
        }
    }
    return $self->SUPER::_compile_write_predicate($expression, $params);
}

# OFFSET requires a LIMIT; the largest unsigned BIGINT means no limit.
# Server errors by MySQL/MariaDB errno, typed like PostgreSQL's constraint
# errors. A deadlock or lock-wait timeout is retryable (the host reruns the
# whole transaction); neither is a client error. The violated key's name is
# kept on the adapter, never in the public details.
sub normalize_error {
    my ($self, $error) = @_;
    return $error if blessed($error) && $error->isa('Selecto::Error');
    my $dbh = $self->{dbh};
    my $text = eval { "$error" } // '';
    # $dbh->err outlives its statement: it counts only when this error is the
    # driver's current one (its text carries the handle's errstr).
    my $errstr = eval { blessed($dbh) && $dbh->can('errstr') ? $dbh->errstr : undef };
    my $errno = defined($errstr) && length($errstr) && index($text, $errstr) >= 0
        ? eval { $dbh->err } : undef;
    delete $self->{_selecto_unique_key};
    return $self->SUPER::normalize_error($error) unless defined($errno) && "$errno" =~ /\A\d+\z/;
    if ($errno == 1062) {
        my ($key) = $text =~ /.*for key '([^']+)'(?: at |\s*\z)/s;
        if (defined $key) {
            $key =~ s/\A.*\.//s;
            $self->{_selecto_unique_key} = lc $key;
        }
        return Selecto::Error->new(code => 'database_unique_violation',
            message => 'A value conflicts with an existing record.', details => {constraint => 'unique'});
    }
    if ($errno == 1451 || $errno == 1452) {
        return Selecto::Error->new(code => 'database_foreign_key_violation',
            message => 'A referenced record does not exist or is not available.',
            details => {constraint => 'foreign_key'});
    }
    # A value the column cannot hold (too long, out of range, not of the
    # column's type, not representable in its character set, an unsigned
    # overflow), as in selecto-c, selecto-cpp and selecto-r; no value, column
    # or SQL is echoed.
    if ($errno == 1264 || $errno == 1265 || $errno == 1292 || $errno == 1366 || $errno == 1367
        || $errno == 1406 || $errno == 1690) {
        return Selecto::Error->new(code => 'database_data_violation',
            message => 'A value does not fit the column it was written to.', details => {constraint => 'data'});
    }
    # An omitted NOT NULL column without a default is PostgreSQL's not-null violation.
    if ($errno == 1364) {
        return Selecto::Error->new(code => 'database_not_null_violation',
            message => 'A required database field was not provided.', details => {constraint => 'not_null'});
    }
    if ($errno == 1048) {
        my ($field) = $text =~ /Column '([A-Za-z_][A-Za-z0-9_]*)' cannot be null/;
        return Selecto::Error->new(code => 'database_not_null_violation',
            message => defined($field) ? "Required field $field was not provided." : 'A required database field was not provided.',
            details => {constraint => 'not_null', defined($field) ? (field => $field) : ()});
    }
    if ($errno == 3819 || $errno == 4025) {
        return Selecto::Error->new(code => 'database_check_violation',
            message => 'A database validation constraint was not satisfied.', details => {constraint => 'check'});
    }
    if ($errno == 1213) {
        return Selecto::Error->new(code => 'database_deadlock_detected',
            message => 'The database rolled the transaction back to resolve a deadlock; retry it.',
            details => {category => 'deadlock_detected', retryable => JSON::PP::true});
    }
    if ($errno == 1205) {
        return Selecto::Error->new(code => 'database_lock_timeout',
            message => 'The database timed out waiting for a lock; retry the transaction.',
            details => {category => 'lock_timeout', retryable => JSON::PP::true});
    }
    return $self->SUPER::normalize_error($error);
}

sub _rereads_written_rows { return 1; }

sub _compile_pagination {
    my ($self, $limit, $offset, @rest) = @_;
    return ' LIMIT 18446744073709551615 OFFSET ' . int($offset) if !defined($limit) && defined($offset);
    return $self->SUPER::_compile_pagination($limit, $offset, @rest);
}

# Neither server has GROUPS frames.
sub _compile_window_frame {
    my ($self, $frame) = @_;
    Selecto::Error->throw('unsupported_feature', 'MySQL-family window frames support rows and range only')
        if ref($frame) eq 'HASH' && uc($frame->{type} // 'rows') eq 'GROUPS';
    return $self->SUPER::_compile_window_frame($frame);
}

# Several JSON renderings repeat their source SQL. Anonymous ? parameters bind
# by occurrence, so a repeated source must carry none.
sub _repeatable_sql {
    my ($self, $sql) = @_;
    (my $bare = "$sql") =~ s/`(?:``|[^`])*`//g;
    $bare =~ s/'(?:''|\\.|[^'\\])*'//g;
    Selecto::Error->throw('unsupported_feature', 'MySQL-family JSON operations require a stored JSON column')
        if $bare =~ /\?/;
    return $sql;
}

# JSON values are typed in SQL from the document itself: a value of another
# JSON type is NULL, never coerced (JSON_TABLE's typed columns would turn the
# string "b" into 0 on MariaDB). $json is SQL yielding a JSON value or NULL.
sub _json_typed_value_sql {
    my ($self, $json, $type) = @_;
    $type = lc("$type");
    my $kind = "JSON_TYPE($json)";
    return "CASE WHEN $kind = 'STRING' THEN JSON_UNQUOTE($json) END"
        if $type =~ /\A(?:string|text|uuid)\z/;
    return "CASE WHEN $kind IN ('INTEGER', 'UNSIGNED INTEGER') THEN CAST(JSON_UNQUOTE($json) AS SIGNED) END"
        if $type =~ /\A(?:integer|int|bigint)\z/;
    return "CASE WHEN $kind IN ('INTEGER', 'UNSIGNED INTEGER', 'DECIMAL', 'DOUBLE') "
        . "THEN CAST(JSON_UNQUOTE($json) AS DECIMAL(65, 30)) END"
        if $type =~ /\A(?:decimal|numeric|number)\z/;
    return "CASE WHEN $kind = 'BOOLEAN' THEN JSON_UNQUOTE($json) = 'true' END" if $type eq 'boolean';
    return "CASE WHEN $kind = 'STRING' THEN CAST(JSON_UNQUOTE($json) AS DATE) END" if $type eq 'date';
    return "CASE WHEN $kind = 'STRING' THEN CAST(JSON_UNQUOTE($json) AS DATETIME(6)) END"
        if $type =~ /\A(?:datetime|naive_datetime|utc_datetime)\z/;
    return "CASE WHEN $kind <> 'NULL' THEN $json END" if $type eq 'json' || $type eq 'jsonb';
    Selecto::Error->throw('invalid_query', "JSON rowset type $type is not portable");
}

# Rowset columns are read as JSON and typed where they are referenced.
sub _query_sources {
    my ($self, $domain, $query) = @_;
    my $sources = $self->SUPER::_query_sources($domain, $query);
    for my $spec (@{$query->json_rowsets}) {
        $sources->{$spec->{name}} = {map { $_ => {mysql_json_type => $spec->{columns}{$_}} } keys %{$spec->{columns}}};
    }
    for my $spec (@{$query->array_rowsets}) {
        $sources->{$spec->{name}}{value} = {
            mysql_json_type => $self->_array_element_type($domain, $spec->{source_field}, 'array rowset source'),
        };
    }
    return $sources;
}

sub _field_sql {
    my ($self, $domain, $path, $params) = @_;
    my ($alias, $field, @rest) = split /\./, "$path";
    my $spec = !@rest && defined($field) && ref($self->{_query_sources}) eq 'HASH'
        && exists($self->{_query_sources}{$alias}) ? $self->{_query_sources}{$alias}{$field} : undef;
    return $self->_json_typed_value_sql($self->_qualified($alias, $field), $spec->{mysql_json_type})
        if ref($spec) eq 'HASH' && defined $spec->{mysql_json_type};
    return $self->SUPER::_field_sql($domain, $path, $params);
}

# JSON_TABLE takes its row path as a string literal, so only a plain member
# and index path is accepted and inlined.
sub _json_table_path {
    my ($self, $path) = @_;
    $path //= '$[*]';
    Selecto::Error->throw('invalid_query', 'JSON rowset path must be a member and index path')
        unless !ref($path) && "$path" =~ /\A\$(?:\.[A-Za-z_][A-Za-z0-9_]*|\[(?:\d{1,9}|\*)\])*\z/;
    return "'$path'";
}

sub _join_keyword {
    my ($type) = @_;
    return $type eq 'cross' ? ('CROSS JOIN', '') : $type eq 'inner' ? ('INNER JOIN', ' ON TRUE')
        : ('LEFT JOIN', ' ON TRUE');
}

sub _compile_json_rowset_join {
    my ($self, $domain, $spec, $params) = @_;
    Selecto::Error->throw('invalid_query', 'JSON rowset source must be a JSON field')
        unless ($domain->resolve($spec->{source_field})->{type} // '') =~ /\Ajsonb?\z/i;
    my $path = $self->_json_table_path($spec->{path});
    my @columns;
    for my $column (sort keys %{$spec->{columns}}) {
        Selecto::Error->throw('invalid_query', 'JSON rowset column must be a valid identifier')
            unless "$column" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        $self->_json_typed_value_sql('NULL', $spec->{columns}{$column});
        push @columns, $self->quote_identifier($column) . qq{ JSON PATH '\$."$column"'};
    }
    my $source = $self->_compile_expression($domain, Selecto::Expression->field($spec->{source_field}), $params);
    my ($keyword) = _join_keyword($spec->{type});
    my $name = $self->quote_identifier($spec->{name});
    # Like SQLite, rows come from object elements only.
    my $element = $self->quote_identifier('__selecto_element');
    push @columns, "$element JSON PATH '\$'";
    return "$keyword JSON_TABLE($source, $path COLUMNS (" . join(', ', @columns) . ")) AS $name"
        . ($spec->{type} eq 'cross' ? " ON JSON_TYPE($name.$element) = 'OBJECT'"
            : " ON JSON_TYPE($name.$element) = 'OBJECT'");
}

sub _compile_array_rowset_join {
    my ($self, $spec, $source) = @_;
    $self->_repeatable_sql($source);
    my @columns = ($self->quote_identifier('value') . q{ JSON PATH '$'});
    unshift @columns, $self->quote_identifier($spec->{ordinality}) . ' FOR ORDINALITY'
        if defined $spec->{ordinality};
    my ($keyword, $on) = _join_keyword($spec->{type});
    # JSON_TABLE yields no rows for NULL or for a document that is not an array.
    return "$keyword JSON_TABLE(CASE WHEN JSON_TYPE($source) = 'ARRAY' THEN $source END, '\$[*]' COLUMNS ("
        . join(', ', @columns) . ')) AS ' . $self->quote_identifier($spec->{name}) . $on;
}

sub _compile_json_text {
    my ($self, $source, $segments, $params) = @_;
    $self->_repeatable_sql($source);
    my $path = '$' . join('', map {
        my $segment = "$_";
        if ($segment =~ /\A\d{1,9}\z/) {
            "[$segment]";
        } else {
            $segment =~ s/(["\\])/\\$1/g;
            qq{."$segment"};
        }
    } @$segments);
    push @$params, $path;
    my $first = $self->placeholder(scalar @$params);
    push @$params, $path;
    my $second = $self->placeholder(scalar @$params);
    return "CASE JSON_TYPE(JSON_EXTRACT($source, $first)) WHEN 'NULL' THEN NULL "
        . "ELSE JSON_UNQUOTE(JSON_EXTRACT($source, $second)) END";
}

# Exact jsonb-style containment. JSON_CONTAINS also matches a scalar inside a
# nested array ({"a": [1]} contains {"a": 1}), which PostgreSQL does not.
sub _compile_json_contains {
    my ($self, $field_sql, $placeholder, $params) = @_;
    Selecto::Error->throw('invalid_query', 'JSON containment needle must be bound by the compiler')
        unless ref($params) eq 'ARRAY' && @$params;
    my $encoded = pop @$params;
    my $needle = JSON::PP->new->allow_nonref(1)->allow_bignum(1)->decode($encoded);
    $self->_repeatable_sql($field_sql);
    local $self->{_selecto_json_depth} = 0;
    return '(' . $self->_json_contains_sql($field_sql, $needle, $params, 1) . ')';
}

sub _json_element_alias {
    my ($self) = @_;
    return $self->quote_identifier('__selecto_json_' . ++$self->{_selecto_json_depth});
}

sub _json_contains_sql {
    my ($self, $json, $needle, $params, $root) = @_;
    my $kind = "JSON_TYPE($json)";
    if (ref($needle) eq 'HASH') {
        my @terms = ("$kind = 'OBJECT'");
        for my $key (sort keys %$needle) {
            (my $escaped = $key) =~ s/(["\\])/\\$1/g;
            # A literal, not a parameter: $member is repeated in nested tests.
            my $path = _text_literal(qq{\$."$escaped"});
            my $exists = 'JSON_CONTAINS_PATH(' . $json . ", 'one', $path)";
            my $member = 'JSON_EXTRACT(' . $json . ", $path)";
            push @terms, $exists, $self->_json_contains_sql($member, $needle->{$key}, $params, 0);
        }
        return join(' AND ', map { "($_)" } @terms);
    }
    if (ref($needle) eq 'ARRAY') {
        my @terms = ("$kind = 'ARRAY'");
        for my $element (@$needle) {
            push @terms, $self->_json_array_has_sql($json, sub {
                my ($item) = @_;
                return $self->_json_contains_sql($item, $element, $params, 0);
            });
        }
        return join(' AND ', map { "($_)" } @terms);
    }
    my $equal = $self->_json_scalar_equals_sql($json, $needle, $params);
    return $equal unless $root;
    # Like jsonb, a root array contains a primitive among its elements.
    my $member = $self->_json_array_has_sql($json, sub {
        return $self->_json_scalar_equals_sql($_[0], $needle, $params);
    });
    return "($equal) OR ($kind = 'ARRAY' AND $member)";
}

# A utf8mb4 string literal of any text, independent of sql_mode escaping.
sub _text_literal {
    my ($text) = @_;
    require Encode;
    my $bytes = Encode::encode('UTF-8', "$text");
    return length($bytes) ? "CONVERT(X'" . unpack('H*', $bytes) . "' USING utf8mb4)" : "''";
}

# Whether any element of the JSON array $json; $test renders the
# condition on one element's JSON value.
sub _json_array_has_sql {
    my ($self, $json, $test) = @_;
    my $alias = $self->_json_element_alias;
    my $item = $self->quote_identifier('item');
    # Counted, not EXISTS: MySQL 8.4 semijoin rewrites of EXISTS over a
    # correlated JSON_TABLE in WHERE drop matching rows.
    return "(SELECT COUNT(*) FROM JSON_TABLE(CASE WHEN JSON_TYPE($json) = 'ARRAY' THEN $json END, "
        . "'\$[*]' COLUMNS ($item JSON PATH '\$')) AS $alias WHERE " . $test->("$alias.$item") . ') > 0';
}

# Never NULL: a JSON null element read through JSON_TABLE is SQL NULL on MySQL.
sub _json_scalar_equals_sql {
    my ($self, $json, $value, $params) = @_;
    my $kind = "JSON_TYPE($json)";
    return "COALESCE($kind, 'NULL') = 'NULL'" unless defined $value;
    if (JSON::PP::is_bool($value)) {
        return "COALESCE($kind = 'BOOLEAN' AND JSON_UNQUOTE($json) = '" . ($value ? 'true' : 'false') . "', FALSE)";
    }
    Selecto::Error->throw('invalid_query', 'JSON containment values must be JSON scalars, arrays or objects')
        if ref($value) && !(blessed($value) && ($value->isa('Math::BigInt') || $value->isa('Math::BigFloat')));
    my $text = JSON::PP->new->allow_nonref(1)->allow_bignum(1)->encode($value);
    if ($text =~ /\A"/) {
        push @$params, "$value";
        return "COALESCE($kind = 'STRING' AND CAST(JSON_UNQUOTE($json) AS BINARY) = CAST("
            . $self->placeholder(scalar @$params) . ' AS BINARY), FALSE)';
    }
    return $self->_json_number_equals_sql($json, $text, $params);
}

sub _json_number_equals_sql {
    my ($self, $json, $text, $params) = @_;
    Selecto::Error->throw('invalid_query', 'JSON containment number is outside the exact decimal range')
        unless "$text" =~ /\A-?\d{1,35}(?:\.\d{1,30})?\z/;
    push @$params, "$text";
    return "COALESCE(JSON_TYPE($json) IN ('INTEGER', 'UNSIGNED INTEGER', 'DECIMAL', 'DOUBLE') AND "
        . "CAST(JSON_UNQUOTE($json) AS DECIMAL(65, 30)) = CAST(" . $self->placeholder(scalar @$params)
        . ' AS DECIMAL(65, 30)), FALSE)';
}

# Typed array predicates on a JSON array column, element by element.
sub _compile_array_predicate {
    my ($self, $kind, $source, $type, $values, $params) = @_;
    Selecto::Error->throw('invalid_query', "$kind requires values") unless ref($values) eq 'ARRAY';
    $self->_repeatable_sql($source);
    my $equals = sub {
        my ($item, $value) = @_;
        Selecto::Error->throw('invalid_query', 'array predicate values must be scalars') if ref($value);
        return "COALESCE(JSON_TYPE($item), 'NULL') = 'NULL'" unless defined $value;
        if ($type eq 'boolean') {
            return "COALESCE(JSON_TYPE($item) = 'BOOLEAN' AND JSON_UNQUOTE($item) = '" . ($value ? 'true' : 'false') . "', FALSE)";
        }
        if ($type eq 'integer' || $type eq 'decimal') {
            Selecto::Error->throw('invalid_query', 'array predicate requires canonical typed elements')
                unless eval { Selecto::InsertAdmission::_value($type, $value, 'array element'); 1 };
            Selecto::Error->throw('invalid_query', 'array predicate requires canonical typed elements')
                if $type eq 'integer' && "$value" !~ /\A-?\d{1,18}\z/;
            return $self->_json_number_equals_sql($item, "$value", $params);
        }
        push @$params, "$value";
        return "COALESCE(JSON_TYPE($item) = 'STRING' AND CAST(JSON_UNQUOTE($item) AS BINARY) = CAST("
            . $self->placeholder(scalar @$params) . ' AS BINARY), FALSE)';
    };
    my $is_array = "JSON_TYPE($source) = 'ARRAY'";
    if ($kind eq 'array_contains') {
        return '(' . join(' AND ', "($is_array)", map {
            my $value = $_;
            '(' . $self->_json_array_has_sql($source, sub { $equals->($_[0], $value) }) . ')';
        } @$values) . ')';
    }
    if ($kind eq 'array_overlap') {
        return "(($is_array) AND " . $self->_json_array_has_sql($source, sub {
            my ($item) = @_;
            return @$values ? '(' . join(' OR ', map { $equals->($item, $_) } @$values) . ')' : 'FALSE';
        }) . ')';
    }
    Selecto::Error->throw('invalid_query', "unsupported array predicate $kind") unless $kind eq 'array_contained';
    return "(($is_array) AND NOT " . $self->_json_array_has_sql($source, sub {
        my ($item) = @_;
        return @$values ? 'NOT (' . join(' OR ', map { $equals->($item, $_) } @$values) . ')' : 'TRUE';
    }) . ')';
}

sub _join_target_key {
    my ($self, $sql, $cast) = @_;
    return $sql unless defined($cast);
    Selecto::Error->throw('invalid_domain', 'unsupported join target key cast')
        unless $cast eq 'string';
    # An explicit binary collation compares the exact key text, like
    # PostgreSQL, whatever the connection and column collations are.
    return "CAST($sql AS CHAR CHARACTER SET utf8mb4) COLLATE utf8mb4_bin";
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    my $kind = $expression->kind;
    return $self->_compile_text_search($domain, $expression, $params)
        if $kind eq 'text_search' || $kind eq 'text_rank';
    return $self->_compile_datetime_format($domain, $expression, $params) if $kind eq 'datetime_format';
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
}

# MATCH ... AGAINST in boolean mode over a FULLTEXT index the host declares on
# exactly the searched root columns. Every word is required, as in a
# PostgreSQL tsquery of the simple configuration; the query is always bound.
sub _compile_text_search {
    my ($self, $domain, $expression, $params) = @_;
    my ($fields, $literal, $options) = @{$expression->arguments};
    Selecto::Error->throw('invalid_query', 'text search requires at least one governed field')
        unless ref($fields) eq 'ARRAY' && @$fields && @$fields <= 16;
    Selecto::Error->throw('invalid_query', 'text search options must be an object')
        unless ref($options) eq 'HASH';
    my @columns;
    for my $field (@$fields) {
        Selecto::Error->throw('invalid_query', 'text search requires governed fields')
            unless blessed($field) && $field->isa('Selecto::Expression') && $field->kind eq 'field';
        my $resolved = $domain->resolve($field->arguments->[0]);
        Selecto::Error->throw('unsupported_feature', 'MySQL-family text search requires stored text fields of the root relation')
            if $resolved->{association} || ($resolved->{type} // '') !~ /\A(?:string|text)\z/
                || ref($domain->field_metadata($field->arguments->[0])->{computed});
        push @columns, $self->_qualified($self->_root_alias, $resolved->{field});
    }
    Selecto::Error->throw('invalid_query', 'MySQL-family text search requires the simple configuration')
        unless lc($options->{configuration} // 'simple') eq 'simple';
    Selecto::Error->throw('invalid_query', 'text search query must be a non-empty literal string')
        unless blessed($literal) && $literal->isa('Selecto::Expression') && $literal->kind eq 'literal'
            && defined($literal->arguments->[0]) && !ref($literal->arguments->[0])
            && length($literal->arguments->[0]) && length($literal->arguments->[0]) <= 4096;
    my $query = "" . $literal->arguments->[0];
    my $mode = lc($options->{mode} // 'plain');
    my $against;
    if ($mode eq 'prefix') {
        # Bound as the tsquery prefix form; rewritten to +word* terms in SQL.
        Selecto::Error->throw('invalid_query', 'prefix search requires normalized word prefixes')
            unless $query =~ /\A[\p{L}\p{N}_]+:\*(?: & [\p{L}\p{N}_]+:\*)*\z/u;
        push @$params, $query;
        $against = q{CONCAT('+', REPLACE(REPLACE(} . $self->placeholder(scalar @$params)
            . q{, ':*', '*'), ' & ', ' +'))};
    } elsif ($mode eq 'plain' || $mode eq 'phrase') {
        my @words = map { lc } $query =~ /([\p{L}\p{N}_]+)/gu;
        Selecto::Error->throw('invalid_query', 'text search requires a non-empty term') unless @words;
        push @$params, $mode eq 'phrase' ? '"' . join(' ', @words) . '"'
            : join(' ', map { "+$_" } @words);
        $against = $self->placeholder(scalar @$params);
    } else {
        Selecto::Error->throw('unsupported_feature', "MySQL-family text search mode $mode is unavailable");
    }
    return 'MATCH (' . join(', ', @columns) . ") AGAINST ($against IN BOOLEAN MODE)";
}

my %AGGREGATE_KINDS = map { $_ => 1 } qw(
    count count_field count_distinct sum sum_zero avg min max true_count false_count true_percentage
    count_bucket grouping dimension_display
);

# MariaDB has no LATERAL (nor derived tables that read the outer row). A
# lateral join lowers to a derived table of the bounded child relation that
# also selects its correlation keys and, for a limit or offset, a per-parent
# ROW_NUMBER over the child's order (with PostgreSQL NULL placement), joined
# on those keys and row numbers. Children whose per-parent semantics would
# change (grouping, aggregates, set operations, retargets) are refused.
sub _compile_lateral_joins {
    my ($self, $domain, $query, $params) = @_;
    my $laterals = $query->lateral_joins;
    return $self->SUPER::_compile_lateral_joins($domain, $query, $params)
        unless @$laterals && $self->name eq 'mariadb';
    Selecto::Error->throw('unsupported_feature', 'adapter does not support lateral joins')
        unless $self->supports('lateral_join');
    my @joins;
    for my $spec (@$laterals) {
        $spec->{domain} = $self->_bounded_source_domain($domain, $spec->{domain}, "lateral $spec->{name}");
        my $child = $spec->{query};
        Selecto::Error->throw('unsupported_feature', 'MariaDB lowers only ungrouped, non-aggregate lateral children')
            if @{$child->groups} || $child->grouping_mode ne 'plain' || @{$child->set_operations}
                || defined($child->retarget_spec) || @{$child->lateral_joins}
                || grep { $AGGREGATE_KINDS{$_->kind} } @{$child->selections};
        my @columns = @{$spec->{columns}};
        Selecto::Error->throw('invalid_query', 'lateral projection width does not match declared columns')
            unless @columns == @{$child->selections};
        my @keys = sort keys %{$spec->{correlations}};
        for my $key (@keys) {
            Selecto::Error->throw('invalid_query', 'lateral correlations require root fields')
                if $spec->{domain}->resolve($key)->{association}
                    || $domain->resolve($spec->{correlations}{$key})->{association};
        }
        my @selections = map { $child->selections->[$_]->as($columns[$_]) } 0 .. $#columns;
        push @selections, map { Selecto::Expression->field($keys[$_])->as("__selecto_lateral_key$_") } 0 .. $#keys;
        my ($limit, $offset) = ($child->limit_value, $child->offset_value);
        my $ranked = defined($limit) || defined($offset);
        push @selections, Selecto::Expression->row_number(
            partition_by => [map { Selecto::Expression->field($_) } @keys],
            order_by => [map { [$_->[0], $_->[1]] } @{$child->orders}],
        )->as('__selecto_lateral_row') if $ranked;
        my $lowered = $child->_copy(selections => \@selections, orders => [],
            limit_value => undef, offset_value => undef);
        my $statement = $self->_compile_single($spec->{domain}, $lowered, root_alias => 'l_' . $spec->{name});
        my $sql = $self->_shift_placeholders($statement->sql, scalar @$params);
        push @$params, @{$statement->params};
        my $name = $self->quote_identifier($spec->{name});
        my @on = map {
            $self->_identity_equal_sql("$name." . $self->quote_identifier("__selecto_lateral_key$_"),
                $self->_qualified($self->_root_alias, $spec->{correlations}{$keys[$_]}),
                $self->_identity_field_exact($domain, $spec->{correlations}{$keys[$_]})
                    || $self->_identity_field_exact($spec->{domain}, $keys[$_]))
        } 0 .. $#keys;
        if ($ranked) {
            my $row = "$name." . $self->quote_identifier('__selecto_lateral_row');
            my $start = int($offset // 0);
            push @on, "$row > $start";
            push @on, "$row <= " . ($start + int($limit)) if defined $limit;
        }
        push @joins, ($spec->{type} eq 'left' ? 'LEFT JOIN' : 'INNER JOIN') . " ($sql) AS $name ON " . join(' AND ', @on);
    }
    return \@joins;
}

sub _compile_function_laterals {
    my ($self, $query, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'MariaDB has no lateral function sources')
        if @{$query->function_laterals} && $self->name eq 'mariadb';
    return $self->SUPER::_compile_function_laterals($query, $params);
}

sub _values_source_cast_sql { return $_[1] eq 'INTEGER' ? 'SIGNED' : 'DOUBLE'; }

sub _values_cast_types {
    return {
        integer => 'SIGNED', int => 'SIGNED', bigint => 'SIGNED',
        decimal => \&Selecto::SQL::_values_decimal_sql,
        numeric => \&Selecto::SQL::_values_decimal_sql,
        string => 'CHAR', text => 'CHAR',
        date => 'DATE', datetime => 'DATETIME(6)', naive_datetime => 'DATETIME(6)',
        utc_datetime => 'DATETIME(6)',
    };
}

# Value expressions cast to fixed targets; a computed decimal keeps the
# widest scale both servers allow.
sub _value_type_sql {
    my ($self, $type) = @_;
    return 'DECIMAL(65, 30)' if lc("$type") eq 'decimal' || lc("$type") eq 'numeric';
    return $self->SUPER::_value_type_sql($type);
}

# RETURNING (and the generated keys and graphs built on it) is emulated by a
# re-read in the write's own transaction; see _execute_compiled_write_in_transaction.
sub write_capabilities {
    my ($self) = @_;
    return {%{$self->SUPER::write_capabilities}, upsert => 1, returning => 1, generated_keys => 1,
        write_graph => 1, typed_insert_admission => 1};
}

sub _validate_write_intent {
    my ($self, $write) = @_;
    my @commands = ref($write) eq 'Selecto::Write::Command' ? ($write)
        : ref($write) eq 'Selecto::Write::Batch' ? @{$write->commands}
        : map { $_->{command} } @{$write->nodes};
    _refuse_scoped_upsert($_) for grep { $_->operation eq 'upsert' } @commands;
    # A graph child's parent binding becomes an assignment; ON DUPLICATE KEY
    # UPDATE could then resolve on any unique key of another parent's row.
    if (ref($write) eq 'Selecto::Write::Graph') {
        Selecto::Error->throw('unsupported_scope_predicate',
            'MySQL-family adapters cannot confine a bound graph child upsert to its parent',
            {upsert_strategy => 'on_duplicate_key'})
            if grep { $_->{command}->operation eq 'upsert' && @{$_->{bindings} // []} } @{$write->nodes};
    }
    return 1;
}

# ON DUPLICATE KEY UPDATE has no WHERE: it updates whichever row holds the
# conflicting key, so it cannot keep a write scope (tenant, caller or
# required predicate). Such upserts are refused, as by the Elixir and Go
# MySQL-family adapters. Query-enforced upserts keep the shared refusal.
sub _refuse_scoped_upsert {
    my ($command) = @_;
    return if defined $command->query_enforcement;
    Selecto::Error->throw('unsupported_scope_predicate',
        'MySQL-family adapters cannot apply write scope predicates to upserts',
        {upsert_strategy => 'on_duplicate_key'})
        if defined($command->predicate) || defined($command->scope_predicate);
}

sub _compile_write {
    my ($self, $command) = @_;
    _refuse_scoped_upsert($command) if $command->operation eq 'upsert';
    local $self->{_selecto_identity_columns} = $self->_write_identity_columns($command);
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

# Upserts never use ON DUPLICATE KEY UPDATE, which resolves on whichever
# unique key collides first (the primary key before the declared target) and
# has no WHERE. They are emulated with PostgreSQL ON CONFLICT semantics; see
# _execute_upsert. A preview shows the INSERT branch.
sub _compile_upsert_clause {
    my ($self, $conflict, $updates) = @_;
    Selecto::Error->throw('invalid_write', 'MySQL-family upserts require update fields') unless @$updates;
    return '';
}

# The declared conflict target must be exactly the columns of a real unique
# index (no prefix or functional part), so at most one row can hold its
# values. The table is read first: its shared metadata lock keeps the index
# set unchanged until the write transaction ends.
sub _admit_upsert_conflict {
    my ($self, $command) = @_;
    my $refuse = sub {
        Selecto::Error->throw('unsupported_upsert_conflict_target',
            'MySQL-family adapters cannot guarantee the declared upsert conflict target', {reason => $_[0]});
    };
    my $table = Selecto::Identifier::checked($command->relation);
    my $conflict = $command->metadata->{conflict_target};
    $refuse->('conflict_target_invalid') unless ref($conflict) eq 'ARRAY' && @$conflict;
    my %target = map { (Selecto::Identifier::checked($_) => 1) } @$conflict;
    my $dbh = $self->dbh;
    my $indexes;
    my $ok = eval {
        $dbh->do('SELECT 1 FROM ' . $self->quote_identifier($table) . ' WHERE 1 = 0');
        $self->_require_transactional_table($table);
        $indexes = $dbh->selectall_arrayref(q{SELECT INDEX_NAME, COLUMN_NAME, SUB_PART FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND NON_UNIQUE = 0 ORDER BY INDEX_NAME, SEQ_IN_INDEX},
            undef, $table);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    my %index;
    for my $row (@$indexes) {
        my ($name, $column, $prefix) = @$row;
        my $entry = $index{$name} //= {columns => {}, usable => 1};
        $entry->{usable} = 0 if !defined($column) || defined($prefix);
        $entry->{columns}{$column} = 1 if defined $column;
    }
    my ($matched) = grep {
        my $entry = $index{$_};
        $entry->{usable} && keys(%{$entry->{columns}}) == keys(%target)
            && !grep { !$entry->{columns}{$_} } keys %target
    } sort keys %index;
    $refuse->('no_matching_unique_index') unless defined $matched;
    return lc $matched;
}

# FOR UPDATE, savepoints and rollback need a transactional engine; a MyISAM
# table would apply every statement immediately and ignore both.
sub _require_transactional_table {
    my ($self, $table) = @_;
    my ($engine) = $self->dbh->selectrow_array(q{SELECT ENGINE FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?}, undef, $table);
    Selecto::Error->throw('write_capability_missing',
        'MySQL-family writes require an InnoDB table', {reason => 'non_transactional_engine'})
        unless defined($engine) && uc($engine) eq 'INNODB';
    return 1;
}

# PostgreSQL ON CONFLICT (target) DO UPDATE, in the write's transaction: a
# locking read of the one row holding the target values (FOR UPDATE, which
# under REPEATABLE READ also locks the gap so no concurrent insert can take
# the key), then an UPDATE of that row confined to the target values, or a
# plain INSERT that any other unique collision fails as it would in
# PostgreSQL. A NULL target value never conflicts.
sub _execute_upsert {
    my ($self, $command) = @_;
    $self->_admit_upsert_conflict($command);
    my $metadata = $command->metadata;
    my $assignments = $command->assignments;
    my (@terms, $null);
    for my $field (@{$metadata->{conflict_target}}) {
        my $value = $assignments->{$field};
        $value = $value->arguments->[0]
            if blessed($value) && $value->isa('Selecto::Write::Expression') && $value->kind eq 'literal';
        Selecto::Error->throw('unsupported_upsert_conflict_target',
            'MySQL-family upsert conflict target values must be literals', {field => $field})
            if !exists($assignments->{$field}) || ref($value);
        $null = 1 unless defined $value;
        push @terms, Selecto::Expression->eq($field, $value);
    }
    my $target = Selecto::QueryEnforcement::combine(@terms);
    my $table = $self->quote_identifier(Selecto::Identifier::checked($command->relation));
    my %branch_metadata = %$metadata;
    delete @branch_metadata{qw(conflict_target upsert_update_fields returning)};
    my %shared = (relation => $command->relation, expected_count => $command->expected_count,
        metadata => \%branch_metadata, foreign_key_guards => $command->foreign_key_guards);
    my $insert = Selecto::Write::Command->new(%shared, operation => 'insert', assignments => $assignments);
    my $run = sub { $self->SUPER::_execute_compiled_write_in_transaction($_[0], $self->SUPER::_compile_write($_[0])) };
    my $result;
    my ($where, @params);
    unless ($null) {
        $where = $self->_compile_write_predicate($target, \@params);
    }
    # Locks and updates the target's row; false when no such row exists.
    my $update_target = sub {
        my $rows;
        my $ok = eval { $rows = $self->dbh->selectall_arrayref("SELECT 1 FROM $table WHERE $where FOR UPDATE", undef, @params); 1 };
        die $self->normalize_error($@) unless $ok;
        return 0 unless @$rows;
        my $update = Selecto::Write::Command->new(%shared, operation => 'update', predicate => $target,
            assignments => {map { ($_ => $assignments->{$_}) } @{$metadata->{upsert_update_fields}}});
        $result = $run->($update);
        return 1;
    };
    my $done = sub { Selecto::Write::Result->new(operation => 'upsert', affected_rows => $result->affected_rows, values => {}) };
    # An existing row is the common case: a plain snapshot read finds it and
    # goes straight to a record lock. Inserting first would leave a shared
    # lock on the duplicate record (a savepoint rollback does not release it),
    # and sessions racing on one row would each hold it while asking for the
    # exclusive lock: a deadlock.
    if (!$null) {
        my $present;
        my $ok = eval { ($present) = $self->dbh->selectrow_array("SELECT 1 FROM $table WHERE $where LIMIT 1", undef, @params); 1 };
        die $self->normalize_error($@) unless $ok;
        return $done->() if $present && $update_target->();
    }
    # Absent: INSERT first, in a savepoint. Locking an absent key first
    # (SELECT ... FOR UPDATE) takes a gap lock that two sessions on the same
    # new key hold together, and both then deadlock inserting. The insert
    # takes the key's record lock directly; a loser waits for the winner and
    # gets 1062.
    my $savepoint = Selecto::SQL::_savepoint_name('selecto_upsert');
    $self->_savepoint_command(create => $savepoint);
    my $inserted = eval { $result = $run->($insert); 1 };
    my $error = $@;
    if ($inserted) {
        $self->_savepoint_command(release => $savepoint);
        return $done->();
    }
    # A deadlock victim's whole transaction is already rolled back, its
    # savepoint with it: the failed ROLLBACK TO (1305) must not replace the
    # typed retryable error. Any other failure to restore the savepoint also
    # ends the upsert with its original error.
    my $restored = eval {
        $self->_savepoint_command(rollback => $savepoint);
        $self->_savepoint_command(release => $savepoint);
        1;
    };
    die $error unless $restored && blessed($error) && $error->isa('Selecto::Error')
        && $error->code eq 'database_unique_violation' && !$null;
    # As PostgreSQL's arbiter index does, the declared target alone decides
    # whether this is a conflict, whichever unique key the server reported
    # first (the primary key is checked before the target). When no target
    # row exists the collision was only on another unique key and the
    # original unique violation stands.
    die $error unless $update_target->();
    return $done->();
}

# RETURNING fields are validated as usual but compiled into no SQL; the
# executor re-reads them.
sub _append_returning {
    my ($self, $sql, $params, $command) = @_;
    my $returning = $command->metadata->{returning} // [];
    return $self->SUPER::_append_returning($sql, $params, $command)
        unless ref($returning) eq 'ARRAY' && @$returning;
    my $compiled = $self->SUPER::_append_returning($sql, $params,
        $command->with_metadata({%{$command->metadata}, returning => []}));
    Selecto::Error->throw('invalid_write', 'returning must be an array of declared identifiers')
        if grep { ref($_) || !defined($_) || !Selecto::Identifier::checked($_) } @$returning;
    return {%$compiled, returning => [], returning_emulated => [@$returning]};
}

# Neither server has UPDATE ... RETURNING (MySQL has no RETURNING at all), so
# a returning write re-reads its rows inside its own transaction, by primary
# key and under the write's scope predicate:
# - update/delete first lock the keys the write's full predicate and guards
#   select (FOR UPDATE), the DML then changes exactly those locked rows, and
#   an update re-reads them while a delete returns what it read before;
# - insert reads the row by its assigned key or AUTO_INCREMENT id, and an
#   upsert by its conflict target, which the index proof makes unique.
# A re-read that disagrees with the affected count fails the write.
sub _execute_compiled_write_in_transaction {
    my ($self, $command, $compiled) = @_;
    local $self->{_selecto_identity_columns} = $self->_write_identity_columns($command);
    my $operation = $command->operation;
    # Affected-row counts are matched rows only with CLIENT_FOUND_ROWS, the
    # DBD::MariaDB default; a handle that names it off in its DSN is refused.
    # (A connect-attribute override is not readable back; hosts must keep it.)
    Selecto::Error->throw('write_capability_missing',
        'MySQL-family writes require mariadb_client_found_rows (matched-row counts)')
        if ($operation eq 'update' || $operation eq 'upsert')
            && (eval { $self->dbh->{Name} } // '') =~ /(?:\A|;)\s*mariadb_client_found_rows\s*=\s*0\b/;
    my @returning = @{$compiled->{returning_emulated} // []};
    unless (@returning) {
        return $self->_execute_upsert($command) if $operation eq 'upsert';
        my $result = $self->SUPER::_execute_compiled_write_in_transaction($command, $compiled);
        $self->_verify_inserted_row($command, $result) if $operation eq 'insert';
        return $result;
    }
    my $metadata = $command->metadata;
    Selecto::Error->throw('write_capability_missing', 'MySQL-family RETURNING requires the governing primary key')
        unless defined($metadata->{__selecto_primary_key}) && !ref($metadata->{__selecto_primary_key});
    my $key = Selecto::Identifier::checked($metadata->{__selecto_primary_key});
    Selecto::Error->throw('write_capability_missing', 'MySQL-family RETURNING requires the governing tenant columns')
        unless ref($metadata->{__selecto_tenant_fields}) eq 'ARRAY';
    # The re-read finds rows by their captured keys; a key change would lose them.
    Selecto::Error->throw('write_capability_missing',
        'MySQL-family RETURNING cannot follow an update of the primary key', {field => $key})
        if $operation eq 'update' && exists $command->assignments->{$key};
    my ($keys, $before);
    if ($operation eq 'update' || $operation eq 'delete') {
        $keys = $self->_locked_write_keys($command, $key);
        $before = $self->_returning_rows($command, \@returning, Selecto::Expression->in($key, $keys))
            if $operation eq 'delete' && @$keys;
    }
    my $result = $operation eq 'upsert' ? $self->_execute_upsert($command)
        : $self->SUPER::_execute_compiled_write_in_transaction($command, {%$compiled, returning => []});
    my $affected = $result->affected_rows;
    my $rows = [];
    if ($operation eq 'update') {
        $rows = $self->_returning_rows($command, \@returning, Selecto::Expression->in($key, $keys)) if @$keys;
    } elsif ($operation eq 'delete') {
        $rows = $before // [];
    } elsif ($affected) {
        $rows = $self->_returning_rows($command, \@returning, $self->_inserted_identity($command, $key));
    }
    # Captured, written and re-read counts must agree: a row the update moved
    # out of its tenant scope is not re-read, and the write rolls back.
    my $expected = $operation eq 'insert' || $operation eq 'upsert' ? ($affected ? 1 : 0) : $affected;
    Selecto::Error->throw('write_returning_missing', 'write returning re-read disagrees with the affected rows')
        unless @$rows == $expected && (!$keys || @$keys == $affected);
    Selecto::Error->throw('write_returning_missing', 'write did not return the requested row')
        if !@$rows && !exists($metadata->{expected_cardinality});
    $self->_verify_inserted_row($command, $result, $rows) if $operation eq 'insert';
    my %values;
    @values{@returning} = @{$rows->[0]} if @$rows;
    return Selecto::Write::Result->new(operation => $operation, affected_rows => $affected, values => \%values);
}

# A guarded insert was admitted by casting its candidate to the column
# storage (type, scale, collation). The stored row is checked again in the
# write transaction: it must still satisfy the enforced predicate when read
# back by its key, or the write fails with query_rule_violation and rolls
# back. This covers storage effects the candidate cast cannot see.
sub _verify_inserted_row {
    my ($self, $command, $result) = @_;
    return unless $result->affected_rows;
    my $predicate = _write_predicate_expression($command);
    return unless defined($predicate) && exists $command->metadata->{__selecto_insert_types};
    my $key = $command->metadata->{__selecto_primary_key};
    Selecto::Error->throw('query_rule_not_evaluable', 'guarded insert verification requires the primary key')
        unless defined($key) && !ref($key);
    $key = Selecto::Identifier::checked($key);
    my @params;
    my $where = $self->_compile_write_predicate(
        Selecto::QueryEnforcement::combine($self->_inserted_identity($command, $key), $predicate), \@params);
    my $sql = 'SELECT COUNT(*) FROM ' . $self->quote_identifier(Selecto::Identifier::checked($command->relation))
        . " WHERE $where";
    my ($count);
    my $ok = eval { ($count) = $self->dbh->selectrow_array($sql, undef, @params); 1 };
    die $self->normalize_error($@) unless $ok;
    Selecto::Error->throw('query_rule_violation', 'stored row does not satisfy the enforced query',
        {truth_value => 'false_or_unknown'}) unless defined($count) && $count == $result->affected_rows;
    return 1;
}

sub _write_predicate_expression {
    my ($command) = @_;
    return Selecto::QueryEnforcement::combine($command->predicate, $command->scope_predicate,
        defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef);
}

sub _locked_write_keys {
    my ($self, $command, $key) = @_;
    my @params;
    my $where = $self->_compile_write_predicate(_write_predicate_expression($command), \@params);
    if ($command->operation eq 'update') {
        my $guard = $self->_compile_foreign_key_guards($command, \@params);
        $where .= " AND $guard" if defined $guard;
    }
    my $bounds = $self->_validate_write_cardinality($command);
    my $column = $self->quote_identifier($key);
    my $sql = "SELECT $column FROM " . $self->quote_identifier(Selecto::Identifier::checked($command->relation))
        . " WHERE $where ORDER BY $column"
        . (defined($bounds->{maximum}) ? ' LIMIT ' . ($bounds->{maximum} + 1) : '') . ' FOR UPDATE';
    my $keys;
    my $ok = eval {
        $self->_require_transactional_table(Selecto::Identifier::checked($command->relation));
        $keys = $self->dbh->selectcol_arrayref($sql, undef, @params);
        1;
    };
    die $@ if !$ok && blessed($@) && $@->isa('Selecto::Error');
    die $self->normalize_error($@) unless $ok;
    return $keys;
}

# The inserted row's identity. LAST_INSERT_ID is used only when the server
# generated the key: the key column is AUTO_INCREMENT and the insert omitted
# it or assigned NULL/DEFAULT. Any other assigned key must be a literal.
sub _inserted_identity {
    my ($self, $command, $key) = @_;
    my $assignments = $command->assignments;
    my $literal = sub {
        my ($field) = @_;
        my $value = $assignments->{$field};
        $value = $value->arguments->[0]
            if blessed($value) && $value->isa('Selecto::Write::Expression') && $value->kind eq 'literal';
        Selecto::Error->throw('write_capability_missing',
            'MySQL-family RETURNING requires a literal identity value', {field => $field})
            if !defined($value) || ref($value);
        return $value;
    };
    if ($command->operation eq 'upsert') {
        my @terms = map { Selecto::Expression->eq($_, $literal->($_)) } @{$command->metadata->{conflict_target}};
        return @terms == 1 ? $terms[0] : Selecto::Expression->all(@terms);
    }
    if (exists $assignments->{$key}) {
        my $value = $assignments->{$key};
        my $generated = !defined($value)
            || (blessed($value) && $value->isa('Selecto::Write::Expression')
                && ($value->kind eq 'default' || ($value->kind eq 'literal' && !defined($value->arguments->[0]))));
        return Selecto::Expression->eq($key, $literal->($key)) unless $generated;
    }
    my $table = Selecto::Identifier::checked($command->relation);
    my ($extra, $id);
    my $ok = eval {
        ($extra) = $self->dbh->selectrow_array(q{SELECT EXTRA FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?}, undef, $table, $key);
        $id = $self->dbh->{mariadb_insertid};
        1;
    };
    die $self->normalize_error($@) unless $ok;
    Selecto::Error->throw('write_capability_missing',
        'MySQL-family RETURNING requires an assigned or AUTO_INCREMENT primary key')
        unless defined($extra) && $extra =~ /\bauto_increment\b/i && defined($id) && "$id" =~ /\A[1-9]\d*\z/;
    return Selecto::Expression->eq($key, "$id");
}

# The top-level eq/IN conjuncts of the write scope on its tenant columns
# (engine tenant, writes.scope.tenant, pins). Non-tenant required predicates
# are left out: an update may legitimately change what they read, and the
# rows were already captured under the write's full condition.
sub _tenant_conjuncts {
    my ($command) = @_;
    my %tenant = map { ($_ => 1) } @{$command->metadata->{__selecto_tenant_fields} // []};
    my @pending = grep { defined } ($command->scope_predicate);
    my @kept;
    while (my $expression = shift @pending) {
        next unless blessed($expression) && $expression->isa('Selecto::Expression');
        if ($expression->kind eq 'and') {
            push @pending, @{$expression->arguments->[0]};
            next;
        }
        my $field = $expression->arguments->[0];
        push @kept, $expression if ($expression->kind eq 'eq' || $expression->kind eq 'in')
            && blessed($field) && $field->kind eq 'field' && $tenant{$field->arguments->[0]};
    }
    return @kept;
}

# A locking read: under REPEATABLE READ a plain read returns the snapshot,
# which after a no-op update or upsert, and for a delete's before image, can
# be older than the row the write locked and changed.
sub _returning_rows {
    my ($self, $command, $fields, $identity) = @_;
    my @params;
    my $where = $self->_compile_write_predicate(
        Selecto::QueryEnforcement::combine($identity, _tenant_conjuncts($command)), \@params);
    my $key = $self->quote_identifier(Selecto::Identifier::checked($command->metadata->{__selecto_primary_key}));
    my $sql = 'SELECT ' . join(', ', map { $self->quote_identifier(Selecto::Identifier::checked($_)) } @$fields)
        . ' FROM ' . $self->quote_identifier(Selecto::Identifier::checked($command->relation))
        . " WHERE $where ORDER BY $key FOR UPDATE";
    my ($sth, $rows);
    my $ok = eval {
        $sth = $self->dbh->prepare($sql);
        $self->_execute_statement($sth, \@params);
        my @types = $self->_column_types($sth);
        $rows = $sth->fetchall_arrayref;
        $self->_decode_rows($rows, \@types);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    return $rows;
}

my %INTEGER_TYPES = map { $_ => 1 } qw(tinyint smallint mediumint int bigint);
my %TEXT_TYPES = map { $_ => 1 } qw(char varchar tinytext text mediumtext longtext);

# The storage contract for a guarded insert's candidate check, read in the
# write transaction after a read of the table: its shared metadata lock keeps
# the column definitions and triggers (CREATE TRIGGER needs an exclusive
# lock) unchanged until commit. Strict SQL mode is required, so a value the
# column cannot hold fails the INSERT instead of being stored altered.
sub insert_admission_storage {
    my ($self, $command, $types) = @_;
    my $fail = sub { Selecto::Error->throw('query_rule_not_evaluable',
        'MySQL-family adapter cannot establish the guarded insert storage contract'); };
    my $dbh = $self->dbh;
    $fail->() unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'MariaDB' };
    my $table = Selecto::Identifier::checked($command->relation);
    my ($mode, $kind, $triggers, $rows);
    my $ok = eval {
        $dbh->do('SELECT 1 FROM ' . $self->quote_identifier($table) . ' WHERE 1 = 0');
        $self->_require_transactional_table($table);
        ($mode) = $dbh->selectrow_array('SELECT @@SESSION.sql_mode');
        ($kind) = $dbh->selectrow_array(q{SELECT TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?}, undef, $table);
        ($triggers) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM information_schema.TRIGGERS
            WHERE EVENT_OBJECT_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = ?}, undef, $table);
        $rows = $dbh->selectall_arrayref(q{SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, EXTRA,
            CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?}, {Slice => {}}, $table);
        1;
    };
    die $self->normalize_error($@) unless $ok;
    $fail->() unless defined($mode) && $mode =~ /\bSTRICT_(?:TRANS|ALL)_TABLES\b/
        && defined($kind) && $kind eq 'BASE TABLE' && !$triggers;
    my %columns = map { ($_->{COLUMN_NAME} => $_) } @$rows;
    my %storage;
    for my $field (keys %$types) {
        my $column = $columns{$field};
        $fail->() unless $column && ($column->{EXTRA} // '') !~ /GENERATED/i;
        my ($name, $declaration) = (lc($column->{DATA_TYPE} // ''), lc($column->{COLUMN_TYPE} // ''));
        my $type = $types->{$field};
        if ($type eq 'integer' || $type eq 'boolean') {
            $fail->() unless $INTEGER_TYPES{$name} && ($type eq 'integer' || $declaration =~ /\Atinyint\(1\)/);
            $storage{$field} = {cast => $declaration =~ /\bunsigned\b/ ? 'UNSIGNED' : 'SIGNED'};
        } elsif ($type eq 'decimal') {
            $fail->() unless $name eq 'decimal' && $declaration =~ /\Adecimal\((\d+),(\d+)\)\z/;
            $storage{$field} = {cast => "DECIMAL($1, $2)"};
        } else {
            $fail->() unless $TEXT_TYPES{$name} && defined($column->{CHARACTER_SET_NAME})
                && defined($column->{COLLATION_NAME})
                && $column->{CHARACTER_SET_NAME} =~ /\A\w+\z/ && $column->{COLLATION_NAME} =~ /\A\w+\z/;
            $storage{$field} = {cast => "CHAR CHARACTER SET $column->{CHARACTER_SET_NAME}",
                collation => $column->{COLLATION_NAME}};
        }
    }
    return \%storage;
}

sub _logical_affected_rows {
    my ($self, $operation, $physical) = @_;
    return 1 if $operation eq 'upsert' && ($physical == 1 || $physical == 2);
    return $physical;
}

# A TINYINT(1) column is how both servers store BOOLEAN; it is named
# 'boolean' so export scalars can emit JSON booleans.
sub _column_types {
    my ($self, $sth) = @_;
    my @names = eval { @{$sth->{mariadb_type_name} // []} };
    my @precision = eval { @{$sth->{PRECISION} // []} };
    return map {
        lc($names[$_] // '') eq 'tinyint' && defined($precision[$_]) && $precision[$_] == 1 ? 'boolean' : $names[$_]
    } 0 .. $#names;
}

# Canonical export scalars: exact decimals keep the scale the server writes,
# booleans are JSON booleans and JSON columns are decoded; other values are
# canonical as usual.
sub execute_query {
    my ($self, $statement, %options) = @_;
    $self->_require_session;
    local $self->{_selecto_export_scalars} = $options{export_scalars} ? 1 : 0;
    return $self->_apply_formatters($statement, $self->SUPER::execute_query($statement));
}

sub _decode {
    my ($self, $value, $type) = @_;
    return undef unless defined $value;
    $type = uc($type // '');
    if ($self->{_selecto_export_scalars}) {
        return "$value" if $type =~ /\A(?:DECIMAL|NUMERIC)\z/;
        return "$value" ? JSON::PP::true : JSON::PP::false if $type eq 'BOOLEAN';
        return JSON::PP->new->allow_nonref(1)->decode("$value") if $type eq 'JSON';
    }
    return int($value) if $type eq 'BOOLEAN' && "$value" =~ /\A-?\d+\z/;
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
    my $record = 'JSON_OBJECT(' . join(', ', @pairs) . ')';
    # Without a requested limit, the default primary-key order is applied
    # only where the server can order the aggregate.
    unless (defined($spec->{order})
        && (defined($spec->{limit}) || $self->supports('ordered_related_collections'))) {
        return $self->_related_collection_aggregate_sql(
            "JSON_ARRAYAGG($record)", $spec->{from}, $spec->{where}, 'JSON_ARRAY()',
        );
    }
    if ($self->name eq 'mariadb') {
        # MariaDB orders (and bounds) the aggregate itself.
        my $aggregate = "JSON_ARRAYAGG($record ORDER BY $spec->{order}"
            . (defined($spec->{limit}) ? ' LIMIT ' . int($spec->{limit}) : '') . ')';
        return $self->_related_collection_aggregate_sql(
            $aggregate, $spec->{from}, $spec->{where}, 'JSON_ARRAY()',
        );
    }
    Selecto::Error->throw('invalid_query', 'related collection limit must be applied by its source')
        if defined $spec->{limit};
    # MySQL's JSON_ARRAYAGG has no ORDER BY; as a window aggregate it adds
    # rows in the window order, here a ROW_NUMBER over the requested order.
    my $children = $self->quote_identifier('__selecto_children');
    my $position = $self->quote_identifier('__selecto_position');
    my $value = $self->quote_identifier('__selecto_record');
    return "COALESCE((SELECT JSON_ARRAYAGG($children.$value) OVER (ORDER BY $children.$position "
        . 'ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM '
        . "(SELECT $record AS $value, ROW_NUMBER() OVER (ORDER BY $spec->{order}) AS $position FROM "
        . $spec->{from} . ' WHERE ' . $spec->{where} . ") AS $children LIMIT 1), JSON_ARRAY())";
}

# MariaDB cannot correlate a derived table with the parent row; its
# aggregate applies the limit instead.
sub _bounded_related_collection_source {
    my ($self, $from, $where, $order, $limit, $quoted_alias) = @_;
    return ($from, $where, $limit) if $self->name eq 'mariadb';
    return $self->SUPER::_bounded_related_collection_source($from, $where, $order, $limit, $quoted_alias);
}

# PostgreSQL orders NULL last ascending and first descending.
sub _related_collection_order_term {
    my ($self, $alias, $field, $direction) = @_;
    my $sql = $self->_qualified($alias, $field);
    return "($sql IS NULL) " . uc($direction) . ", $sql " . uc($direction);
}

# Rewrites the shared cursor predicate's (IS [NOT] DISTINCT FROM ?) into the
# null-safe <=>. Only a quoted identifier (optionally qualified) is the left
# operand, so the rewrite never swallows an opening parenthesis, and the
# negation is parenthesized so it covers just the comparison.
my $QUOTED_IDENTIFIER = qr/`(?:``|[^`])*`(?:\.`(?:``|[^`])*`)*/;

sub _null_safe_cursor_sql {
    my ($sql) = @_;
    $sql =~ s/($QUOTED_IDENTIFIER) IS NOT DISTINCT FROM (\?)/($1 <=> $2)/g;
    $sql =~ s/($QUOTED_IDENTIFIER) IS DISTINCT FROM (\?)/(NOT ($1 <=> $2))/g;
    return $sql;
}

sub _related_collection_cursor_predicate {
    my ($self, @arguments) = @_;
    return _null_safe_cursor_sql($self->SUPER::_related_collection_cursor_predicate(@arguments));
}

sub _related_collection_text_sql {
    my ($self, $sql) = @_;
    return "CAST($sql AS CHAR)";
}


# The session contract every read, stream and write checks first, in one
# round trip and never cached (a host can SET the session at any time):
# - the session time zone is UTC ('UTC', '+00:00', 'Etc/UTC', or SYSTEM
#   while the server's system zone is 'UTC' or '+00:00'; never 'GMT', which
#   is also Europe/London's winter abbreviation): TIMESTAMP values and
#   CURRENT_TIMESTAMP are read and written in it;
# - client, connection and result character sets are utf8mb4 (a narrower
#   one turns four-byte characters into '?');
# - sql_mode is strict (STRICT_TRANS_TABLES or STRICT_ALL_TABLES), so a
#   value a column cannot hold fails instead of being stored altered;
# - the driver returns utf8mb4 text and DATETIME values unchanged (a handle
#   of another driver, or without utf8mb4 decoding, is refused).
# A connection that breaks it is refused with invalid_connection before
# anything else runs. On MariaDB a write also refuses a handle whose server
# transaction was opened outside the driver (a raw START TRANSACTION while
# AutoCommit is on): whether a host transaction is open is decided only by
# the driver's AutoCommit, never by server introspection, and a write must
# neither commit nor discard such work. Hosts open transactions with
# begin_work (MySQL has no @@in_transaction to check this with).
my %UTC_ZONES = map { ($_ => 1) } ('UTC', '+00:00', 'Etc/UTC');

sub _require_session {
    my ($self, %options) = @_;
    return if $self->{_selecto_session_verified};
    my $dbh = $self->{dbh};
    my $open_check = $options{write} && $self->name eq 'mariadb';
    my @row;
    my $ok = eval {
        local $dbh->{PrintError} = 0;
        @row = $dbh->selectrow_array('SELECT @@SESSION.time_zone, @@system_time_zone, '
            . '@@SESSION.character_set_client, @@SESSION.character_set_connection, @@SESSION.character_set_results, '
            . q{@@SESSION.sql_mode, CONVERT(X'F09F9880' USING utf8mb4), CAST('2024-03-10 02:30:00.5' AS DATETIME(6))}
            . ($open_check ? ', @@in_transaction' : ''));
        1;
    };
    die $self->normalize_error($@) unless $ok;
    my ($zone, $system, $client, $connection, $results, $mode, $text, $datetime, $open) = @row;
    my $refuse = sub {
        my ($reason, $message) = @_;
        Selecto::Error->throw('invalid_connection', $message, {reason => $reason});
    };
    $refuse->('session_time_zone', 'MySQL-family sessions must use the UTC time zone')
        unless defined($zone) && ($UTC_ZONES{$zone}
            || ($zone eq 'SYSTEM' && defined($system) && ($system eq 'UTC' || $system eq '+00:00')));
    $refuse->('session_character_set',
        'MySQL-family sessions must use utf8mb4 client, connection and result character sets')
        if grep { !defined($_) || lc($_) ne 'utf8mb4' } $client, $connection, $results;
    $refuse->('session_sql_mode',
        'MySQL-family sessions must use a strict sql_mode (STRICT_TRANS_TABLES or STRICT_ALL_TABLES)')
        unless defined($mode) && grep { $_ eq 'STRICT_TRANS_TABLES' || $_ eq 'STRICT_ALL_TABLES' } split /,/, uc($mode);
    $refuse->('client_decoding', 'MySQL-family connections must return utf8mb4 text and DATETIME values unchanged')
        unless defined($text) && $text eq "\x{1F600}"
            && defined($datetime) && "$datetime" eq '2024-03-10 02:30:00.500000';
    Selecto::Error->throw('invalid_adapter',
        'the connection is inside a transaction its driver did not open; open host transactions with begin_work',
        {reason => 'transaction_outside_driver'})
        if $open_check && defined($open) && "$open" eq '1' && eval { $dbh->{AutoCommit} };
    return 1;
}

# Runs $work with the session verified once for the whole call, so reads and
# writes nested inside it are not checked again.
sub _with_verified_session {
    my ($self, $write, $work) = @_;
    return $work->() if $self->{_selecto_session_verified};
    $self->_require_session(write => $write);
    local $self->{_selecto_session_verified} = 1;
    return $work->();
}

sub execute_write_unsafe {
    my ($self, @arguments) = @_;
    return $self->_with_verified_session(1, sub { $self->SUPER::execute_write_unsafe(@arguments) });
}

sub execute_batch_unsafe {
    my ($self, @arguments) = @_;
    return $self->_with_verified_session(1, sub { $self->SUPER::execute_batch_unsafe(@arguments) });
}

sub execute_graph_unsafe {
    my ($self, @arguments) = @_;
    return $self->_with_verified_session(1, sub { $self->SUPER::execute_graph_unsafe(@arguments) });
}

sub execute_transaction {
    my ($self, @arguments) = @_;
    return $self->_with_verified_session(1, sub { $self->SUPER::execute_transaction(@arguments) });
}

1;

__END__

=head1 NAME

Selecto::MySQLFamily - shared DBD::MariaDB mechanics for the MySQL and MariaDB adapters

=head1 DESCRIPTION

Common base class of L<Selecto::MySQL> and L<Selecto::MariaDB>: placeholders,
backtick quoting and value decoding. The two public adapters stay separate
classes with separate identities.

Unscoped upserts follow PostgreSQL C<ON CONFLICT> semantics and never use
C<ON DUPLICATE KEY UPDATE>, which resolves on whichever unique key collides
first: the declared target must be exactly a real unique index, the row is
inserted inside a savepoint, and a duplicate on that index is answered by
locking and updating the target row. A collision on any other unique key is a
C<database_unique_violation>. An upsert carrying a write scope is refused with
C<unsupported_scope_predicate> (HTTP 501). A deadlock or lock-wait timeout
(possible when three or more sessions race on one new key) is the retryable
C<database_deadlock_detected> or C<database_lock_timeout>; the host reruns its
transaction.

Writes need InnoDB tables and a connection with C<mariadb_client_found_rows>
on (the DBD::MariaDB default, which this module cannot read back from a
handle): a DSN that sets it to 0 is refused for updates and upserts, but one
passed as a connect attribute is a host requirement.

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
