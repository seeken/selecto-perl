package Selecto::SQLite::UpsertCandidate;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use bytes ();
use JSON::PP ();
use POSIX ();
use Scalar::Util qw(blessed reftype refaddr);
use Hash::Util::FieldHash qw(fieldhash);
use DBI ();
use Selecto::DataRules ();
use Selecto::Limits ();
use Selecto::Error ();
use Selecto::Identifier ();
use Selecto::Write::Capabilities ();
use Selecto::Write::PortableCommand ();
use Selecto::SQLite::Ownership ();

fieldhash my %SCOPES;
fieldhash my %RECEIPTS;
fieldhash my %COMMANDS;
my $LIMITS = Selecto::Limits->new;
my $SERIAL = 0;

sub _pending { Selecto::Error->throw('required_data_rule_pending',
    'SQLite cannot establish the protected UPSERT candidate', {reason => $_[0] // 'native_proof_unavailable'}) }
sub _fold { my $value = $_[0]; $value =~ tr/A-Z/a-z/; return $value }
sub _upper { my $value = $_[0]; $value =~ tr/a-z/A-Z/; return $value }
sub _same { defined($_[0]) && defined($_[1]) && _fold($_[0]) eq _fold($_[1]) }
sub _identity { return Selecto::Write::PortableCommand::_receipt_digest($_[0]) }
sub _plain { return Selecto::DataRules::_copy_plain($_[0], $LIMITS,
    'required_data_rule_pending', 'upsert candidate data') }
sub _check_args { _pending('tied_argument') if grep { defined(tied($_[$_])) } 0 .. $#_ }
sub _native_handle {
    my ($dbh) = @_;
    return unless blessed($dbh) && UNIVERSAL::isa($dbh, 'DBI::db') && reftype($dbh) eq 'HASH';
    my $tied = tied(%$dbh);
    return unless blessed($tied) && UNIVERSAL::isa($tied, 'DBI::db');
    return eval {
        # Require a native DBI-backed handle, not a blessed HASH advertising
        # matching driver names or overriding ordinary Perl DBI accessors.
        my ($outer, $inner) = DBI::_handles($dbh);
        return unless blessed($outer) && blessed($inner)
            && refaddr($outer) == refaddr($dbh) && refaddr($inner) == refaddr($tied)
            && refaddr($outer) != refaddr($inner) && UNIVERSAL::isa($inner, 'DBI::db');
        my $driver = $dbh->{Driver};
        return unless blessed($driver) && UNIVERSAL::isa($driver, 'DBI::dr') && reftype($driver) eq 'HASH';
        my $driver_tied = tied(%$driver);
        return unless blessed($driver_tied) && UNIVERSAL::isa($driver_tied, 'DBI::dr');
        my ($driver_outer, $driver_inner) = DBI::_handles($driver);
        return unless blessed($driver_outer) && blessed($driver_inner)
            && refaddr($driver_outer) == refaddr($driver) && refaddr($driver_inner) == refaddr($driver_tied)
            && refaddr($driver_outer) != refaddr($driver_inner);
        return $driver->{Name} eq 'SQLite' ? $dbh : undef;
    };
}
sub _dbh {
    my ($adapter) = @_;
    my $dbh = $adapter->dbh;
    _pending('native_connection_required') unless _native_handle($dbh);
    return $dbh;
}
sub _scope {
    my ($adapter) = @_;
    my $scope = $SCOPES{$adapter};
    _pending('transaction_scope_required') unless $scope && $scope->{active};
    my $dbh = _dbh($adapter);
    my ($outer, $inner) = DBI::_handles($dbh);
    _pending('transaction_connection_changed') unless refaddr($scope->{dbh}) == refaddr($dbh)
        && refaddr($scope->{inner}) == refaddr($inner);
    _pending('transaction_scope_required') if $dbh->sqlite_get_autocommit;
    _isolated($adapter);
    return $scope;
}

# Snapshot protection rests on SQLite's own read isolation. A shared-cache
# connection with PRAGMA read_uncommitted takes no table read locks: it can
# read another connection's uncommitted rows, and that connection can commit
# or roll back between the candidate proof and the business DML. The adapter
# cannot observe whether the cache is shared (another connection may join it
# later), so the pragma alone refuses, on every check, before business DML.
sub _isolated {
    my ($adapter) = @_;
    my $rows = _rows($adapter, 'PRAGMA read_uncommitted', [], 1);
    _pending('read_isolation_unverifiable') unless @$rows == 1 && @{$rows->[0]} == 1
        && defined($rows->[0][0]) && $rows->[0][0] =~ /\A[01]\z/;
    _pending('read_uncommitted_isolation') if $rows->[0][0];
    return 1;
}

# The engine opens the real adapter transaction before entering this scope.
# Registry lifetime is lexical: raw BEGIN/COMMIT state or serialized metadata
# cannot recreate an expired receipt. Nested adapter calls reuse the registry.
# The scope also carries the live trusted write context of the engine whose
# transaction is running. Receipts are minted only under a matching context
# and every dispatch recheck compares the receipt with the live one, so a
# receipt cannot be dispatched by a nested engine with another context.
sub scope {
    &_check_args;
    my ($class, $adapter, $work, $context) = @_;
    _pending('invalid_scope_callback') unless ref($work) eq 'CODE';
    _pending('invalid_scope_context') unless !defined($context) || ref($context) eq 'HASH' && !defined(tied(%$context));
    $context = _plain($context // {});
    my $dbh = _dbh($adapter);
    if ($SCOPES{$adapter} && _scope($adapter)) {
        my $active = $SCOPES{$adapter};
        my @previous = @{$active}{qw(context context_identity)};
        @{$active}{qw(context context_identity)} = ($context, _identity($context));
        my $restore = bless {finish => sub { @{$active}{qw(context context_identity)} = @previous }},
            'Selecto::SQLite::UpsertCandidate::_Scope';
        my $want = wantarray;
        return $work->() unless defined $want;
        return $want ? $work->() : scalar $work->();
    }
    # DBI AutoCommit=>0 transactions begin lazily, before a plain statement.
    _rows($adapter, 'SELECT 1', [], 1);
    _pending('native_transaction_required') if $dbh->sqlite_get_autocommit;
    _isolated($adapter);
    my ($outer, $inner) = DBI::_handles($dbh);
    my $scope = {dbh => $dbh, inner => $inner, active => 1, subjects => {}, rows => {},
        context => $context, context_identity => _identity($context)};
    $SCOPES{$adapter} = $scope;
    my $guard = bless {finish => sub {
        $scope->{active} = 0;
        delete $RECEIPTS{$_} for values %{$scope->{subjects}};
        $scope->{subjects} = {}; $scope->{rows} = {};
        delete $SCOPES{$adapter};
    }},
        'Selecto::SQLite::UpsertCandidate::_Scope';
    my $want = wantarray;
    return $work->() unless defined $want;
    return $want ? $work->() : scalar $work->();
}

sub project {
    &_check_args;
    my ($class, $adapter, $command, $request) = @_;
    Selecto::Write::Capabilities->requirements($command);
    _pending('upsert_command_required') unless ref($command) eq 'Selecto::Write::Command'
        && $command->operation eq 'upsert' && !defined($command->predicate);
    _pending('invalid_request') unless ref($request) eq 'HASH' && !defined(tied(%$request))
        && keys(%$request) <= 5;
    _pending('invalid_request') if grep { defined(tied($request->{$_})) } keys %$request;
    _pending('invalid_request') if grep { !/\A(?:field_types|dependencies|context|subject|prior)\z/ } keys %$request;
    my $subject = $request->{subject};
    _pending('subject_required') unless ref($subject) && !blessed($subject);
    my $data = _plain({field_types => $request->{field_types}, dependencies => $request->{dependencies},
        context => $request->{context} // {}});
    _pending('invalid_request') unless ref($data->{field_types}) eq 'HASH'
        && keys(%{$data->{field_types}}) && keys(%{$data->{field_types}}) <= 512
        && ref($data->{context}) eq 'HASH';
    my $scope = _scope($adapter);
    _pending('receipt_context_mismatch') unless _identity($data->{context}) eq $scope->{context_identity};
    my $previous = _prior($scope, $subject, $request->{prior}, $data->{context});
    my ($facts, $inserted, $selection, $values, $prior_values, $effect);
    my $ok = eval {
        $facts = _schema($adapter, $command, $data);
        _pending('schema_changed') if $previous && $previous->{schema_identity} ne $facts->{schema_identity};
        my $submitted = _submitted($command, $facts);
        my @keys = grep { !($facts->{schema}{$_}{rowid_alias} && !defined($submitted->{$_})) } @{$facts->{target}};
        $inserted = _project_values($adapter, $facts, 'insert', $submitted, \@keys);
        $selection = _select($adapter, $facts, $inserted);
        _same_selection($previous, $selection) if $previous;
        if ($selection->{branch} eq 'insert') {
            $values = _project_values($adapter, $facts, 'insert', $inserted, $facts->{dependencies});
            $prior_values = {}; $effect = 'insert';
        } else {
            $prior_values = _project_values($adapter, $facts, 'update', $selection->{prior}, $facts->{dependencies});
            my %combined = (%$prior_values, map { exists($inserted->{$_}) ? ($_ => $inserted->{$_}) : () } @{$facts->{mask}});
            _pending('missing_update_assignment') if grep { !exists($inserted->{$_}) } @{$facts->{mask}};
            $values = _project_values($adapter, $facts, 'update', \%combined, $facts->{dependencies});
            $effect = @{$facts->{mask}} ? 'update' : 'nothing';
        }
        1;
    };
    if (!$ok) {
        my $error = $@;
        die $error if ref($error) eq 'Selecto::Error' && $error->code =~ /\A(?:evaluation_limit|required_data_rule_pending)\z/;
        _pending('native_projection_failed');
    }
    my $key = refaddr($subject);
    _pending('subject_limit') if !exists($scope->{subjects}{$key}) && keys(%{$scope->{subjects}}) >= 1024;
    my $witness_key = defined($selection->{physical_id})
        ? _identity([$facts->{table}, $selection->{physical_id}]) : undef;
    _pending('ambiguous_candidate_identity') if defined($witness_key) && exists($scope->{rows}{$witness_key})
        && $scope->{rows}{$witness_key} != $key;
    my $receipt = bless \(my $opaque = undef), 'Selecto::SQLite::UpsertCandidate::_Receipt';
    my $entry = {%$facts, %$selection, scope => $scope, adapter => $adapter, subject => $subject,
        context => $data->{context}, context_identity => _identity($data->{context}),
        command => _identity($command), request => $data, inserted => $inserted,
        values => $values, effect => $effect};
    delete $RECEIPTS{$request->{prior}} if defined($request->{prior});
    $RECEIPTS{$receipt} = $entry;
    $scope->{subjects}{$key} = $receipt;
    $scope->{rows}{$witness_key} = $key if defined $witness_key;
    $COMMANDS{$command} = $receipt;
    return {values => _plain($values), prior_values => _plain($prior_values),
        branch => $selection->{branch}, effect => $effect, complete => 1,
        protection => 'serializable', receipt => $receipt};
}

sub _prior {
    my ($scope, $subject, $receipt, $context) = @_;
    my $latest = $scope->{subjects}{refaddr($subject)};
    return undef if !defined($latest) && !defined($receipt);
    _pending('stale_receipt') unless defined($latest) && ref($receipt)
        && refaddr($latest) == refaddr($receipt) && exists($RECEIPTS{$receipt});
    my $entry = $RECEIPTS{$receipt};
    _pending('receipt_context_mismatch') unless refaddr($entry->{subject}) == refaddr($subject)
        && refaddr($entry->{scope}) == refaddr($scope)
        && $entry->{context_identity} eq _identity($context);
    return $entry;
}

my $command_entry = sub {
    &_check_args;
    my ($class, $adapter, $command) = @_;
    Selecto::Write::Capabilities->requirements($command);
    my $receipt = $COMMANDS{$command};
    if (!$receipt) {
        _pending('receipt_required') if grep { !ref($_) && $_ eq 'protected_upsert_candidates' }
            @{$command->metadata->{required_capabilities} // []};
        return;
    }
    my $scope = _scope($adapter);
    my $entry = $RECEIPTS{$receipt};
    _pending('receipt_mismatch') unless $entry && refaddr($entry->{scope}) == refaddr($scope)
        && refaddr($entry->{adapter}) == refaddr($adapter) && $entry->{command} eq _identity($command);
    # Compare the receipt with the live context of the running scope, not
    # with the context the receipt itself recorded.
    _prior($scope, $entry->{subject}, $receipt, $scope->{context});
    my $facts = _schema($adapter, $command, $entry->{request});
    _pending('schema_changed') unless $facts->{schema_identity} eq $entry->{schema_identity}
        && $facts->{schema_version} == $entry->{schema_version};
    _same_selection($entry, _select($adapter, $facts, $entry->{inserted}));
    return $entry;
};

sub validate_command {
    &_check_args;
    my $entry = $command_entry->(@_);
    return $entry ? 1 : undef;
}

sub validate_plan {
    &_check_args;
    my ($class, $adapter, $commands, $cleanup) = @_;
    _pending('invalid_plan') unless ref($commands) eq 'ARRAY' && !defined(tied(@$commands)) && @$commands <= 1024
        && (!defined($cleanup) || ref($cleanup) eq 'ARRAY' && !defined(tied(@$cleanup)) && @$cleanup <= 1024);
    for my $list ($commands, $cleanup // []) {
        for my $index (0 .. $#$list) {
            _pending('invalid_plan') if defined(tied($list->[$index]));
            Selecto::Write::Capabilities->requirements($list->[$index]);
        }
    }
    my (%subjects, @entries);
    for my $command (@$commands) {
        my $entry = $command_entry->($class, $adapter, $command);
        next unless $entry;
        _pending('ambiguous_candidate_identity') if $subjects{refaddr($entry->{subject})}++;
        push @entries, [$command, $entry];
    }
    for my $pair (@entries) {
        my ($command, $entry) = @$pair;
        # A final independence proof will admit disjoint same-table plans.
        # Until then no plan ordering or symbolic cleanup can claim exclusion.
        for my $other (@$commands, @{$cleanup // []}) {
            next if refaddr($other) == refaddr($command);
            _pending('plan_independence_unavailable') if _same($other->relation, $entry->{table});
        }
    }
    return 1;
}

# Read native catalog rows directly. Host SQL collations and SQL table-valued
# PRAGMAs cannot decide identifier authority. Row/byte bounds precede copying.
sub _rows {
    my ($adapter, $sql, $params, $maximum) = @_;
    my $dbh = _dbh($adapter);
    my $sth = DBI::db::prepare($dbh, $sql);
    _pending('native_prepare_failed') unless $sth;
    my (@rows, $bytes);
    my $ok = eval {
        Selecto::SQLite::_execute_statement($adapter, $sth, $params);
        while ($sth->{NUM_OF_FIELDS} && (my $row = DBI::st::fetchrow_arrayref($sth))) {
            _pending('native_row_limit') if @rows >= $maximum;
            for my $value (@$row) {
                $bytes += defined($value) ? bytes::length($value) : 0;
                _pending('native_byte_limit') if $bytes > 1_048_576;
            }
            push @rows, [@$row];
        }
        _pending('native_fetch_failed') if DBI::common::err($sth);
        1;
    };
    my $error = $@;
    DBI::st::finish($sth);
    die $error unless $ok;
    return \@rows;
}
sub _q { return $_[0]->quote_identifier($_[1]) }
sub _canonical_field {
    my ($field, $schema) = @_;
    _pending('invalid_field') unless defined($field) && !ref($field) && bytes::length($field) <= 1024;
    my @matches = grep { _same($_, $field) } keys %$schema;
    _pending('invalid_field') unless @matches == 1;
    return $matches[0];
}
sub _fields {
    my ($fields, $schema) = @_;
    _pending('invalid_fields') unless ref($fields) eq 'ARRAY' && @$fields <= 512;
    my (%seen, @result);
    for my $field (@$fields) {
        my $name = _canonical_field($field, $schema);
        _pending('duplicate_field') if $seen{$name}++;
        push @result, $name;
    }
    return \@result;
}
sub _schema {
    my ($adapter, $command, $request) = @_;
    return $adapter->_read_only(sub {
        my $table = Selecto::Identifier::checked($command->relation);
        my $main = _rows($adapter, 'SELECT type,name,tbl_name,sql FROM main.sqlite_schema LIMIT 4097', [], 4096);
        my $temp = _rows($adapter, 'SELECT type,name,tbl_name,sql FROM temp.sqlite_schema LIMIT 4097', [], 4096);
        _pending('temp_shadow') if grep { _same($_->[1], $table) } @$temp;
        my @catalog = grep { _same($_->[1], $table) } @$main;
        _pending('ordinary_main_table_required') unless @catalog == 1 && $catalog[0][0] eq 'table'
            && defined($catalog[0][3]) && $catalog[0][3] =~ /\ACREATE\s+TABLE\b/i;
        $table = $catalog[0][1];
        _pending('unsafe_conflict_policy') if Selecto::SQLite::Ownership::_has_unsafe_conflict_policy($catalog[0][3]);
        _pending('trigger_effects') if grep { $_->[0] eq 'trigger' && _same($_->[2], $table) } (@$main, @$temp);
        my @native = grep { $_->[0] eq 'main' && _same($_->[1], $table) }
            @{_rows($adapter, 'PRAGMA main.table_list', [], 4096)};
        _pending('ordinary_main_table_required') unless @native == 1 && $native[0][2] eq 'table';
        my $columns = _rows($adapter, 'PRAGMA main.table_xinfo(' . _q($adapter, $table) . ')', [], 512);
        _pending('hidden_columns') unless @$columns && !grep { @$_ != 7 || $_->[6] } @$columns;
        my $indexes = _rows($adapter, 'PRAGMA main.index_list(' . _q($adapter, $table) . ')', [], 256);
        _pending('invalid_indexes') if grep { @$_ != 5 } @$indexes;
        my @pk = sort { $a->[5] <=> $b->[5] } grep { $_->[5] } @$columns;
        my $rowid = !$native[0][4] && @pk == 1 && _upper($pk[0][2]) eq 'INTEGER'
            && !(grep { $_->[3] eq 'pk' } @$indexes) ? $pk[0][1] : undef;
        my (%schema, %folded);
        for my $column (@$columns) {
            my ($cid, $name, $type, $notnull, $default, $pk) = @$column;
            _pending('duplicate_native_column') if $folded{_fold($name)}++;
            my $metadata = _dbh($adapter)->sqlite_table_column_metadata('main', $table, $name);
            _pending('column_metadata_unavailable') unless ref($metadata) eq 'HASH';
            my $coll = _upper($metadata->{collation_name} // '');
            _pending('unsupported_collation') unless $coll =~ /\A(?:BINARY|NOCASE|RTRIM)\z/;
            $schema{$name} = {type => _upper($type), collation => $coll, default => $default,
                pk => $pk, nullable => !$notnull, rowid_alias => defined($rowid) && $name eq $rowid ? 1 : 0};
        }
        my %types;
        for my $field (keys %{$request->{field_types}}) {
            my $name = _canonical_field($field, \%schema);
            _pending('duplicate_type') if exists $types{$name};
            my $type = $request->{field_types}{$field};
            _pending('invalid_type') unless defined($type) && !ref($type);
            $type = lc($type);
            _compatible($type, $schema{$name}{type});
            $types{$name} = $type;
        }
        my $metadata = $command->metadata;
        my $target = _fields($metadata->{conflict_target}, \%schema);
        _pending('arbiter_required') unless @$target;
        my $mask = _fields($metadata->{upsert_update_fields}, \%schema);
        my $dependencies = !ref($request->{dependencies}) && defined($request->{dependencies}) && $request->{dependencies} eq 'all'
            ? [sort keys %types] : _fields($request->{dependencies}, \%schema);
        _pending('dependency_type_required') if grep { !exists($types{$_}) } @$dependencies;
        my ($arbiter, @matches);
        if (@$target == 1 && $schema{$target->[0]}{rowid_alias}) {
            $arbiter = {kind => 'rowid', fields => [[$target->[0], 'BINARY']]};
        } else {
            my %targets = map { $_ => 1 } @$target;
            for my $index (@$indexes) {
                next unless $index->[2] && !$index->[4];
                my $rows = _rows($adapter, 'PRAGMA main.index_xinfo(' . _q($adapter, $index->[1]) . ')', [], 513);
                _pending('invalid_index_fields') if grep { @$_ != 6 } @$rows;
                my @keys = grep { $_->[5] } @$rows;
                next if grep { $_->[1] == -2 } @keys;
                _pending('invalid_index_fields') if grep { $_->[1] < 0 || !exists($schema{$_->[2]}) } @keys;
                next unless @keys == @$target && !grep { !$targets{$_->[2]} } @keys;
                my @fields = sort { $a->[0] cmp $b->[0] } map { [$_->[2], _upper($_->[4])] } @keys;
                _pending('unsupported_arbiter_collation') if grep { $_->[1] !~ /\A(?:BINARY|NOCASE|RTRIM)\z/ } @fields;
                push @matches, \@fields;
            }
            my %identities = map { _identity($_) => $_ } @matches;
            _pending('ambiguous_or_missing_arbiter') unless keys(%identities) == 1;
            $arbiter = {kind => 'index', fields => (values %identities)[0]};
        }
        # SQL conflict targets may match a permutation of an index's fields.
        $target = [map { $_->[0] } @{$arbiter->{fields}}];
        my $witness;
        if ($native[0][4]) { $witness = [sort map { $_->[1] } @pk]; _pending('physical_witness_required') unless @$witness }
        else {
            ($witness) = map { [$_] } grep { !$folded{$_} } qw(rowid _rowid_ oid);
            _pending('physical_witness_required') unless $witness;
        }
        my $version = _rows($adapter, 'PRAGMA main.schema_version', [], 1)->[0][0];
        return {table => $table, schema => \%schema, types => \%types, target => $target,
            mask => $mask, arbiter => $arbiter, witness => $witness, dependencies => $dependencies,
            schema_version => $version,
            schema_identity => _identity([$catalog[0], $native[0], \%schema, $indexes, $arbiter])};
    });
}
sub _compatible {
    my ($kind, $declared) = @_;
    _pending('unsupported_declaration') unless $declared =~ /\A[A-Z][A-Z0-9_]*(?:\(\s*\d+\s*(?:,\s*\d+\s*)?\))?\z/;
    return if $kind =~ /\A(?:integer|bigint)\z/ && $declared =~ /INT/;
    return if $kind eq 'boolean' && ($declared =~ /INT/ || $declared eq 'BOOLEAN');
    return if $kind =~ /\A(?:decimal|numeric)\z/ && $declared =~ /\A(?:NUMERIC|DECIMAL)(?:\(|\z)/;
    return if $kind =~ /\A(?:string|text|uuid|date|naive_datetime|utc_datetime)\z/
        && $declared !~ /INT/ && $declared =~ /CHAR|CLOB|TEXT/;
    _pending('incompatible_storage_type');
}
sub _submitted {
    my ($command, $facts) = @_;
    my %values;
    for my $field (keys %{$command->assignments}) {
        my $name = _canonical_field($field, $facts->{schema});
        _pending('duplicate_assignment') if exists $values{$name};
        _pending('assignment_type_required') unless exists $facts->{types}{$name};
        my $value = $command->assignments->{$field};
        if (ref($value) eq 'Selecto::Write::Expression') {
            _pending('literal_assignment_required') unless $value->kind eq 'literal';
            $value = $value->arguments->[0];
        }
        _pending('literal_assignment_required') if ref($value) && !JSON::PP::is_bool($value);
        $values{$name} = $value;
    }
    return _plain(\%values);
}
sub _default {
    my ($adapter, $sql) = @_;
    _pending('unconsumed_default_unavailable') unless defined($sql) && !ref($sql)
        && bytes::length($sql) <= 4096 && index($sql, "\0") < 0;
    $sql =~ s/\A\s+|\s+\z//g;
    for my $depth (0 .. 16) {
        last unless substr($sql, 0, 1) eq '(';
        _pending('default_depth') if $depth == 16;
        my ($level, $quote, $whole) = (0, 0, 1);
        for (my $i = 0; $i < length($sql); ++$i) {
            my $c = substr($sql, $i, 1);
            if ($c eq "'") {
                if ($quote && substr($sql, $i + 1, 1) eq "'") { ++$i; next }
                $quote = !$quote; next;
            }
            next if $quote;
            ++$level if $c eq '(';
            if ($c eq ')') { --$level; $whole = 0 if $level == 0 && $i != length($sql) - 1 }
            _pending('default_parentheses') if $level < 0;
        }
        _pending('default_parentheses') unless $whole && !$quote && $level == 0 && substr($sql, -1) eq ')';
        $sql = substr($sql, 1, length($sql) - 2); $sql =~ s/\A\s+|\s+\z//g;
    }
    _pending('nonliteral_default') unless $sql =~ /\A(?:NULL|TRUE|FALSE)\z/i
        || $sql =~ /\A[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|0[xX][0-9a-fA-F]+)\z/
        || $sql =~ /\A'(?:[^']|'')*'\z/s;
    return $adapter->_read_only(sub { _rows($adapter, 'SELECT ' . $sql, [], 1)->[0][0] });
}
sub _project_values {
    my ($adapter, $facts, $operation, $values, $dependencies) = @_;
    my %projected = %$values;
    for my $field (@$dependencies) {
        _pending('generated_dependency_unavailable') if $operation eq 'insert'
            && $facts->{schema}{$field}{rowid_alias} && !defined($projected{$field});
        next if exists $projected{$field};
        _pending('missing_stored_dependency') unless $operation eq 'insert';
        my $default = $facts->{schema}{$field}{default};
        $projected{$field} = defined($default) ? _default($adapter, $default) : undef;
    }
    delete $projected{$_} for grep { $operation eq 'insert' && $facts->{schema}{$_}{rowid_alias}
        && !defined($projected{$_}) } keys %projected;
    my @fields = sort keys %projected;
    return {} unless @fields;
    my (@definitions, @params);
    for my $field (@fields) {
        _pending('projection_type_required') unless exists($facts->{types}{$field});
        my $column = $facts->{schema}{$field};
        push @definitions, _q($adapter, $field) . ' ' . $column->{type} . ' COLLATE ' . _q($adapter, $column->{collation});
        my $value = $projected{$field};
        _pending('projection_literal_required') if ref($value) && !JSON::PP::is_bool($value);
        push @params, $value;
    }
    my $name = 'selecto_upsert_projection_' . ++$SERIAL;
    my $savepoint = 'selecto_upsert_probe_' . $SERIAL;
    my ($answer, $error);
    _rows($adapter, 'SAVEPOINT ' . $savepoint, [], 1);
    my $ok = eval {
        _rows($adapter, 'CREATE TEMP TABLE ' . _q($adapter, $name) . '(' . join(',', @definitions) . ')', [], 1);
        _rows($adapter, 'INSERT INTO temp.' . _q($adapter, $name) . ' VALUES(' . join(',', ('?') x @fields) . ')', \@params, 1);
        my $rows = _rows($adapter, 'SELECT * FROM temp.' . _q($adapter, $name), [], 1);
        _pending('projection_row_required') unless @$rows == 1 && @{$rows->[0]} == @fields;
        $answer = {};
        for my $i (0 .. $#fields) { $answer->{$fields[$i]} = _scalar($facts->{types}{$fields[$i]}, $rows->[0][$i]) }
        1;
    };
    $error = $@ unless $ok;
    my $restored = eval {
        _rows($adapter, 'ROLLBACK TO ' . $savepoint, [], 1);
        _rows($adapter, 'RELEASE ' . $savepoint, [], 1); 1;
    };
    _pending('projection_restore_failed') unless $restored;
    die $error unless $ok;
    return _plain($answer);
}
sub _scalar {
    my ($type, $value) = @_;
    return undef unless defined $value;
    _pending('nonfinite_projection') if ref($value);
    if ($type =~ /\A(?:integer|bigint|decimal|numeric|boolean)\z/) {
        my $flags = B::svref_2object(\$value)->FLAGS;
        _pending('nonnumeric_projection') unless $flags & (B::SVf_IOK() | B::SVf_NOK());
        _pending('nonfinite_projection') unless POSIX::isfinite($value);
    }
    if ($type =~ /\A(?:integer|bigint)\z/) {
        _pending('noninteger_projection') unless B::svref_2object(\$value)->FLAGS & B::SVf_IOK();
        return 0 + $value;
    }
    if ($type eq 'boolean') {
        _pending('nonboolean_projection') unless "$value" =~ /\A[01]\z/;
        return $value ? JSON::PP::true : JSON::PP::false;
    }
    if ($type =~ /\A(?:decimal|numeric)\z/) {
        _pending('nonnumeric_projection') unless B::svref_2object(\$value)->FLAGS & (B::SVf_IOK() | B::SVf_NOK());
        return Selecto::DataRules::_copy_plain($value, $LIMITS, 'required_data_rule_pending', 'projected scalar');
    }
    _pending('nontext_projection') unless B::svref_2object(\$value)->FLAGS & B::SVf_POK();
    return substr($value, 0);
}
sub _select {
    my ($adapter, $facts, $inserted) = @_;
    my @keys = map { $inserted->{$_->[0]} } @{$facts->{arbiter}{fields}};
    return {branch => 'insert', physical_id => undef, prior => {}, keys => \@keys, arbiter => $facts->{arbiter}}
        if grep { !defined($_) } @keys;
    return $adapter->_read_only(sub {
        my @fields = sort keys %{$facts->{types}};
        my @aliases = map { 'selecto_upsert_witness_' . $_ } 0 .. $#{$facts->{witness}};
        _pending('witness_alias_collision') if grep { my $alias = $_; grep { _same($_, $alias) } keys %{$facts->{schema}} } @aliases;
        my @projection = (map { _q($adapter, $facts->{witness}[$_]) . ' AS ' . _q($adapter, $aliases[$_]) } 0 .. $#aliases);
        push @projection, map { _q($adapter, $_) } @fields;
        my $where = join(' AND ', map { _q($adapter, $_->[0]) . ' COLLATE ' . _q($adapter, $_->[1]) . ' = ?' } @{$facts->{arbiter}{fields}});
        my $rows = _rows($adapter, 'SELECT ' . join(',', @projection) . ' FROM main.' . _q($adapter, $facts->{table}) . ' WHERE ' . $where . ' LIMIT 2', \@keys, 2);
        return {branch => 'insert', physical_id => undef, prior => {}, keys => \@keys, arbiter => $facts->{arbiter}} unless @$rows;
        _pending('ambiguous_candidate_identity') unless @$rows == 1;
        my @row = @{$rows->[0]};
        my @physical = splice(@row, 0, scalar @aliases);
        my %prior = map { $fields[$_] => _scalar($facts->{types}{$fields[$_]}, $row[$_]) } 0 .. $#fields;
        return {branch => 'conflict', physical_id => \@physical, prior => _plain(\%prior), keys => \@keys, arbiter => $facts->{arbiter}};
    });
}
sub _same_selection {
    my ($previous, $current) = @_;
    _pending('protected_branch_changed') unless _identity([@{$previous}{qw(branch physical_id prior arbiter)}])
        eq _identity([@{$current}{qw(branch physical_id prior arbiter)}]);
}

package Selecto::SQLite::UpsertCandidate::_Scope;
sub DESTROY { $_[0]{finish}->() }

1;
