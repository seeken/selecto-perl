package Selecto::Domain::Identity;

use 5.034;
use strict;
use warnings;
use B ();
use JSON::PP ();
use Cpanel::JSON::XS ();
use Scalar::Util qw(blessed refaddr);
use Selecto::Error ();

my @CANONICAL = qw(schema_version domain_version domain_fingerprint name source schemas joins
    default_selected required_selected required_filters required_order_by required_group_by filters
    functions query_members query_library rules co_domains domain_dependencies operations experiences
    published_views detail_actions editors components imports domain_data extensions);
my @PROJECTION = qw(columns custom_columns json_schemas subfilters window_functions pagination retarget redact_fields);
my @PROPOSED = qw(writes actions events capabilities source_relationships choice_sources);
my %CATEGORY = ((map { $_ => 'canonical' } @CANONICAL), (map { $_ => 'projection' } @PROJECTION),
    (map { $_ => 'proposed' } @PROPOSED));
my @MAPS = qw(source schemas joins filters functions query_members query_library rules operations
    experiences published_views detail_actions editors components imports columns custom_columns
    json_schemas subfilters window_functions pagination retarget writes actions events capabilities
    source_relationships choice_sources co_domains);
my @LISTS = qw(default_selected required_selected required_filters required_order_by required_group_by
    domain_dependencies redact_fields);
my %MAP = map { $_ => 1 } @MAPS;
my %COLLISION = map { $_ => 1 } qw(actions capabilities source_relationships choice_sources co_domains);
my @QUERY = qw(default_selected required_selected required_filters required_order_by required_group_by
    filters functions query_members query_library published_views);

