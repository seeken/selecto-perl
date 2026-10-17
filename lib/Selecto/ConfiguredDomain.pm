package Selecto::ConfiguredDomain;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use bytes ();
use Digest::SHA ();
use Encode qw(encode_utf8);
use Scalar::Util qw(blessed refaddr reftype);
use Selecto::Error ();
use Selecto::Limits ();

# Internal structural identity, independent of the public cached fingerprint.
# Never serialize blessed records or call their methods, overloads or hooks.
# These are the native immutable records contained by a constructed domain.
my %RECORD = map { $_ => 1 } qw(Selecto::Domain Selecto::Domain::Association
    Selecto::Expression Selecto::DataRules Selecto::Pattern Selecto::Limits
    Math::BigRat Math::BigInt Math::BigInt::Calc);
my %BOOLEAN = map { $_ => 1 } qw(JSON::PP::Boolean JSON::XS::Boolean Types::Serialiser::Boolean);
my %COMPILED_NUMBERS = map { $_ => 1 } qw(Selecto::Pattern Selecto::Limits
    Math::BigRat Math::BigInt Math::BigInt::Calc);
my @RECORD_BASES = keys %RECORD;
my @COMPILED_BASES = keys %COMPILED_NUMBERS;
my $LIMITS = Selecto::Limits->new;

sub digest {
    my ($class, $domain, $scope) = @_;
    my $state = {hash => Digest::SHA->new(256), nodes => 0, bytes => 0, active => {},
        limits => $LIMITS, node_limit => 'max_response_nodes', byte_limit => 'max_response_bytes'};
    _walk($state, [$domain, $scope], 0);
    return $state->{hash}->hexdigest;
}

