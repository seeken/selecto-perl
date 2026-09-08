package Selecto::Document::ShapeRelease;
use 5.034;
use strict;
use warnings;
use Hash::Util qw(lock_hash);
use Hash::Util::FieldHash qw(fieldhash);
use Storable qw(dclone);
use Selecto::Error ();
fieldhash my %STATE;

sub new {
    my ($class, %args) = @_;
    my $a = $args{artifact};
    _require(ref($a) eq 'HASH', 'invalid_shape_release', 'Shape release must be an object');
    _require(($a->{status} // '') eq 'approved', 'unapproved_shape_release', 'Host-approved shape required');
    _require(ref($a->{$_}) eq 'HASH', 'invalid_shape_release', 'Source, shape and relations required') for qw(source shape relations);
    _require(_identifier($a->{source}{id}) && _identifier($a->{source}{collection}) && _path($a->{source}{tenant_path}), 'invalid_shape_release', 'Invalid source metadata');
    my $fields = $a->{shape}{fields};
    _require(ref($fields) eq 'HASH' && keys(%$fields), 'invalid_shape_release', 'Published fields required');
    for my $id (keys %$fields) {
        my $field = $fields->{$id};
        _require(_identifier($id) && ref($field) eq 'HASH' && _path($field->{path}) && ($field->{type} // '') =~ /\A(?:string|integer|boolean)\z/, 'invalid_shape_release', 'Invalid published scalar field');
    }
    _require(keys(%{$a->{relations}}), 'invalid_shape_release', 'Published relations required');
    for my $id (keys %{$a->{relations}}) {
        my $r = $a->{relations}{$id};
        _require(_identifier($id) && ref($r) eq 'HASH' && ($r->{kind} // '') eq 'root', 'unsupported_relation', 'Only root relations are supported');
        _require(ref($r->{access_patterns}) eq 'HASH' && keys(%{$r->{access_patterns}}), 'invalid_access_pattern', 'Named access patterns required');
        for my $name (keys %{$r->{access_patterns}}) {
            my $p = $r->{access_patterns}{$name};
            _require(_identifier($name) && ref($p) eq 'HASH' && _identifier($p->{index}), 'invalid_access_pattern', 'Invalid named index');
            for my $key (qw(filter_fields order_fields)) {
                _require(ref($p->{$key}) eq 'ARRAY' && !(grep { !_identifier($_) || !exists($fields->{$_}) } @{$p->{$key}}), 'invalid_access_pattern', 'Access pattern references unpublished fields');
            }
        }
    }
    my $self = bless {}, $class;
    $STATE{$self} = dclone($a);
    lock_hash(%$self);
    return $self;
}
sub source { _require(exists($STATE{$_[0]}), 'invalid_shape_release', 'Native release required'); dclone($STATE{$_[0]}{source}) }
sub relation {
    my ($self, $id) = @_;
    _require(_identifier($id) && exists($STATE{$self}{relations}{$id}), 'unknown_relation', 'Relation is not published');
    return dclone($STATE{$self}{relations}{$id});
}
sub field {
    my ($self, $id) = @_;
    _require(_identifier($id) && exists($STATE{$self}{shape}{fields}{$id}), 'unknown_field', 'Field is not published');
    return dclone($STATE{$self}{shape}{fields}{$id});
}
sub access_pattern {
    my ($self, $relation, $id) = @_;
    my $r = $self->relation($relation);
    _require(_identifier($id) && exists($r->{access_patterns}{$id}), 'unknown_access_pattern', 'Access pattern is not published');
    return dclone($r->{access_patterns}{$id});
}
sub _require { Selecto::Error->throw($_[1], $_[2]) unless $_[0] }
sub _identifier { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[a-z_][a-z0-9_]{0,63}\z/ }
sub _path { ref($_[0]) eq 'ARRAY' && @{$_[0]} && @{$_[0]} <= 32 && !grep { !_identifier($_) } @{$_[0]} }
1;
