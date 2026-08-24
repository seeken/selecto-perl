package Selecto::Domain::DSL;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Storable qw(dclone);
use Selecto::Error ();

sub new {
    my ($class) = @_;
    return bless {fragment => {}}, $class;
}

sub define {
    my ($class, $callback) = @_;
    Selecto::Error->throw('invalid_domain_overlay', 'overlay DSL requires a callback')
        unless ref($callback) eq 'CODE';
    my $dsl = $class->new;
    $callback->($dsl);
    return $dsl->overlay;
}

sub overlay { return dclone($_[0]->{fragment}); }
sub build   { return $_[0]->overlay; }

sub section {
    my ($self, $name, $value) = @_;
    $name = _name($name, 'section');
    $self->{fragment}{$name} = _clone($value);
    return $self;
}

sub source {
    my ($self, @config) = @_;
    return $self->_merge_path(['source'], _config('source', @config));
}

sub source_column      { my $self = shift; return $self->_named_path(['source', 'columns'], @_); }
sub source_association { my $self = shift; return $self->_named_path(['source', 'associations'], @_); }
sub column             { my $self = shift; return $self->_named_path(['columns'], @_); }
sub filter             { my $self = shift; return $self->_named_path(['filters'], @_); }
sub function           { my $self = shift; return $self->_named_path(['functions'], @_); }
sub detail_action      { my $self = shift; return $self->_named_path(['detail_actions'], @_); }
sub join               { my $self = shift; return $self->_named_path(['joins'], @_); }
sub schema             { my $self = shift; return $self->_named_path(['schemas'], @_); }
sub source_relationship { my $self = shift; return $self->_named_path(['source_relationships'], @_); }
sub choice_source      { my $self = shift; return $self->_named_path(['choice_sources'], @_); }
sub action             { my $self = shift; return $self->_named_path(['actions'], @_); }
sub capability         { my $self = shift; return $self->_named_path(['capabilities'], @_); }
sub jsonb_schema       { my $self = shift; return $self->_named_path(['jsonb_schemas'], @_); }
sub component {
    my ($self, $name, $value) = @_;
    $name = _name($name, 'component');
    my $components = $self->_hash_path(['components']);
    $components->{$name} = _clone($value);
    return $self;
}

sub schema_association {
    my ($self, $schema, $name, @config) = @_;
    return $self->_named_path(['schemas', _name($schema, 'schema'), 'associations'], $name, @config);
}

sub query_member {
    my ($self, $kind, $name, @config) = @_;
    return $self->_named_path(['query_members', _name($kind, 'query member kind')], $name, @config);
}

sub query_segment    { my $self = shift; return $self->_named_path(['query_library', 'segments'], @_); }
sub query_projection { my $self = shift; return $self->_named_path(['query_library', 'projections'], @_); }
sub query_ordering   { my $self = shift; return $self->_named_path(['query_library', 'orderings'], @_); }
sub query_view       { my $self = shift; return $self->_named_path(['query_library', 'views'], @_); }

sub write_operation    { my $self = shift; return $self->_named_path(['writes', 'operations'], @_); }
sub write_field        { my $self = shift; return $self->_named_path(['writes', 'fields'], @_); }
sub write_relationship { my $self = shift; return $self->_named_path(['writes', 'relationships'], @_); }
sub write_transition   { my $self = shift; return $self->_named_path(['writes', 'transitions'], @_); }
sub write_hook         { my $self = shift; return $self->_named_path(['writes', 'hooks'], @_); }

sub write_tenant_scope {
    my ($self, @config) = @_;
    return $self->_merge_path(['writes', 'scope', 'tenant'], _config('tenant scope', @config));
}

sub write_validation {
    my ($self, $rule) = @_;
    return $self->_append_path(['writes', 'validations'], $rule, 'write validation');
}

sub write_constraint {
    my ($self, $rule) = @_;
    return $self->_append_path(['writes', 'constraints'], $rule, 'write constraint');
}

sub redact_fields        { my $self = shift; return $self->_unique_list_path(['redact_fields'], @_); }
sub source_redact_fields { my $self = shift; return $self->_unique_list_path(['source', 'redact_fields'], @_); }
sub extensions           { my $self = shift; return $self->_unique_list_path(['extensions'], @_); }
sub default_selected     { my $self = shift; return $self->_list_path(['default_selected'], @_); }
sub required_selected    { my $self = shift; return $self->_list_path(['required_selected'], @_); }
sub required_order_by    { my $self = shift; return $self->_list_path(['required_order_by'], @_); }

