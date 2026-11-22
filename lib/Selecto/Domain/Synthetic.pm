package Selecto::Domain::Synthetic;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use Selecto::Error ();

my $PATH = qr/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*\z/;
my $MAX_BUCKETS = 50;

sub _fail {
    my ($field, $message) = @_;
    Selecto::Error->throw('invalid_domain', "computed column $field: $message", {field => $field});
}

sub _only {
    my ($field, $spec, @allowed) = @_;
    my %allowed = map { ($_ => 1) } 'kind', @allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$spec;
    _fail($field, 'unsupported keys ' . join(', ', @unknown)) if @unknown;
}

sub _path {
    my ($field, $value, $label) = @_;
    _fail($field, "$label must be a field path") unless defined($value) && !ref($value) && $value =~ $PATH;
    return "$value";
}

# The value expression a shorthand computed column stands for.
sub expand {
    my ($class, $field, $spec, $type_of) = @_;
    my $kind = $spec->{kind};
    return _temporal_delta($field, $spec) if $kind eq 'temporal_delta';
    return _bucket($field, $spec, $type_of) if $kind eq 'bucket';
    _fail($field, "unsupported shorthand kind $kind");
}

sub _temporal_delta {
    my ($field, $spec) = @_;
    _only($field, $spec, qw(from to unit otherwise minimum));
    my $unit = $spec->{unit} // 'day';
    _fail($field, 'temporal_delta unit must be day, hour or fractional_day')
        unless !ref($unit) && $unit =~ /\A(?:day|hour|fractional_day)\z/;
    _fail($field, 'temporal_delta otherwise must be now')
        if exists($spec->{otherwise}) && (!defined($spec->{otherwise})
            || ref($spec->{otherwise}) || $spec->{otherwise} ne 'now');
    _fail($field, 'temporal_delta minimum must be 0')
        if exists($spec->{minimum}) && (!defined($spec->{minimum})
            || ref($spec->{minimum}) || "$spec->{minimum}" !~ /\A0(?:\.0+)?\z/);
    my @ends = map {
        defined($_) && !ref($_) && $_ eq 'now' ? ['current_timestamp']
            : ['field', _path($field, $_, 'temporal_delta endpoint')]
    } @{$spec}{qw(from to)};
    $ends[1] = ['temporal_coalesce', $ends[1], ['current_timestamp']]
        if exists $spec->{otherwise};
    my $expression = [ {day => 'days_between', hour => 'hours_between',
        fractional_day => 'fractional_days_between'}->{$unit}, @ends ];
    return exists($spec->{minimum}) ? ['clamp_zero', $expression] : $expression;
}

sub _bound {
    my ($field, $bucket, $key) = @_;
    return undef unless defined $bucket->{$key};
    _fail($field, "bucket $key must be a number")
        unless !ref($bucket->{$key}) && looks_like_number($bucket->{$key}) && $bucket->{$key} =~ /\A-?\d+(?:\.\d+)?\z/;
    return $bucket->{$key};
}

