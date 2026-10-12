package Selecto::MySQLFamily;

use Mojo::Base 'Selecto::SQL';
use Selecto::Error ();
use Selecto::Identifier ();
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
    lateral_join => [[8, 0, 14], undef],
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
    return 1 if "$feature" eq 'transactions' || "$feature" eq 'stream';
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
        my $quoted = $self->quote_identifier($column);
        return "$position $direction" unless defined $nulls;
        # Both servers sort NULL first ascending and last descending.
        return ($quoted . ' IS NULL ' . ($nulls eq 'first' ? 'DESC' : 'ASC')) . ", $position $direction";
    }, %options);
}

sub _compile_selection_expression {
    my ($self, $domain, $expression, $params, $compiled_selections, $options) = @_;
    return Selecto::SQL::RollupEmulation::selection_expression($self, $options, sub {
        return $self->_compile_expression($domain, $expression, $params, $compiled_selections);
    });
}

# DBD::MariaDB binds client-side, quoting every value, and both servers need
# the LAG/LEAD offset, NTILE count and NTH_VALUE position as integers: they are
# rendered as validated integer literals.
my %WINDOW_INTEGER_ARGUMENT = (lag => 1, lead => 1, ntile => 0, nth_value => 1);

sub _compile_window {
    my ($self, $domain, $expression, $params) = @_;
    my ($function, $arguments) = @{$expression->arguments};
    my %inline;
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
    Selecto::Error->throw('unsupported_feature', 'MySQL-family grouping markers require a rollup projection')
        if blessed($expression) && $expression->isa('Selecto::Expression')
            && ($expression->kind eq 'grouping' || $expression->kind eq 'dimension_display');
    return $self->SUPER::_compile_expression($domain, $expression, $params, $compiled_selections);
}

# OFFSET requires a LIMIT; the largest unsigned BIGINT means no limit.
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

sub write_capabilities {
    my ($self) = @_;
    return {%{$self->SUPER::write_capabilities}, upsert => 0};
}

sub _validate_write_intent {
    my ($self, $write) = @_;
    my @commands = ref($write) eq 'Selecto::Write::Command' ? ($write)
        : ref($write) eq 'Selecto::Write::Batch' ? @{$write->commands}
        : map { $_->{command} } @{$write->nodes};
    Selecto::Error->throw('unsupported_upsert_conflict_target',
        'MySQL-family adapters cannot guarantee the declared upsert conflict target')
        if grep { $_->operation eq 'upsert' } @commands;
    return 1;
}

# ON DUPLICATE KEY UPDATE fires on every unique key, not the declared
# conflict target. Refuse every upsert: an unscoped table may have another
# unique index too, and a domain allowlist is not a physical index inventory.
sub _compile_write {
    my ($self, $command) = @_;
    Selecto::Error->throw(
        'unsupported_upsert_conflict_target',
        'MySQL-family adapters cannot guarantee the declared upsert conflict target',
    ) if $command->operation eq 'upsert';
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
    Selecto::Error->throw('unsupported_upsert_conflict_target',
        'MySQL-family adapters cannot guarantee the declared upsert conflict target');
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

sub _related_collection_cursor_predicate {
    my ($self, @arguments) = @_;
    my $sql = $self->SUPER::_related_collection_cursor_predicate(@arguments);
    $sql =~ s/(\S+) IS NOT DISTINCT FROM (\?)/($1 <=> $2)/g;
    $sql =~ s/(\S+) IS DISTINCT FROM (\?)/NOT ($1 <=> $2)/g;
    return $sql;
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

1;

__END__

=head1 NAME

Selecto::MySQLFamily - shared DBD::MariaDB mechanics for the MySQL and MariaDB adapters

=head1 DESCRIPTION

Common base class of L<Selecto::MySQL> and L<Selecto::MariaDB>: placeholders,
backtick quoting and value decoding. The two public adapters stay separate
classes with separate identities. Their C<upsert> write capability is false:
C<ON DUPLICATE KEY UPDATE> can match any unique index and cannot guarantee the
declared conflict target. All upsert previews and executions therefore fail
with C<unsupported_upsert_conflict_target> before database preparation.

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
