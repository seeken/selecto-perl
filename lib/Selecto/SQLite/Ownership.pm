package Selecto::SQLite::Ownership;
use 5.034;
use strict;
use warnings;
use Selecto::QueryEnforcement ();
use Selecto::Error ();
use Selecto::Identifier ();

# Catalog proof belongs to the native adapter, and is repeated in the write
# transaction. Authored relationship names are not physical ownership proof.
sub _fail { Selecto::Error->throw('ownership_storage_not_evaluable', 'SQLite cannot establish exact physical ownership') }
sub _lower { my $name = $_[0] // ''; $name =~ tr/A-Z/a-z/; return $name }
sub _upper { my $name = $_[0] // ''; $name =~ tr/a-z/A-Z/; return $name }
sub _same { defined($_[0]) && defined($_[1]) && _lower($_[0]) eq _lower($_[1]) }
sub _affinity {
    my $type = _upper($_[0]);
    return 'INTEGER' if $type =~ /INT/;
    return 'TEXT' if $type =~ /CHAR|CLOB|TEXT/;
    return 'BLOB' if $type eq '' || $type =~ /BLOB/;
    return 'REAL' if $type =~ /REAL|FLOA|DOUB/;
    return 'NUMERIC';
}
sub table {
    my ($class, $adapter, $name) = @_;
    Selecto::Identifier::checked($name);
    _fail() unless $adapter->_sqlite_version_at_least(3, 37, 0);
    my $dbh = $adapter->dbh;
    my ($shadow) = $dbh->selectrow_array('SELECT 1 FROM temp.sqlite_schema WHERE name = ? COLLATE NOCASE AND type IN (\'table\',\'view\')', undef, $name);
    _fail() if $shadow;
    my @tables = grep { $_->{schema} eq 'main' && _same($_->{name}, $name) }
        @{$dbh->selectall_arrayref('PRAGMA table_list', {Slice => {}})};
    _fail() unless @tables == 1 && $tables[0]{type} eq 'table';
    my $rows = $dbh->selectall_arrayref('PRAGMA main.table_xinfo(' . $adapter->quote_identifier($name) . ')', {Slice => {}});
    _fail() unless @$rows;
    return {name => $tables[0]{name}, wr => $tables[0]{wr}, columns => $rows};
}
sub verify {
    my ($class, $adapter, $parent_table, $parent_key, $child_table, $child_key) = @_;
    my $parent = $class->table($adapter, $parent_table);
    my $child = $class->table($adapter, $child_table);
    my ($pc) = grep { _same($_->{name}, $parent_key) && !$_->{hidden} } @{$parent->{columns}};
    my ($cc) = grep { _same($_->{name}, $child_key) && !$_->{hidden} } @{$child->{columns}};
    _fail() unless $pc && $cc;
    my $dbh = $adapter->dbh;
    my $pm = $dbh->sqlite_table_column_metadata('main', $parent->{name}, $pc->{name});
    my $cm = $dbh->sqlite_table_column_metadata('main', $child->{name}, $cc->{name});
    _fail() unless ref($pm) eq 'HASH' && ref($cm) eq 'HASH';
    my $collation = _upper($pm->{collation_name});
    _fail() unless $collation =~ /\A(?:BINARY|NOCASE|RTRIM)\z/
        && $collation eq _upper($cm->{collation_name})
        && _affinity($pm->{data_type}) eq _affinity($cm->{data_type});
    my @pk = sort { $a->{pk} <=> $b->{pk} } grep { $_->{pk} } @{$parent->{columns}};
    my $indexes = $dbh->selectall_arrayref('PRAGMA main.index_list(' . $adapter->quote_identifier($parent->{name}) . ')', {Slice => {}});
    # A rowid alias has no primary-key index. INTEGER PRIMARY KEY DESC does.
    my $unique = @pk == 1 && _same($pk[0]{name}, $pc->{name})
        && _upper($pc->{type}) eq 'INTEGER' && !$parent->{wr}
        && !grep { ($_->{origin} // '') eq 'pk' } @$indexes;
    for my $index (@$indexes) {
        next unless $index->{unique} && !$index->{partial};
        my @keys = grep { $_->{key} } @{$dbh->selectall_arrayref('PRAGMA main.index_xinfo(' . $adapter->quote_identifier($index->{name}) . ')', {Slice => {}})};
        $unique = 1 if @keys == 1 && ($keys[0]{cid} // -1) >= 0
            && _same($keys[0]{name}, $pc->{name}) && _upper($keys[0]{coll}) eq $collation;
    }
    _fail() unless $unique;
    my %groups;
    push @{$groups{$_->{id}}}, $_ for @{$dbh->selectall_arrayref('PRAGMA main.foreign_key_list(' . $adapter->quote_identifier($child->{name}) . ')', {Slice => {}})};
    for my $group (values %groups) {
        next unless grep { _same($_->{from}, $cc->{name}) } @$group;
        _fail() unless @$group == 1 && _same($group->[0]{table}, $parent->{name});
        my $target = $group->[0]{to};
        if (!defined($target) || $target eq '') {
            _fail() unless @pk == 1;
            $target = $pk[0]{name};
        }
        _fail() unless _same($target, $pc->{name});
    }
    return 1;
}
sub rules_storage {
    my ($class, $adapter, $command) = @_;
    my $table = $class->table($adapter, $command->relation);
    _fail() if grep { $_->{hidden} } @{$table->{columns}};
    return 1 unless $command->operation eq 'update';
    my %assigned = map { (_lower($_) => 1) } keys %{$command->assignments};
    my @pk = sort { $a->{pk} <=> $b->{pk} } grep { $_->{pk} } @{$table->{columns}};
    # Automatic FK updates cannot become undeclared graph mutations, including
    # when a normalizer adds an unsubmitted natural-key assignment.
    for my $other (@{$adapter->dbh->selectall_arrayref('PRAGMA table_list', {Slice => {}})}) {
        next unless $other->{schema} eq 'main' && $other->{type} eq 'table';
        my $rows = $adapter->dbh->selectall_arrayref('PRAGMA main.foreign_key_list(' . $adapter->quote_identifier($other->{name}) . ')', {Slice => {}});
        for my $fk (@$rows) {
            next unless _same($fk->{table}, $table->{name});
            my $target = $fk->{to};
            $target = $pk[$fk->{seq}]{name} if (!defined($target) || $target eq '') && exists $pk[$fk->{seq}];
            next unless defined($target) && $assigned{_lower($target)};
            _fail() unless ($fk->{on_update} // '') =~ /\A(?:NO ACTION|RESTRICT)\z/;
        }
    }
    return 1;
}

sub rowid_alias {
    my ($class, $adapter, $table) = @_;
    return if $table->{wr};
    my @pk = grep { $_->{pk} } @{$table->{columns}};
    return unless @pk == 1 && _upper($pk[0]{type}) eq 'INTEGER';
    my $indexes = $adapter->dbh->selectall_arrayref('PRAGMA main.index_list(' . $adapter->quote_identifier($table->{name}) . ')', {Slice => {}});
    return if grep { ($_->{origin} // '') eq 'pk' } @$indexes;
    return $pk[0]{name};
}

sub plan_storage {
    my ($class, $adapter, $commands) = @_;
    my $pending = sub {
        my ($command) = @_;
        my $guarded_insert = $command && $command->operation eq 'insert'
            && Selecto::QueryEnforcement::combine($command->predicate, $command->scope_predicate,
                $command->query_enforcement ? $command->query_enforcement->predicate : undef);
        Selecto::Error->throw($guarded_insert ? 'query_rule_not_evaluable' : 'required_data_rule_pending',
            'SQLite cannot prove all physical mutation effects belong to the governed plan');
    };
    my $dbh = $adapter->dbh;
    $pending->() unless eval { $dbh->isa('DBI::db') && $dbh->{Driver}{Name} eq 'SQLite' };
    my %targets;
    for my $command (@$commands) {
        my $physical;
        my $ok = eval {
            $physical = $class->table($adapter, $command->relation);
            _fail() if grep { $_->{hidden} } @{$physical->{columns}};
            for my $catalog (qw(main temp)) {
                my ($trigger) = $dbh->selectrow_array("SELECT 1 FROM $catalog.sqlite_schema WHERE type='trigger' AND tbl_name=? COLLATE NOCASE LIMIT 1", undef, $physical->{name});
                _fail() if $trigger;
            }
            1;
        };
        $pending->($command) unless $ok;
        $targets{_lower($command->relation)} = $physical;
    }
    my @relevant = grep { $_->operation =~ /\A(?:update|upsert|delete)\z/ } @$commands;
    return 1 unless @relevant;
    my $tables = $dbh->selectall_arrayref("SELECT name FROM main.sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 1025", {Slice => {}});
    $pending->() if @$tables > 1024;
    my $count = 0;
    for my $table (@$tables) {
        my $foreign = $dbh->selectall_arrayref('PRAGMA main.foreign_key_list(' . $adapter->quote_identifier($table->{name}) . ')', {Slice => {}});
        $count += @$foreign; $pending->() if $count > 4096;
        for my $fk (@$foreign) {
            for my $command (@relevant) {
                next unless _same($fk->{table}, $command->relation);
                my $deletion = $command->operation eq 'delete';
                my $action = _upper($fk->{$deletion ? 'on_delete' : 'on_update'});
                next if $action eq 'NO ACTION' || $action eq 'RESTRICT';
                $pending->() unless $action =~ /\A(?:CASCADE|SET NULL|SET DEFAULT)\z/;
                $pending->() if $deletion;
                my $fields = $command->operation eq 'upsert' ? $command->metadata->{upsert_update_fields} : [keys %{$command->assignments}];
                $pending->() unless ref($fields) eq 'ARRAY';
                my @pk = sort { $a->{pk} <=> $b->{pk} } grep { $_->{pk} } @{$targets{_lower($command->relation)}{columns}};
                my $key = $fk->{to};
                $key = $pk[$fk->{seq}]{name} if (!defined($key) || $key eq '') && exists($pk[$fk->{seq}]);
                $pending->() unless defined($key) && length($key);
                $pending->() if grep { _same($_, $key) } @$fields;
            }
        }
    }
    return 1;
}
1;