sub _bucket {
    my ($field, $spec, $type_of) = @_;
    _only($field, $spec, qw(field buckets otherwise));
    my $source = _path($field, $spec->{field}, 'bucket field');
    # $type_of gives a field's declared type where the caller can tell it.
    if (defined(my $type = $type_of ? $type_of->($source) : undef)) {
        require Selecto::ValueExpression;
        _fail($field, "bucket field $source must be numeric")
            unless Selecto::ValueExpression->category($type) =~ /\A(?:integer|decimal)\z/;
    }
    my $buckets = $spec->{buckets};
    _fail($field, "buckets must be an array of 1 to $MAX_BUCKETS ranges")
        unless ref($buckets) eq 'ARRAY' && @$buckets && @$buckets <= $MAX_BUCKETS;
    my (%labels, @ranges, @branches);
    for my $bucket (@$buckets) {
        _fail($field, 'a bucket is {label => ..., min => ..., max => ...}')
            unless ref($bucket) eq 'HASH' && !grep { !/\A(?:label|min|max)\z/ } keys %$bucket;
        my $label = $bucket->{label};
        _fail($field, 'bucket labels must be distinct non-empty strings')
            unless defined($label) && !ref($label) && $label =~ /\S/ && !$labels{$label}++;
        my ($min, $max) = map { _bound($field, $bucket, $_) } qw(min max);
        _fail($field, "bucket $label needs a min, a max, or both") unless defined($min) || defined($max);
        _fail($field, "bucket $label has min above max") if defined($min) && defined($max) && $min > $max;
        push @ranges, [$min, $max, $label];
        my @conditions = (
            (defined($min) ? ['gte', $source, $min] : ()),
            (defined($max) ? ['lte', $source, $max] : ()),
        );
        push @branches, [@conditions == 1 ? $conditions[0] : ['and', @conditions], ['literal', "$label", 'string']];
    }
    # Both bounds are inclusive, so two buckets may not share a value: a row
    # then has exactly one label whatever the order they are written in.
    my @sorted = sort { ($a->[0] // '-inf') <=> ($b->[0] // '-inf') } map {
        [defined($_->[0]) ? $_->[0] : -9**9**9, defined($_->[1]) ? $_->[1] : 9**9**9, $_->[2]]
    } @ranges;
    for my $index (1 .. $#sorted) {
        _fail($field, "buckets $sorted[$index - 1][2] and $sorted[$index][2] overlap")
            if $sorted[$index][0] <= $sorted[$index - 1][1];
    }
    if (defined $spec->{otherwise}) {
        _fail($field, 'bucket otherwise must be a non-empty label distinct from the buckets')
            if ref($spec->{otherwise}) || $spec->{otherwise} !~ /\S/ || $labels{$spec->{otherwise}};
        push @branches, ['else', ['literal', "$spec->{otherwise}", 'string']];
    }
    return ['case', @branches];
}

1;

__END__

=head1 NAME

Selecto::Domain::Synthetic - shorthand for common computed domain columns

=head1 SYNOPSIS

  columns => {
      lead_days => {
          type => 'integer',
          computed => {kind => 'temporal_delta', from => 'purchased_at', to => 'event.starts_at'},
      },
      lead_bucket => {
          type => 'string',
          computed => {kind => 'bucket', field => 'lead_days', otherwise => 'Unknown', buckets => [
              {label => 'After the start', max => -1},
              {label => '0-6 days', min => 0, max => 6},
              {label => '7-29 days', min => 7, max => 29},
              {label => '30+ days', min => 30},
          ]},
      },
  },

=head1 DESCRIPTION

Two kinds of computed column are written as a short declaration and stored as
the L<Selecto::ValueExpression> they stand for. After parsing, the column is
an ordinary C<expression> computed column: it can be selected, filtered,
grouped and ordered like one, it is read-only, and L<Selecto::Domain> exports
it in the expanded form.

=head2 temporal_delta

C<from> and C<to> are C<date>, C<utc_datetime>, datetime or
C<epoch_datetime> field paths, including a one-to-one association path. The
reserved endpoint C<now> uses the adapter clock. C<otherwise =E<gt> 'now'>
replaces a NULL C<to> only; a NULL C<from> still gives NULL.

C<unit> defaults to C<day>: whole calendar days (the difference of dates,
whatever the times of day), with a declared C<integer> result. C<hour> and
C<fractional_day> give elapsed seconds divided by 3600 and 86400 respectively;
declare these columns C<decimal>. A date means midnight in the session zone,
or in C<use_timezone> when given. Elapsed units subtract instants, so a DST
spring-forward day may contain 23 hours. C<minimum =E<gt> 0> optionally clamps
negative results to zero, preserving NULL. No other minimum is supported.

  pickup_delay => {type => 'decimal', display => {decimals => 1}, computed => {
      kind => 'temporal_delta', from => 'scheduled_pickup', to => 'actual_pickup',
      otherwise => 'now', unit => 'hour', minimum => 0,
  }},

C<field_unit> and C<field_metadata> derive C<< {kind => 'duration', code =>
'day' | 'hour'} >> unless the host declares a unit. Fractional days have code
C<day>. The derived metadata does not rewrite legacy contracts or fingerprints.
The expanded expression remains numeric for sums, averages and numeric buckets.

PostgreSQL and DuckDB render C<CURRENT_TIMESTAMP>, sharing the transaction
clock. Their session zone, or the query's C<use_timezone>, decides calendar
dates. SQLite, MySQL and MariaDB bind one application-server local timestamp
per compilation, shared with C<date_shortcut> and every duration in the query.
These adapters do not support arbitrary query time zones (SQLite accepts UTC
only). Configure the application server, stored wall times and database session
zones consistently; UTC is recommended. SQLite converts epochs to UTC;
MySQL/MariaDB convert epochs using the database session zone. Numeric epochs
are Unix seconds. Naive timestamps on adapters without zone support retain
their stored wall-clock meaning. Recompile queries to refresh bound clocks.

The compile cache excludes computed columns. C<CannedPage> runs its queries
on every request and has no result cache. No clock value or result is frozen
in either cache; hosts adding their own result caches must expire or bypass
time-dependent expressions (C<current_timestamp> in the expanded AST).

=head2 bucket

C<field> is a numeric field path, which may itself be a computed column.
Each bucket has a C<label> and a C<min>, a C<max> or both; the bounds are
inclusive. Buckets must not overlap, so every value has at most one label.
A value outside every bucket, and a C<NULL>, give C<NULL> unless C<otherwise>
names a label for them. Declare the column as C<string>.

Labels are plain strings: a query that orders by the bucket column sorts the
labels as text, not by their ranges.

=cut
