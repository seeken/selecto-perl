package Selecto::Domain::SchemaV2;

# Domain schema 2 (certification specification 3.0; the harness's
# docs/domain_schema_v2.md is normative). The RFC 8785 fingerprint, the
# version 2 rules, the migration from version 1, and the mapping a version 2
# document takes to the version 1 form the rest of Selecto parses.

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use Digest::SHA ();
use Encode ();
use JSON::PP ();
use POSIX ();
use Scalar::Util qw(blessed reftype);

my @SOURCES = qw(trusted_context prefix filter payload);
my %SOURCES = map { $_ => 1 } @SOURCES;
my %TENANT_KEYS = map { $_ => 1 } qw(field write_field satisfied_by pins);

# ------------------------------------------------------------------ RFC 8785

sub _is_number {
    my ($value) = @_;
    my $flags = B::svref_2object(\$value)->FLAGS;
    return ($flags & (B::SVp_IOK() | B::SVp_NOK())) && !($flags & B::SVp_POK()) ? 1 : 0;
}

sub _is_integer {
    my ($value) = @_;
    my $flags = B::svref_2object(\$value)->FLAGS;
    return ($flags & B::SVp_IOK()) && !($flags & B::SVp_NOK()) ? 1 : 0;
}

sub _number {
    my ($value) = @_;
    if (_is_integer($value)) {
        die "integer outside the range JCS represents exactly\n" if abs($value) > 2**53;
        return "$value";
    }
    die "JCS has no representation for NaN or Infinity\n" if $value != $value || $value == 9**9**9 || $value == -9**9**9;
    return '0' if $value == 0;
    my $abs = abs($value);
    # The shortest digits that read back as the same double.
    my ($digits, $exponent);
    for my $precision (1 .. 17) {
        my $text = sprintf('%.*e', $precision - 1, $abs);
        next unless $text + 0 == $abs;
        my ($mantissa, $exp) = $text =~ /\A([0-9.]+)e([-+][0-9]+)\z/ or die "unexpected float form $text\n";
        ($digits = $mantissa) =~ s/\.//;
        $digits =~ s/0+\z//;
        $digits = '0' if $digits eq '';
        $exponent = $exp + 1;    # value = 0.digits * 10**exponent
        last;
    }
    my $sign = $value < 0 ? '-' : '';
    my ($k, $n) = (length($digits), $exponent);
    return $sign . $digits . ('0' x ($n - $k)) if $k <= $n && $n <= 21;
    return $sign . substr($digits, 0, $n) . '.' . substr($digits, $n) if 0 < $n && $n <= 21;
    return $sign . '0.' . ('0' x -$n) . $digits if -6 < $n && $n <= 0;
    my $e = $n - 1;
    my $mantissa = substr($digits, 0, 1) . ($k > 1 ? '.' . substr($digits, 1) : '');
    return $sign . $mantissa . 'e' . ($e >= 0 ? '+' : '-') . abs($e);
}

