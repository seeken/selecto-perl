package Selecto::Document::Plan;

use 5.034;
use strict;
use warnings;
use Storable qw(dclone);
use Selecto::Error ();

sub new {
    my ($class, %args) = @_;
    my $release = $args{release};
    Selecto::Error->throw('invalid_document_plan', 'plan requires a shape release')
        unless ref($release) && $release->isa('Selecto::Document::ShapeRelease');
    my $relation_id = $args{relation};
    my $relation = $release->relation($relation_id);
    my $tenant = $args{tenant};
    Selecto::Error->throw('tenant_required', 'trusted tenant scope is required')
        unless defined($tenant) && !ref($tenant) && length("$tenant");
    my $limit = defined($args{limit}) ? $args{limit} : 100;
    Selecto::Error->throw('invalid_limit', 'document limit must be between 1 and 1000')
        unless "$limit" =~ /\A\d+\z/ && $limit >= 1 && $limit <= 1000;
    my @projection = @{$args{select} // []};
    Selecto::Error->throw('invalid_projection', 'document projection must not be empty') unless @projection;
    my @fields = map { $release->field($_) } @projection;
    my $pattern_id = $args{access_pattern};
    my $pattern = $release->access_pattern($relation_id, $pattern_id);
    my $where = $args{where};
    if (defined $where) {
        Selecto::Error->throw('invalid_predicate', 'document predicate must be an object')
            unless ref($where) eq 'HASH';
        Selecto::Error->throw('invalid_predicate', 'unsupported document predicate operator')
            unless ($where->{op} // '') =~ /\A(?:eq|gt|gte|lt|lte)\z/;
        $release->field($where->{field});
    }
    my $order = $args{order} // [];
    Selecto::Error->throw('invalid_order', 'document order must contain at most one entry')
        unless ref($order) eq 'ARRAY' && @$order <= 1;
    if (@$order) {
        Selecto::Error->throw('invalid_order', 'document order entry must be [field, direction]')
            unless ref($order->[0]) eq 'ARRAY' && @{$order->[0]} == 2
                && $order->[0][1] =~ /\A(?:asc|desc)\z/;
        $release->field($order->[0][0]);
    }
    return bless {
        release => $release, relation_id => "$relation_id", relation => $relation,
        tenant => "$tenant", projection => \@fields, projection_ids => [map { "$_" } @projection],
        access_pattern => $pattern, access_pattern_id => "$pattern_id",
        predicate => defined($where) ? dclone($where) : undef,
        order => dclone($order), limit => int($limit),
    }, $class;
}

sub release { $_[0]{release} }
sub relation_id { $_[0]{relation_id} }
sub relation { dclone($_[0]{relation}) }
sub tenant { $_[0]{tenant} }
sub projection { dclone($_[0]{projection}) }
sub projection_ids { [@{$_[0]{projection_ids}}] }
sub access_pattern { dclone($_[0]{access_pattern}) }
sub access_pattern_id { $_[0]{access_pattern_id} }
sub predicate { defined($_[0]{predicate}) ? dclone($_[0]{predicate}) : undef }
sub order { dclone($_[0]{order}) }
sub limit { $_[0]{limit} }

1;
