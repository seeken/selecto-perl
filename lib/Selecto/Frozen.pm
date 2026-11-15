package Selecto::Frozen;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed refaddr reftype);
use Hash::Util::FieldHash qw(fieldhash);
use JSON::PP ();
use Storable ();
use Hash::Util ();
use Selecto::Error ();

fieldhash my %IDENTITY;
my $NEXT = 0;

sub identity { return $IDENTITY{$_[1]}; }

# Freeze native containers in place, including aliases held before freezing.
# Domain metadata hashes allow ordinary missing-key reads via immutable ties.
# Query records have a complete fixed key set, so native restricted hashes
# suffice there. Native read-only arrays protect length and existing slots.
sub freeze {
    my ($class, $root) = @_;
    return $root if $IDENTITY{$root};
    if (ref($root) eq "Selecto::Limits") {
        Hash::Util::lock_hash(%$root);
        $IDENTITY{$root} = join ":", $$, ++$NEXT;
        return $root;
    }
    my (%seen, @nodes);
    _freeze_nodes($root, 0, \%seen, \@nodes);
    for my $node (@nodes) {
        if (JSON::PP::is_bool($node)) {
            Internals::SvREADONLY($$node, 1);
        } elsif (ref($node) eq 'Selecto::Query') {
            Hash::Util::lock_hash(%$node);
        } elsif (reftype($node) eq 'HASH') {
            my %data = %$node;
            # Protect scalar aliases acquired before tie as well.
            Internals::SvREADONLY($node->{$_}, 1) for keys %$node;
            tie %$node, 'Selecto::Frozen::Hash', \%data;
        } else {
            Internals::SvREADONLY($node->[$_], 1) for 0 .. $#$node;
            Internals::SvREADONLY(@$node, 1);
            # Perl permits $#array assignment through a separate length SV.
            Internals::SvREADONLY($#$node, 1);
        }
    }
    $IDENTITY{$root} = join ':', $$, ++$NEXT;
    return $root;
}

sub _freeze_nodes {
    my ($value, $depth, $seen, $nodes) = @_;
    return unless ref $value;
    Selecto::Error->throw('invalid_domain', 'frozen metadata exceeds structural limits')
        if $depth > 128 || keys(%$seen) > 100_000;
    if (JSON::PP::is_bool($value)) { push @$nodes, $value; return; }
    my $type = reftype($value) // '';
    Selecto::Error->throw('invalid_domain', 'frozen domains require native hash and array metadata')
        unless $type eq 'HASH' || $type eq 'ARRAY' || $type eq 'CODE';
    return if $type eq 'CODE'; # callbacks are retained, but never fast-key eligible
    return if $seen->{refaddr($value)}++;
    if ($type eq 'HASH') {
        my $tie = tied %$value;
        return if $tie && ref($tie) eq 'Selecto::Frozen::Hash';
        Selecto::Error->throw('invalid_domain', 'cannot freeze tied domain metadata') if $tie;
        _freeze_nodes($_, $depth + 1, $seen, $nodes) for values %$value;
    } else {
        Selecto::Error->throw('invalid_domain', 'cannot freeze tied domain metadata') if tied @$value;
        _freeze_nodes($_, $depth + 1, $seen, $nodes) for @$value;
    }
    push @$nodes, $value;
}

# Public document getters/derivation must return ordinary mutable containers.
# Unlike dclone on a tied record, this deliberately drops the freeze machinery.
sub copy {
    my ($class, $root) = @_;
    return _copy_value($root, {});
}
sub _copy_value {
    my ($value, $seen) = @_;
    return $value unless ref $value;
    return $value if JSON::PP::is_bool($value);
    return $seen->{refaddr($value)} if exists $seen->{refaddr($value)};
    my $type = reftype($value) // '';
    return Storable::dclone($value) unless $type eq 'HASH' || $type eq 'ARRAY';
    my $copy = $type eq 'HASH' ? {} : [];
    my $class = blessed($value);
    bless $copy, $class if defined $class;
    $seen->{refaddr($value)} = $copy;
    if ($type eq 'HASH') { $copy->{$_} = _copy_value($value->{$_}, $seen) for keys %$value }
    else { push @$copy, _copy_value($_, $seen) for @$value }
    return $copy;
}

package Selecto::Frozen::Hash;
use strict;
use warnings;
sub TIEHASH { bless {data => $_[1]}, $_[0] }
sub FETCH { $_[0]{data}{$_[1]} }
sub EXISTS { exists $_[0]{data}{$_[1]} }
sub FIRSTKEY { my $n = keys %{$_[0]{data}}; each %{$_[0]{data}} }
sub NEXTKEY { each %{$_[0]{data}} }
sub SCALAR { scalar %{$_[0]{data}} }
sub STORE { die "cannot mutate a frozen Selecto domain; derive or reload it\n" }
sub DELETE { goto &STORE }
sub CLEAR { goto &STORE }

1;