my %ESCAPE = ('"' => '\\"', '\\' => '\\\\', "\b" => '\\b', "\f" => '\\f', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t');

sub _string {
    my ($value) = @_;
    (my $text = "$value") =~ s{(["\\\x00-\x1f])}{ $ESCAPE{$1} // sprintf('\\u%04x', ord $1) }ge;
    return qq{"$text"};
}

sub _utf16 { return Encode::encode('UTF-16BE', $_[0]) }

sub jcs {
    my ($class, $value) = @_;
    return _jcs($value);
}

sub _jcs {
    my ($value) = @_;
    return 'null' unless defined $value;
    if (JSON::PP::is_bool($value)) { return ${$value} ? 'true' : 'false' }
    my $type = reftype($value);
    if (!defined $type) {
        return _is_number($value) ? _number($value) : _string($value);
    }
    if ($type eq 'ARRAY') { return '[' . join(',', map { _jcs($_) } @$value) . ']' }
    if ($type eq 'HASH') {
        my @keys = sort { _utf16($a) cmp _utf16($b) } keys %$value;
        return '{' . join(',', map { _string($_) . ':' . _jcs($value->{$_}) } @keys) . '}';
    }
    die "not a JSON value\n";
}

sub fingerprint {
    my ($class, $document) = @_;
    my %body = %$document;
    delete $body{domain_fingerprint};
    return Digest::SHA::sha256_hex(Encode::encode_utf8(_jcs(\%body)));
}

# ------------------------------------------------------------------ validation

# Whether a schema_version says 2, read without giving a number a string form
# (which would change its RFC 8785 serialization and so the fingerprint).
sub is_version_2 {
    my ($class, $version) = @_;
    return 0 unless defined($version) && !ref($version);
    # Only the number 2: the string "2" (a decoded JSON string) is not schema 2,
    # as in the reference. A number keeps its numeric flag even after it has
    # been printed, so a numeric flag is enough here.
    my $flags = B::svref_2object(\$version)->FLAGS;
    return ($flags & (B::SVp_IOK() | B::SVp_NOK())) && $version == 2 ? 1 : 0;
}

sub _relations {
    my ($document) = @_;
    my @relations;
    push @relations, [['source'], $document->{source}] if ref($document->{source}) eq 'HASH';
    if (ref($document->{schemas}) eq 'HASH') {
        for my $name (sort keys %{$document->{schemas}}) {
            push @relations, [['schemas', $name], $document->{schemas}{$name}] if ref($document->{schemas}{$name}) eq 'HASH';
        }
    }
    return @relations;
}

sub _scalar {
    my ($value) = @_;
    return 0 unless defined($value);
    return 1 if JSON::PP::is_bool($value);
    return defined(reftype($value)) ? 0 : 1;
}

# The version 2 rules: a list of {code, path}. Everything else is version 1's.
sub validate {
    my ($class, $document) = @_;
    my @errors;
    my $error = sub { push @errors, {code => $_[0], path => $_[1]} };
    return [{code => 'invalid_domain', path => []}] unless ref($document) eq 'HASH';
    my $version = $document->{schema_version};
    $error->('invalid_schema_version', ['schema_version'])
        unless $class->is_version_2($version);
    for my $relation (_relations($document)) {
        my ($path, $spec) = @$relation;
        my $columns = $spec->{columns};
        $error->('fields_removed', [@$path, 'fields']) if exists $spec->{fields};
        $error->('tenant_field_removed', [@$path, 'tenant_field']) if $path->[0] eq 'source' && exists $spec->{tenant_field};
        unless (ref($columns) eq 'HASH' && %$columns) {
            $error->('invalid_columns', [@$path, 'columns']);
            next;
        }
        if (exists $spec->{field_order}) {
            my $order = $spec->{field_order};
            my %seen;
            my $ok = ref($order) eq 'ARRAY' && !grep({ !defined($_) || ref($_) || $seen{$_}++ } @$order)
                && @$order == keys(%$columns) && !grep({ !exists $columns->{$_} } @$order);
            $error->('invalid_field_order', [@$path, 'field_order']) unless $ok;
        }
    }
    my $writes = $document->{writes};
    $error->('writes_scope_tenant_removed', ['writes', 'scope', 'tenant'])
        if ref($writes) eq 'HASH' && ref($writes->{scope}) eq 'HASH' && exists $writes->{scope}{tenant};
    if (exists $document->{tenant}) {
        my $tenant = $document->{tenant};
        my $columns = ref($document->{source}) eq 'HASH' && ref($document->{source}{columns}) eq 'HASH'
            ? $document->{source}{columns} : {};
        if (ref($tenant) ne 'HASH') {
            $error->('invalid_tenant', ['tenant']);
        } else {
            $error->('unknown_tenant_key', ['tenant', $_]) for sort grep { !$TENANT_KEYS{$_} } keys %$tenant;
            my $field = $tenant->{field};
            $error->('invalid_tenant_field', ['tenant', 'field'])
                unless defined($field) && !ref($field) && !_is_number($field) && exists $columns->{$field};
            if (exists $tenant->{write_field}) {
                my $write = $tenant->{write_field};
                $error->('invalid_tenant_write_field', ['tenant', 'write_field'])
                    unless defined($write) && !ref($write) && exists($columns->{$write}) && (!defined($field) || ref($field) || $write ne $field);
            }
            if (exists $tenant->{satisfied_by}) {
                my $sources = $tenant->{satisfied_by};
                my %seen;
                $error->('invalid_tenant_satisfied_by', ['tenant', 'satisfied_by'])
                    unless ref($sources) eq 'ARRAY' && @$sources
                        && !grep({ !defined($_) || ref($_) || !$SOURCES{$_} || $seen{$_}++ } @$sources);
            }
            if (exists $tenant->{pins}) {
                my $pins = $tenant->{pins};
                if (ref($pins) ne 'ARRAY') {
                    $error->('invalid_tenant_pins', ['tenant', 'pins']);
                } else {
                    for my $i (0 .. $#$pins) {
                        my $pin = $pins->[$i];
                        $error->('invalid_tenant_pin', ['tenant', 'pins', $i])
                            unless ref($pin) eq 'ARRAY' && @$pin == 2 && defined($pin->[0]) && !ref($pin->[0])
                                && exists($columns->{$pin->[0]}) && _scalar($pin->[1]);
                    }
                }
            }
        }
    }
    if (exists $document->{domain_fingerprint}) {
        my $declared = $document->{domain_fingerprint};
        $error->('domain_fingerprint_mismatch', ['domain_fingerprint'])
            unless defined($declared) && !ref($declared) && $declared eq $class->fingerprint($document);
    }
    return \@errors;
}

# ------------------------------------------------------------------ migration

sub _copy {
    my ($value) = @_;
    my $type = reftype($value);
    return $value if !defined($type) || JSON::PP::is_bool($value);
    return {map { ($_ => _copy($value->{$_})) } keys %$value} if $type eq 'HASH';
    return [map { _copy($_) } @$value] if $type eq 'ARRAY';
    return $value;
}

sub _sorted_names { return sort { _utf16($a) cmp _utf16($b) } @_ }

# Version 1 to version 2. Returns {document, diagnostics}, or
# {refused => {code, path}} for what the migration cannot place.
sub migrate {
    my ($class, $v1) = @_;
    my $refuse = sub { return {refused => {code => $_[0], path => $_[1]}} };
    return $refuse->('not_version_1', ['schema_version'])
        unless ref($v1) eq 'HASH' && (!defined($v1->{schema_version}) || (!ref($v1->{schema_version}) && $v1->{schema_version} eq '1'));
    my $doc = _copy($v1);
    my @diagnostics = ({code => 'domain_schema_deprecated'});
    $doc->{schema_version} = 2;

    for my $relation (_relations($doc)) {
        my ($path, $spec) = @$relation;
        next unless exists $spec->{fields};
        my $fields = delete $spec->{fields};
        my $columns = $spec->{columns};
        my %seen;
        return $refuse->('domain_migration_ambiguous', [@$path, 'fields'])
            unless ref($fields) eq 'ARRAY' && ref($columns) eq 'HASH'
                && !grep({ !defined($_) || ref($_) || $seen{$_}++ } @$fields)
                && @$fields == keys(%$columns) && !grep({ !exists $columns->{$_} } @$fields);
        my @sorted = _sorted_names(keys %$columns);
        $spec->{field_order} = $fields if join("\0", @$fields) ne join("\0", @sorted);
    }

    my $source = ref($doc->{source}) eq 'HASH' ? $doc->{source} : {};
    my $tenant_field = delete $source->{tenant_field};
    my $writes = ref($doc->{writes}) eq 'HASH' ? $doc->{writes} : undef;
    my $scope_tenant;
    if ($writes && ref($writes->{scope}) eq 'HASH') {
        $scope_tenant = delete $writes->{scope}{tenant};
        delete $writes->{scope} unless %{$writes->{scope}};
        delete $doc->{writes} unless %$writes;
    }
    my $tenant;
    if (defined($tenant_field) || defined($scope_tenant)) {
        my $scope_field = ref($scope_tenant) eq 'HASH' ? $scope_tenant->{field} // $scope_tenant->{tenant_field} : undef;
        my $field = $tenant_field // $scope_field;
        return $refuse->('domain_migration_ambiguous', ['writes', 'scope', 'tenant']) unless defined $field;
        $tenant = {field => $field};
        $tenant->{write_field} = $scope_field if defined($scope_field) && $scope_field ne $field;
        if (ref($scope_tenant) eq 'HASH') {
            my $sources = exists($scope_tenant->{satisfied_by}) ? $scope_tenant->{satisfied_by} : $scope_tenant->{sources};
            $tenant->{satisfied_by} = [@$sources] if ref($sources) eq 'ARRAY';
        }
    }

    if ($tenant && ref($doc->{required_filters}) eq 'ARRAY') {
        my %tenant_columns = map { ($_ => 1) } $tenant->{field}, (exists($tenant->{write_field}) ? $tenant->{write_field} : ());
        my (@kept, @pins);
        for my $entry (@{$doc->{required_filters}}) {
            if (ref($entry) eq 'ARRAY' && @$entry == 2 && defined($entry->[0]) && !ref($entry->[0])
                && $tenant_columns{$entry->[0]} && _scalar($entry->[1])) {
                push @pins, [$entry->[0], $entry->[1]];
            } else {
                push @kept, $entry;
            }
        }
        $tenant->{pins} = \@pins if @pins;
        if (@kept) { $doc->{required_filters} = \@kept } else { delete $doc->{required_filters} }
    }
    $doc->{tenant} = $tenant if $tenant;

    my $actions = ref($doc->{actions}) eq 'HASH' ? $doc->{actions} : {};
    if (ref($doc->{capabilities}) eq 'HASH') {
        my $capabilities = $doc->{capabilities};
        for my $id (sort keys %$actions) {
            my $action = $actions->{$id};
            next unless ref($action) eq 'HASH';
            my $name = $action->{capability};
            my $operation = ref($action->{execution}) eq 'HASH' ? $action->{execution}{operation} : undef;
            next unless defined($name) && !ref($name) && defined($operation) && !ref($operation);
            my $entry = $capabilities->{$name};
            next unless ref($entry) eq 'HASH' && join(',', sort keys %$entry) eq 'action,operations'
                && defined($entry->{action}) && !ref($entry->{action}) && $entry->{action} eq $id
                && ref($entry->{operations}) eq 'ARRAY';
            my %ops;
            next if grep { !defined($_) || ref($_) || $ops{$_}++ } @{$entry->{operations}};
            my %want = map { ($_ => 1) } 'action', $operation;
            next unless join(',', sort keys %ops) eq join(',', sort keys %want);
            delete $capabilities->{$name};
        }
        delete $doc->{capabilities} unless %$capabilities;
    }

    if (exists $doc->{domain_fingerprint}) {
        push @diagnostics, {code => 'declared_fingerprint_dropped', value => delete $doc->{domain_fingerprint}};
    }
    return {document => $doc, diagnostics => \@diagnostics};
}

# ------------------------------------------------------------------ to version 1

# The version 1 form of a valid version 2 document, for the rest of Selecto's
# parser: the inverse of the migration.
sub to_version_1 {
    my ($class, $v2) = @_;
    my $doc = _copy($v2);
    delete $doc->{domain_fingerprint};
    $doc->{schema_version} = 1;
    for my $relation (_relations($doc)) {
        my (undef, $spec) = @$relation;
        my $order = delete $spec->{field_order};
        $spec->{fields} = $order // [_sorted_names(keys %{$spec->{columns}})];
    }
    if (my $tenant = delete $doc->{tenant}) {
        $doc->{source}{tenant_field} = $tenant->{field};
        # The tenant declaration is also the public write authority, so the
        # schema 1 form always carries writes.scope.tenant.
        my $scope = {required => JSON::PP::true, field => $tenant->{write_field} // $tenant->{field}};
        $scope->{satisfied_by} = $tenant->{satisfied_by} if exists $tenant->{satisfied_by};
        $doc->{writes}{scope}{tenant} = $scope;
        # Pins lead, as tenant pins usually do in version 1.
        unshift @{$doc->{required_filters}}, map { [@$_] } @{$tenant->{pins}} if ref($tenant->{pins}) eq q{ARRAY} && @{$tenant->{pins}};
    }
    if (ref($doc->{actions}) eq 'HASH') {
        for my $id (sort keys %{$doc->{actions}}) {
            my $action = $doc->{actions}{$id};
            next unless ref($action) eq 'HASH' && defined($action->{capability}) && !ref($action->{capability});
            my $operation = ref($action->{execution}) eq 'HASH' ? $action->{execution}{operation} : undef;
            next unless defined($operation) && !ref($operation);
            next if ref($doc->{capabilities}) eq 'HASH' && exists $doc->{capabilities}{$action->{capability}};
            $doc->{capabilities}{$action->{capability}} = {action => $id, operations => ['action', $operation]};
        }
    }
    return $doc;
}

# ------------------------------------------------------------------ nested domains

# The domains nested in write relationships (writes.relationships.*.domain),
# at any depth, loaded in place into the schema 1 form the write engine reads:
# a schema 2 one by its own rules and to_version_1 (its tenant becomes
# source.tenant_field and writes.scope.tenant), and one that is not schema 2
# refuses a top-level tenant as a top-level domain does. Returns a list of
# {code, path}; a domain that breaks a rule is left as it was.
sub load_nested_domains {
    my ($class, $document, $path) = @_;
    $path //= [];
    my @errors;
    return \@errors unless ref($document) eq 'HASH' && ref($document->{writes}) eq 'HASH'
        && ref($document->{writes}{relationships}) eq 'HASH';
    my $relationships = $document->{writes}{relationships};
    for my $id (sort keys %$relationships) {
        my $spec = $relationships->{$id};
        next unless ref($spec) eq 'HASH' && ref($spec->{domain}) eq 'HASH';
        my $nested = $spec->{domain};
        my @at = (@$path, 'writes', 'relationships', $id, 'domain');
        if ($class->is_version_2($nested->{schema_version})) {
            my $rules = $class->validate($nested);
            if (@$rules) {
                push @errors, map { {code => $_->{code}, path => [@at, @{$_->{path}}]} } @$rules;
                next;
            }
            $nested = $spec->{domain} = $class->to_version_1($nested);
        } elsif (exists $nested->{tenant}) {
            push @errors, {code => 'unknown_domain_key', path => [@at, 'tenant']};
            next;
        }
        push @errors, @{$class->load_nested_domains($nested, \@at)};
    }
    return \@errors;
}

# ------------------------------------------------------------------ composition

# A plain copy that keeps each scalar's number or string form, so the copy's
# RFC 8785 serialization (and so its fingerprint) is the original's.
sub copy {
    my ($class, $value) = @_;
    return _copy($value);
}

# What a schema 1 shaped overlay cannot say to a schema 2 base: a list of
# {code, path}. Tenancy is declared once, in the top-level tenant, so the
# schema 1 tenancy keys refuse rather than being guessed into it; the version
# is not the overlay's to change; and the fingerprint is computed.
sub overlay_errors {
    my ($class, $overlay) = @_;
    my @errors;
    return \@errors unless ref($overlay) eq 'HASH';
    push @errors, {code => 'overlay_schema_version', path => ['schema_version']}
        if exists($overlay->{schema_version}) && !$class->is_version_2($overlay->{schema_version});
    push @errors, {code => 'domain_fingerprint_computed', path => ['domain_fingerprint']}
        if exists $overlay->{domain_fingerprint};
    push @errors, {code => 'tenant_field_removed', path => ['source', 'tenant_field']}
        if ref($overlay->{source}) eq 'HASH' && exists $overlay->{source}{tenant_field};
    push @errors, {code => 'writes_scope_tenant_removed', path => ['writes', 'scope', 'tenant']}
        if ref($overlay->{writes}) eq 'HASH' && ref($overlay->{writes}{scope}) eq 'HASH'
            && exists $overlay->{writes}{scope}{tenant};
    return \@errors;
}

# Settles a merged schema 2 document in place and returns a list of
# {code, path}. A relation's schema 1 `fields` list (from an overlay) must name
# exactly its composed columns; it becomes the field_order (none when it is the
# sorted order). Columns an overlay adds to a relation whose field_order came
# from the base follow that order, sorted. A declared fingerprint is dropped:
# the composed document's fingerprint is computed.
sub settle_composition {
    my ($class, $document) = @_;
    my @errors;
    delete $document->{domain_fingerprint};
    for my $relation (_relations($document)) {
        my ($path, $spec) = @$relation;
        my $columns = $spec->{columns};
        next unless ref($columns) eq 'HASH';
        if (exists $spec->{fields}) {
            my $fields = delete $spec->{fields};
            my %seen;
            unless (ref($fields) eq 'ARRAY' && !grep({ !defined($_) || ref($_) || $seen{$_}++ } @$fields)
                && @$fields == keys(%$columns) && !grep({ !exists $columns->{$_} } @$fields)) {
                push @errors, {code => 'overlay_fields_not_columns', path => [@$path, 'fields']};
                next;
            }
            if (join("\0", @$fields) ne join("\0", _sorted_names(keys %$columns))) {
                $spec->{field_order} = [@$fields];
            } else {
                delete $spec->{field_order};
            }
        } elsif (ref($spec->{field_order}) eq 'ARRAY') {
            my %ordered = map { (defined($_) && !ref($_) ? ($_ => 1) : ()) } @{$spec->{field_order}};
            push @{$spec->{field_order}}, _sorted_names(grep { !$ordered{$_} } keys %$columns);
        }
    }
    return \@errors;
}

1;

__END__

=head1 NAME

Selecto::Domain::SchemaV2 - domain schema 2: fingerprint, rules, migration

=head1 DESCRIPTION

Domain schema 2 (certification specification 3.0) declares tenancy once in a
top-level C<tenant>, lists a relation's fields as its C<columns> (ordered by an
optional C<field_order>), implies the capability entry an action only restates,
and computes the domain fingerprint: the SHA-256 of the RFC 8785 serialization
of the document without C<domain_fingerprint>. L<Selecto::Domain/parse> accepts
both versions; a version 1 domain reports C<domain_schema_deprecated>.

C<< jcs($value) >>, C<< fingerprint($document) >>, C<< validate($document) >>
(a list of C<{code, path}>), C<< migrate($v1) >> (C<{document, diagnostics}> or
C<{refused}>) and C<< to_version_1($v2) >> are class methods.

C<< load_nested_domains($doc) >> loads, in place and at any depth, the
domains nested in write relationships (C<writes.relationships.*.domain>) into
the schema 1 form the write engine reads: a schema 2 one by its rules and
C<to_version_1>, so its tenant becomes that child's C<writes.scope.tenant>.
A nested domain that is not schema 2 and has a top-level C<tenant> is an
C<unknown_domain_key> error. It returns a list of C<{code, path}>.

Composition (L<Selecto::Domain/compose>) uses three more. C<< copy($value) >>
copies a document keeping each scalar's number or string form.
C<< overlay_errors($overlay) >> lists what an overlay cannot say to a schema 2
base: a C<schema_version> other than the number 2
(C<overlay_schema_version>), a C<domain_fingerprint>
(C<domain_fingerprint_computed>), and the schema 1 tenancy keys
C<source.tenant_field> (C<tenant_field_removed>) and C<writes.scope.tenant>
(C<writes_scope_tenant_removed>); tenancy is declared in the top-level
C<tenant>, which an overlay deep-merges into. C<< settle_composition($doc) >>
settles a merged document in place: a schema 1 C<fields> list must name exactly
the relation's composed columns (else C<overlay_fields_not_columns>) and
becomes its C<field_order>, or none when it is the sorted order; columns added
to a relation whose C<field_order> came from the base are appended to it,
sorted; and a declared C<domain_fingerprint> is dropped, since the composed
document's fingerprint is computed.

=cut
