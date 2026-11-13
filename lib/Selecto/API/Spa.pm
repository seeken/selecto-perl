package Selecto::API::Spa;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use B ();
use JSON::PP ();
use List::Util qw(max min);
use Scalar::Util qw(blessed);
use Selecto::API::EngineHandler ();
use Selecto::Error ();

# The Selecto SPA explorer protocol (selecto.spa.*/v1) over the canonical
# API's query handler: this module validates explorer requests against the
# host's descriptor, translates them into canonical query bodies and shapes
# the canonical results into explorer responses. Field validation, filter
# translation, selection and execution are the canonical handler's.

our $QUERY_REQUEST  = 'selecto.spa.query-request/v1';
our $QUERY_RESPONSE = 'selecto.spa.query-response/v1';
our $ERROR          = 'selecto.spa.error/v1';
our $DESCRIPTOR     = 'selecto.spa.domain-descriptor/v1';

# Request limits; the defaults are the builder explorer contract's.
my %DEFAULT_LIMITS = (
    selected => 5, columns => 20, alias => 80, order_by => 6, group_by => 3,
    aggregates => 8, filter_rules => 50, filter_depth => 3, in_values => 100,
    text => 255, page_number => 10_000, page_size => 500, groups => 1000,
);
my %FORMATS = map { $_ => 1 } qw(number percent date_short date_medium date_long
    datetime_short datetime_medium time_short time_medium yes_no);
my %FUNCTION_LABEL = (count => 'Count', count_distinct => 'Distinct count', sum => 'Sum',
    avg => 'Average', min => 'Min', max => 'Max');
# Explorer operator => canonical filter operator.
my %OPERATOR = (
    equals => 'eq', not_equals => 'ne', greater_than => 'gt', greater_than_or_equal => 'gte',
    less_than => 'lt', less_than_or_equal => 'lte', between => 'between', in => 'in',
    not_in => 'not_in', contains => 'text_contains', starts_with => 'starts_with',
    ends_with => 'ends_with', is_null => 'is_null', is_not_null => 'not_null',
);
my %NUMERIC = map { $_ => 1 } qw(integer decimal number float);

has 'domains';
has base_path => '/api/selecto';
has unavailable_message => 'The database is unavailable';
has limits => sub { +{} };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    _host_error('limits must be a hash') unless ref($self->limits) eq 'HASH';
    my %limits = (%DEFAULT_LIMITS, %{$self->limits});
    for my $name (keys %limits) {
        _host_error("unknown limit $name") unless exists $DEFAULT_LIMITS{$name};
        _host_error("limit $name must be a positive integer")
            unless defined($limits{$name}) && !ref($limits{$name}) && $limits{$name} =~ /\A[1-9][0-9]*\z/;
    }
    $self->limits(\%limits);
    my $domains = $self->domains;
    _host_error('domains must be a non-empty array')
        unless ref($domains) eq 'ARRAY' && @$domains;
    my %by_id;
    for my $entry (@$domains) {
        _host_error('each domain needs a descriptor and an engine')
            unless ref($entry) eq 'HASH' && ref($entry->{descriptor}) eq 'HASH'
                && (ref($entry->{engine}) eq 'CODE'
                    || (blessed($entry->{engine}) && $entry->{engine}->isa('Selecto::Engine')));
        my $descriptor = $entry->{descriptor};
        _host_error('descriptor must be a selecto.spa domain descriptor')
            unless ($descriptor->{schema} // '') eq $DESCRIPTOR && _is_string($descriptor->{id})
                && ref($descriptor->{fields}) eq 'ARRAY';
        _host_error("duplicate domain $descriptor->{id}") if $by_id{$descriptor->{id}};
        my $domain = blessed($entry->{engine}) ? $entry->{engine}->domain : $entry->{domain};
        _host_error('an engine factory needs its domain')
            unless blessed($domain) && $domain->isa('Selecto::Domain');
        my %fields;
        for my $field (@{$descriptor->{fields}}) {
            _host_error('descriptor fields need an id and a type')
                unless ref($field) eq 'HASH' && _is_string($field->{id}) && _is_string($field->{type});
            my $selector = _selector($field);
            # Advertising a field is not authority to read it: the canonical
            # handler refuses internal fields, and so does the descriptor.
            _host_error("descriptor field $field->{id} is not a public domain field")
                unless eval { $domain->resolve($selector); 1 } && $domain->field_is_public($selector);
            $fields{$field->{id}} = {%$field, selector => $selector};
        }
        my $primary_key = $descriptor->{primaryKey} // $domain->primary_key;
        $by_id{$descriptor->{id}} = {descriptor => $descriptor, engine => $entry->{engine},
            fields => \%fields, primary_key => $primary_key};
    }
    $self->{by_id} = \%by_id;
    my $limits = $self->limits;
    $self->{handler} = Selecto::API::EngineHandler->new(
        filter_groups => 1, aggregate_selections => 1,
        max_filters => $limits->{filter_rules}, max_filter_values => $limits->{in_values},
        max_filter_depth => $limits->{filter_depth} + 1, max_orders => $limits->{order_by} + 1,
        max_fields => max($limits->{selected}, $limits->{group_by} + $limits->{aggregates}),
        max_limit => max($limits->{page_size}, $limits->{groups}),
        default_limit => $limits->{page_size},
        max_offset => ($limits->{page_number} - 1) * $limits->{page_size},
    );
    return $self;
}