sub normalize {
    my ($class, $input) = @_;
    $input = $input->as_contract if blessed($input) && $input->isa('Selecto::Domain');
    return _result(undef, [_diagnostic('invalid_domain', [], 'domain must be an object')], [], undef, 0)
        unless ref($input) eq 'HASH';
    my $authored = _clone($input);
    my ($version, $inferred, $version_warning) = _schema_version($authored);
    my %sections = map { $_ => [] } qw(canonical projection proposed unknown);
    push @{$sections{$CATEGORY{$_} // 'unknown'}}, $_ for sort keys %$authored;
    my @warnings = @$version_warning;
    for my $section (@MAPS, @LISTS, 'extensions', 'name', 'domain_version', 'domain_fingerprint') {
        next unless exists $authored->{$section};
        my $value = $authored->{$section};
        my $valid = $MAP{$section} ? ref($value) eq 'HASH'
            : grep($_ eq $section, @LISTS) ? ref($value) eq 'ARRAY'
            : $section eq 'extensions' ? ref($value) eq 'HASH' || ref($value) eq 'ARRAY'
            : $section eq 'domain_version' ? _version_label($value)
            : $section eq 'domain_fingerprint' ? _string($value) && $value =~ /\S/
            : _string($value);
        push @warnings, _diagnostic('invalid_section_shape', [$section], 'domain section has an invalid shape')
            unless $valid;
    }
    push @warnings, {code => 'schema_version_inferred', schema_version => $version,
        message => 'schema_version was inferred for compatibility'} if $inferred;
    for my $category (qw(projection proposed unknown)) {
        push @warnings, {code => $category . '_sections', sections => _clone($sections{$category}),
            message => "$category domain sections are present"} if @{$sections{$category}};
    }
    my $domain = _clone($authored);
    $domain->{schema_version} = $version;
    my $domain_version = _version_label($authored->{domain_version})
        ? _trim($authored->{domain_version}) : undef;
    my $fingerprint = _string($authored->{domain_fingerprint}) && $authored->{domain_fingerprint} =~ /\S/
        ? _trim($authored->{domain_fingerprint}) : undef;
    $domain->{domain_version} = $domain_version if defined $domain_version;
    $domain->{domain_fingerprint} = $fingerprint if defined $fingerprint;
    # Canonical normalization exposes an empty write registry for a source.
    # Diagnostics classify authored keys; a subsequent composition normalizes
    # this canonical map and consequently sees the proposed writes section.
    $domain->{writes} = {} if ref($domain->{source}) eq 'HASH' && !exists $domain->{writes};
    my $normalized = {schema_version => $version, domain_version => $domain_version,
        domain_fingerprint => $fingerprint, authored_domain => $authored, domain => $domain,
        sections => _clone(\%sections), source => _clone($domain->{source}),
        schemas => _clone(exists($domain->{schemas}) ? $domain->{schemas} : {}),
        joins => _clone(exists($domain->{joins}) ? $domain->{joins} : {}),
        query => {map { exists($domain->{$_}) ? ($_ => _clone($domain->{$_})) : () } @QUERY}};
    my $result = _result($normalized, [], \@warnings, $version, $inferred);
    $result->{diagnostics}{sections} = _clone(\%sections);
    return $result;
}

# This validates source identity and relation fields, not executable query/write policy.
sub validate {
    my ($class, $input) = @_;
    my $result = $class->normalize($input);
    return $result unless $result->{ok};
    my $normalized = $result->{normalized};
    my $domain = $normalized->{domain};
    my $errors = $result->{diagnostics}{errors};
    for my $section (qw(source schemas)) {
        push @$errors, _diagnostic('missing_required_section', [$section], 'required domain section is missing')
            unless exists $normalized->{authored_domain}{$section};
    }
    _relation_errors($domain->{source}, ['source'], 'source', $errors);
    if (ref($normalized->{schemas}) eq 'HASH') {
        _relation_errors($normalized->{schemas}{$_}, ['schemas', $_], 'schema', $errors)
            for sort keys %{$normalized->{schemas}};
    } else {
        push @$errors, _diagnostic('invalid_section_shape', ['schemas'], 'schemas must be an object');
    }
    $result->{ok} = @$errors ? JSON::PP::false : JSON::PP::true;
    return $result;
}

sub compose {
    my ($class, $base, $overlays) = @_;
    my $result = $class->normalize($base);
    return $result unless $result->{ok};
    $overlays = [] unless defined $overlays;
    $overlays = [$overlays] if ref($overlays) eq 'HASH';
    return _overlay_error(undef) unless ref($overlays) eq 'ARRAY';
    my $domain = $result->{normalized}{domain};
    my @warnings;
    for my $index (0 .. $#$overlays) {
        my $overlay = $overlays->[$index];
        return _overlay_error($index) unless ref($overlay) eq 'HASH';
        for my $section (sort keys %COLLISION) {
            next unless ref($domain->{$section}) eq 'HASH' && ref($overlay->{$section}) eq 'HASH';
            push @warnings, {code => 'overlay_collision', section => $section, key => $_,
                overlay_index => $index, message => 'overlay updates an existing registry entry'}
                for grep { exists $domain->{$section}{$_} } sort keys %{$overlay->{$section}};
        }
        $domain = _merge($domain, $overlay, []);
    }
    # Metadata inspection never invokes extension or other declared callbacks.
    $result = $class->normalize($domain);
    unshift @{$result->{diagnostics}{warnings}}, @warnings;
    return $result;
}

sub query_identity {
    my ($class, $input) = @_;
    my $result = $class->normalize($input);
    return $result unless $result->{ok};
    my $domain = $result->{normalized}{domain};
    my $source = ref($domain->{source}) eq 'HASH' ? $domain->{source} : {};
    my $columns = ref($source->{columns}) eq 'HASH' ? $source->{columns} : {};
    $result->{identity} = {name => $domain->{name}, source => {map { $_ => _clone($source->{$_}) }
        qw(source_table primary_key)}, fields => [map { {id => $_, type => _clone($columns->{$_}{type})} }
        grep { ref($columns->{$_}) eq 'HASH' } sort keys %$columns]};
    return $result;
}

sub _relation_errors {
    my ($relation, $path, $kind, $errors) = @_;
    unless (ref($relation) eq 'HASH') {
        push @$errors, _diagnostic('invalid_section_shape', $path, 'relation must be an object');
        return;
    }
    my @required = ($kind eq 'source' ? ('source_table') : (), qw(primary_key fields columns));
    my @missing = grep { !exists $relation->{$_} } @required;
    push @$errors, { %{_diagnostic('missing_required_keys', $path, 'relation is missing required keys')},
        keys => \@missing} if @missing;
    push @$errors, _diagnostic('invalid_source_table', [@$path, 'source_table'], 'source_table must be a string')
        if exists($relation->{source_table}) && !_string($relation->{source_table});
    push @$errors, _diagnostic('invalid_root_values', [@$path, 'values'], 'root source must use source_table')
        if $kind eq 'source' && exists $relation->{values};
    if ($kind ne 'source') {
        my $has_table = exists $relation->{source_table};
        my $has_values = exists $relation->{values};
        push @$errors, _diagnostic('invalid_relation_source', $path, 'schema must declare exactly one of source_table or values')
            if $has_table == $has_values;
        _values_errors($relation, $path, $errors) if $has_values;
    }
    my $fields = $relation->{fields};
    my $columns = $relation->{columns};
    push @$errors, _diagnostic('invalid_fields', [@$path, 'fields'], 'fields must be an array of identifiers')
        if exists($relation->{fields}) && (ref($fields) ne 'ARRAY' || grep { !_string($_) } @$fields);
    if (exists $relation->{columns}) {
        if (ref($columns) ne 'HASH') {
            push @$errors, _diagnostic('invalid_columns', [@$path, 'columns'], 'columns must be an object');
        } else {
            push @$errors, _diagnostic('invalid_column_definition', [@$path, 'columns', $_], 'column must be an object')
                for grep { ref($columns->{$_}) ne 'HASH' } sort keys %$columns;
        }
    }
    if (ref($fields) eq 'ARRAY' && ref($columns) eq 'HASH') {
        push @$errors, _diagnostic($kind . '_field_missing_column', [@$path, 'columns', $_], 'field is missing a column definition')
            for grep { _string($_) && !exists $columns->{$_} } @$fields;
    }
    if (exists $relation->{primary_key}) {
        my $key = $relation->{primary_key};
        my @keys = ref($key) eq 'ARRAY' ? @$key : ($key);
        my %seen;
        if (!@keys || grep { !_string($_) || $seen{$_}++ } @keys) {
            push @$errors, _diagnostic('invalid_primary_key', [@$path, 'primary_key'], 'primary_key must contain distinct identifiers');
        } elsif (ref($fields) eq 'ARRAY') {
            my %fields = map { _string($_) ? ($_ => 1) : () } @$fields;
            push @$errors, _diagnostic('primary_key_not_found', [@$path, 'primary_key'], 'primary key is not listed in fields')
                for grep { !$fields{$_} } @keys;
        }
    }
}

sub _values_errors {
    my ($relation, $path, $errors) = @_;
    my ($fields, $rows) = @{$relation}{qw(fields values)};
    unless (ref($fields) eq 'ARRAY' && @$fields && !grep { !_string($_) } @$fields) {
        push @$errors, _diagnostic('invalid_relation_values', [@$path, 'values'], 'values require a non-empty field list');
        return;
    }
    unless (ref($rows) eq 'ARRAY' && @$rows) {
        push @$errors, _diagnostic('invalid_relation_values', [@$path, 'values'], 'values must be a non-empty row list');
        return;
    }
    my %fields = map { $_ => 1 } @$fields;
    for my $index (0 .. $#$rows) {
        my $row = $rows->[$index];
        my $valid = ref($row) eq 'HASH' && keys(%$row) == keys(%fields) &&
            !grep { !exists($fields{$_}) || !_scalar_literal($row->{$_}) } keys %$row;
        push @$errors, _diagnostic('invalid_relation_values_row', [@$path, 'values', $index],
            'values row must contain exactly the declared scalar fields') unless $valid;
    }
}

sub _scalar_literal { !ref($_[0]) || JSON::PP::is_bool($_[0]) }

sub _merge {
    my ($base, $overlay, $path) = @_;
    my $result = _clone($base);
    for my $key (sort keys %$overlay) {
        my @next = (@$path, $key);
        my ($old, $new) = ($result->{$key}, $overlay->{$key});
        if (ref($old) eq 'ARRAY' && ref($new) eq 'ARRAY' &&
            ((@next == 1 && ($key eq 'redact_fields' || $key eq 'extensions')) ||
             (@next == 2 && $next[0] eq 'source' && $key eq 'redact_fields'))) {
            my %seen;
            my $json = Cpanel::JSON::XS->new->canonical;
            $result->{$key} = [map { _clone($_) } grep {
                my $id = $json->encode(_key($_));
                !$seen{$id}++
            } (@$old, @$new)];
        } elsif (ref($old) eq 'HASH' && ref($new) eq 'HASH' &&
            (@next > 1 || $MAP{$key} || $key eq 'extensions')) {
            $result->{$key} = _merge($old, $new, \@next);
        } else {
            $result->{$key} = _clone($new);
        }
    }
    return $result;
}

sub _schema_version {
    my ($domain) = @_;
    return (1, 1, []) unless exists $domain->{schema_version};
    my $value = $domain->{schema_version};
    my $flags = !ref($value) && defined($value) ? B::svref_2object(\$value)->FLAGS : 0;
    my $text = defined($value) && !ref($value) ? "$value" : '';
    my $digits = $text; $digits =~ s/^\+//; $digits =~ s/^0+(?=[0-9])//;
    if ($text =~ /\A\+?[0-9]+\z/ && !(($flags & B::SVp_NOK()) && !($flags & (B::SVp_POK() | B::SVp_IOK())))
        && (length($digits) < 19 || (length($digits) == 19 && $digits le '9223372036854775807')) && $digits ne '0') {
        my $version = 0 + $digits;
        return ($version, 0, $version > 1 ? [{code => 'unsupported_schema_version', schema_version => $version,
            supported_schema_version => 1, message => 'schema_version is newer than this release understands'}] : []);
    }
    return (1, 0, [{code => 'invalid_schema_version', value => _clone($value), schema_version => 1,
        message => 'schema_version must be a positive integer; using the current schema version'}]);
}

sub _string { defined($_[0]) && !ref($_[0]) && (B::svref_2object(\$_[0])->FLAGS & B::SVp_POK()) }
sub _version_label {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value);
    return $value =~ /\S/ if _string($value);
    return (B::svref_2object(\$value)->FLAGS & B::SVp_IOK()) ? 1 : 0;
}
sub _trim { my $value = $_[0]; $value =~ s/^\s+|\s+$//g if _string($value); return $value }
sub _diagnostic { +{code => $_[0], path => _clone($_[1]), message => $_[2]} }
sub _result {
    my ($normalized, $errors, $warnings, $version, $inferred) = @_;
    return {ok => @$errors ? JSON::PP::false : JSON::PP::true, normalized => $normalized,
        diagnostics => {errors => $errors, warnings => $warnings, schema_version => $version,
            schema_version_inferred => $inferred ? JSON::PP::true : JSON::PP::false}};
}
sub _overlay_error {
    my ($index) = @_;
    my $error = _diagnostic('invalid_domain_overlay', [], 'domain overlays must be objects');
    $error->{overlay_index} = $index;
    return _result(undef, [$error], [], undef, 0);
}
sub _clone {
    my ($value, $active) = @_;
    return $value unless ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
    $active //= {};
    my $id = refaddr($value);
    Selecto::Error->throw('invalid_domain', 'domain metadata must not contain cycles') if $active->{$id};
    local $active->{$id} = 1;
    return ref($value) eq 'HASH' ? {map { $_ => _clone($value->{$_}, $active) } keys %$value}
        : [map { _clone($_, $active) } @$value];
}
sub _key {
    my ($value) = @_;
    return {declared_callback_identity => refaddr($value)} if ref($value) eq 'CODE';
    return {map { $_ => _key($value->{$_}) } keys %$value} if ref($value) eq 'HASH';
    return [map { _key($_) } @$value] if ref($value) eq 'ARRAY';
    return $value;
}

1;

=head1 NAME

Selecto::Domain::Identity - metadata-only domain identity normalization

=head1 METHODS

C<normalize>, C<validate>, C<compose>, and C<query_identity> return an object
containing C<ok>, C<normalized>, and structured C<diagnostics>. Validation checks
the required source/schemas identity sections, relation fields, column shapes,
primary keys, and schema table/VALUES source identity. VALUES rows must be
non-empty, scalar, and contain exactly the declared fields. It does not authorize executable query, write, action, or
extension policy; use C<Selecto::Domain-E<gt>parse> at that boundary.

Declared versions and fingerprints are opaque metadata. Schema versions are
positive signed-64-bit integers or integer strings; missing versions infer v1,
future versions warn, and invalid versions warn and use v1. Inspection copies
input containers and never executes callbacks. Composition deep-merges known
map sections, unions redaction/extension lists, and replaces other lists.
It does not invoke extension callbacks or expand executable shorthand.

=cut