# A prepared read binds its actual compiler output and transfer metadata, not
# public cached fingerprints. Traverse the raw statement without accessors.
sub prepared_digest {
    my ($class, $prepared) = @_;
    Selecto::Error->throw('domain_modified_after_configuration', 'prepared read metadata is invalid', {path => []})
        unless ref($prepared) eq 'HASH' && !defined(tied(%$prepared))
            && !grep { !exists($prepared->{$_}) || defined(tied($prepared->{$_})) } qw(statement collections limits);
    my $statement = $prepared->{statement};
    Selecto::Error->throw('domain_modified_after_configuration', 'prepared read statement is invalid', {path => []})
        unless blessed($statement) && UNIVERSAL::isa($statement, 'Selecto::Statement')
            && (reftype($statement) // '') eq 'HASH' && !defined(tied(%$statement));
    my $state = {hash => Digest::SHA->new(256), nodes => 0, bytes => 0, active => {},
        limits => $LIMITS, node_limit => 'max_response_nodes', byte_limit => 'max_response_bytes',
        extra_record => 'Selecto::Statement'};
    # Preserve subclass identity while admitting every raw field. Any nested
    # unknown blessed value, tie or callback still fails the ordinary walker.
    _walk($state, [$statement, $prepared->{collections}, $prepared->{limits}], 0);
    return $state->{hash}->hexdigest;
}

# A plain portable library is admitted before any dclone or canonical encoder.
# Keep the original native metadata ceilings, independently of compiled-record
# identity ceilings. Unknown blessed values cannot execute serialization hooks.
sub admit_library {
    my ($class, $library) = @_;
    my $state = {hash => Digest::SHA->new(256), nodes => 0, bytes => 0, active => {},
        limits => $LIMITS, node_limit => 'max_expression_nodes', byte_limit => 'max_state_bytes', plain => 1};
    _walk($state, $library, 0);
    return $library;
}

sub _refuse {
    my ($state) = @_;
    if ($state->{plain}) {
        Selecto::Error->throw('invalid_query_library',
            'query library contains unsupported metadata or exceeds its resource limit');
    }
    Selecto::Error->throw('domain_modified_after_configuration',
        'configured domain identity is invalid or has changed', {path => []});
}
sub _part {
    my ($state, $tag, $value) = @_;
    my $bytes = utf8::is_utf8($value) ? encode_utf8($value) : $value;
    # $bytes is an octet string here (encoded above, or never character-flagged), so
    # length() is its byte length; the limit is read once per digest, not per part.
    my $size = length($bytes);
    $state->{bytes} += $size unless $state->{plain} && $tag =~ /\A(?:C|H|A|E)\z/;
    _refuse($state) if $state->{bytes} > ($state->{byte_max} //= $state->{limits}->get($state->{byte_limit}));
    $state->{hash}->add($tag, pack('N', $size), $bytes);
}
sub _walk {
    my ($state, $value, $depth, $compiled) = @_;
    _refuse($state) if ++$state->{nodes} > ($state->{node_max} //= $state->{limits}->get($state->{node_limit}))
        || $depth > ($state->{depth_max} //= $state->{limits}->get('max_expression_depth'));
    my $type = reftype($value);
    unless (defined $type) {
        return _part($state, 'U', '') unless defined $value;
        my $flags = B::svref_2object(\$value)->FLAGS;
        # Native compiled rule indices/numbers may acquire Perl string caches
        # during evaluation. Their record class already establishes the type.
        # Authored scalar values still retain SQL numeric/string identity.
        my $kind = $compiled ? 'V' : $flags & B::SVp_POK() ? 'S' : $flags & B::SVp_IOK() ? 'I' : 'N';
        return _part($state, $kind . (utf8::is_utf8($value) ? 'u' : 'b'), "$value");
    }
    my $class = blessed($value) // '';
    $compiled ||= $COMPILED_NUMBERS{$class}
        || length($class) && grep { UNIVERSAL::isa($value, $_) } @COMPILED_BASES;
    if ($BOOLEAN{$class} && $type eq 'SCALAR') {
        _refuse($state) if defined(tied($$value)) || !defined($$value) || defined(reftype($$value)) || "$$value" !~ /\A[01]\z/;
        return _part($state, 'B', $$value ? '1' : '0');
    }
    _refuse($state) if length($class) && ($state->{plain} || !$RECORD{$class}
        && !(grep { UNIVERSAL::isa($value, $_) } @RECORD_BASES)
        && !(defined($state->{extra_record}) && UNIVERSAL::isa($value, $state->{extra_record})));
    _refuse($state) unless $type eq 'HASH' || $type eq 'ARRAY';
    _refuse($state) if $type eq 'HASH' ? defined(tied(%$value)) : defined(tied(@$value));
    my $id = refaddr($value);
    _refuse($state) if $state->{active}{$id};
    local $state->{active}{$id} = 1;
    _part($state, 'C', $class);
    my $count = $type eq 'HASH' ? scalar(keys %$value) : scalar(@$value);
    # Refuse breadth before sorting keys or traversing child occurrences.
    _refuse($state) if $state->{nodes} + $count > ($state->{node_max} //= $state->{limits}->get($state->{node_limit}));
    _part($state, $type eq 'HASH' ? 'H' : 'A', "$count");
    if ($type eq 'HASH') {
        for my $key (sort keys %$value) {
            _refuse($state) if defined(tied($value->{$key}));
            _part($state, 'K', $key);
            _walk($state, $value->{$key}, $depth + 1, $compiled);
        }
    } else {
        for my $index (0 .. $#$value) {
            _refuse($state) if defined(tied($value->[$index]));
            _walk($state, $value->[$index], $depth + 1, $compiled);
        }
    }
    _part($state, 'E', '');
    return;
}

1;

__END__

=head1 NAME

Selecto::ConfiguredDomain - internal bounded configured-domain identity

=head1 DESCRIPTION

The engine retains a private digest of actual constructed domain records and
trusted scope, including predicates, associations and contract metadata.
Structural traversal rejects cycles, tied containers, executable references
and unknown blessed values without invoking their methods or serialization
hooks. Native record subclasses are admitted through direct inheritance checks,
and their entire raw record is traversed with overloading disabled. Native
rule-number records and JSON booleans are traversed directly.
The public domain fingerprint does not establish this execution authority.
Metadata admission uses fixed trusted native response byte/node ceilings and
the native structural depth ceiling, independent of per-query tightened limits.
This helper establishes structural metadata identity; it does not establish
native catalog authority or validate unsupported query-policy declarations.

=cut
