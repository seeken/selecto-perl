package Selecto::Domain::Schema;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use JSON::PP ();
use Scalar::Util qw(blessed reftype);
use Selecto::Domain::QueryContract ();
use Selecto::Domain::QueryMembers ();
use Selecto::QueryLibrary::Contract ();
use Selecto::OperationBudget ();
use Selecto::Limits ();
use Selecto::Error ();

my %EVENT_TYPE = map { $_ => 1 } qw(any boolean enum integer list map number string uuid);
sub _string { defined($_[0]) && !defined(reftype($_[0])) && (B::svref_2object(\$_[0])->FLAGS & B::SVp_POK()) }
sub _scalar { !defined(reftype($_[0])) || ref($_[0]) eq 'JSON::PP::Boolean' }
sub _bool { ref($_[0]) eq 'JSON::PP::Boolean' }
sub _error {
    my ($state, $code, $path) = @_;
    my $error = {code => $code, path => [@$path], message => 'invalid portable domain declaration'};
    $state->{budget}->check_tree($error, label => 'domain schema diagnostics', bytes_limit => 'max_state_bytes');
    push @{$state->{errors}}, $error;
}
sub _relation {
    my ($state, $value, $path, $root) = @_;
    unless (ref($value) eq 'HASH') { _error($state, 'invalid_section_shape', $path); return }
    _error($state, 'missing_required_keys', $path)
        if grep { !exists $value->{$_} } ($root ? ('source_table') : (), qw(primary_key fields columns));
    _error($state, 'invalid_source_table', [@$path, 'source_table']) if exists($value->{source_table}) && !_string($value->{source_table});
    _error($state, 'invalid_root_values', [@$path, 'values']) if $root && exists $value->{values};
    _error($state, 'invalid_relation_source', $path) if !$root && exists($value->{source_table}) == exists($value->{values});
    my ($fields, $columns) = @{$value}{qw(fields columns)};
    _error($state, 'invalid_fields', [@$path, 'fields'])
        if exists($value->{fields}) && (ref($fields) ne 'ARRAY' || grep { !_string($_) } @$fields);
    if (exists $value->{columns}) {
        if (ref($columns) ne 'HASH') { _error($state, 'invalid_columns', [@$path, 'columns']) }
        else { _error($state, 'invalid_column_definition', [@$path, 'columns', $_])
            for grep { ref($columns->{$_}) ne 'HASH' } sort keys %$columns }
    }
    if (ref($fields) eq 'ARRAY' && ref($columns) eq 'HASH') {
        _error($state, $root ? 'source_field_missing_column' : 'schema_field_missing_column', [@$path, 'columns', $_])
            for grep { _string($_) && !exists($columns->{$_}) } @$fields;
    }
    if (exists $value->{primary_key}) {
        my $key = $value->{primary_key};
        my @keys = ref($key) eq 'ARRAY' ? @$key : ($key);
        my %seen;
        if (!@keys || grep { !_string($_) || $seen{$_}++ } @keys) { _error($state, 'invalid_primary_key', [@$path, 'primary_key']) }
        elsif (ref($fields) eq 'ARRAY') {
            my %known = map { $_ => 1 } grep { _string($_) } @$fields;
            _error($state, 'primary_key_not_found', [@$path, 'primary_key']) for grep { !$known{$_} } @keys;
        }
    }
    if (!$root && exists $value->{values}) {
        my $rows = $value->{values};
        if (ref($fields) ne 'ARRAY' || !@$fields || grep { !_string($_) } @$fields) {
            _error($state, 'invalid_relation_values', [@$path, 'values']);
        } elsif (ref($rows) ne 'ARRAY' || !@$rows) {
            _error($state, 'invalid_relation_values', [@$path, 'values']);
        } else {
            my %known = map { $_ => 1 } @$fields;
            for my $i (0 .. $#$rows) {
                my $row = $rows->[$i];
                _error($state, 'invalid_relation_values_row', [@$path, 'values', $i])
                    unless ref($row) eq 'HASH' && keys(%$row) == keys(%known)
                        && !grep { !exists($known{$_}) || !_scalar($row->{$_}) } keys %$row;
            }
        }
    }
    if (exists $value->{source_kind}) {
        my $kind = $value->{source_kind};
        _error($state, 'invalid_source_kind', [@$path, 'source_kind'])
            unless _string($kind) && $kind =~ /\A(?:table|view|materialized_view)\z/;
    }
    _error($state, 'invalid_readonly', [@$path, 'readonly']) if exists($value->{readonly}) && !_bool($value->{readonly});
}
sub _event_field {
    my ($state, $spec, $path) = @_;
    if (_string($spec)) {
        _error($state, 'unsupported_event_field_type', [@$path, 'type']) unless $EVENT_TYPE{$spec};
        return;
    }
    unless (ref($spec) eq 'HASH') { _error($state, 'invalid_event_field_spec', $path); return }
    my $type = $spec->{type};
    $type = 'any' if !defined($type) || _bool($type) && !$$type;
    _error($state, 'unsupported_event_field_type', [@$path, 'type']) unless _string($type) && $EVENT_TYPE{$type};
    for my $key (qw(required nullable)) {
        _error($state, 'invalid_event_field_option', [@$path, $key]) if defined($spec->{$key}) && !_bool($spec->{$key});
    }
    _error($state, 'invalid_event_enum', [@$path, 'values']) if _string($type) && $type eq 'enum' && ref($spec->{values}) ne 'ARRAY';
    if (defined $spec->{item}) {
        if (_string($type) && $type eq 'list') { _event_field($state, $spec->{item}, [@$path, 'item']) }
        else { _error($state, 'event_item_on_non_list', [@$path, 'item']) }
    }
}
sub _events {
    my ($state, $events) = @_;
    unless (ref($events) eq 'HASH') { _error($state, 'invalid_section_shape', ['events']); return }
    for my $id (sort keys %$events) {
        my $path = ['events', $id];
        _error($state, 'invalid_event_id', $path) unless length $id;
        my $event = $events->{$id};
        unless (ref($event) eq 'HASH') { _error($state, 'invalid_event_spec', $path); next }
        my $version = $event->{schema_version};
        my $flags = B::svref_2object(\$version)->FLAGS;
        _error($state, 'invalid_event_schema_version', [@$path, 'schema_version'])
            unless defined($version) && !defined(reftype($version)) && $flags & B::SVp_IOK() && !($flags & B::SVp_POK()) && $version > 0;
        _error($state, 'invalid_event_additional_fields', [@$path, 'additional_fields'])
            if defined($event->{additional_fields}) && !_bool($event->{additional_fields});
        my $data = $event->{data};
        unless (ref($data) eq 'HASH') { _error($state, 'invalid_event_data_contract', [@$path, 'data']); next }
        for my $field (sort keys %$data) {
            _error($state, 'invalid_event_field_id', [@$path, 'data', $field]) unless length $field;
            _event_field($state, $data->{$field}, [@$path, 'data', $field]);
        }
    }
}
sub _registry {
    my ($state, $raw, $section) = @_;
    return unless exists $raw->{$section};
    my $registry = $raw->{$section};
    unless (ref($registry) eq 'HASH') { _error($state, 'invalid_section_shape', [$section]); return }
    for my $id (sort keys %$registry) {
        _error($state, 'invalid_consumer_registry_id', [$section, $id]) unless $id =~ /\S/;
        _error($state, 'invalid_consumer_registry_entry', [$section, $id]) unless ref($registry->{$id}) eq 'HASH';
    }
}
sub validate {
    my ($class, $given) = @_;
    my $raw = Selecto::Domain::QueryContract->copy_declaration($given);
    my $state = {errors => [], budget => Selecto::OperationBudget->new(limits => Selecto::Limits->new, code => 'invalid_domain_schema')};
    _error($state, 'missing_required_section', [$_]) for grep { !exists($raw->{$_}) } qw(source schemas);
    _relation($state, $raw->{source}, ['source'], 1);
    if (ref($raw->{schemas}) eq 'HASH') { _relation($state, $raw->{schemas}{$_}, ['schemas', $_], 0) for sort keys %{$raw->{schemas}} }
    else { _error($state, 'invalid_section_shape', ['schemas']) }
    _events($state, $raw->{events}) if exists $raw->{events};
    _registry($state, $raw, $_) for qw(operations experiences);
    my $query = Selecto::Domain::QueryContract->validate($raw);
    _error($state, $_->{code}, $_->{path}) for @{$query->{errors}};
    if (${$query->{valid}}) {
        my $library = Selecto::QueryLibrary::Contract->validate_declaration($raw);
        _error($state, $_->{code}, $_->{path}) for @{$library->{errors}};
    }
    my $members = Selecto::Domain::QueryMembers->validate($raw);
    _error($state, $_->{code}, $_->{path}) for @{$members->{errors}};
    my $valid = @{$state->{errors}} ? 0 : 1;
    return Selecto::Domain::QueryContract->copy_declaration({valid => bless(\$valid, 'JSON::PP::Boolean'),
        errors => $state->{errors}, warnings => [], validated_sections => [qw(source schemas query_contract query_members query_library events operations experiences)]});
}

1;

=head1 NAME

Selecto::Domain::Schema - bounded portable domain declaration validation

=head1 DESCRIPTION

C<validate($plain_contract)> returns C<valid>, structured C<errors> and explicit
C<validated_sections>. It validates relation/table/VALUES shapes and metadata,
query declarations and the ordinary query-library subset, event payload schemas
and operation/experience registry envelopes. Components, opaque domain data and
JSON-schema payloads remain metadata. Complete plain input is admitted before
copying or interpreting; callbacks, ties, unknown blessed objects and cycles
refuse without hooks. Input, reference work, generated identifiers and emitted
diagnostics use fixed trusted native metadata ceilings.

This separate metadata boundary does not construct an executable native domain,
execute event actions or consumer vocabularies, or enable rich native import,
UDFs, callbacks or unsupported query-library expressions. Existing identity
normalization and native C<Selecto::Domain-E<gt>parse> semantics are preserved.

=cut