sub _named_path {
    my ($self, $path, $name, @config) = @_;
    $name = _name($name, 'entry');
    my $target = $self->_hash_path($path);
    $target->{$name} = _config($name, @config);
    return $self;
}

sub _merge_path {
    my ($self, $path, $config) = @_;
    my $target = $self->_hash_path($path);
    _deep_merge_into($target, $config);
    return $self;
}

sub _append_path {
    my ($self, $path, $value, $label) = @_;
    Selecto::Error->throw('invalid_domain_overlay', "$label must be an object")
        unless ref($value) eq 'HASH';
    my @parent_path = @$path;
    my $key = pop @parent_path;
    my $parent = $self->_hash_path(\@parent_path);
    $parent->{$key} //= [];
    Selecto::Error->throw('invalid_domain_overlay', "$label list is not an array")
        unless ref($parent->{$key}) eq 'ARRAY';
    push @{$parent->{$key}}, dclone($value);
    return $self;
}

sub _list_path {
    my ($self, $path, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    my @parent_path = @$path;
    my $key = pop @parent_path;
    my $parent = $self->_hash_path(\@parent_path);
    $parent->{$key} = [map { _clone($_) } @values];
    return $self;
}

sub _unique_list_path {
    my ($self, $path, @values) = @_;
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    my @parent_path = @$path;
    my $key = pop @parent_path;
    my $parent = $self->_hash_path(\@parent_path);
    $parent->{$key} //= [];
    Selecto::Error->throw('invalid_domain_overlay', "overlay path $key must be an array")
        unless ref($parent->{$key}) eq 'ARRAY';
    my %seen = map { _value_key($_) => 1 } @{$parent->{$key}};
    for my $value (@values) {
        my $value_key = _value_key($value);
        next if $seen{$value_key}++;
        push @{$parent->{$key}}, _clone($value);
    }
    return $self;
}

sub _hash_path {
    my ($self, $path) = @_;
    my $target = $self->{fragment};
    for my $part (@$path) {
        $part = _name($part, 'path');
        $target->{$part} //= {};
        Selecto::Error->throw('invalid_domain_overlay', "overlay path $part must be an object")
            unless ref($target->{$part}) eq 'HASH';
        $target = $target->{$part};
    }
    return $target;
}

sub _config {
    my ($label, @config) = @_;
    if (@config == 1 && ref($config[0]) eq 'HASH') {
        return dclone($config[0]);
    }
    Selecto::Error->throw('invalid_domain_overlay', "$label configuration must be an object")
        if @config % 2;
    my %config = @config;
    return dclone(\%config);
}

sub _deep_merge_into {
    my ($target, $overlay) = @_;
    for my $key (keys %$overlay) {
        if (ref($target->{$key}) eq 'HASH' && ref($overlay->{$key}) eq 'HASH') {
            _deep_merge_into($target->{$key}, $overlay->{$key});
        } else {
            $target->{$key} = _clone($overlay->{$key});
        }
    }
}

sub _name {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_domain_overlay', "$label name must be a non-empty string")
        if !defined($value) || ref($value) || "$value" !~ /\S/;
    return "$value";
}

sub _clone {
    my ($value) = @_;
    return ref($value) ? dclone($value) : $value;
}

sub _value_key {
    my ($value) = @_;
    my $key = eval { JSON::PP->new->canonical(1)->allow_nonref(1)->encode($value) };
    return defined($key) ? $key : (ref($value) || 'scalar') . ':' . "$value";
}

1;

__END__

=head1 NAME

Selecto::Domain::DSL - fluent builder for portable Selecto domain overlays

=head1 SYNOPSIS

  my $overlay = Selecto::Domain::DSL->define(sub {
      my ($dsl) = @_;
      $dsl->source_column(total => {label => 'Total'})
          ->write_field(status => {updatable => 1});
  });

=head1 DESCRIPTION

The builder emits an ordinary hash contract consumed by
C<Selecto::Domain-E<gt>compose>. It stores configuration data only; it does not
execute SQL or callbacks.

=cut
