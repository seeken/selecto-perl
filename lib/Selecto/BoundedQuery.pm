package Selecto::BoundedQuery;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed refaddr reftype);
use Mojo::JSON qw(decode_json);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Limits ();
use Selecto::OperationBudget ();

# HTTP-neutral finite result consumption. Dialects own transfer guards; a host
# adapter must explicitly implement that capability, bounded streaming and a
# real database deadline. A post-fetch byte check is not a buffering capability.
sub prepare {
    my ($class, $engine, $query, %args) = @_;
    my $limits = _limits($engine, $args{limits});
    my $adapter = $engine->adapter;
    _capabilities($adapter);
    Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query')->check_tree($query,
        allowed_classes => ['Selecto::Query', 'Selecto::Expression'], label => 'Bounded query');
    my %top = map { refaddr($_) => 1 } @{$query->selections};
    my @scan = ($query);
    while (@scan) {
        my $node = pop @scan;
        next unless ref($node);
        Selecto::Error->throw('unsupported_feature', 'nested collection expressions require a bounded profile')
            if blessed($node) && $node->isa('Selecto::Expression')
                && $node->kind eq 'related_collection' && !$top{refaddr($node)};
        push @scan, ref($node) eq 'ARRAY' ? @$node
            : (reftype($node) // '') eq 'HASH' ? values(%$node) : ();
    }
    # UI surfaces use ordinary selections. Advanced query sources can conceal
    # nested materialization and require a separately reviewed bounded profile.
    Selecto::Error->throw('unsupported_feature', 'advanced query sources are unavailable for bounded results')
        if grep { @{$query->{$_} // []} } qw(set_operations ctes lateral_joins json_rowsets array_rowsets members);
    # Compiler admission runs before reading/cloning any public expression args.
    $engine->compile($query);
    my (@select, @collections);
    for my $expression (@{$query->selections}) {
        if ($expression->kind eq 'related_collection') {
            my ($path, $fields, $options) = @{$expression->arguments};
            $options //= {};
            if (!defined($options->{aggregate})) {
                Selecto::Error->throw('unsupported_feature', 'bounded child collections require PostgreSQL')
                    unless $adapter->name eq 'postgresql';
                Selecto::Error->throw('unsupported_feature', 'bounded child collections require scalar or formatted child fields')
                    if grep { ref($_) && !_formatted_child($_) } @$fields;
                my $association = $engine->domain->resolve_association($path)->{association};
                my $key = $association->target_primary_key;
                Selecto::Error->throw('unsupported_feature', 'bounded child collections require a primary key')
                    unless defined $key;
                my $cap = $limits->get('max_collection_rows');
                $cap = $options->{limit} if defined($options->{limit}) && $options->{limit} < $cap;
                my @orders = @{$options->{order_by} // []};
                push @orders, [$key, 'asc'] unless grep { $_->[0] eq $key } @orders;
                my $bounded = Selecto::Expression->related_collection($path, $fields,
                    %$options, order_by => \@orders, limit => $cap + 1);
                $bounded = $bounded->as($expression->alias_name) if defined($expression->alias_name);
                $expression = $bounded;
                push @collections, [scalar(@select), $cap];
            }
        }
        push @select, $expression;
    }
    my $bounded = $query->_copy(selections => \@select);
    return {statement => $engine->compile($bounded), query => $bounded, collections => \@collections, limits => $limits};
}

# A formatted child date is still one value per child row. Any other child
# expression could conceal a nested collection outside the per-parent cap.
sub _formatted_child {
    my ($field) = @_;
    my $expression = ref($field) eq 'HASH' ? $field->{expression} : undef;
    return 0 unless blessed($expression) && $expression->isa('Selecto::Expression')
        && $expression->kind eq 'datetime_format';
    my $operand = $expression->arguments->[0];
    return blessed($operand) && $operand->kind eq 'field' ? 1 : 0;
}

sub all {
    my ($class, $engine, $query, %args) = @_;
    return $class->execute($engine, $class->prepare($engine, $query, %args), %args);
}

sub execute {
    my ($class, $engine, $prepared, %args) = @_;
    my $statement = ref($prepared) eq 'HASH' ? $prepared->{statement} : $prepared;
    my $collections = ref($prepared) eq 'HASH' ? $prepared->{collections} : [];
    my $limits = _limits($engine, $args{limits} // (ref($prepared) eq 'HASH' ? $prepared->{limits} : undef));
    my $max_rows = $args{max_rows} // $limits->get('max_total_cells');
    my $timeout = $args{timeout_ms} // 5000;
    for ($max_rows, $timeout) {
        Selecto::Error->throw('invalid_query', 'bounded execution limits must be positive integers')
            unless defined($_) && !ref($_) && "$_" =~ /\A[1-9][0-9]{0,8}\z/;
    }
    # The query's own LIMIT is a firmer row ceiling than the caller's allowance.
    my $query = ref($prepared) eq 'HASH' ? $prepared->{query} : undef;
    my $query_limit = blessed($query) && $query->can('limit_value') ? $query->limit_value : undef;
    $max_rows = 0 + $query_limit
        if defined($query_limit) && !ref($query_limit) && "$query_limit" =~ /\A[1-9][0-9]{0,8}\z/
            && $query_limit < $max_rows;
    my $adapter = $engine->adapter;
    _capabilities($adapter);
    Selecto::OperationBudget->new(limits => $limits, code => 'invalid_query')->consume_parameters($statement->params);
    my @columns = @{$statement->columns};
    $limits->check_count('max_generated_selections', scalar(@columns), 'result_limit_exceeded', 'Result columns');
    my $cell_limit = $limits->get('max_result_cell_bytes');
    my $row_cell_limit = int($limits->get('max_response_bytes') / (@columns || 1));
    $cell_limit = $row_cell_limit if $row_cell_limit < $cell_limit;
    Selecto::Error->throw('result_limit_exceeded', 'Result transfer exceeds its resource limit') unless $cell_limit;
    my $guarded = $adapter->bounded_result_statement($statement, max_cell_bytes => $cell_limit, max_rows => $max_rows + 1);
    my ($stream, $deadline, @rows);
    my $budget = $class->result_budget($limits);
    my @canonical = exists($args{canonical_values}) && $adapter->supports('canonical_values')
        ? (canonical_values => $args{canonical_values} ? 1 : 0) : ();
    my $admit = sub {
        my ($row) = @_;
        $deadline->check(defer_rearm => 1);
        Selecto::Error->throw('result_limit_exceeded', 'Result exceeds its transfer limit')
            unless @$row == @columns + 1 && !pop(@$row);
        Selecto::Error->throw('result_limit_exceeded', 'Result row limit exceeded') if @rows >= $max_rows;
        $class->admit_row($budget, $row, $collections);
        push @rows, $row;
    };
    # A result whose guard keeps it within one fetch batch buffers no more as a
    # plain statement than a cursor would: run it directly, under a timeout that
    # lasts for the host's transaction. Two round trips instead of a cursor's
    # savepoint, declare, fetches, close and timeout restore.
    my $direct = $max_rows + 1 <= DIRECT_ROWS()
        && $adapter->can('bounded_direct_supported') && $adapter->bounded_direct_supported;
    my $ok = eval {
        if ($direct) {
            $deadline = $adapter->begin_query_budget(timeout_ms => $timeout);
            $deadline->check(defer_rearm => 1);
            $admit->($_) for @{$adapter->execute_query($guarded, @canonical)->{rows}};
        } else {
            $deadline = $adapter->begin_query_budget(timeout_ms => $timeout);
            $stream = $adapter->stream_query($guarded, bounded => 1, fetch_size => fetch_rows($max_rows), @canonical);
            while (my $row = $stream->next) {
                $admit->($row);
            }
        }
        1;
    };
    my $error = $@;
    eval { $stream->close if $stream; 1 } or $error ||= $@;
    eval { $deadline->close if $deadline; 1 } or $error ||= $@;
    die $error unless $ok && !$error;
    return {columns => \@columns, rows => \@rows};
}

# Rows per database round trip: the whole result when it fits (max_rows plus
# the one row that detects excess), otherwise batches of FETCH_ROWS. Every cell
# is already capped by the transfer guard, so a batch is bounded too.
use constant FETCH_ROWS => 100;
sub fetch_rows { my ($max_rows) = @_; return $max_rows + 1 < FETCH_ROWS ? $max_rows + 1 : FETCH_ROWS; }

# Rows a guarded result may hold and still run as one plain statement: a page of
# up to 100 rows, the row that detects another page and the row that detects
# excess, about one FETCH_ROWS batch.
use constant DIRECT_ROWS => 102;

sub result_budget {
    my ($class, $limits) = @_;
    return {limits => $limits, cells => 0, children => 0,
        tree => Selecto::OperationBudget->new(limits => $limits, code => 'result_limit_exceeded')};
}

sub admit_row {
    my ($class, $budget, $row, $collections) = @_;
    my $limits = $budget->{limits};
    Selecto::Error->throw('invalid_result', 'Invalid result row') unless ref($row) eq 'ARRAY';
    $limits->check_count('max_total_cells', $budget->{cells} += @$row, 'result_limit_exceeded', 'Result cells');
    # Raw JSON must fit before decoding, even for custom host cache entries.
    for my $column (@{$collections // []}) {
        my ($index, $cap) = @$column;
        my $value = $row->[$index];
        if (defined($value) && !ref($value)) {
            $limits->check_bytes('max_result_cell_bytes', $value, 'result_limit_exceeded', 'Result cell');
            my $json = utf8::is_utf8($value) ? do { require Encode; Encode::encode('UTF-8', $value) } : $value;
            $value = eval { decode_json($json) };
            Selecto::Error->throw('invalid_result', 'Invalid child collection') if $@;
        }
        Selecto::Error->throw('invalid_result', 'Invalid child collection')
            unless ref($value) eq 'ARRAY' && !grep { ref($_) ne 'HASH' } @$value;
        Selecto::Error->throw('result_limit_exceeded', 'Child collection exceeds its resource limit') if @$value > $cap;
        $limits->check_count('max_total_collection_rows', $budget->{children} += @$value,
            'result_limit_exceeded', 'Child collections');
        $row->[$index] = $value;
    }
    $budget->{tree}->check_tree($row, label => 'Result', bytes_limit => 'max_response_bytes',
        scalar_limit => 'max_result_cell_bytes');
    # Count nested cells as well as parent slots. The tree guard has already
    # bounded this traversal and rejected cycles and unsupported references.
    my @nested = grep { ref($_) eq 'ARRAY' || ref($_) eq 'HASH' } @$row;
    while (@nested) {
        my $value = pop @nested;
        my @values = ref($value) eq 'ARRAY' ? @$value : values %$value;
        $limits->check_count('max_total_cells', $budget->{cells} += @values,
            'result_limit_exceeded', 'Result cells');
        push @nested, grep { ref($_) eq 'ARRAY' || ref($_) eq 'HASH' } @values;
    }
    return $row;
}

sub validate_result {
    my ($class, $result, $limits, $collections) = @_;
    Selecto::Error->throw('invalid_result', 'Invalid result shape')
        unless ref($result) eq 'HASH' && ref($result->{columns}) eq 'ARRAY' && ref($result->{rows}) eq 'ARRAY';
    $limits->check_count('max_generated_selections', scalar(@{$result->{columns}}), 'result_limit_exceeded', 'Result columns');
    my $budget = $class->result_budget($limits);
    $budget->{tree}->check_tree($result->{columns}, bytes_limit => 'max_response_bytes', scalar_limit => 'max_result_cell_bytes');
    for my $row (@{$result->{rows}}) {
        Selecto::Error->throw('invalid_result', 'Invalid result width') unless ref($row) eq 'ARRAY' && @$row == @{$result->{columns}};
        $class->admit_row($budget, $row, $collections);
    }
    return $result;
}

sub _limits {
    my ($engine, $limits) = @_;
    my $base = $engine->can('limits') ? $engine->limits : Selecto::Limits->new;
    return defined($limits) ? $base->intersect($limits) : $base;
}
sub _capabilities {
    my ($adapter) = @_;
    Selecto::Error->throw('unsupported_feature', 'Adapter cannot provide bounded result execution')
        unless $adapter->can('bounded_result_statement') && $adapter->can('bounded_stream_supported')
            && $adapter->bounded_stream_supported && $adapter->can('query_budget_supported')
            && $adapter->query_budget_supported && $adapter->can('begin_query_budget');
}

1;

__END__

=head1 NAME

Selecto::BoundedQuery - finite ordinary result execution for untrusted surfaces

=head1 SYNOPSIS

    my $result = Selecto::BoundedQuery->all($engine, $query,
        limits => $trusted_limits, max_rows => 1000, timeout_ms => 5000);

=head1 DESCRIPTION

Intersects host limits with the engine limits, bounds PostgreSQL child
collections before JSON aggregation, and consumes one guarded row at a time.
It fetches C<min(max_rows + 1, 100)> guarded rows per database round trip,
so an ordinary page is a single fetch; each row is admitted as it is handed
out.
The concrete materialization guards require PostgreSQL 12 or newer, or SQLite
3.35 or newer. The adapter must implement C<bounded_result_statement>, bounded streaming and
a database deadline. PostgreSQL and SQLite transfer guards suppress a cell
larger than the trusted byte ceiling before it reaches DBI, and mark the row
for rejection. C<max_rows + 1> detects excess rows; excess children or bytes
raise an error, never a successful truncated result. Advanced query-source
shapes and nested collections on unsupported adapters fail closed.

Rows hold the adapter's default result values; pass
C<< canonical_values => 1 >> to C<all> or C<execute> for canonical values
(see L<Selecto::PostgreSQL/RESULT VALUES>). L<Selecto::CannedPage> does.

The result walker checks cumulative cells, child counts, UTF-8 bytes, nodes,
depth and cycles. This bounds application transfer/materialization; it is not
a general database query-plan memory proof. Transports must additionally
check their final encoded response size. All streams and database deadline
scopes close on success and failure.

C<prepare> returns a trusted statement/query/collection-bound bundle for
cache-aware consumers. C<execute> accepts that bundle or a trusted compiled
scalar-result statement. Never accept compiled SQL or execution options from
request data. C<validate_result> admits cached result structures using the
same trusted result limits; cache authorization namespacing belongs to the
host, independently of this module.

=cut
