package Selecto::SQLite;

use Mojo::Base 'Selecto::SQL';
use Selecto::Error ();
use Selecto::Statement ();
use Scalar::Util qw(blessed);
use POSIX qw(isfinite);
use DBI qw(SQL_INTEGER SQL_DOUBLE SQL_VARCHAR);
use Selecto::SQLite::Ownership ();
use Selecto::SQLite::UpsertCandidate ();
use Cpanel::JSON::XS ();
use JSON::PP ();

sub rule_upsert_scope {
    Selecto::SQLite::UpsertCandidate::_check_args(@_);
    my ($self, $work, %options) = @_;
    Selecto::Error->throw('required_data_rule_pending', 'SQLite candidate scope requires a callback')
        unless ref($work) eq 'CODE';
    Selecto::Error->throw('required_data_rule_pending', 'SQLite candidate scope accepts only a trusted context')
        if grep { $_ ne 'context' } keys %options;
    # Existing compiler/test providers can still serve ordinary stored-rule
    # requests. Native UPSERT projection separately requires the real scope.
    my $native = Selecto::SQLite::UpsertCandidate::_native_handle($self->dbh);
    return $work->() unless $native;
    return Selecto::SQLite::UpsertCandidate->scope($self, $work, $options{context});
}
sub rule_upsert_candidate {
    Selecto::SQLite::UpsertCandidate::_check_args(@_);
    my ($self, $command, $request) = @_;
    return Selecto::SQLite::UpsertCandidate->project($self, $command, $request);
}
sub rule_upsert_validate_command {
    Selecto::SQLite::UpsertCandidate::_check_args(@_);
    my ($self, $command) = @_;
    return Selecto::SQLite::UpsertCandidate->validate_command($self, $command);
}
sub rule_upsert_validate_plan {
    Selecto::SQLite::UpsertCandidate::_check_args(@_);
    my ($self, $commands, $cleanup) = @_;
    return Selecto::SQLite::UpsertCandidate->validate_plan($self, $commands, $cleanup);
}
# Engine governance adds this capability only on the protected path, and
# dispatch then requires the command's private candidate receipt.
sub _admits_empty_upsert_mask {
    my ($self, $command) = @_;
    return scalar grep { !ref($_) && $_ eq 'protected_upsert_candidates' }
        @{$command->metadata->{required_capabilities} // []};
}
sub _execute_compiled_write_in_transaction {
    my ($self, $command, $compiled) = @_;
    $self->rule_upsert_validate_command($command);
    return $self->SUPER::_execute_compiled_write_in_transaction($command, $compiled);
}

sub ownership_storage {
    my ($self, @edge) = @_;
    return Selecto::SQLite::Ownership->verify($self, @edge);
}
sub rule_candidate_storage {
    my ($self, $command) = @_;
    return Selecto::SQLite::Ownership->rules_storage($self, $command);
}

sub preview_write {
    my ($self, $command) = @_;
    # A compiler-only host has no native connection whose storage can be admitted.
    return $self->SUPER::preview_write($command)
        unless eval { $self->dbh->isa('DBI::db') && $self->dbh->{Driver}{Name} eq 'SQLite' };
    return $self->_transaction(sub {
        $self->_admit_plan_storage([$command]);
        return $self->SUPER::preview_write($command);
    });
}

sub _admit_plan_storage {
    my ($self, $commands, $cleanup) = @_;
    Selecto::SQLite::Ownership->plan_storage($self, [@$commands, @{$cleanup // []}]);
    return $self->rule_upsert_validate_plan($commands, $cleanup);
}

sub rule_project_subject {
    my ($self, $command, $values) = @_;
    return $values unless $command->operation eq 'insert';
    my $table = Selecto::SQLite::Ownership->table($self, $command->relation);
    my $alias = Selecto::SQLite::Ownership->rowid_alias($self, $table);
    my %projected = %$values;
    delete $projected{$alias} if defined($alias) && exists($projected{$alias}) && !defined($projected{$alias});
    return \%projected;
}

sub _admit_graph_storage {
    my ($self, $graph) = @_;
    my %nodes = map { ($_->{id} => $_) } @{$graph->nodes};
    for my $node (@{$graph->nodes}) {
        for my $binding (@{$node->{bindings}}) {
            $self->_stable_graph_owner($nodes{$binding->{from}}{command}, $binding->{key});
            $self->ownership_storage($nodes{$binding->{from}}{command}->relation, $binding->{key},
                $node->{command}->relation, $binding->{field});
        }
    }
    for my $set (@{$graph->{_governed_owned_sets} // []}) {
        $self->_stable_graph_owner($nodes{$set->{parent}}{command}, $set->{parent_key});
        $self->ownership_storage($nodes{$set->{parent}}{command}->relation, $set->{parent_key},
            $set->{cleanup}->relation, $set->{child_key});
    }
}
sub _stable_graph_owner {
    my ($self, $command, $key) = @_;
    return unless exists $command->assignments->{$key};
    my $changes = $command->operation eq 'update';
    if ($command->operation eq 'upsert') {
        my $metadata = $command->metadata;
        my $updates = $metadata->{upsert_update_fields};
        $changes = ref($updates) eq 'ARRAY' ? scalar(grep {lc($_) eq lc($key)} @$updates)
            : !(grep {lc($_) eq lc($key)} @{$metadata->{conflict_target} // []});
    }
    Selecto::Error->throw('ownership_storage_not_evaluable', 'SQLite graph ownership keys cannot be reassigned') if $changes;
}

sub name    { return 'sqlite'; }
sub dialect { return __PACKAGE__; }

# The guard suppresses an oversized value on the server before DBI receives
# it, and adds a sentinel that the bounded consumer must reject. No truncation
# is presented as a successful value. Placeholders and their order are unchanged.
sub bounded_result_statement {
    my ($self, $statement, %args) = @_;
    Selecto::Error->throw('unsupported_feature', 'bounded SQLite results require SQLite 3.35.0')
        unless $self->_sqlite_version_at_least(3, 35, 0);
    my ($cap, $rows) = @args{qw(max_cell_bytes max_rows)};
    Selecto::Error->throw('invalid_query', 'invalid bounded result limits')
        if grep { !defined($_) || ref($_) || "$_" !~ /\A[1-9][0-9]{0,9}\z/ } ($cap, $rows);
    my (@values, @overflow, %seen);
    for my $name (@{$statement->columns}) {
        Selecto::Error->throw('unsupported_feature', 'bounded results require unique named columns')
            unless defined($name) && !ref($name) && length($name) && !$seen{$name}++;
        my $column = 'selecto_bounded.' . $self->quote_identifier($name);
        my $large = "length(CAST($column AS BLOB)) > " . int($cap);
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
    return '?';
}

sub normalize_type {
    my ($self, $name) = @_;
    my $declared = lc($name // '');
    return 'boolean' if $declared eq 'boolean';
    return 'integer' if $declared =~ /int/;
    return 'decimal' if $declared =~ /decimal|numeric|real|double|float/;
    return 'naive_datetime' if $declared =~ /datetime|timestamp/;
    return 'date' if $declared eq 'date';
    return 'time' if $declared eq 'time';
    return 'json' if $declared =~ /\Ajsonb?\z/;
    return 'blob' if $declared =~ /blob/ || !length($declared);
    return 'string' if $declared =~ /char|clob|text/;
    return 'unknown';
}

sub insert_admission_storage {
    my ($self, $command, $types, %opts) = @_;
    my $dbh = $self->dbh;
    my $fail = sub { Selecto::Error->throw('query_rule_not_evaluable',
        'SQLite cannot establish the guarded insert storage contract'); };
    $fail->() unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'SQLite' }
        && $dbh->can('sqlite_table_column_metadata');
    my $table = Selecto::Identifier::checked($command->relation);
    # The main-schema profile refuses shadowing/attached-only names. Reading
    # sqlite_schema in the transaction also prevents a concurrent schema change.
    my ($shadow) = $dbh->selectrow_array('SELECT 1 FROM temp.sqlite_master WHERE name = ? COLLATE NOCASE', undef, $table);
    $fail->() if $shadow;
    my ($kind, $ddl) = $dbh->selectrow_array('SELECT type, sql FROM main.sqlite_master WHERE name = ? COLLATE NOCASE', undef, $table);
    $fail->() unless defined($kind) && $kind eq 'table' && defined($ddl) && $ddl =~ /\ACREATE\s+TABLE\b/i;
    for my $schema (qw(main temp)) {
        my ($trigger) = $dbh->selectrow_array("SELECT 1 FROM $schema.sqlite_master WHERE type = 'trigger' AND tbl_name = ? COLLATE NOCASE LIMIT 1", undef, $table);
        $fail->() if $trigger;
    }
    my $rows = $dbh->selectall_arrayref('PRAGMA main.table_xinfo(' . $self->quote_identifier($table) . ')', {Slice => {}});
    my %columns = map { $_->{name} => $_ } @$rows;
    my $physical = Selecto::SQLite::Ownership->table($self, $table);
    my $alias = Selecto::SQLite::Ownership->rowid_alias($self, $physical);
    my %storage;
    for my $field (keys %$types) {
        $fail->() unless exists($columns{$field}) && !$columns{$field}{hidden};
        my $value = $command->assignments->{$field};
        $value = $value->arguments->[0] if blessed($value) && $value->isa('Selecto::Write::Expression') && $value->kind eq 'literal';
        $fail->() if !$opts{for_rules} && defined($alias) && $field eq $alias && exists($command->assignments->{$field}) && !defined($value);
        my $metadata = $dbh->sqlite_table_column_metadata('main', $table, $field);
        $fail->() unless ref($metadata) eq 'HASH';
        my $declared = uc($metadata->{data_type} // '');
        my $collation = uc($metadata->{collation_name} // '');
        my $type = $types->{$field};
        my $cast;
        if ($type eq 'integer' || $type eq 'boolean') {
            $fail->() unless $declared =~ /INT/ || ($type eq 'boolean' && $declared eq 'BOOLEAN');
            $cast = 'INTEGER';
        } elsif ($type eq 'decimal') {
            $fail->() unless $declared =~ /\A(?:NUMERIC|DECIMAL)(?:\(\s*\d+\s*(?:,\s*\d+\s*)?\))?\z/;
            $cast = 'NUMERIC';
        } else {
            $fail->() unless $declared !~ /INT/ && $declared =~ /CHAR|CLOB|TEXT/;
            $fail->() unless $collation =~ /\A(?:BINARY|NOCASE|RTRIM)\z/;
            $cast = 'TEXT';
        }
        $storage{$field} = {cast => $cast,
            $type eq 'string' ? (collation => $self->quote_identifier($collation)) : ()};
    }
    return \%storage;
}

sub supports {
    my ($self, $feature) = @_;
    return $self->_returning_available if "$feature" eq 'returning';
    return $self->_sqlite_version_at_least(3, 28, 0) if "$feature" eq 'window_functions';
    return $self->_sqlite_version_at_least(3, 8, 3)
        if "$feature" eq 'cte' || "$feature" eq 'recursive_cte';
    return $self->_json_available if "$feature" =~ /\A(?:json_rowset|json_contains|json_text|array_rowset|array_predicates)\z/;
    return $self->_json_available && $self->_sqlite_version_at_least(3, 35, 0)
        if "$feature" eq 'ordered_related_collections' || "$feature" eq 'bounded_related_collections';
    return $self->_fts5_available if "$feature" eq 'text_search';
    return $self->_sqlite_version_at_least(3, 26, 0) if "$feature" eq 'schema_introspection';
    return "$feature" eq 'transactions' || "$feature" eq 'set_operations'
        || "$feature" eq 'stream' || "$feature" eq 'value_expressions'
        || "$feature" eq 'rollup' ? 1 : 0;
}

my %ROLLUP_AGGREGATES = map { $_ => 1 } qw(
    count count_field count_distinct sum sum_zero avg min max
    true_count false_count true_percentage count_bucket
);

sub _emulates_rollup { return 1; }

sub _validate_rollup_projection {
    my ($self, $expression, $dimensions) = @_;
    my $key = Selecto::SQL::_expression_key($expression);
    return if exists($dimensions->{$key}) || $expression->kind eq 'literal'
        || $ROLLUP_AGGREGATES{$expression->kind};
    my ($kind, $args) = ($expression->kind, $expression->arguments);
    if ($kind eq 'grouping') {
        Selecto::Error->throw('invalid_query', 'GROUPING must reference at most 31 rollup dimensions')
            unless ref($args->[0]) eq 'ARRAY' && @{$args->[0]} && @{$args->[0]} <= 31
                && !grep { !exists $dimensions->{Selecto::SQL::_expression_key($_)} } @{$args->[0]};
        return;
    }
    if ($kind eq 'dimension_display') {
        Selecto::Error->throw('invalid_query', 'dimension display requires a rollup dimension')
            unless @$args == 2 && blessed($args->[1]) && $args->[1]->isa('Selecto::Expression')
                && exists $dimensions->{Selecto::SQL::_expression_key($args->[1])};
        return;
    }
    # Scalar compositions may use dimensions, constants, and closed measures.
    # A free field, window, subquery, or unrelated value AST is not a measure.
    Selecto::Error->throw('invalid_query', 'rollup projections require dimensions or closed aggregates')
        if $kind =~ /\A(?:field|value|window|related_collection|recursion_depth)\z/;
    my @children = _rollup_expression_children($args);
    Selecto::Error->throw('invalid_query', 'rollup projections require dimensions or closed aggregates')
        unless @children;
    $self->_validate_rollup_projection($_, $dimensions) for @children;
}

sub _rollup_expression_children {
    my ($value) = @_;
    return ($value) if blessed($value) && $value->isa('Selecto::Expression');
    return map { _rollup_expression_children($_) } @$value if ref($value) eq 'ARRAY';
    return map { _rollup_expression_children($value->{$_}) } sort keys %$value if ref($value) eq 'HASH';
    return ();
}

sub _compile_rollup {
    my ($self, $domain, $query, %options) = @_;
    my $groups = $query->groups;
    my %dimensions;
    for my $index (0 .. $#$groups) {
        my $key = Selecto::SQL::_expression_key($groups->[$index]);
        Selecto::Error->throw('invalid_query', 'rollup requires at most 31 distinct dimensions')
            if @$groups > 31 || exists $dimensions{$key};
        $dimensions{$key} = $index;
    }
    Selecto::Error->throw('invalid_query', 'rollup requires at least one dimension') unless @$groups;
    Selecto::Error->throw('unsupported_feature', 'adapter does not support row locks')
        if defined $query->row_lock;
    my $selections = $query->selections;
    Selecto::Error->throw('invalid_query', 'query must select at least one expression') unless @$selections;
    $self->_validate_rollup_projection($_, \%dimensions) for @$selections;
    my @columns = map { $self->_selection_name($_) } @$selections;
    my @aliased = map { $selections->[$_]->as($columns[$_]) } 0 .. $#$selections;
    my (@branches, @params);
    for (my $level = @$groups; $level >= 0; $level--) {
        my $branch = $query->_copy(
            selections => \@aliased,
            grouping_mode => 'plain', groups => $level ? [@$groups[0 .. $level - 1]] : [],
            orders => [], limit_value => undef, offset_value => undef,
        );
        my $statement = $self->_compile_single($domain, $branch, %options,
            rollup_projection => {dimensions => \%dimensions, level => $level});
        # A derived table also keeps branch-local WITH clauses legal in a union.
        push @branches, 'SELECT * FROM (' . $statement->sql . ') AS '
            . $self->quote_identifier('__selecto_rollup_branch' . $level);
        push @params, @{$statement->params};
    }
    my $sql = 'SELECT * FROM (' . join(' UNION ALL ', @branches) . ') AS '
        . $self->quote_identifier('__selecto_rollup');
    my @orders;
    for my $order (@{$query->orders}) {
        my $key = Selecto::SQL::_expression_key($order->[0]);
        my ($position) = grep {
            Selecto::SQL::_expression_key($selections->[$_]) eq $key
                || ($order->[0]->kind eq 'field' && $order->[0]->arguments->[0] eq $columns[$_])
        } 0 .. $#$selections;
        Selecto::Error->throw('invalid_query', 'rollup ordering must reference a selected output column')
            unless defined $position;
        push @orders, ($position + 1) . ' ' . uc($order->[1]);
    }
    my ($marker) = grep {
        $selections->[$_]->kind eq 'grouping'
            && Selecto::SQL::_value_key($selections->[$_]->arguments->[0]) eq Selecto::SQL::_value_key($groups)
    } 0 .. $#$selections;
    if (@orders) {
        $_ .= @$groups == 1 && defined($marker) ? ' NULLS LAST' : ' NULLS FIRST' for @orders;
        if (defined $marker) {
            @$groups == 1 ? unshift(@orders, ($marker + 1) . ' DESC')
                : push(@orders, ($marker + 1) . ' DESC');
        }
        $sql .= ' ORDER BY ' . join(', ', @orders);
    }
    $sql .= $self->_compile_pagination($query->limit_value, $query->offset_value, @orders ? 1 : 0);
    return Selecto::Statement->new(sql => $sql, params => \@params,
        columns => \@columns, adapter_name => $self->name);
}

sub _compile_selection_expression {
    my ($self, $domain, $expression, $params, $compiled_selections, $options) = @_;
    local $self->{_rollup_branch} = $options->{rollup_projection};
    local $self->{_rollup_projection} = defined $self->{_rollup_branch};
    my $sql = $self->_compile_expression($domain, $expression, $params, $compiled_selections);
    # COUNT forces the empty grouping set to yield one row even with no measure.
    return $self->{_rollup_branch} && $self->{_rollup_branch}{level} == 0
        ? 'CASE WHEN COUNT(*) >= 0 THEN ' . $sql . ' END' : $sql;
}

sub _compile_expression {
    my ($self, $domain, $expression, $params, $compiled_selections) = @_;
    my $branch = $self->{_rollup_branch};
    if ($branch && blessed($expression) && $expression->isa('Selecto::Expression')) {
        my $key = Selecto::SQL::_expression_key($expression);
        if ($self->{_rollup_projection} && exists $branch->{dimensions}{$key}) {
            return 'NULL' if $branch->{dimensions}{$key} >= $branch->{level};
            local $self->{_rollup_projection} = 0;
            return $self->SUPER::_compile_expression($domain, $expression, $params, $compiled_selections);
        }
        if ($expression->kind eq 'grouping') {
            $self->_validate_rollup_projection($expression, $branch->{dimensions});
            my $marker = 0;
            for my $dimension (@{$expression->arguments->[0]}) {
                my $index = $branch->{dimensions}{Selecto::SQL::_expression_key($dimension)};
                Selecto::Error->throw('invalid_query', 'GROUPING must reference rollup dimensions') unless defined $index;
                $marker = ($marker << 1) | ($index >= $branch->{level} ? 1 : 0);
            }
            return "$marker";
        }
        if ($expression->kind eq 'dimension_display') {
            my ($display, $dimension) = @{$expression->arguments};
            my $index = $branch->{dimensions}{Selecto::SQL::_expression_key($dimension)};
            Selecto::Error->throw('invalid_query', 'dimension display requires a rollup dimension') unless defined $index;
            return 'NULL' if $index >= $branch->{level};
            local $self->{_rollup_projection} = 0;
            return 'MIN(' . $self->_compile_expression($domain, $display, $params) . ')';
        }
        if ($ROLLUP_AGGREGATES{$expression->kind}) {
            local $self->{_rollup_projection} = 0;
            return $self->SUPER::_compile_expression($domain, $expression, $params, $compiled_selections);
        }
    }
    Selecto::Error->throw('unsupported_feature', 'SQLite grouping markers require a rollup projection')
        if blessed($expression) && $expression->isa('Selecto::Expression')
            && ($expression->kind eq 'grouping' || $expression->kind eq 'dimension_display');
    return $self->SUPER::_compile_expression($domain, $expression, $params, $compiled_selections);
}

sub _validate_numeric_parameter {
    my ($self, $value) = @_;
    my $type = Selecto::SQL::_numeric_scalar_type($value);
    return unless defined $type;
    if ($type eq 'INTEGER') {
        my $text = "$value";
        my $bound = $text =~ s/\A-// ? '9223372036854775808' : '9223372036854775807';
        Selecto::Error->throw('invalid_query', 'SQLite integer literal exceeds signed 64-bit storage')
            if length($text) > length($bound)
                || (length($text) == length($bound) && $text gt $bound);
    } elsif ($type eq 'REAL') {
        Selecto::Error->throw('invalid_query', 'SQLite numeric literal must be finite') unless isfinite($value);
    }
    return $type;
}

sub admit_parameters {
    my ($self, $budget, $parameters, @options) = @_;
    my $result = $self->SUPER::admit_parameters($budget, $parameters, @options);
    $self->_validate_numeric_parameter($_) for @$parameters;
    return $result;
}

# SQLite stores bound text as TEXT; only integer affinity changes ordering.
sub _values_cast_types {
    return { integer => 'INTEGER', int => 'INTEGER', bigint => 'INTEGER' };
}

sub _sqlite_value_types {
    return { integer => 'INTEGER', int => 'INTEGER', bigint => 'INTEGER',
        string => 'TEXT', text => 'TEXT', decimal => 'REAL', numeric => 'REAL',
        number => 'REAL', boolean => 'INTEGER', date => 'TEXT',
        datetime => 'TEXT', utc_datetime => 'TEXT', json => 'TEXT', jsonb => 'TEXT', uuid => 'TEXT' };
}

sub _value_type_sql {
    my ($self, $type) = @_;
    my $cast = $self->_sqlite_value_types->{lc "$type"};
    Selecto::Error->throw('unsupported_feature', "SQLite cannot cast value expressions to $type") unless $cast;
    return $cast;
}

sub write_capabilities {
    my ($self) = @_;
    my $capabilities = $self->SUPER::write_capabilities;
    $capabilities->{typed_insert_admission} = 1;
    my $native_upsert = eval {
        my $dbh = $self->dbh;
        Selecto::SQLite::UpsertCandidate::_native_handle($dbh)
            && $dbh->can('sqlite_get_autocommit') && $dbh->can('sqlite_table_column_metadata');
    };
    $capabilities->{protected_upsert_candidates} = $native_upsert && $self->_sqlite_version_at_least(3, 37, 0) ? 1 : 0;
    if ($self->_returning_available) {
        $capabilities->{returning} = 1;
        $capabilities->{generated_keys} = 1;
    }
    if ($self->_returning_available && $self->_sqlite_version_at_least(3, 37, 0)) {
        $capabilities->{write_graph} = 1;
        $capabilities->{owned_set_sync} = 1;
    }
    return $capabilities;
}

sub _returning_available {
    my ($self) = @_;
    return $self->_sqlite_version_at_least(3, 35, 0);
}

sub _sqlite_version_at_least {
    my ($self, $required_major, $required_minor, $required_patch) = @_;
    $required_patch //= 0;
    my $key = "_sqlite_version_${required_major}_${required_minor}_${required_patch}";
    return $self->{$key} if exists $self->{$key};
    my $version = eval { ($self->dbh->selectrow_array('SELECT sqlite_version()'))[0] };
    my ($major, $minor, $patch) = defined($version) && "$version" =~ /\A(\d+)\.(\d+)\.(\d+)\z/
        ? (0 + $1, 0 + $2, 0 + $3) : (0, 0, 0);
    return $self->{$key} = (
        $major > $required_major
            || ($major == $required_major && ($minor > $required_minor
                || ($minor == $required_minor && $patch >= $required_patch)))
    ) ? 1 : 0;
}

sub bounded_stream_supported {
    my ($self) = @_;
    return $self->SUPER::bounded_stream_supported && $self->_sqlite_version_at_least(3, 35, 0);
}

sub _server_transaction_open {
    my ($self) = @_;
    return eval { !$self->dbh->sqlite_get_autocommit } ? 1 : 0;
}

# Preserve caller-owned transactions and query_only exactly. The guard also
# covers SELECT functions that attempt database writes while rows are fetched.
sub _read_only {
    my ($self, $operation) = @_;
    my $dbh = $self->dbh;
    return $operation->() unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'SQLite' };
    my ($prior) = $dbh->selectrow_array('PRAGMA query_only');
    Selecto::Error->throw('query_error', 'SQLite read-only state is unavailable') unless defined $prior;
    my ($ok, $value, $error);
    eval {
        defined($dbh->do('PRAGMA query_only = ON')) or die 'read-only guard failed';
        $value = $operation->();
        $ok = 1;
        1;
    } or $error = $self->normalize_error($@);
    my $restored = eval { defined($dbh->do('PRAGMA query_only = ' . ($prior ? 'ON' : 'OFF'))) };
    Selecto::Error->throw('query_error', 'SQLite read-only state could not be restored') unless $restored;
    die $error unless $ok;
    return $value;
}

sub _query_transport_sql {
    my ($self, $statement) = @_;
    return $statement->sql if $self->{_sqlite_query_unsafe};
    Selecto::Error->throw('invalid_query', 'SQLite query requires a Selecto statement')
        unless blessed($statement) && $statement->isa('Selecto::Statement');
    my $tokens = $statement->sql;
    # SQLite quotes/comments are removed only for statement-boundary checks;
    # the original SQL is prepared, without rewriting literals or identifiers.
    $tokens =~ s{('(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\])|--[^\n]*(?:\n|\z)|/\*.*?\*/}{defined($1) ? ' ' : ''}gse;
    Selecto::Error->throw('query_error', 'SQLite queries require one read-only SELECT statement')
        unless $tokens =~ /\A\s*(?:EXPLAIN(?:\s+QUERY\s+PLAN)?\s+)?(?:SELECT|WITH)\b/i
        && $tokens !~ /;\s*\S/;
    return $statement->sql;
}

sub execute_query {
    my ($self, $statement, @options) = @_;
    $self->_query_transport_sql($statement);
    return $self->_read_only(sub {
        my ($sth, $rows);
        my $ok = eval {
            $sth = $self->dbh->prepare($statement->sql);
            die Selecto::SQL::_dbi_error($self->dbh, 'database query preparation failed') unless $sth;
            defined($self->_execute_statement($sth, $statement->params))
                or die Selecto::SQL::_dbi_error($sth, 'database query execution failed');
            my @types = $self->_column_types($sth);
            $rows = $sth->fetchall_arrayref;
            die Selecto::SQL::_dbi_error($sth, 'database query fetch failed')
                unless ref($rows) eq 'ARRAY' && !eval { $sth->err };
            $self->_decode_rows($rows, \@types);
            1;
        };
        my $error = $ok ? undef : $self->normalize_error($@);
        eval { $sth->finish } if $sth;
        die $error unless $ok;
        return {columns => $statement->columns, rows => $rows};
    });
}

# Explicit trusted adapter tooling; governed Engine reads never use this.
sub execute_query_unsafe {
    my ($self, @arguments) = @_;
    local $self->{_sqlite_query_unsafe} = 1;
    return $self->SUPER::execute_query(@arguments);
}

sub _execute_statement {
    my ($self, $sth, $params) = @_;
    my $native = blessed($sth) && $sth->isa('DBI::st')
        && $sth->{Database}{Driver}{Name} eq 'SQLite';
    my $result;
    if ($native) {
        for my $index (0 .. $#$params) {
            my $value = $params->[$index];
            my $type = $self->_validate_numeric_parameter($value);
            $value = $value ? 1 : 0 if JSON::PP::is_bool($value);
            my $bound = $sth->bind_param($index + 1, $value,
                !defined($type) ? SQL_VARCHAR : $type eq 'INTEGER' ? SQL_INTEGER : SQL_DOUBLE);
            die Selecto::SQL::_dbi_error($sth, 'database parameter binding failed') unless defined $bound;
        }
        $result = $sth->execute;
    } else {
        $result = $self->SUPER::_execute_statement($sth, $params);
    }
    die Selecto::SQL::_dbi_error($sth, 'database statement execution failed') unless defined $result;
    return $result;
}

sub stream_query {
    my ($self, $statement, @options) = @_;
    $self->_query_transport_sql($statement);
    my $stream = $self->_read_only(sub { $self->SUPER::stream_query($statement, @options) });
    $stream->{sqlite_adapter} = $self;
    return bless $stream, 'Selecto::SQLite::Stream';
}

sub _compile_pagination {
    my ($self, $limit, $offset, @rest) = @_;
    return ' LIMIT -1 OFFSET ' . int($offset) if !defined($limit) && defined($offset);
    return $self->SUPER::_compile_pagination($limit, $offset, @rest);
}

sub explain_query {
    my ($self, $statement) = @_;
    $self->_query_transport_sql($statement);
    return $self->execute_query(Selecto::Statement->new(sql => 'EXPLAIN QUERY PLAN ' . $statement->sql,
        params => $statement->params, columns => [qw(id parent notused detail)], adapter_name => $self->name));
}

sub introspect_schema {
    my ($self) = @_;
    Selecto::Error->throw('unsupported_feature', 'SQLite schema introspection requires SQLite 3.26.0')
        unless $self->supports('schema_introspection');
    return $self->_read_only(sub {
        my $dbh = $self->dbh;
        my $tables = $dbh->selectall_arrayref(q{SELECT name, type FROM main.sqlite_master
            WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name}, {Slice => {}});
        for my $table (@$tables) {
            my $name = $self->quote_identifier($table->{name});
            $table->{columns} = $dbh->selectall_arrayref("PRAGMA main.table_xinfo($name)", {Slice => {}});
            $_->{normalized_type} = $self->normalize_type($_->{type}) for @{$table->{columns}};
            $table->{foreign_keys} = $dbh->selectall_arrayref("PRAGMA main.foreign_key_list($name)", {Slice => {}});
            $table->{indexes} = $dbh->selectall_arrayref("PRAGMA main.index_list($name)", {Slice => {}});
            for my $index (@{$table->{indexes}}) {
                $index->{columns} = $dbh->selectall_arrayref('PRAGMA main.index_xinfo(' . $self->quote_identifier($index->{name}) . ')', {Slice => {}});
            }
        }
        return {tables => $tables};
    });
}

sub feature_inventory {
    my ($self) = @_;
    return [@{$self->SUPER::feature_inventory}, qw(value_expressions json_text json_contains array_rowset array_predicates
        ordered_related_collections bounded_related_collections)];
}

sub _json_available {
    my ($self) = @_;
    return $self->{_sqlite_json_available} if exists $self->{_sqlite_json_available};
    my $available = eval {
        my $dbh = $self->dbh;
        die 'SQLite JSON function registration unavailable' unless $dbh->can('sqlite_create_function');
        my ($valid) = $dbh->selectrow_array(q{SELECT json_valid('[]')});
        die 'SQLite JSON unavailable' unless $valid;
        my $registered = $dbh->sqlite_create_function('selecto_json_contains', 2, sub {
            my ($source, $needle) = @_;
            return undef unless defined($source) && defined($needle);
            my ($left, $right);
            my $json = Cpanel::JSON::XS->new->allow_nonref(1)->allow_bignum(1);
            return 0 unless eval { $left = $json->decode($source); $right = $json->decode($needle); 1 };
            return _json_contains_value($left, $right) ? 1 : 0;
        });
        die 'SQLite JSON function registration failed' unless $registered;
        1;
    };
    return $self->{_sqlite_json_available} = $available ? 1 : 0;
}

# SQLite extracts JSON booleans as SQL integers. Structural containment must
# retain their JSON types, object-key presence and recursively matched arrays.
# This adapter-owned scalar function provides those semantics on every JSON1
# provider, without relying on textual JSON equality or lossy SQL coercion.
sub _json_contains_value {
    my ($source, $needle, $nested) = @_;
    # PostgreSQL jsonb permits only a root array to contain a primitive RHS.
    # Recursive object members and array elements still require matching shapes.
    if (!$nested && ref($source) eq 'ARRAY' && ref($needle) ne 'ARRAY' && ref($needle) ne 'HASH') {
        return scalar(grep { _json_contains_value($_, $needle, 1) } @$source) ? 1 : 0;
    }
    if (ref($needle) eq 'HASH') {
        return 0 unless ref($source) eq 'HASH';
        for my $key (keys %$needle) {
            return 0 unless exists($source->{$key}) && _json_contains_value($source->{$key}, $needle->{$key}, 1);
        }
        return 1;
    }
    if (ref($needle) eq 'ARRAY') {
        return 0 unless ref($source) eq 'ARRAY';
        for my $element (@$needle) {
            return 0 unless grep { _json_contains_value($_, $element, 1) } @$source;
        }
        return 1;
    }
    return !defined($source) ? 1 : 0 unless defined $needle;
    return 0 unless defined $source;
    if (JSON::PP::is_bool($needle) || JSON::PP::is_bool($source)) {
        return JSON::PP::is_bool($needle) && JSON::PP::is_bool($source)
            && ($source ? 1 : 0) == ($needle ? 1 : 0) ? 1 : 0;
    }
    return 0 if ref($source) eq 'HASH' || ref($source) eq 'ARRAY';
    my $json = Cpanel::JSON::XS->new->allow_nonref(1)->allow_bignum(1);
    my $left = $json->encode($source);
    my $right = $json->encode($needle);
    my $left_string = $left =~ /\A"/;
    my $right_string = $right =~ /\A"/;
    return 0 if $left_string != $right_string;
    return $source eq $needle ? 1 : 0 if $left_string;
    return $source == $needle ? 1 : 0;
}

sub _compile_json_contains { return 'selecto_json_contains(' . $_[1] . ', ' . $_[2] . ')'; }

sub _json_path {
    my ($self, $segments) = @_;
    return '$' . join('', map { /\A\d+\z/ ? '[' . int($_) . ']' : '."' . $_ . '"' } @$segments);
}

sub _compile_json_text {
    my ($self, $source, $segments, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'SQLite JSON functions are unavailable')
        unless $self->supports('json_text');
    push @$params, $self->_json_path($segments);
    return '(SELECT CASE JSON_TYPE(__selecto_json.doc, __selecto_json.path) '
        . q{WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' WHEN 'null' THEN NULL }
        . 'ELSE CAST(JSON_EXTRACT(__selecto_json.doc, __selecto_json.path) AS TEXT) END '
        . 'FROM (SELECT ' . $source . ' AS doc, ' . $self->placeholder(scalar @$params)
        . ' AS path) AS __selecto_json)';
}

sub _compile_array_predicate {
    my ($self, $kind, $source, $type, $values, $params) = @_;
    if ($type =~ /\A(?:integer|decimal|boolean)\z/) {
        for my $value (@$values) {
            Selecto::Error->throw('invalid_query', 'SQLite array predicate requires canonical typed elements')
                unless eval { Selecto::InsertAdmission::_value($type, $value, 'array element'); 1 };
            Selecto::Error->throw('invalid_query', 'SQLite array element must be finite')
                if $type eq 'decimal' && '' . (0 + $value) =~ /inf|nan/i;
        }
    }
    my @typed = map {
        $type eq 'integer' ? 0 + $_ : $type eq 'boolean' ? ($_ ? JSON::PP::true : JSON::PP::false)
            : $type eq 'decimal' ? 0 + $_ : "$_"
    } @$values;
    push @$params, Cpanel::JSON::XS->new->canonical(1)->encode(\@typed);
    my $marker = $self->placeholder(scalar @$params);
    return 'selecto_json_contains(' . ($kind eq 'array_contained' ? "$marker, $source" : "$source, $marker") . ')'
        if $kind ne 'array_overlap';
    return '(SELECT CASE WHEN __selecto_overlap.doc IS NULL THEN NULL '
        . 'WHEN NOT JSON_VALID(__selecto_overlap.doc) THEN 0 '
        . q{WHEN JSON_TYPE(__selecto_overlap.doc) != 'array' THEN 0 ELSE EXISTS (}
        . 'SELECT 1 FROM JSON_EACH(__selecto_overlap.doc) AS __selecto_array '
        . 'INNER JOIN JSON_EACH(__selecto_overlap.needle) AS __selecto_needle '
        . q{ON (__selecto_array.type = __selecto_needle.type OR (__selecto_array.type IN ('integer','real') }
        . q{AND __selecto_needle.type IN ('integer','real'))) AND __selecto_array.value IS __selecto_needle.value) }
        . 'END FROM (SELECT ' . $source . ' AS doc, ' . $marker . ' AS needle) AS __selecto_overlap)';
}

sub _query_sources {
    my ($self, $domain, $query) = @_;
    my $sources = $self->SUPER::_query_sources($domain, $query);
    for my $spec (@{$query->json_rowsets}) {
        $sources->{$spec->{name}} = {map { $_ => {sqlite_json_type => $spec->{columns}{$_}} } keys %{$spec->{columns}}};
    }
    for my $spec (@{$query->array_rowsets}) {
        $sources->{$spec->{name}}{value} = {sqlite_array_type => $self->_array_element_type($domain, $spec->{source_field}, 'array rowset source')};
        $sources->{$spec->{name}}{$spec->{ordinality}} = {sqlite_ordinality => 1} if defined $spec->{ordinality};
    }
    return $sources;
}

sub _field_sql {
    my ($self, $domain, $path, $params) = @_;
    my ($alias, $field, @rest) = split /\./, "$path";
    my $spec = !@rest && defined($field) && ref($self->{_query_sources}) eq 'HASH'
        && exists($self->{_query_sources}{$alias})
        ? $self->{_query_sources}{$alias}{$field} : undef;
    if (ref($spec) eq 'HASH') {
        return '(CAST(' . $self->_qualified($alias, 'key') . ' AS INTEGER) + 1)' if $spec->{sqlite_ordinality};
        my $type = lc($spec->{sqlite_json_type} // $spec->{sqlite_array_type});
        my $cast = $self->_sqlite_value_types->{$type};
        Selecto::Error->throw('invalid_query', "JSON rowset type $type is not portable") unless $cast;
        my $value = $self->_qualified($alias, 'value');
        if (exists $spec->{sqlite_json_type}) {
            push @$params, '$."' . $field . '"';
            $value = '(SELECT JSON_EXTRACT(__selecto_record.doc, __selecto_record.path) '
                . 'FROM (SELECT CASE WHEN ' . $self->_qualified($alias, 'type') . q{ = 'object' THEN }
                . $value . ' END AS doc, ' . $self->placeholder(scalar @$params) . ' AS path) AS __selecto_record)';
        }
        return 'CAST(' . $value . ' AS ' . $cast . ')';
    }
    return $self->SUPER::_field_sql($domain, $path, $params);
}

sub _json_rowset_source {
    my ($self, $source, $path, $params) = @_;
    $path //= '$';
    Selecto::Error->throw('unsupported_feature', 'SQLite JSON rowset path requires a direct array path')
        unless !ref($path) && "$path" =~ /\A\$(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[\d+\]))*(?:\[\*\])?\z/;
    $path =~ s/\[\*\]\z//;
    push @$params, "$path";
    return '(SELECT CASE WHEN JSON_TYPE(__selecto_rows.items) = '
        . q{'array' THEN __selecto_rows.items ELSE '[]' END FROM (SELECT JSON_EXTRACT(}
        . 'CASE WHEN JSON_VALID(__selecto_doc.doc) THEN __selecto_doc.doc END, '
        . $self->placeholder(scalar @$params) . ') AS items FROM (SELECT ' . $source
        . ' AS doc) AS __selecto_doc) AS __selecto_rows)';
}

sub _compile_json_rowset_join {
    my ($self, $domain, $spec, $params) = @_;
    Selecto::Error->throw('invalid_query', 'JSON rowset source must be a JSON field')
        unless ($domain->resolve($spec->{source_field})->{type} // '') =~ /\Ajsonb?\z/i;
    for my $type (values %{$spec->{columns}}) {
        Selecto::Error->throw('invalid_query', "JSON rowset type $type is not portable")
            unless $self->_sqlite_value_types->{lc "$type"};
    }
    my @source_params;
    my $source = $self->_field_sql($domain, $spec->{source_field}, \@source_params);
    my $array = $self->_json_rowset_source($source, $spec->{path}, $params);
    push @$params, @source_params;
    my $keyword = $spec->{type} eq 'left' ? 'LEFT JOIN' : 'INNER JOIN';
    return $keyword . ' JSON_EACH(' . $array . ') AS ' . $self->quote_identifier($spec->{name})
        . ' ON ' . $self->_qualified($spec->{name}, 'type') . q{ = 'object'};
}

sub _compile_array_rowset_join {
    my ($self, $spec, $source) = @_;
    my $array = '(SELECT CASE WHEN JSON_TYPE(CASE WHEN JSON_VALID(__selecto_array.doc) '
        . 'THEN __selecto_array.doc END) = ' . q{'array' THEN __selecto_array.doc ELSE '[]' END }
        . 'FROM (SELECT ' . $source . ' AS doc) AS __selecto_array)';
    return ($spec->{type} eq 'left' ? 'LEFT JOIN' : 'CROSS JOIN') . ' JSON_EACH(' . $array . ') AS '
        . $self->quote_identifier($spec->{name}) . ($spec->{type} eq 'left' ? ' ON TRUE' : '');
}

sub _compile_value_expression {
    my ($self, $domain, $node, $params) = @_;
    if ($node->[0] eq 'concat') {
        return '(' . join(' || ', map {
            'COALESCE(CAST(' . $self->_compile_value_expression($domain, $_, $params) . q{ AS TEXT), '')}
        } @$node[1 .. $#$node]) . ')';
    }
    return $self->SUPER::_compile_value_expression($domain, $node, $params);
}

sub _compile_timezone_sql {
    my ($self, $sql, $type, $timezone) = @_;
    Selecto::Error->throw('unsupported_feature', 'SQLite requires UTC for explicit query timezones')
        unless $timezone eq 'UTC';
    return $type eq 'epoch_datetime' ? "DATETIME($sql, 'unixepoch')" : "DATETIME($sql)";
}

sub _governed_dialect_field {
    my ($self, $domain, $field) = @_;
    Selecto::Error->throw('invalid_query', 'dialect expression requires a governed field')
        unless blessed($field) && $field->isa('Selecto::Expression') && $field->kind eq 'field';
    return $domain->resolve($field->arguments->[0]);
}

sub _compile_dialect_expression {
    my ($self, $domain, $expression, $params) = @_;
    my ($kind, $arguments) = ($expression->kind, $expression->arguments);
    return $self->_compile_bucket($domain, @$arguments, $params) if $kind eq 'bucket';
    return $self->_compile_count_bucket($domain, @$arguments, $params) if $kind eq 'count_bucket';
    return $self->_compile_text_search($domain, $expression, $params)
        if $kind eq 'text_search' || $kind eq 'text_rank';
    if ($kind eq 'epoch_datetime') {
        my $resolved = $self->_governed_dialect_field($domain, $arguments->[0]);
        Selecto::Error->throw('invalid_query', 'epoch datetime requires an epoch datetime field')
            unless $resolved->{type} eq 'epoch_datetime';
        local $self->{_suppress_field_timezone} = 1;
        return 'DATETIME(' . $self->_compile_expression($domain, $arguments->[0], $params) . q{, 'unixepoch')};
    }
    return $self->_compile_datetime_format($domain, @$arguments, $params) if $kind eq 'datetime_format';
    return $self->SUPER::_compile_dialect_expression($domain, $expression, $params);
}

sub _fts5_available {
    my ($self) = @_;
    return $self->{_sqlite_fts5_available} if exists $self->{_sqlite_fts5_available};
    my $available = eval {
        require Selecto::SQLite::FtsIndex;
        $self->dbh->isa('DBI::db') && $self->dbh->{Driver}{Name} eq 'SQLite'
            && grep { $_->[0] eq 'fts5' } @{Selecto::SQLite::FtsIndex::_rows($self->dbh, 'PRAGMA module_list')};
    };
    return $self->{_sqlite_fts5_available} = $available ? 1 : 0;
}

# Native BM25 scores are smaller for stronger matches. Public rank values
# retain that native representation; lookup ordering chooses the best first.
sub text_search_rank_direction { return 'asc'; }

sub _compile_text_search {
    my ($self, $domain, $expression, $params) = @_;
    # Both supported FTS shapes prove their catalog and index in main. A
    # prefixed root must not borrow those matches solely through equal rowids.
    my $read_prefix = $domain->{_read_prefix};
    Selecto::Error->throw('unsupported_feature', 'SQLite FTS5 currently requires a main-schema read root')
        if defined($read_prefix) && $read_prefix !~ /\A[mM][aA][iI][nN]\z/;
    Selecto::Error->throw('unsupported_feature', 'SQLite FTS5 is unavailable') unless $self->_fts5_available;
    my ($fields, $literal, $options) = @{$expression->arguments};
    if (defined $domain->fts5_index) {
        require Selecto::SQLite::FtsIndex;
        return Selecto::SQLite::FtsIndex->compile($self, $domain, $expression, $params);
    }
    Selecto::Error->throw('invalid_query', 'SQLite text search requires governed FTS5 fields')
        unless ref($fields) eq 'ARRAY' && @$fields && @$fields <= 128;
    my @columns;
    for my $field (@$fields) {
        my $resolved = $self->_governed_dialect_field($domain, $field);
        Selecto::Error->throw('unsupported_feature', 'SQLite text search requires fields declared fts5 on the root FTS table')
            unless !$resolved->{association} && ($resolved->{type} // '') =~ /\A(?:fts5|text_search_document)\z/;
        push @columns, $resolved->{field};
    }
    require Selecto::SQLite::FtsIndex;
    Selecto::SQLite::FtsIndex->prove_root($self, $domain, \@columns);
    Selecto::Error->throw('invalid_query', 'SQLite text search requires the simple configuration')
        unless ($options->{configuration} // '') eq 'simple';
    Selecto::Error->throw('invalid_query', 'SQLite text search query must be a non-empty literal string')
        unless blessed($literal) && $literal->isa('Selecto::Expression') && $literal->kind eq 'literal'
        && defined($literal->arguments->[0]) && !ref($literal->arguments->[0]) && length($literal->arguments->[0])
        && bytes::length($literal->arguments->[0]) <= 4096;
    my $query = $literal->arguments->[0];
    my $mode = $options->{mode} // 'plain';
    my $prefix = $mode eq 'prefix';
    if ($mode eq 'plain') {
        my @terms = grep { length } split /\s+/, "$query";
        Selecto::Error->throw('invalid_query', 'SQLite text search requires a non-empty term') unless @terms;
        $query = join(' AND ', map { my $term = $_; $term =~ s/"/""/g; '"' . $term . '"' } @terms);
    } elsif ($mode eq 'phrase') {
        $query =~ s/"/""/g;
        $query = '"' . $query . '"';
    } elsif ($prefix) {
        Selecto::Error->throw('invalid_query', 'SQLite prefix search requires normalized word prefixes')
            unless $query =~ /\A[\p{L}\p{N}_]+:\*(?: & [\p{L}\p{N}_]+:\*)*\z/u;
    } elsif ($mode ne 'boolean' && $mode ne 'websearch') {
        Selecto::Error->throw('invalid_query', 'SQLite text search mode is unavailable');
    }
    my $table = $self->quote_identifier($domain->table);
    return "BM25($table)" if $expression->kind eq 'text_rank';
    if ($prefix) {
        push @$params, $query;
        my $placeholder = $self->placeholder(scalar @$params);
        return $self->_qualified($self->_root_alias, $domain->table)
            . " MATCH ('{" . join(' ', @columns) . "}:(' || replace(replace($placeholder, ':*', '*'), ' & ', ' AND ') || ')')";
    }
    push @$params, '{' . join(' ', @columns) . '}:(' . $query . ')';
    return $self->_qualified($self->_root_alias, $domain->table) . ' MATCH ' . $self->placeholder(scalar @$params);
}

sub _compile_datetime_format {
    my ($self, $domain, $field, $format, $params) = @_;
    my $source = $field->kind eq 'epoch_datetime' ? $field->arguments->[0] : $field;
    my $resolved = $self->_governed_dialect_field($domain, $source);
    Selecto::Error->throw('invalid_query', 'datetime format requires a date or time field')
        unless $resolved->{type} =~ /(?:date|time)/i;
    my $sql = $self->_compile_expression($domain, $field, $params);
    $sql = "DATETIME($sql, 'unixepoch')" if $resolved->{type} eq 'epoch_datetime' && $field->kind eq 'field'
        && !defined($self->{_timezone});
    my $value = '__selecto_calendar.value';
    my %formats = (day => '%Y-%m-%d', time => '%H:%M:%S', day_hour => '%Y-%m-%d %H',
        month => '%Y-%m', year => '%Y', month_of_year => '%m', month_day => '%m-%d',
        day_of_month => '%d', day_of_year => '%j', hour => '%H');
    my $result;
    if (exists $formats{$format}) {
        $result = "STRFTIME('$formats{$format}', $value)";
    } elsif ($format eq 'iso8601') {
        my $pattern = $resolved->{type} eq 'date' ? '%Y-%m-%d'
            : $resolved->{type} =~ /\A(?:utc_datetime|epoch_datetime)\z/ ? '%Y-%m-%dT%H:%M:%SZ' : '%Y-%m-%dT%H:%M:%S';
        $result = "STRFTIME('$pattern', $value)";
    } elsif ($format eq 'rfc3339_millis') {
        $result = "STRFTIME('%Y-%m-%dT%H:%M:%fZ', $value)";
    } elsif ($format eq 'epoch_seconds' || $format eq 'epoch_milliseconds') {
        $result = "CAST(STRFTIME('%s', $value) AS INTEGER)";
        $result = "($result * 1000 + CAST(SUBSTR(STRFTIME('%f', $value), 4, 3) AS INTEGER))"
            if $format eq 'epoch_milliseconds';
    } elsif ($format eq 'timezone_offset') {
        $result = "CASE WHEN DATETIME($value) IS NOT NULL THEN '+00:00' END";
    } elsif ($format eq 'day_of_week_num') {
        $result = "((CAST(STRFTIME('%w', $value) AS INTEGER) + 6) % 7 + 1)";
    } elsif ($format eq 'day_of_week') {
        my @names = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
        $result = "CASE STRFTIME('%w', $value) " . join(' ', map { "WHEN '$_' THEN '$names[$_]'" } 0 .. 6) . ' END';
    } elsif ($format eq 'quarter') {
        $result = "STRFTIME('%Y', $value) || '-Q' || CAST((CAST(STRFTIME('%m', $value) AS INTEGER) + 2) / 3 AS INTEGER)";
    } elsif ($format eq 'week' || $format eq 'iso_week' || $format eq 'iso_week_date') {
        # ISO week belongs to the year containing its Thursday, including
        # December/January crossings. This works before SQLite's %G/%V support.
        my $thursday = "DATE($value, '-3 days', 'weekday 4')";
        $result = "STRFTIME('%Y', $thursday) || '-W' || PRINTF('%02d', ((CAST(STRFTIME('%j', $thursday) AS INTEGER) - 1) / 7) + 1)";
        $result .= " || '-' || ((CAST(STRFTIME('%w', $value) AS INTEGER) + 6) % 7 + 1)" if $format eq 'iso_week_date';
        $result = "CASE WHEN DATE($value) IS NOT NULL THEN $result END";
    } else {
        Selecto::Error->throw('invalid_query', 'datetime format is not available');
    }
    return '(SELECT ' . $result . ' FROM (SELECT ' . $sql . ' AS value) AS __selecto_calendar)';
}

sub _compile_count_bucket {
    my ($self, $domain, $field, $spec, $params) = @_;
    my $resolved = $self->_governed_dialect_field($domain, $field);
    Selecto::Error->throw('invalid_query', 'bucket count specification must be an object') unless ref($spec) eq 'HASH';
    my $mode = $spec->{mode} // 'numeric';
    Selecto::Error->throw('invalid_query', 'bucket count mode is not available') unless $mode eq 'numeric' || $mode eq 'elapsed_days';
    Selecto::Error->throw('invalid_query', 'bucket count requires a compatible field')
        unless $mode eq 'numeric' ? $resolved->{type} =~ /(?:int|decimal|number|numeric|float|double|real)/i
            : $resolved->{type} =~ /(?:date|time)/i;
    my ($minimum, $maximum) = @$spec{qw(minimum maximum)};
    Selecto::Error->throw('invalid_query', 'bucket count requires integer boundaries')
        unless (defined($minimum) || defined($maximum))
        && !grep { defined($_) && (ref($_) || "$_" !~ /\A-?\d+\z/) } ($minimum, $maximum);
    my @predicates;
    for my $boundary (['>=', $minimum], ['<=', $maximum]) {
        next unless defined $boundary->[1];
        my $value = $self->_compile_expression($domain, $field, $params);
        $value = "(JULIANDAY('now', 'start of day') - JULIANDAY(DATE($value)))" if $mode eq 'elapsed_days';
        push @$params, 0 + $boundary->[1];
        push @predicates, $value . ' ' . $boundary->[0] . ' CAST(' . $self->placeholder(scalar @$params) . ' AS INTEGER)';
    }
    return 'COUNT(CASE WHEN ' . join(' AND ', @predicates) . ' THEN 1 END)';
}

sub _compile_bucket {
    my ($self, $domain, $field, $spec, $params) = @_;
    my $resolved = $self->_governed_dialect_field($domain, $field);
    Selecto::Error->throw('invalid_query', 'bucket specification must be an object') unless ref($spec) eq 'HASH';
    my $kind = $spec->{kind} // '';
    my $type = $resolved->{type};
    Selecto::Error->throw('invalid_query', 'numeric buckets require a numeric field')
        if $kind =~ /\Anumeric_/ && $type !~ /(?:int|decimal|number|numeric|float|double|real)/i;
    Selecto::Error->throw('invalid_query', 'temporal buckets require a date or time field')
        if $kind =~ /\A(?:year_|elapsed_days_|date_relative_)/ && $type !~ /(?:date|time)/i;
    my @source_params;
    my $source = $self->_compile_expression($domain, $field, \@source_params);
    my $value = '__selecto_bucket.value';
    my $result;
    if ($kind eq 'numeric_increment' || $kind eq 'year_increment') {
        my $increment = $spec->{increment};
        Selecto::Error->throw('invalid_query', 'bucket increment must be a positive integer')
            unless defined($increment) && !ref($increment) && "$increment" =~ /\A[1-9]\d{0,8}\z/;
        $increment = int($increment);
        my $number = $kind eq 'year_increment' ? "CAST(STRFTIME('%Y', $value) AS INTEGER)" : $value;
        my $quotient = "(CAST($number AS REAL) / $increment)";
        my $start = "((CAST($quotient AS INTEGER) - ($quotient < CAST($quotient AS INTEGER))) * $increment)";
        $result = "CASE WHEN $number IS NULL THEN 'Other' ELSE CAST($start AS TEXT) || '-' || CAST(($start + " . ($increment - 1) . ') AS TEXT) END';
    } elsif ($kind eq 'text_prefix') {
        Selecto::Error->throw('invalid_query', 'text prefix bucket requires a text field') unless $type =~ /(?:string|text|char|citext)/i;
        my $length = $spec->{prefix_length} // 2;
        Selecto::Error->throw('invalid_query', 'text prefix length must be between 1 and 10')
            unless !ref($length) && "$length" =~ /\A\d+\z/ && $length >= 1 && $length <= 10;
        my $text = "TRIM(COALESCE(CAST($value AS TEXT), ''))";
        if ($spec->{exclude_articles}) {
            $text = "CASE WHEN LOWER($text) IN ('a','an','the') THEN '' "
                . "WHEN LOWER(SUBSTR($text,1,2)) = 'a ' THEN LTRIM(SUBSTR($text,3)) "
                . "WHEN LOWER(SUBSTR($text,1,3)) = 'an ' THEN LTRIM(SUBSTR($text,4)) "
                . "WHEN LOWER(SUBSTR($text,1,4)) = 'the ' THEN LTRIM(SUBSTR($text,5)) ELSE $text END";
        }
        $result = "CASE WHEN ($text) = '' THEN 'Other' ELSE UPPER(SUBSTR(($text),1," . int($length) . ')) END';
    } else {
        my %ranges = map { $_ => 1 } qw(numeric_ranges elapsed_days_ranges date_relative_ranges year_ranges);
        Selecto::Error->throw('invalid_query', 'bucket kind is not available') unless $ranges{$kind};
        my $ranges = $spec->{ranges};
        Selecto::Error->throw('invalid_query', 'bucket ranges must be a non-empty array') unless ref($ranges) eq 'ARRAY' && @$ranges;
        my $number = $kind eq 'elapsed_days_ranges' ? "(JULIANDAY('now', 'start of day') - JULIANDAY(DATE($value)))"
            : $kind eq 'year_ranges' ? "CAST(STRFTIME('%Y', $value) AS INTEGER)"
            : $kind eq 'date_relative_ranges' ? "DATE($value)" : $value;
        my @clauses;
        for my $range (@$ranges) {
            Selecto::Error->throw('invalid_query', 'bucket range must be an object') unless ref($range) eq 'HASH';
            my ($minimum, $maximum, $label) = @$range{qw(minimum maximum label)};
            Selecto::Error->throw('invalid_query', 'bucket range label is required')
                unless defined($label) && !ref($label) && length("$label") <= 80;
            my @predicates;
            if ($kind eq 'date_relative_ranges' && defined($minimum) && !ref($minimum) && "$minimum" =~ /\A(?:today|yesterday|tomorrow)\z/) {
                Selecto::Error->throw('invalid_query', 'date keyword bucket boundaries must match')
                    unless defined($maximum) && !ref($maximum) && "$maximum" eq "$minimum";
                my $modifier = $minimum eq 'yesterday' ? ', \'-1 day\'' : $minimum eq 'tomorrow' ? ', \'+1 day\'' : '';
                push @predicates, "$number = DATE('now'$modifier)";
            } else {
                Selecto::Error->throw('invalid_query', 'bucket range requires integer boundaries')
                    unless (defined($minimum) || defined($maximum))
                    && !grep { defined($_) && (ref($_) || "$_" !~ /\A-?\d+\z/) } ($minimum, $maximum);
                for my $bound (['>=', $minimum], ['<=', $maximum]) {
                    next unless defined $bound->[1];
                    push @$params, 0 + $bound->[1];
                    my $marker = $self->placeholder(scalar @$params);
                    push @predicates, $kind eq 'date_relative_ranges'
                        ? "$number " . ($bound->[0] eq '>=' ? '<=' : '>=') . " DATE('now', '-' || $marker || ' days')"
                        : "$number $bound->[0] CAST($marker AS INTEGER)";
                }
            }
            push @$params, "$label";
            push @clauses, 'WHEN ' . join(' AND ', @predicates) . ' THEN ' . $self->placeholder(scalar @$params);
        }
        push @$params, 'Other';
        $result = 'CASE ' . join(' ', @clauses) . ' ELSE ' . $self->placeholder(scalar @$params) . ' END';
    }
    push @$params, @source_params;
    return '(SELECT ' . $result . ' FROM (SELECT ' . $source . ' AS value) AS __selecto_bucket)';
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
    Selecto::Error->throw('unsupported_feature', 'SQLite JSON functions are unavailable')
        if eval { $self->dbh->isa('DBI::db') } && !$self->_json_available;
    return '(SELECT JSON_GROUP_ARRAY(JSON(__selecto_children.record)) FROM '
        . '(SELECT JSON_OBJECT(' . join(', ', @pairs) . ') AS record FROM ' . $spec->{from}
        . ' WHERE ' . $spec->{where} . (defined($spec->{order}) ? ' ORDER BY ' . $spec->{order} : '')
        . ') AS __selecto_children)';
}

sub _related_collection_order_term {
    my ($self, $alias, $field, $direction) = @_;
    my $sql = $self->_qualified($alias, $field);
    return "($sql IS NULL) " . uc($direction) . ", $sql " . uc($direction);
}

sub _related_collection_cursor_predicate {
    my ($self, @arguments) = @_;
    my $sql = $self->SUPER::_related_collection_cursor_predicate(@arguments);
    $sql =~ s/IS NOT DISTINCT FROM/IS/g;
    $sql =~ s/IS DISTINCT FROM/IS NOT/g;
    return $sql;
}

sub _related_collection_value_sql {
    my ($self, $field) = @_;
    return $self->SUPER::_related_collection_value_sql($field) if $field->{stringify};
    my $sql = $field->{sql};
    return "(SELECT JSON(CASE WHEN __selecto_bool.value IS NULL THEN 'null' WHEN __selecto_bool.value THEN 'true' ELSE 'false' END) FROM (SELECT $sql AS value) AS __selecto_bool)"
        if ($field->{type} // '') eq 'boolean';
    return "JSON($sql)" if ($field->{type} // '') =~ /\Ajsonb?\z/;
    return $self->SUPER::_related_collection_value_sql($field);
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

package Selecto::SQLite::Stream;
use Mojo::Base 'Selecto::Stream';
sub next {
    my ($self) = @_;
    return undef if $self->closed;
    return $self->{sqlite_adapter}->_read_only(sub { $self->SUPER::next });
}

1;

__END__

=head1 NAME

Selecto::SQLite - SQLite adapter

=head1 SYNOPSIS

  my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
      {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1});
  my $adapter = Selecto->adapter(sqlite => (dbh => $dbh));

=head1 DESCRIPTION

Registered as C<sqlite>; needs L<DBD::SQLite> 1.64 or newer. It uses
double-quoted identifiers and C<?> parameters. Features depend on the SQLite
library version, which the adapter checks once per feature:

=over 4

=item *

CTEs and recursive CTEs need SQLite 3.8.3, window functions including modern
frames need 3.28.0, and C<RETURNING>, write graphs and bounded materialized
results need 3.35.0. Older libraries report the feature as
unsupported rather than emulating it.

=item *

Transactions, portable set operations, streaming and typed value expressions
are available. Offset-only queries use C<LIMIT -1>.

=item *

Rollups use C<UNION ALL> over at most 31 distinct dimensions. Each branch
retains the query's joins and required predicates. Projections must be
dimensions, literals, closed aggregates, or scalar compositions of these.
C<GROUPING> emits explicit integer masks, keeping real NULL groups distinct
from subtotal NULLs. Ordering uses selected expressions or aliases; pagination
applies to the combined result. The grand total exists even on empty input.

=item *

Numeric Perl/JSON parameters use explicit integer or real DBI bindings,
so aggregate comparisons retain numeric semantics. Authored strings use text
bindings even when the host enables numeric guessing, preserving exact decimal
text and leading zeroes. Native integers must fit signed 64-bit storage and
real parameters must be finite.

=item *

JSON extraction, recursive type-aware containment, JSON record rowsets and
JSON-backed typed array predicates/rowsets probe the connected JSON1 functions.
Containment preserves explicit null versus missing keys, booleans versus
numbers, nested object subsets and array-element subsets. Empty objects and
arrays match containers of their own type. A root array may contain a primitive
right-hand value; that exception does not flatten nested arrays or object members.
Repeated object keys use their final value during containment. Array ordinality is one-based.
JSON rowset paths accept direct object/array paths, optionally ending in C<[*]>;
other SQL/JSON path constructs fail closed.

=item *

Calendar formats, UTC instant/epoch formats and numeric, temporal and text
buckets compile to SQLite operations. ISO weeks use the ISO year at calendar
year boundaries. Named IANA timezone conversion, lateral joins and
row locks remain explicitly unsupported. Decimal arithmetic uses SQLite
floating-point storage and cannot promise fixed-scale decimal precision.

=item *

FTS5 is probed through the connected native catalog. Search uses either a
supplied root FTS5 virtual table with fields declared C<fts5> or
C<text_search_document>, or an ordinary table with public string fields and
C<source.fts5_index =E<gt> {table =E<gt> 'items_search', key =E<gt> 'id'}>.
The external index must name that main content table and its sole INTEGER
PRIMARY KEY rowid alias, index the requested stored text columns, and use
C<unicode61> tokenization with full detail. Declarations are checked on each
compilation, including TEMP shadows; the host owns index creation and upkeep.
Plain and phrase modes quote their terms; boolean and websearch modes accept
FTS5 query grammar. Prefix mode binds normalized C<word:*> terms from
L<Selecto::CoDomain>. Search text is bounded to 4096 bytes. Public ranking
retains native negative C<BM25> scores; lookups sort ascending to return
stronger matches first. Configuration must be C<simple>.

=item *

C<DEFAULT> cannot be used as an individual assignment expression.

=back

Related collections use C<JSON_GROUP_ARRAY> over ordered JSON records, preserving
JSON booleans and embedded JSON. SQLite 3.35.0 with JSON1 supports per-parent
limits/cursors, bounded direct/through collections and API subtables. Bounded
collections fetch the limit plus one and refuse a whole response on overflow;
successful API subtable metadata includes the actual limit and C<complete=true>.

C<execute_query> and C<stream_query> accept one read-only SELECT/CTE statement.
Every execution/fetch preserves the caller's C<PRAGMA query_only> state and
transaction ownership, including raw C<BEGIN> transactions. Trusted adapter
tooling can explicitly use C<execute_query_unsafe>; governed reads do not use it.

C<introspect_schema> returns main-schema tables/views, column metadata, foreign
keys and indexes (SQLite 3.26.0 or later). C<explain_query($statement)> executes
the bound C<EXPLAIN QUERY PLAN> and returns its structured columns and rows.

=head1 SEE ALSO

L<Selecto>, L<Selecto::SQL>, L<DBD::SQLite>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
