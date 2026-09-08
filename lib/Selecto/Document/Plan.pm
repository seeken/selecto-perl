package Selecto::Document::Plan;
use 5.034;
use strict;
use warnings;
use Hash::Util qw(lock_hash);
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(blessed refaddr);
use Storable qw(dclone);
use Encode qw(encode_utf8);
use JSON::PP ();
use Selecto::Document::Integer ();
use Selecto::Error ();
fieldhash my %STATE;
sub _require { Selecto::Error->throw($_[1], $_[2]) unless $_[0] }

sub new {
    my ($class, %args) = @_;
    my %allowed = map { $_ => 1 } qw(release tenant relation access_pattern select where order limit);
    _require(!(grep { !$allowed{$_} } keys %args), 'invalid_document_plan', 'Unknown document intent option');
    my $release = $args{release};
    _require(blessed($release) && $release->isa('Selecto::Document::ShapeRelease'), 'invalid_document_plan', 'Native shape release required');
    $release->source;
    my $tenant = $args{tenant};
    _require(defined($tenant) && !ref($tenant) && length("$tenant") && length(encode_utf8("$tenant")) <= 128, 'tenant_required', 'Trusted tenant required');
    my $relation = $release->relation($args{relation});
    my $pattern = $release->access_pattern($args{relation}, $args{access_pattern});
    my $limit = $args{limit} // 100;
    _require(!ref($limit) && "$limit" =~ /\A\d+\z/ && $limit >= 1 && $limit <= 1000, 'invalid_limit', 'Limit must be between 1 and 1000');
    my $select = $args{select};
    my %seen;
    _require(ref($select) eq 'ARRAY' && @$select && @$select <= 64, 'invalid_projection', 'Finite nonempty projection required');
    _require(!(grep { ref($_) || !defined($_) || $seen{$_}++ } @$select), 'invalid_projection', 'Unique field identifiers required');
    my @fields = map { $release->field($_) } @$select;
    my $where = $args{where};
    if (defined $where) {
        _require(ref($where) eq 'HASH' && keys(%$where) == 3 && ($where->{op} // '') =~ /\A(?:eq|gt|gte|lt|lte)\z/, 'invalid_predicate', 'Typed scalar comparison required');
        my $field = $release->field($where->{field});
        my %allowed = map { $_ => 1 } @{$pattern->{filter_fields}};
        _require($allowed{$where->{field}}, 'unsupported_access_pattern_predicate', 'Predicate is not allowed by access pattern');
        my $value = $where->{value};
        my $type = $field->{type};
        my $valid = $type eq 'string' ? defined($value) && !ref($value)
            : $type eq 'integer' ? blessed($value) && $value->isa('Selecto::Document::Integer')
            : JSON::PP::is_bool($value);
        _require($valid, 'invalid_predicate_value', 'Value does not match the published scalar type');
    }
    my $order = $args{order} // [];
    _require(ref($order) eq 'ARRAY' && @$order <= 1, 'invalid_order', 'At most one order field allowed');
    if (@$order) {
        my %allowed = map { $_ => 1 } @{$pattern->{order_fields}};
        _require(ref($order->[0]) eq 'ARRAY' && @{$order->[0]} == 2 && ($order->[0][1] // '') =~ /\A(?:asc|desc)\z/, 'invalid_order', 'Order entry requires field and direction');
        $release->field($order->[0][0]);
        _require($allowed{$order->[0][0]}, 'unsupported_access_pattern_order', 'Order is not allowed by access pattern');
    }
    my $self = bless {}, $class;
    $STATE{$self} = {
        release => $release, tenant => "$tenant", relation_id => $args{relation}, relation => $relation,
        access_pattern_id => $args{access_pattern}, access_pattern => $pattern,
        projection_ids => [@$select], projection => \@fields, predicate => defined($where) ? dclone($where) : undef,
        order => dclone($order), limit => int($limit)
    };
    lock_hash(%$self);
    return $self;
}
sub validate_scope {
    my ($self, $release, $tenant) = @_;
    _require(exists($STATE{$self}), 'invalid_document_plan', 'Plan was not constructed by the public API');
    _require(refaddr($STATE{$self}{release}) == refaddr($release) && $STATE{$self}{tenant} eq $tenant, 'document_source_mismatch', 'Plan belongs to another source or tenant');
    return $self;
}
sub release { $STATE{$_[0]}{release} }
sub tenant { $STATE{$_[0]}{tenant} }
sub relation_id { $STATE{$_[0]}{relation_id} }
sub access_pattern_id { $STATE{$_[0]}{access_pattern_id} }
sub limit { $STATE{$_[0]}{limit} }
sub relation { dclone($STATE{$_[0]}{relation}) }
sub projection { dclone($STATE{$_[0]}{projection}) }
sub projection_ids { dclone($STATE{$_[0]}{projection_ids}) }
sub access_pattern { dclone($STATE{$_[0]}{access_pattern}) }
sub predicate { defined($STATE{$_[0]}{predicate}) ? dclone($STATE{$_[0]}{predicate}) : undef }
sub order { dclone($STATE{$_[0]}{order}) }
1;
