package Selecto::Write::ConflictTarget;

use 5.034;
use strict;
use warnings;
use Selecto::Error ();

# Field order is part of the declared portable identity. Never infer an
# allowed conflict target from the set of fields a caller may insert.
sub validate {
    my ($class, $writes, $target, $fields) = @_;
    my $upsert = ref($writes) eq 'HASH' && ref($writes->{operations}) eq 'HASH'
        ? $writes->{operations}{upsert} : undef;
    my $declared = ref($upsert) eq 'HASH' ? $upsert->{conflict_targets} : undef;
    my $valid = _fields($target, $fields);
    $valid &&= ref($declared) eq 'ARRAY' && grep {
        _fields($_, $fields) && join("\0", @$_) eq join("\0", @$target)
    } @$declared;
    Selecto::Error->throw('conflict_target_not_declared',
        'upsert conflict target must exactly match a declared conflict target') unless $valid;
    return [map { "$_" } @$target];
}

sub _fields {
    my ($target, $fields) = @_;
    return 0 unless ref($target) eq 'ARRAY' && @$target;
    my %seen;
    for my $field (@$target) {
        return 0 unless defined($field) && !ref($field)
            && "$field" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
            && !$seen{"$field"}++ && ref($fields) eq 'HASH' && exists($fields->{$field});
    }
    return 1;
}

1;
