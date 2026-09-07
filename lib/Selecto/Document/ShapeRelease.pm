package Selecto::Document::ShapeRelease;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    my $artifact = $args{artifact};
    Selecto::Error->throw('invalid_shape_release', 'shape release must be an object')
        unless ref($artifact) eq 'HASH';
    Selecto::Error->throw('unapproved_shape_release', 'document queries require an approved shape release')
        unless ($artifact->{status} // '') eq 'approved';
    for my $key (qw(source shape relations)) {
        Selecto::Error->throw('invalid_shape_release', "shape release requires $key")
            unless ref($artifact->{$key}) eq 'HASH';
    }
    Selecto::Error->throw('invalid_shape_release', 'document source requires id, collection, and tenant_path')
        unless _identifier($artifact->{source}{id})
            && _identifier($artifact->{source}{collection})
            && _path($artifact->{source}{tenant_path});
    Selecto::Error->throw('invalid_shape_release', 'shape fields must be an object')
        unless ref($artifact->{shape}{fields}) eq 'HASH';
    return bless { artifact => dclone($artifact) }, $class;
}

sub source { return dclone($_[0]{artifact}{source}); }

sub relation {
    my ($self, $id) = @_;
    my $relation = $self->{artifact}{relations}{$id};
    Selecto::Error->throw('unknown_relation', 'document relation is not published')
        unless ref($relation) eq 'HASH';
    return dclone($relation);
}

sub field {
    my ($self, $id) = @_;
    my $field = $self->{artifact}{shape}{fields}{$id};
    Selecto::Error->throw('unknown_field', 'document field is not published')
        unless ref($field) eq 'HASH' && _path($field->{path});
    return dclone($field);
}

sub access_pattern {
    my ($self, $relation_id, $id) = @_;
    my $relation = $self->relation($relation_id);
    my $pattern = $relation->{access_patterns}{$id};
    Selecto::Error->throw('unknown_access_pattern', 'document access pattern is not published')
        unless ref($pattern) eq 'HASH';
    return dclone($pattern);
}

sub _identifier { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[a-z_][a-z0-9_]{0,63}\z/ }
sub _path { ref($_[0]) eq 'ARRAY' && @{$_[0]} && !grep { !_identifier($_) } @{$_[0]} }

1;
