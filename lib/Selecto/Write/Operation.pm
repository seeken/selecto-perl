package Selecto::Write::Operation;

use 5.034;
use strict;
use warnings;
no overloading;
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed reftype);
use Selecto::Error ();
use Selecto::Domain::QueryContract ();

# Portable authored intent is separate from an executable native command.
# A private weak registry binds it to its actual constructor and plain input.
fieldhash my %STATE;
my %OP = map { $_ => 1 } qw(insert update upsert delete);

sub _copy {
    return Selecto::Domain::QueryContract->copy_declaration({value => $_[0]})->{value};
}
sub _seal {
    my ($state) = @_;
    my $token = 0;
    my $object = bless \$token, __PACKAGE__;
    $STATE{$object} = _copy($state);
    return $object;
}
sub snapshot {
    my ($self) = @_;
    Selecto::Error->throw('invalid_write_operation', 'portable operation must be constructed by its public API')
        unless (blessed($self) // '') eq __PACKAGE__
            && (reftype($self) // '') eq 'SCALAR' && exists $STATE{$self};
    return _copy($STATE{$self});
}
sub new {
    my ($class, $domain, $opts) = @_;
    Selecto::Error->throw('invalid_write_operation', 'portable operation class is fixed')
        unless defined($class) && !ref($class) && $class eq __PACKAGE__;
    my $state = _copy({domain => $domain, opts => $opts // {}, filters => []});
    Selecto::Error->throw('invalid_domain', 'portable write domain must be a plain object')
        unless ref($state->{domain}) eq 'HASH';
    return _seal($state);
}
sub _with {
    my ($self, %changes) = @_;
    return _seal({%{$self->snapshot}, %changes});
}
sub operation {
    my ($self, $type, $values) = @_;
    my $input = _copy({type => $type, values => $values});
    Selecto::Error->throw('invalid_write_operation', 'unsupported portable write operation')
        unless defined($input->{type}) && !ref($input->{type}) && $OP{$input->{type}};
    Selecto::Error->throw('invalid_write_operation', 'write values must be an object or ordered field/value pairs')
        unless $type eq 'delete' || ref($input->{values}) eq 'HASH' || ref($input->{values}) eq 'ARRAY';
    return $self->_with(type => $input->{type}, values => $type eq 'delete' ? {} : $input->{values});
}
sub insert { return $_[0]->operation('insert', $_[1]); }
sub update { return $_[0]->operation('update', $_[1]); }
sub upsert { return $_[0]->operation('upsert', $_[1]); }
sub delete { return $_[0]->operation('delete', {}); }
sub filter {
    my ($self, $condition) = @_;
    return $self->filters([$condition]);
}
sub filters {
    my ($self, $conditions) = @_;
    $conditions = _copy($conditions);
    Selecto::Error->throw('invalid_write_filter', 'portable filters must be an array')
        unless ref($conditions) eq 'ARRAY';
    my $state = $self->snapshot;
    return $self->_with(filters => [@{$state->{filters}}, @$conditions]);
}
sub with_tenant { return $_[0]->_with(tenant => _copy($_[1])); }
sub returning { return $_[0]->_with(returning => _copy($_[1])); }
sub expected_cardinality { return $_[0]->_with(expected_cardinality => _copy($_[1])); }
sub conflict_target { return $_[0]->_with(conflict_target => _copy($_[1])); }
sub with_execution_scope { return $_[0]->_with(execution_scope => _copy($_[1])); }

1;

__END__

=head1 NAME

Selecto::Write::Operation - immutable portable write intent

=head1 DESCRIPTION

Build authored operation intent from a complete plain domain and explicit write
values. The snapshot is portable input, not execution authorization. Every
builder returns a new operation. Input and getter copies are independent. Callbacks, native objects,
tied data, cycles and excessive metadata are rejected before interpretation.

Assignments accept an object or ordered C<[field, value]> pairs. Pairs retain
repeated identifiers so compilation can reject ambiguity before dispatch.
Trusted host tenant and execution context are supplied separately from values.

=cut