sub descriptors ($self) {
    return [map { $_->{descriptor} } @{$self->domains}];
}

sub descriptor ($self, $id) {
    my $entry = _is_string($id) ? $self->{by_id}{$id} : undef;
    return $entry ? $entry->{descriptor} : undef;
}

# {method, path, body, context} => {status, json}. context is passed to an
# engine factory.
sub request ($self, $request) {
    my ($method, $path) = map { $request->{$_} // '' } qw(method path);
    my $base = $self->base_path;
    return {status => 200, json => $self->descriptors} if $method eq 'GET' && $path eq "$base/domains";
    if ($method eq 'GET' && index($path, "$base/domains/") == 0) {
        my $descriptor = $self->descriptor(substr($path, length("$base/domains/")));
        return {status => 200, json => $descriptor} if $descriptor;
    }
    if ($method eq 'POST' && $path eq "$base/query") {
        my $result = eval { $self->query($request->{body}, $request->{context}) };
        return {status => 200, json => $result} if $result;
        my $error = $@;
        # The request (or the engine's validation of it) is invalid; anything
        # else, such as a database failure, is the server's.
        return {status => 503, json => {error => $self->unavailable_message}}
            unless blessed($error) && $error->isa('Selecto::Error')
                && $error->code !~ /\A(?:query_error|database_|invalid_api_host|invalid_api_handler)/;
        return {status => 422, json => _error('invalid_query', 'Unsupported or invalid query')};
    }
    return {status => 404, json => _error('not_found', 'Not found')};
}

sub query ($self, $body, $context = undef) {
    _invalid('Unsupported query') unless _is_hash($body) && _is_string($body->{schema})
        && $body->{schema} eq $QUERY_REQUEST && _is_string($body->{domainId})
        && $self->{by_id}{$body->{domainId}} && _is_string($body->{view})
        && $body->{view} =~ /\A(?:detail|aggregate|graph)\z/;
    my $domain = $self->{by_id}{$body->{domainId}};
    my $limits = $self->limits;
    my $state = $body->{state};
    _invalid('Invalid state') unless _is_hash($state);
    my $filter = defined($body->{filters}) ? $self->_group($domain, $body->{filters}, 0, \(my $rules = 0)) : undef;
    my $page = $body->{page} // {number => 1, size => 30};
    _invalid('Invalid page') unless _is_hash($page);
    my ($number, $size) = ($page->{number} // 1, $page->{size} // 30);
    _invalid('Invalid page') unless _is_integer($number) && $number >= 1 && $number <= $limits->{page_number}
        && _is_integer($size) && $size >= 1 && $size <= $limits->{page_size};
    my $orders = $state->{orderBy} // [];
    _invalid('Invalid order') unless ref($orders) eq 'ARRAY' && @$orders <= $limits->{order_by}
        && !grep { !_is_hash($_) || !_is_string($_->{direction} // 'asc') || ($_->{direction} // 'asc') !~ /\A(?:asc|desc)\z/ } @$orders;
    my $engine = ref($domain->{engine}) eq 'CODE' ? $domain->{engine}->($context) : $domain->{engine};
    my $run = {engine => $engine, filters => $filter ? [$filter] : []};
    my $page_info = {number => 0 + $number, size => 0 + $size};
    return $body->{view} eq 'detail'
        ? $self->_detail($domain, $run, $state, $orders, $page_info)
        : $self->_aggregate($domain, $run, $body->{view}, $state, $orders, $page_info);
}

sub _detail ($self, $domain, $run, $state, $orders, $page) {
    my ($fields, $limits) = ($domain->{fields}, $self->limits);
    my $known = sub ($id) { _is_string($id) && $fields->{$id} };
    my $selected = $state->{selected};
    my %seen;
    _invalid('Invalid selection') unless ref($selected) eq 'ARRAY' && @$selected >= 1 && @$selected <= $limits->{selected}
        && !grep { !$known->($_) || !_allows($fields->{$_}, 'selectable') || $seen{$_}++ } @$selected;
    my @occurrences = map { +{field => $_} } @$selected;
    if (defined $state->{columns}) {
        my $columns = $state->{columns};
        _invalid('Invalid columns') unless ref($columns) eq 'ARRAY' && @$columns >= 1 && @$columns <= $limits->{columns};
        for my $column (@$columns) {
            _invalid('Invalid column') unless _is_hash($column) && $known->($column->{field})
                && (!defined($column->{alias}) || $self->_valid_label($column->{alias}))
                && (!defined($column->{format}) || (_is_string($column->{format}) && $FORMATS{$column->{format}}));
        }
        my %first;
        my @distinct = grep { !$first{$_}++ } map { $_->{field} } @$columns;
        _invalid('Columns must list the selected fields')
            unless @distinct == @$selected && !grep { $distinct[$_] ne $selected->[$_] } 0 .. $#distinct;
        @occurrences = @$columns;
    }
    _invalid('Invalid order') if grep { !$known->($_->{field}) || !_allows($fields->{$_->{field}}, 'sortable') } @$orders;
    my @order_by = map { +{field => $fields->{$_->{field}}{selector}, direction => $_->{direction} // 'asc'} } @$orders;
    # A unique tie-breaker keeps pages stable.
    push @order_by, {field => $domain->{primary_key}, direction => 'asc'}
        if defined($domain->{primary_key}) && !grep { $_->{field} eq $domain->{primary_key} } @order_by;
    my $total = $self->_run($run, {select => [{aggregate => 'count', alias => 'total'}], limit => 1})->{rows}[0][0];
    my $result = $self->_run($run, {
        select => [map { +{field => $fields->{$selected->[$_]}{selector}, alias => "c$_"} } 0 .. $#$selected],
        order_by => \@order_by, limit => $page->{size}, offset => ($page->{number} - 1) * $page->{size},
    });
    my (%count, @columns);
    for my $occurrence (@occurrences) {
        my $field = $fields->{$occurrence->{field}};
        my $n = ++$count{$field->{id}};
        my $alias = _is_string($occurrence->{alias}) && $occurrence->{alias} =~ /\S/ ? $occurrence->{alias} : undef;
        push @columns, {id => $n == 1 ? $field->{id} : "$field->{id}~$n", label => $alias // $field->{label}, type => $field->{type},
            (defined($occurrence->{format}) ? (format => $occurrence->{format}) : ()), ($n > 1 ? (field => $field->{id}, occurrence => $n) : ())};
    }
    my %position = map { $selected->[$_] => $_ } 0 .. $#$selected;
    my @rows = map {
        my $row = $_;
        +{map { $columns[$_]{id} => _wire($row->[$position{$occurrences[$_]{field}}], $columns[$_]{type}) } 0 .. $#columns}
    } @{$result->{rows}};
    return {schema => $QUERY_RESPONSE, columns => \@columns, rows => \@rows, page => {%$page, totalRows => 0 + ($total // 0)}};
}

sub _aggregate ($self, $domain, $run, $view, $state, $orders, $page) {
    my ($fields, $limits) = ($domain->{fields}, $self->limits);
    my $known = sub ($id) { _is_string($id) && $fields->{$id} };
    my $group_by = $state->{groupBy} // [];
    my %seen;
    _invalid('Invalid groups') unless ref($group_by) eq 'ARRAY' && @$group_by <= $limits->{group_by}
        && !grep { !$known->($_) || !_allows($fields->{$_}, 'groupable') || $seen{$_}++ } @$group_by;
    my $requested = $state->{aggregates} // [];
    _invalid('Invalid aggregates') unless ref($requested) eq 'ARRAY' && @$requested <= $limits->{aggregates};
    my @aggregates = map {
        my $item = $_;
        _invalid('Invalid aggregate') unless _is_hash($item) && $known->($item->{field}) && _is_string($item->{function})
            && $FUNCTION_LABEL{$item->{function}}
            && grep { $_ eq $item->{function} } @{$fields->{$item->{field}}{aggregateFunctions} // []};
        my $explicit = defined($item->{alias}) && !(_is_string($item->{alias}) && $item->{alias} eq '');
        _invalid('Invalid alias') if $explicit && !$self->_valid_label($item->{alias});
        my $field = $fields->{$item->{field}};
        +{id => $explicit ? $item->{alias} : "$item->{function}_" . ($item->{field} =~ s/\./_/r),
            label => $explicit ? $item->{alias} : "$FUNCTION_LABEL{$item->{function}} of $field->{label}",
            field => $field, function => $item->{function},
            type => $item->{function} eq 'avg' ? 'decimal' : $item->{function} =~ /\Acount/ ? 'integer' : $field->{type}};
    } @$requested;
    my %ids;
    _invalid('Duplicate aggregate alias') if grep { $ids{$_->{id}}++ || $fields->{$_->{id}} } @aggregates;
    _invalid('Choose a group or an aggregate') unless @$group_by || @aggregates;
    # Explorers carry the Detail sort into these views; ignore entries that
    # name neither a group field nor an aggregate.
    my @sorts = grep { my $f = $_->{field}; _is_string($f) && ((grep { $_ eq $f } @$group_by) || $ids{$f}) } @$orders;
    my %types = ((map { $_ => $fields->{$_}{type} } @$group_by), (map { $_->{id} => $_->{type} } @aggregates));
    my $rollup = $view eq 'aggregate' && _is_true($state->{rollup}) && !_is_true($state->{aggregateGrid}) && @$group_by;
    # Rollup runs one bounded grouped query per prefix of the groups, the
    # portable path for databases without a common ROLLUP syntax.
    my @levels = $rollup ? ((reverse 1 .. @$group_by), 0) : (scalar @$group_by);
    my @merged;
    for my $level (@levels) {
        my @groups = map { $fields->{$_}{selector} } @$group_by[0 .. $level - 1];
        my @select = ((map { +{field => $groups[$_], alias => "g$_"} } 0 .. $#groups),
            (map { +{aggregate => $aggregates[$_]{function}, field => $aggregates[$_]{field}{selector}, alias => "a$_"} } 0 .. $#aggregates));
        # A grand total with no aggregates selects nothing: one empty row.
        my $result = @select
            ? $self->_run($run, {select => \@select, limit => $limits->{groups},
                (@groups ? (group_by => \@groups, order_by => [map { +{field => $_} } @groups]) : ())})
            : {rows => [[]], has_more => 0};
        _invalid('Too many groups') if $result->{has_more} || @merged + @{$result->{rows}} > $limits->{groups};
        for my $row (@{$result->{rows}}) {
            my %out;
            $out{$group_by->[$_]} = $_ < $level ? _wire($row->[$_], $types{$group_by->[$_]}) : undef for 0 .. $#$group_by;
            $out{$aggregates[$_]{id}} = _wire($row->[@groups + $_], $aggregates[$_]{type}) for 0 .. $#aggregates;
            push @merged, {row => \%out, level => $level};
        }
    }
    @merged = sort {
        my $c = 0;
        if (!$rollup) {
            for my $o (@sorts) {
                $c = _compare($a->{row}{$o->{field}}, $b->{row}{$o->{field}}, $types{$o->{field}});
                if ($c) { $c = -$c if ($o->{direction} // 'asc') eq 'desc'; last }
            }
        }
        for my $i (0 .. $#$group_by) {
            last if $c;
            my ($ra, $rb) = ($i < $a->{level} ? 0 : 1, $i < $b->{level} ? 0 : 1);
            $c = $ra <=> $rb || _compare($a->{row}{$group_by->[$i]}, $b->{row}{$group_by->[$i]}, $types{$group_by->[$i]});
        }
        $c;
    } @merged;
    my ($number, $size) = @$page{qw(number size)};
    my @page_items = grep { defined } @merged[($number - 1) * $size .. min($number * $size, scalar @merged) - 1];
    my @columns = ((map { +{id => $_, label => $fields->{$_}{label}, type => $fields->{$_}{type}} } @$group_by),
        (map { my $item = $_; +{map { $_ => $item->{$_} } qw(id label type)} } @aggregates));
    my @row_meta = map {
        my ($row, $level) = @$_{qw(row level)};
        $level == 0 ? {rollupLevel => 0, rollupKind => 'total', drilldowns => []}
            : {rollupLevel => $level, rollupKind => $level < @$group_by ? 'subtotal' : 'detail',
                drilldowns => [{columnId => $group_by->[$level - 1],
                    constraints => [map { +{field => $_, operator => 'equals', value => $row->{$_}} } @$group_by[0 .. $level - 1]]}]};
    } @page_items;
    return {schema => $QUERY_RESPONSE, columns => \@columns, rows => [map { $_->{row} } @page_items],
        (@$group_by ? (rowMeta => \@row_meta) : ()), page => {%$page, totalRows => scalar @merged}};
}

sub _run ($self, $run, $body) {
    return $self->{handler}->query($run->{engine}, {%$body, (@{$run->{filters}} ? (filters => $run->{filters}) : ())});
}

# An explorer filter group as one canonical filter (an any/all group or a
# single filter), or undef for an empty group.
sub _group ($self, $domain, $group, $depth, $rules) {
    _invalid('Invalid filters') unless _is_hash($group) && $depth <= $self->limits->{filter_depth} && ref($group->{items}) eq 'ARRAY';
    my $conjunction = $group->{conjunction} // 'and';
    _invalid('Invalid filters') unless _is_string($conjunction) && $conjunction =~ /\A(?:and|or)\z/;
    my @parts = grep { defined } map {
        _is_hash($_) && exists $_->{items} ? $self->_group($domain, $_, $depth + 1, $rules) : $self->_rule($domain, $_, $rules)
    } @{$group->{items}};
    return undef unless @parts;
    return $parts[0] if @parts == 1;
    return {($conjunction eq 'and' ? 'all' : 'any') => \@parts};
}

sub _rule ($self, $domain, $item, $rules) {
    my $limits = $self->limits;
    _invalid('Invalid filter') unless _is_hash($item) && ++$$rules <= $limits->{filter_rules}
        && _is_string($item->{field}) && $domain->{fields}{$item->{field}};
    my $field = $domain->{fields}{$item->{field}};
    my $operator = $item->{operator};
    _invalid('Unsupported filter') unless _is_string($operator) && $OPERATOR{$operator}
        && grep { $_ eq $operator } @{$field->{filterOperators} // []};
    my %filter = (field => $field->{selector}, op => $OPERATOR{$operator});
    if ($operator eq 'in' || $operator eq 'not_in') {
        _invalid('Invalid filter value') unless ref($item->{value}) eq 'ARRAY' && @{$item->{value}} >= 1
            && @{$item->{value}} <= $limits->{in_values};
        $filter{value} = [map { $self->_scalar($field, $_) } @{$item->{value}}];
    } elsif ($operator eq 'between') {
        @filter{qw(value end)} = map { $self->_scalar($field, $_) } @{$item}{qw(value valueTo)};
    } elsif ($operator ne 'is_null' && $operator ne 'is_not_null') {
        $filter{value} = $self->_scalar($field, $item->{value});
    }
    return \%filter;
}

# A filter value of the field's type. Integer fields also accept decimal
# digit strings, as explorer inputs send them.
sub _scalar ($self, $field, $value) {
    if ($field->{type} eq 'integer') {
        return 0 + $value if _is_string($value) && $value =~ /\A-?[0-9]{1,15}\z/;
        _invalid('Invalid filter value') unless _is_integer($value);
        return $value;
    }
    if ($NUMERIC{$field->{type}}) {
        return 0 + $value if _is_string($value) && $value =~ /\A-?[0-9]{1,15}(?:\.[0-9]{1,15})?\z/;
        _invalid('Invalid filter value') unless defined($value) && !ref($value) && !_is_string($value);
        return $value;
    }
    if ($field->{type} eq 'boolean') {
        _invalid('Invalid filter value') unless JSON::PP::is_bool($value);
        return $value ? JSON::PP::true : JSON::PP::false;
    }
    _invalid('Invalid filter value') unless _is_string($value) && _text_length($value) <= $self->limits->{text};
    return $value;
}

sub _valid_label ($self, $value) {
    return _is_string($value) && _text_length($value) <= $self->limits->{alias} && $value !~ /[\x00-\x1f\x7f]/;
}

# A descriptor field's domain path: metadata.selectoSelector when present,
# otherwise its id with the explorer's source. prefix removed.
sub _selector ($field) {
    my $metadata = ref($field->{metadata}) eq 'HASH' ? $field->{metadata} : {};
    return _is_string($metadata->{selectoSelector}) ? $metadata->{selectoSelector} : $field->{id} =~ s/\Asource\.//r;
}

# Capabilities default to allowed when a descriptor leaves them out.
sub _allows ($field, $capability) {
    return !exists($field->{$capability}) || $field->{$capability} ? 1 : 0;
}

# Drivers return counts, sums and averages as numbers or numeric strings;
# emit JSON numbers for numeric columns and JSON strings for text.
sub _wire ($value, $type) {
    return undef unless defined $value;
    return 0 + $value if $NUMERIC{$type};
    return $value ? JSON::PP::true : JSON::PP::false if $type eq 'boolean';
    return "$value";
}

# Nulls first, numbers numerically, text by code point.
sub _compare ($x, $y, $type) {
    return defined($x) ? 1 : defined($y) ? -1 : 0 unless defined($x) && defined($y);
    return $NUMERIC{$type} ? $x <=> $y : $x cmp $y;
}

sub _error ($code, $message) {
    return {schema => $ERROR, error => {code => $code, message => $message, issues => []}};
}

sub _invalid ($message) { Selecto::Error->throw('invalid_spa_query', $message) }
sub _host_error ($message) { Selecto::Error->throw('invalid_spa_host', $message) }
sub _is_hash ($value) { return ref($value) eq 'HASH' }
# JSON strings decode as Perl strings and JSON numbers as numbers; tell them
# apart by the scalar's flags before anything stringifies it.
sub _is_string ($value) { return defined($value) && !ref($value) && (B::svref_2object(\$value)->FLAGS & B::SVf_POK) }
sub _is_integer ($value) { return defined($value) && !ref($value) && !_is_string($value) && $value == int($value) && abs($value) <= 9_007_199_254_740_991 }
sub _is_true ($value) { return JSON::PP::is_bool($value) && $value }
# Lengths count UTF-16 code units, as JavaScript clients do.
sub _text_length ($value) { return length($value) + ($value =~ tr/\x{10000}-\x{10FFFF}//) }

1;

__END__

=head1 NAME

Selecto::API::Spa - the Selecto SPA explorer protocol over the canonical query handler

=head1 SYNOPSIS

  my $spa = Selecto::API::Spa->new(
      domains => [{descriptor => $descriptor, engine => $engine}],
  );
  # In a web route: {status, json}
  my $response = $spa->request({method => 'POST', path => '/api/selecto/query', body => $json});

=head1 DESCRIPTION

Serves the C<selecto.spa.*/v1> protocol that the Selecto SPA explorers (Vue,
React, Svelte, Angular) speak: domain descriptors, and Detail, Aggregate (with
rollup and the aggregate grid) and Graph queries with nested AND/OR filters,
repeated Detail columns and paging.

The module owns only the protocol: it validates each request against the
host's descriptor (fields, their advertised capabilities, operators and
aggregate functions, labels, formats and the limits below), translates it into
canonical query bodies and shapes the results. Every query runs through
L<Selecto::API::EngineHandler>, the canonical API's handler, with its
C<filter_groups> and C<aggregate_selections> extensions enabled: field
visibility, filter translation (including conditional choice filters), tenant
boundaries, response limits and execution are the canonical API's.

=head1 CONSTRUCTOR

=head2 new

=over 4

=item domains

An array of C<< {descriptor => \%descriptor, engine => $engine} >>. The
descriptor is a trusted C<selecto.spa.domain-descriptor/v1> document served
as is; each field's domain path is its C<metadata.selectoSelector>, or its id
without a leading C<source.>, and must be a public field of the engine's
domain. C<engine> may be a callback receiving the request's C<context>; it
then needs C<< domain => $domain >> too.

=item limits

Overrides for the request limits: C<selected> (5), C<columns> (20), C<alias>
(80), C<order_by> (6), C<group_by> (3), C<aggregates> (8), C<filter_rules>
(50), C<filter_depth> (3), C<in_values> (100), C<text> (255), C<page_number>
(10000), C<page_size> (500) and C<groups> (1000).

=item base_path

Route prefix, default C</api/selecto>.

=item unavailable_message

The C<error> text of a 503 response.

=back

=head1 METHODS

=head2 request

  my $response = $spa->request({method => ..., path => ..., body => ..., context => ...});

Routes C<GET base/domains>, C<GET base/domains/:id> and C<POST base/query>.
Returns C<< {status => ..., json => ...} >>. An invalid request is 422 with a
C<selecto.spa.error/v1> body (code C<invalid_query>); a database failure is
503; an unknown route is 404.

=head2 query

  my $response = $spa->query($request_body, $context);

Runs one C<selecto.spa.query-request/v1> and returns its
C<selecto.spa.query-response/v1>, or throws a L<Selecto::Error>
(C<invalid_spa_query> for protocol errors).

=head2 descriptors, descriptor

The configured descriptors, or one by id.

=head1 SEE ALSO

L<Selecto::API::EngineHandler>, L<Selecto::API>.

=cut
