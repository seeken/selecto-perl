package Selecto::Write;

use 5.034;
use strict;
use warnings;

1;

package Selecto::Write::Command;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

my %OPERATIONS = map { $_ => 1 } qw(insert update upsert delete);

sub new {
    my ($class, %args) = @_;
    my $operation = defined($args{operation}) ? "$args{operation}" : '';
    Selecto::Error->throw('invalid_write', "unsupported operation $operation") unless $OPERATIONS{$operation};
    Selecto::Error->throw('invalid_write', 'relation must be a non-empty string')
        unless defined($args{relation}) && !ref($args{relation}) && "$args{relation}" ne '';
    my $assignments = $args{assignments} // {};
    my $metadata = $args{metadata} // {};
    Selecto::Error->throw('invalid_write', 'assignments must be an object') unless ref($assignments) eq 'HASH';
    Selecto::Error->throw('invalid_write', 'metadata must be an object') unless ref($metadata) eq 'HASH';
    return bless {
        operation => $operation,
        relation => "$args{relation}",
        assignments => { map { ("$_", _clone($assignments->{$_})) } keys %$assignments },
        predicate => $args{predicate},
        scope_predicate => $args{scope_predicate},
        query_enforcement => $args{query_enforcement},
        expected_count => exists($args{expected_count}) ? $args{expected_count} : 1,
        metadata => { map { ("$_", _clone($metadata->{$_})) } keys %$metadata },
    }, $class;
}

sub operation      { return $_[0]->{operation}; }
sub relation       { return $_[0]->{relation}; }
sub assignments    { return { map { ($_ => _clone($_[0]->{assignments}{$_})) } keys %{$_[0]->{assignments}} }; }
sub predicate      { return $_[0]->{predicate}; }
sub scope_predicate { return $_[0]->{scope_predicate}; }
sub query_enforcement { return $_[0]->{query_enforcement}; }
sub expected_count { return $_[0]->{expected_count}; }
sub metadata       { return { map { ($_ => _clone($_[0]->{metadata}{$_})) } keys %{$_[0]->{metadata}} }; }

sub with_query_enforcement {
    my ($self, $evidence) = @_;
    return ref($self)->new(
        operation => $self->operation,
        relation => $self->relation,
        assignments => $self->assignments,
        predicate => $self->predicate,
        scope_predicate => $self->scope_predicate,
        query_enforcement => $evidence,
        expected_count => $self->expected_count,
        metadata => $self->metadata,
    );
}

sub _clone {
    my ($value) = @_;
    return [map { _clone($_) } @$value] if ref($value) eq 'ARRAY';
    return { map { ($_ => _clone($value->{$_})) } keys %$value } if ref($value) eq 'HASH';
    return $value;
}

package Selecto::Write::Batch;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Error ();

sub new {
    my ($class, @commands) = @_;
    @commands = @{$commands[0]} if @commands == 1 && ref($commands[0]) eq 'ARRAY';
    Selecto::Error->throw('invalid_write', 'batch must contain commands') unless @commands;
    Selecto::Error->throw('invalid_write', 'batch contains a non-command')
        if grep { !blessed($_) || !$_->isa('Selecto::Write::Command') } @commands;
    return bless { commands => [@commands] }, $class;
}

sub commands { return [@{$_[0]->{commands}}]; }

package Selecto::Write::Result;

use 5.034;
use strict;
use warnings;

sub new { my ($class, %args) = @_; return bless { %args }, $class; }
sub operation { return $_[0]->{operation}; }
sub affected_rows { return $_[0]->{affected_rows}; }
sub to_hash { return { operation => $_[0]->{operation}, affected_rows => $_[0]->{affected_rows} }; }

1;
