package Selecto::Domain::Overlay;

use 5.034;
use strict;
use warnings;
use Cpanel::JSON::XS ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Domain ();
use Selecto::Domain::SchemaV2 ();
use Selecto::DataRules ();
use Selecto::Limits ();
use Selecto::Error ();

my %MAP_SECTION = map { $_ => 1 } qw(
    source schemas joins associations filters functions query_members query_library tenant
    published_views detail_actions components columns custom_columns jsonb_schemas
    subfilters window_functions pagination retarget writes actions imports capabilities
    source_relationships choice_sources co_domains editors
);
my %COLLISION_SECTION = map { $_ => 1 } qw(
    actions capabilities source_relationships choice_sources
);
my %LIST_SECTION = map { $_ => 1 } qw(
    default_selected required_selected required_order_by required_group_by redact_fields
);

sub compose {
    my ($class, $base, @overlays) = @_;
    @overlays = @{$overlays[0]} if @overlays == 1 && ref($overlays[0]) eq 'ARRAY';

    my $base_domain = _coerce_domain($base, 'base domain');
    # A schema 2 base composes as its schema 2 document and stays schema 2.
    my $schema_2 = $base_domain->schema_version == 2;
    my $contract = $schema_2 ? $base_domain->as_document : $base_domain->as_contract;
    _validate_section_shapes($contract, undef);
    my @warnings;

    for my $index (0 .. $#overlays) {
        my $overlay = _overlay_fragment($overlays[$index], $index);
        _throw_schema_2_errors(Selecto::Domain::SchemaV2->overlay_errors($overlay), $index)
            if $schema_2;
        push @warnings, _collision_warnings($contract, $overlay, $index);
        $contract = _merge_domain_maps($contract, $overlay);
    }

    _throw_schema_2_errors(Selecto::Domain::SchemaV2->settle_composition($contract), undef)
        if $schema_2;
    _validate_section_shapes($contract, undef);
    my $domain = Selecto::Domain->parse($contract, strict => 1);
    my $diagnostics = {
        errors => [],
        warnings => \@warnings,
        overlay_count => scalar(@overlays),
    };
    return wantarray ? ($domain, dclone($diagnostics)) : $domain;
}

sub merge_contracts {
    my ($class, $base, @overlays) = @_;
    my ($domain, $diagnostics) = $class->compose($base, @overlays);
    my $contract = $domain->as_document;
    return wantarray ? ($contract, $diagnostics) : $contract;
}

sub _throw_schema_2_errors {
    my ($errors, $index) = @_;
    return unless @$errors;
    my $first = $errors->[0];
    Selecto::Error->throw(
        'invalid_domain_overlay',
        "domain overlay against a schema 2 domain: $first->{code}",
        {
            reason => $first->{code},
            path => $first->{path},
            errors => $errors,
            (defined($index) ? (overlay_index => $index) : ()),
        },
    );
}

sub validate_contract_shapes {
    my ($class, $contract) = @_;
    Selecto::Error->throw('invalid_domain', 'domain contract must be an object')
        unless ref($contract) eq 'HASH';
    _validate_section_shapes($contract, undef);
    return 1;
}

sub _coerce_domain {
    my ($value, $label) = @_;
    return $value if blessed($value) && $value->isa('Selecto::Domain');
    my $domain = eval { Selecto::Domain->parse($value, strict => 1) };
    die $@ if $@;
    return $domain;
}

sub _overlay_fragment {
    my ($value, $index) = @_;
    if (blessed($value) && $value->can('overlay')) {
        $value = $value->overlay;
    }
    Selecto::Error->throw(
        'invalid_domain_overlay',
        'Selecto domain overlays must be objects',
        {overlay_index => $index, actual => _value_type($value)},
    ) unless ref($value) eq 'HASH';
    _validate_section_shapes($value, $index);
    return Selecto::Domain::_clone_with_rules($value);
}

sub _validate_section_shapes {
    my ($value, $overlay_index) = @_;
    my $code = defined($overlay_index) ? 'invalid_domain_overlay' : 'invalid_domain';
    my $label = defined($overlay_index) ? 'domain overlay section' : 'domain section';
    for my $section (sort keys %MAP_SECTION) {
        next unless exists $value->{$section};
        Selecto::Error->throw(
            $code,
            "$label $section must be an object",
            {
                section => $section,
                (defined($overlay_index) ? (overlay_index => $overlay_index) : ()),
                actual => _value_type($value->{$section}),
            },
        ) unless ref($value->{$section}) eq 'HASH';
    }
    for my $section (sort keys %LIST_SECTION) {
        next unless exists $value->{$section};
        Selecto::Error->throw(
            $code,
            "$label $section must be an array",
            {
                section => $section,
                (defined($overlay_index) ? (overlay_index => $overlay_index) : ()),
                actual => _value_type($value->{$section}),
            },
        ) unless ref($value->{$section}) eq 'ARRAY';
    }
    if (exists($value->{extensions})
        && ref($value->{extensions}) ne 'ARRAY'
        && ref($value->{extensions}) ne 'HASH') {
        Selecto::Error->throw(
            $code,
            "$label extensions must be an array or object",
            {
                section => 'extensions',
                (defined($overlay_index) ? (overlay_index => $overlay_index) : ()),
                actual => _value_type($value->{extensions}),
            },
        );
    }
    if (ref($value->{source}) eq 'HASH' && exists $value->{source}{redact_fields}) {
        Selecto::Error->throw(
            $code,
            "$label source.redact_fields must be an array",
            {
                section => 'source.redact_fields',
                (defined($overlay_index) ? (overlay_index => $overlay_index) : ()),
                actual => _value_type($value->{source}{redact_fields}),
            },
        ) unless ref($value->{source}{redact_fields}) eq 'ARRAY';
    }
}

