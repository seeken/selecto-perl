package Selecto::Write::Editable;

use 5.034;
use strict;
use warnings;
no overloading;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed reftype);
use Selecto::Write::Session ();
use Selecto::Domain::QueryContract ();
use Selecto::Expression ();
use Selecto::Error ();

fieldhash my %ROWS;
fieldhash my %RESULTS;
sub _fail { Selecto::Error->throw('invalid_edit_handle', $_[0]) }
sub _copy { Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value} }
sub _row {
    my ($row) = @_;
    _fail('an original native editable row is required')
        unless (blessed($row) // '') eq 'Selecto::Write::Editable::Row'
            && (reftype($row) // '') eq 'SCALAR' && exists $ROWS{$row};
    my $s = $ROWS{$row};
    Selecto::Write::Session->require_live($s->{engine});
    return $s;
}
my $issue = sub {
    my ($engine, $result, $values) = @_;
    Selecto::Write::Session->require_live($engine);
    my $keys = $engine->domain->primary_keys;
    _fail('editable result requires a complete non-null root identity')
        if grep { !defined($values->{$_}) || ref($values->{$_}) } @$keys;
    my ($rt, $ht) = (0, 0);
    my $row = bless \$ht, 'Selecto::Write::Editable::Row';
    $ROWS{$row} = {engine => $engine, keys => $keys, identity => {map { ($_ => $values->{$_}) } @$keys}};
    my $res = bless \$rt, 'Selecto::Write::Editable::Result';
    $RESULTS{$res} = {row => $row, result => $result, values => _copy($values)};
    return $res;
};
sub dispatch {
    my ($class, $engine, $command, $phase) = @_;
    Selecto::Write::Session->require_live($engine);
    _fail('edit handles require one insert, update, or upsert')
        unless $command->operation =~ /\A(?:insert|update|upsert)\z/;
    my $cardinality = $command->metadata->{expected_cardinality};
    _fail('edit handles require exactly one affected row')
        unless ref($cardinality) eq 'ARRAY' && @$cardinality == 2
            && $cardinality->[0] eq 'exactly' && $cardinality->[1] == 1;
    my $keys = $engine->domain->primary_keys;
    my $returning = $command->metadata->{returning} // [];
    # This pilot requires an explicitly granted identity in the requested
    # projection. No hidden identity read or implicit returning grant.
    my %returning = map { ($_ => 1) } @$returning;
    _fail('return_for_update must include every granted primary-key field')
        if grep { !$returning{$_} } @$keys;
    return $engine->preview_write($command) if $phase eq 'preview';
    my ($res, $error);
    my $ok = eval {
        my $native = $engine->execute_write($command);
        _fail('edit handles require one native returned row') unless $native->affected_rows == 1;
        $res = $issue->($engine, $native, $native->values);
        1;
    };
    if (!$ok) { $error = $@; Selecto::Write::Session->poison($engine, $error); die $error }
    return $res;
}
sub validate_read {
    my ($class, $engine, $query) = @_;
    Selecto::Write::Session->require_live($engine);
    _fail('select_for_update requires an ungrouped root query')
        if $query->retarget_spec || @{$query->groups} || $query->grouping_mode ne 'plain' || $query->offset_value
            || defined($query->limit_value) && $query->limit_value == 0
            || grep { @{$query->{$_} // []} } qw(set_operations ctes lateral_joins json_rowsets array_rowsets members values_sources subqueries function_laterals);
    my $keys = $engine->domain->primary_keys;
    my %keys = map { ($_ => 1) } @$keys;
    my %identity;
    my $find;
    $find = sub {
        my ($expr) = @_;
        return unless blessed($expr) && $expr->isa('Selecto::Expression');
        if ($expr->kind eq 'and') { $find->($_) for @{$expr->arguments->[0]}; return }
        return unless $expr->kind eq 'eq';
        my ($left, $right) = @{$expr->arguments};
        return unless blessed($left) && blessed($right) && $left->kind eq 'field' && $right->kind eq 'literal'
            && $keys{$left->arguments->[0]};
        my $key = $left->arguments->[0];
        my $value = $right->arguments->[0];
        _fail('root identity must be a non-null scalar') unless defined($value) && !ref($value);
        _fail('conflicting root identities') if exists($identity{$key}) && "$identity{$key}" ne "$value";
        $identity{$key} = $value;
    };
    $find->($query->predicate);
    _fail('select_for_update requires every exact root primary-key filter') if grep { !exists $identity{$_} } @$keys;
    my @fields;
    for my $expr (@{$query->selections}) {
        _fail('editable reads select declared public root fields only')
            unless $expr->kind eq 'field' && !$expr->alias_name;
        my $field = $expr->arguments->[0];
        _fail('editable reads select declared public root fields only')
            unless exists($engine->domain->fields->{$field}) && $engine->domain->field_is_public($field);
        push @fields, $field;
    }
    my %fields = map { ($_ => 1) } @fields;
    _fail('editable read projection must include every primary-key field') if grep { !$fields{$_} } @$keys;
    return 1;
}
sub locked_read {
    my ($class, $engine, $query) = @_;
    _fail('editable read must acquire an update lock') unless ($query->row_lock // '') eq 'update';
    $class->validate_read($engine, $query);
    my $native = $engine->all($query->limit(2));
    _fail('select_for_update must resolve exactly one row') unless @{$native->{rows}} == 1;
    my %values;
    @values{@{$native->{columns}}} = @{$native->{rows}[0]};
    return $issue->($engine, Selecto::Write::Result->new(operation => 'select', affected_rows => 1, values => \%values), \%values);
}
sub _bind_builder {
    my ($row, $edge) = @_;
    my $s = _row($row);
    require Selecto::Write::Builder;
    return Selecto::Write::Builder->_from_editable($s->{engine}, $row, $edge);
}
sub bound_command {
    my ($class, $row, $edge_name, $type, $values, $metadata) = @_;
    my $s = _row($row);
    my $engine = $s->{engine};
    my $predicate = Selecto::Expression->all(map { Selecto::Expression->eq($_, $s->{identity}{$_}) } @{$s->{keys}});
    _fail('related write pilot supports owned one-to-many inserts only') unless $type eq 'insert';
    my $edge = $engine->domain->writes->{relationships}{$edge_name};
    _fail('related write requires a declared owned one-to-many edge')
        unless ref($edge) eq 'HASH' && ($edge->{ownership} // '') =~ /\A(?:owned|composition)\z/
            && ($edge->{cardinality} // '') eq 'many' && ref($edge->{domain}) eq 'HASH';
    my $parent_key = $edge->{parent_key} // (@{$s->{keys}} == 1 ? $s->{keys}[0] : undef);
    my $child_key = $edge->{child_key} // $edge->{foreign_key};
    _fail('related insert requires a declared bound parent key')
        unless defined($parent_key) && !ref($parent_key) && exists($s->{identity}{$parent_key}) && defined($child_key);
    _fail('related assignments cannot override the parent binding') if exists($values->{$child_key});
    my $child = Selecto::Engine::_native_relationship_domain($edge->{domain});
    my $anchor = Selecto::Write::Command->new(operation => 'update', relation => $engine->domain->table,
        assignments => {}, predicate => $predicate, expected_count => 1, metadata => {returning => $s->{keys}});
    my $command = Selecto::Write::Command->new(operation => 'insert', relation => $child->table,
        assignments => $values, expected_count => 1, metadata => $metadata);
    return Selecto::Write::Graph->new(nodes => [
        {id => 'parent', command => $anchor, reference_only => 1},
        {id => 'child', command => $command, bindings => [{field => $child_key, from => 'parent', key => $parent_key}]},
    ]);
}
sub identity_filter {
    my ($class, $row) = @_;
    my $s = _row($row);
    return [map { [$_, $s->{identity}{$_}] } @{$s->{keys}}];
}
sub assert_live { _row($_[1]); return 1 }

package Selecto::Write::Editable::Row;
sub write { Selecto::Write::Editable::_bind_builder($_[0], undef) }
sub related_write {
    Selecto::Write::Editable::_fail('related_write requires one relationship name')
        unless @_ == 2 && defined($_[1]) && !ref($_[1]) && $_[1] =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return Selecto::Write::Editable::_bind_builder($_[0], $_[1]);
}

package Selecto::Write::Editable::Result;
sub _state {
    Selecto::Write::Editable::_fail('an original editable result is required')
        unless exists $RESULTS{$_[0]};
    return $RESULTS{$_[0]};
}
sub row { my $s = _state($_[0]); Selecto::Write::Editable->assert_live($s->{row}); return $s->{row} }
sub values { Selecto::Write::Editable::_copy(_state($_[0])->{values}) }
sub operation { _state($_[0])->{result}->operation }
sub affected_rows { _state($_[0])->{result}->affected_rows }
sub metadata { _state($_[0])->{result}->metadata }

1;