sub _merge_domain_maps {
    my ($base, $overlay) = @_;
    my $result = Selecto::Domain::_clone_with_rules($base);
    for my $key (sort keys %$overlay) {
        my $base_value = $result->{$key};
        my $overlay_value = $overlay->{$key};
        $result->{$key} = _merge_section_value($key, $base_value, $overlay_value, [$key]);
    }
    return $result;
}

sub _merge_section_value {
    my ($section, $base, $overlay, $path) = @_;
    if (($section eq 'extensions' || $section eq 'redact_fields')
        && ref($base) eq 'ARRAY' && ref($overlay) eq 'ARRAY') {
        return _unique_list(@$base, @$overlay);
    }
    if ($section eq 'extensions'
        && ref($base) eq 'HASH' && ref($overlay) eq 'HASH') {
        return _deep_merge($base, $overlay, $path);
    }
    if ($MAP_SECTION{$section} && ref($base) eq 'HASH' && ref($overlay) eq 'HASH') {
        return _deep_merge($base, $overlay, $path);
    }
    return _clone($overlay, $path);
}

sub _deep_merge {
    my ($base, $overlay, $path) = @_;
    my $result = _clone($base, $path);
    for my $key (sort keys %$overlay) {
        my @next_path = (@$path, $key);
        if (@next_path == 2 && $next_path[0] eq 'source' && $next_path[1] eq 'redact_fields'
            && ref($result->{$key}) eq 'ARRAY' && ref($overlay->{$key}) eq 'ARRAY') {
            $result->{$key} = _unique_list(@{$result->{$key}}, @{$overlay->{$key}});
        } elsif (ref($result->{$key}) eq 'HASH' && ref($overlay->{$key}) eq 'HASH') {
            $result->{$key} = _deep_merge($result->{$key}, $overlay->{$key}, \@next_path);
        } else {
            $result->{$key} = _clone($overlay->{$key}, \@next_path);
        }
    }
    return $result;
}

sub _collision_warnings {
    my ($base, $overlay, $index) = @_;
    my @warnings;
    for my $section (sort keys %COLLISION_SECTION) {
        next unless ref($base->{$section}) eq 'HASH' && ref($overlay->{$section}) eq 'HASH';
        for my $key (sort keys %{$overlay->{$section}}) {
            next unless exists $base->{$section}{$key};
            push @warnings, {
                code => 'domain_composition_collision',
                message => "domain overlay $index updates existing $section entry $key",
                section => $section,
                key => $key,
                overlay_index => $index,
            };
        }
    }
    return @warnings;
}

sub _unique_list {
    my @values = @_;
    my (%seen, @unique);
    for my $value (@values) {
        my $key = eval { Cpanel::JSON::XS->new->canonical(1)->allow_nonref(1)->encode($value) };
        $key = defined($key) ? $key : _value_type($value) . ':' . "$value";
        next if $seen{$key}++;
        push @unique, _clone($value);
    }
    return \@unique;
}

sub _value_type {
    my ($value) = @_;
    return 'undefined' unless defined $value;
    return lc(ref($value)) if ref($value);
    return 'scalar';
}

sub _clone {
    my ($value, $path) = @_;
    return Selecto::DataRules::_copy_plain($value, Selecto::Limits->new,
        'invalid_domain_overlay', 'policy overlay')
        if $path && ($path->[0] eq 'rules' || $path->[0] eq 'writes' || $path->[0] eq 'actions');
    return ref($value) ? dclone($value) : $value;
}

1;

__END__

=head1 NAME

Selecto::Domain::Overlay - deterministic composition of Selecto domain contracts

=head1 DESCRIPTION

Implements L<Selecto::Domain/compose>. Maps deep-merge, C<redact_fields> and
C<extensions> lists union uniquely, and other lists and scalar values are
replaced by later overlays. Updates to existing C<actions>, C<capabilities>,
C<source_relationships> and C<choice_sources> entries are reported as
collision diagnostics. The complete result crosses the strict
L<Selecto::Domain> parser before it is returned.

A schema 2 base (a schema 2 document, or a domain parsed from one) composes as
its schema 2 document, so the result is a schema 2 domain: its top-level
C<tenant> deep-merges like the other maps, and its fingerprint is computed for
the composed document. Overlays written in schema 1 shape are read this way: a
relation's C<fields> list must name exactly that relation's composed columns
and becomes its C<field_order> (none when sorted); columns added to a relation
whose C<field_order> came from the base are appended to it, sorted; and
C<source.tenant_field>, C<writes.scope.tenant>, a C<schema_version> other than 2
and a C<domain_fingerprint> refuse with C<invalid_domain_overlay>, its
C<reason> naming the rule (see L<Selecto::Domain::SchemaV2>). C<merge_contracts>
returns the schema 2 document for a schema 2 base.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; call C<< Selecto::Domain->compose >> and build
overlays with L<Selecto::Domain::DSL>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Domain>, L<Selecto::Domain::DSL>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
