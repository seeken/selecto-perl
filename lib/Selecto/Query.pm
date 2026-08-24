package Selecto::Query;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::Expression ();

sub new {
    my ($class, %args) = @_;
    my %allowed = map { $_ => 1 } qw(
        selections predicate groups grouping_mode orders limit_value offset_value applied_query_library
        set_operations ctes lateral_joins json_rowsets
    );
    my @unknown = sort grep { !$allowed{$_} } keys %args;
    Selecto::Error->throw(
        'invalid_query',
        'query state contains unsupported keys',
        { keys => \@unknown },
    ) if @unknown;
    for my $order (@{$args{orders} // []}) {
        Selecto::Error->throw('invalid_query', 'order entries must contain a field and direction')
            unless ref($order) eq 'ARRAY' && @$order == 2;
        my $direction = defined($order->[1]) ? lc("$order->[1]") : 'asc';
        Selecto::Error->throw('invalid_query', 'order direction must be asc or desc')
            unless $direction eq 'asc' || $direction eq 'desc';
    }
    my $grouping_mode = $args{grouping_mode} // 'plain';
    Selecto::Error->throw('invalid_query', 'grouping mode must be plain or rollup')
        unless $grouping_mode eq 'plain' || $grouping_mode eq 'rollup';
    my $set_operations = $args{set_operations} // [];
    Selecto::Error->throw('invalid_query', 'set operations must be an array')
        unless ref($set_operations) eq 'ARRAY';
    for my $operation (@$set_operations) {
        Selecto::Error->throw('invalid_query', 'set operation must be an object')
            unless ref($operation) eq 'HASH';
        my @unknown_operation_keys = sort grep {
            $_ ne 'operation' && $_ ne 'all' && $_ ne 'query'
        } keys %$operation;
        Selecto::Error->throw(
            'invalid_query',
            'set operation contains unsupported keys',
            {keys => \@unknown_operation_keys},
        ) if @unknown_operation_keys;
        Selecto::Error->throw('invalid_query', 'unsupported set operation')
            unless ($operation->{operation} // '') =~ /\A(?:union|intersect|except)\z/;
        Selecto::Error->throw('invalid_query', 'set operation requires a query')
            unless blessed($operation->{query}) && $operation->{query}->isa(__PACKAGE__);
        Selecto::Error->throw('invalid_query', 'set operation all option must be boolean')
            if exists($operation->{all}) && ref($operation->{all});
        Selecto::Error->throw('invalid_query', 'portable ALL semantics are available only for UNION')
            if $operation->{operation} ne 'union' && $operation->{all};
        Selecto::Error->throw(
            'invalid_query',
            'set operands cannot carry outer ordering or pagination',
        ) if @{$operation->{query}->orders}
            || defined($operation->{query}->limit_value)
            || defined($operation->{query}->offset_value);
    }
    my $ctes = $args{ctes} // [];
    my $lateral_joins = $args{lateral_joins} // [];
    my $json_rowsets = $args{json_rowsets} // [];
    Selecto::Error->throw('invalid_query', 'CTEs must be an array') unless ref($ctes) eq 'ARRAY';
    Selecto::Error->throw('invalid_query', 'lateral joins must be an array')
        unless ref($lateral_joins) eq 'ARRAY';
    Selecto::Error->throw('invalid_query', 'JSON rowsets must be an array')
        unless ref($json_rowsets) eq 'ARRAY';
    Selecto::Error->throw('invalid_query', 'advanced query source entries must be objects')
        if grep { ref($_) ne 'HASH' } (@$ctes, @$lateral_joins, @$json_rowsets);
    return bless {
        selections  => [@{$args{selections} // []}],
        predicate   => $args{predicate},
        groups      => [@{$args{groups} // []}],
        grouping_mode => $grouping_mode,
        orders      => [map { [@$_] } @{$args{orders} // []}],
        limit_value  => defined($args{limit_value}) ? _nonnegative($args{limit_value}, 'limit') : undef,
        offset_value => defined($args{offset_value}) ? _nonnegative($args{offset_value}, 'offset') : undef,
        set_operations => [map {{
            operation => "$_->{operation}",
            all => $_->{all} ? 1 : 0,
            query => $_->{query},
        }} @$set_operations],
        ctes => [map { _clone_cte_spec($_) } @$ctes],
        lateral_joins => [map { _clone_lateral_spec($_) } @$lateral_joins],
        json_rowsets => [map { _clone_json_rowset_spec($_) } @$json_rowsets],
        applied_query_library => dclone($args{applied_query_library} // {
            segments => [], projections => [], projection => undef,
            ordering => undef, views => [],
        }),
    }, $class;
}

sub select {
    my ($self, @values) = @_;
    $self->_ensure_pre_set_mutation('select');
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    my @expressions = map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @values;
    return $self->_copy(selections => \@expressions);
}

sub where {
    my ($self, $expression) = @_;
    $self->_ensure_pre_set_mutation('where');
    Selecto::Error->throw('invalid_query', 'where expects an expression')
        unless blessed($expression) && $expression->isa('Selecto::Expression');
    return $self->_copy(predicate => $expression);
}

sub group_by {
    my ($self, @fields) = @_;
    $self->_ensure_pre_set_mutation('group_by');
    @fields = @{$fields[0]} if @fields == 1 && ref($fields[0]) eq 'ARRAY';
    return $self->_copy(groups => [map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @fields], grouping_mode => 'plain');
}

sub group_by_rollup {
    my ($self, @fields) = @_;
    $self->_ensure_pre_set_mutation('group_by_rollup');
    @fields = @{$fields[0]} if @fields == 1 && ref($fields[0]) eq 'ARRAY';
    Selecto::Error->throw('invalid_query', 'rollup requires at least one grouping expression')
        unless @fields;
    return $self->_copy(groups => [map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @fields], grouping_mode => 'rollup');
}

sub order_by {
    my ($self, $field, $direction) = @_;
    $direction = defined($direction) ? lc("$direction") : 'asc';
    Selecto::Error->throw('invalid_query', 'order direction must be asc or desc')
        unless $direction eq 'asc' || $direction eq 'desc';
    my $expression = blessed($field) && $field->isa('Selecto::Expression')
        ? $field : Selecto::Expression->field($field);
    return $self->_copy(orders => [@{$self->{orders}}, [$expression, $direction]]);
}

sub replace_selections {
    my ($self, @values) = @_;
    $self->_ensure_pre_set_mutation('replace_selections');
    @values = @{$values[0]} if @values == 1 && ref($values[0]) eq 'ARRAY';
    my @expressions = map {
        blessed($_) && $_->isa('Selecto::Expression') ? $_ : Selecto::Expression->field($_)
    } @values;
    return $self->_copy(selections => \@expressions);
}

sub replace_orders {
    my ($self, $orders) = @_;
    Selecto::Error->throw('invalid_query', 'orders must be an array')
        unless ref($orders) eq 'ARRAY';
    my $query = $self->_copy(orders => []);
    for my $order (@$orders) {
        Selecto::Error->throw('invalid_query', 'order entries must contain a field and direction')
            unless ref($order) eq 'ARRAY' && @$order == 2;
        $query = $query->order_by($order->[0], $order->[1]);
    }
    return $query;
}

sub union     { my ($self, $query, %opts) = @_; return $self->_set_operation('union', $query, %opts); }
sub union_all { my ($self, $query) = @_; return $self->_set_operation('union', $query, all => 1); }
sub intersect { my ($self, $query, %opts) = @_; return $self->_set_operation('intersect', $query, %opts); }
sub except    { my ($self, $query, %opts) = @_; return $self->_set_operation('except', $query, %opts); }

sub _set_operation {
    my ($self, $operation, $query, %opts) = @_;
    my @unknown = sort grep { $_ ne 'all' } keys %opts;
    Selecto::Error->throw(
        'invalid_query',
        'set operation contains unsupported options',
        {keys => \@unknown},
    ) if @unknown;
    Selecto::Error->throw('invalid_query', 'set operation requires a Selecto query')
        unless blessed($query) && $query->isa(__PACKAGE__);
    Selecto::Error->throw(
        'invalid_query',
        'set operands cannot carry outer ordering or pagination',
    ) if @{$query->orders} || defined($query->limit_value) || defined($query->offset_value);
    Selecto::Error->throw('invalid_query', 'set operation all option must be boolean')
        if exists($opts{all}) && ref($opts{all});
    Selecto::Error->throw('invalid_query', 'portable ALL semantics are available only for UNION')
        if $operation ne 'union' && $opts{all};
    return $self->_copy(set_operations => [
        @{$self->{set_operations}},
        {operation => $operation, all => $opts{all} ? 1 : 0, query => $query},
    ]);
}

sub with_cte {
    my ($self, $name, $domain, $query, %opts) = @_;
    $self->_ensure_pre_set_mutation('with_cte');
    _known_options(\%opts, [qw(columns join depends_on)], 'CTE');
    _source_name($name, 'CTE');
    _domain_query($domain, $query, 'CTE');
    _unique_source_name($self, $name);
    my $columns = $opts{columns} // _query_columns($query);
    _columns($columns, 'CTE');
    my $join = _join_spec($opts{join}, $columns, 'CTE');
    my $dependencies = $opts{depends_on} // [];
    $dependencies = [$dependencies] unless ref($dependencies) eq 'ARRAY';
    my %available = map { $_->{name} => 1 } @{$self->{ctes}};
    for my $dependency (@$dependencies) {
        _source_name($dependency, 'CTE dependency');
        Selecto::Error->throw('invalid_query', "missing CTE dependency $dependency")
            unless $available{$dependency};
    }
    return $self->_copy(ctes => [@{$self->{ctes}}, {
        name => "$name", recursive => 0, domain => $domain, query => $query,
        columns => [@$columns], join => $join, dependencies => [map { "$_" } @$dependencies],
    }]);
}

sub with_recursive_cte {
    my ($self, $name, $domain, $anchor, $recursive, %opts) = @_;
    $self->_ensure_pre_set_mutation('with_recursive_cte');
    _known_options(\%opts, [qw(columns join recursive_join)], 'recursive CTE');
    _source_name($name, 'recursive CTE');
    _domain_query($domain, $anchor, 'recursive CTE anchor');
    _domain_query($domain, $recursive, 'recursive CTE member');
    _unique_source_name($self, $name);
    my $columns = $opts{columns} // _query_columns($anchor);
    _columns($columns, 'recursive CTE');
    my $join = _join_spec($opts{join}, $columns, 'recursive CTE');
    my $recursive_join = _join_spec($opts{recursive_join}, $columns, 'recursive CTE member');
    Selecto::Error->throw('invalid_query', 'recursive CTE member join must be inner')
        unless $recursive_join->{type} eq 'inner';
    return $self->_copy(ctes => [@{$self->{ctes}}, {
        name => "$name", recursive => 1, domain => $domain,
        anchor => $anchor, recursive_query => $recursive,
        columns => [@$columns], join => $join, recursive_join => $recursive_join,
        dependencies => [],
    }]);
}

sub lateral_join {
    my ($self, $name, $domain, $query, %opts) = @_;
    $self->_ensure_pre_set_mutation('lateral_join');
    _known_options(\%opts, [qw(columns correlations type)], 'lateral join');
    _source_name($name, 'lateral alias');
    _domain_query($domain, $query, 'lateral query');
    _unique_source_name($self, $name);
    my $columns = $opts{columns} // _query_columns($query);
    _columns($columns, 'lateral query');
    my $type = lc($opts{type} // 'left');
    Selecto::Error->throw('invalid_query', 'lateral join type must be left, inner, or cross')
        unless $type eq 'left' || $type eq 'inner' || $type eq 'cross';
    my $correlations = $opts{correlations};
    Selecto::Error->throw('invalid_query', 'lateral correlations must be a non-empty object')
        unless ref($correlations) eq 'HASH' && keys %$correlations;
    for my $child (keys %$correlations) {
        _source_name($child, 'lateral child field');
        _source_name($correlations->{$child}, 'lateral parent field');
    }
    return $self->_copy(lateral_joins => [@{$self->{lateral_joins}}, {
        name => "$name", domain => $domain, query => $query, columns => [@$columns],
        type => $type, correlations => {%$correlations},
    }]);
}

sub json_rowset {
    my ($self, $source_field, $name, $columns, %opts) = @_;
    $self->_ensure_pre_set_mutation('json_rowset');
    _known_options(\%opts, [qw(path type)], 'JSON rowset');
    _source_name($name, 'JSON rowset alias');
    _unique_source_name($self, $name);
    Selecto::Error->throw('invalid_query', 'JSON rowset source field is required')
        unless defined($source_field) && !ref($source_field) && "$source_field" ne '';
    Selecto::Error->throw('invalid_query', 'JSON rowset columns must be a non-empty object')
        unless ref($columns) eq 'HASH' && keys %$columns;
    for my $column (keys %$columns) {
        _source_name($column, 'JSON rowset column');
        Selecto::Error->throw('invalid_query', 'JSON rowset column types must be strings')
            if !defined($columns->{$column}) || ref($columns->{$column}) || "$columns->{$column}" eq '';
    }
    my $type = lc($opts{type} // 'left');
    Selecto::Error->throw('invalid_query', 'JSON rowset join type must be left, inner, or cross')
        unless $type eq 'left' || $type eq 'inner' || $type eq 'cross';
    return $self->_copy(json_rowsets => [@{$self->{json_rowsets}}, {
        name => "$name", source_field => "$source_field", columns => {%$columns},
        type => $type, (exists($opts{path}) ? (path => $opts{path}) : ()),
    }]);
}

sub _source_name {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_query', "$label must be a valid identifier")
        unless defined($value) && !ref($value) && "$value" =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return "$value";
}

sub _known_options {
    my ($options, $allowed, $label) = @_;
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$options;
    Selecto::Error->throw(
        'invalid_query',
        "$label contains unsupported options",
        {keys => \@unknown},
    ) if @unknown;
}

sub _domain_query {
    my ($domain, $query, $label) = @_;
    Selecto::Error->throw('invalid_query', "$label requires a Selecto domain")
        unless blessed($domain) && $domain->isa('Selecto::Domain');
    Selecto::Error->throw('invalid_query', "$label requires a Selecto query")
        unless blessed($query) && $query->isa(__PACKAGE__);
}

sub _query_columns {
    my ($query) = @_;
    my @columns = map {
        defined($_->alias_name) ? $_->alias_name
            : $_->kind eq 'field' ? (split(/\./, $_->arguments->[0]))[-1]
            : Selecto::Error->throw(
                'invalid_query',
                'computed CTE and lateral selections require aliases',
            )
    } @{$query->selections};
    return \@columns;
}

sub _columns {
    my ($columns, $label) = @_;
    Selecto::Error->throw('invalid_query', "$label columns must be a non-empty array")
        unless ref($columns) eq 'ARRAY' && @$columns;
    my %seen;
    for my $column (@$columns) {
        _source_name($column, "$label column");
        Selecto::Error->throw('invalid_query', "$label columns must be unique")
            if $seen{"$column"}++;
    }
}

sub _join_spec {
    my ($join, $columns, $label) = @_;
    Selecto::Error->throw('invalid_query', "$label requires an explicit join contract")
        unless ref($join) eq 'HASH';
    my $owner_key = _source_name($join->{owner_key}, "$label owner key");
    my $related_key = _source_name($join->{related_key}, "$label related key");
    Selecto::Error->throw('invalid_query', "$label related key must be a projected column")
        unless grep { $_ eq $related_key } @$columns;
    my $type = lc($join->{type} // 'left');
    Selecto::Error->throw('invalid_query', "$label join type must be left or inner")
        unless $type eq 'left' || $type eq 'inner';
    return {owner_key => $owner_key, related_key => $related_key, type => $type};
}

sub _unique_source_name {
    my ($self, $name) = @_;
    my %names = map { $_->{name} => 1 }
        (@{$self->{ctes}}, @{$self->{lateral_joins}}, @{$self->{json_rowsets}});
    Selecto::Error->throw('invalid_query', "duplicate query source $name") if $names{$name};
}

sub _ensure_pre_set_mutation {
    my ($self, $operation) = @_;
    Selecto::Error->throw(
        'invalid_query',
        "$operation cannot be applied after a set operation",
    ) if @{$self->{set_operations}};
    return $self;
}

sub _set_base_query {
    my ($self) = @_;
    return $self->_copy(
        set_operations => [], orders => [], limit_value => undef, offset_value => undef,
    );
}

sub with_applied_query_library {
    my ($self, $applied) = @_;
    Selecto::Error->throw('invalid_query', 'applied query library state must be an object')
        unless ref($applied) eq 'HASH';
    return $self->_copy(applied_query_library => $applied);
}

sub limit  { my ($self, $value) = @_; return $self->_copy(limit_value  => _nonnegative($value, 'limit')); }
sub offset { my ($self, $value) = @_; return $self->_copy(offset_value => _nonnegative($value, 'offset')); }

sub _nonnegative {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_query', "$label must be a non-negative integer")
        unless defined($value) && "$value" =~ /\A\d+\z/;
    return int($value);
}

sub _copy {
    my ($self, %changes) = @_;
    my %state = (
        selections   => $self->{selections},
        predicate    => $self->{predicate},
        groups       => $self->{groups},
        grouping_mode => $self->{grouping_mode},
        orders       => $self->{orders},
        limit_value  => $self->{limit_value},
        offset_value => $self->{offset_value},
        set_operations => $self->{set_operations},
        ctes => $self->{ctes},
        lateral_joins => $self->{lateral_joins},
        json_rowsets => $self->{json_rowsets},
        applied_query_library => $self->{applied_query_library},
        %changes,
    );
    return ref($self)->new(%state);
}

sub selections   { return [@{$_[0]->{selections}}]; }
sub predicate    { return $_[0]->{predicate}; }
sub groups       { return [@{$_[0]->{groups}}]; }
sub grouping_mode { return $_[0]->{grouping_mode}; }
sub orders       { return [map { [@$_] } @{$_[0]->{orders}}]; }
sub limit_value  { return $_[0]->{limit_value}; }
sub offset_value { return $_[0]->{offset_value}; }
sub set_operations { return [map {{%$_}} @{$_[0]->{set_operations}}]; }
sub ctes { return [map { _clone_cte_spec($_) } @{$_[0]->{ctes}}]; }
sub lateral_joins { return [map { _clone_lateral_spec($_) } @{$_[0]->{lateral_joins}}]; }
sub json_rowsets { return [map { _clone_json_rowset_spec($_) } @{$_[0]->{json_rowsets}}]; }
sub applied_query_library { return dclone($_[0]->{applied_query_library}); }

sub _clone_cte_spec {
    my ($spec) = @_;
    return {
        %$spec,
        (ref($spec->{columns}) eq 'ARRAY' ? (columns => [@{$spec->{columns}}]) : ()),
        (ref($spec->{dependencies}) eq 'ARRAY'
            ? (dependencies => [@{$spec->{dependencies}}]) : ()),
        (ref($spec->{join}) eq 'HASH' ? (join => {%{$spec->{join}}}) : ()),
        (ref($spec->{recursive_join}) eq 'HASH'
            ? (recursive_join => {%{$spec->{recursive_join}}}) : ()),
    };
}

sub _clone_lateral_spec {
    my ($spec) = @_;
    return {
        %$spec,
        (ref($spec->{columns}) eq 'ARRAY' ? (columns => [@{$spec->{columns}}]) : ()),
        (ref($spec->{correlations}) eq 'HASH'
            ? (correlations => {%{$spec->{correlations}}}) : ()),
    };
}

sub _clone_json_rowset_spec {
    my ($spec) = @_;
    return {
        %$spec,
        (ref($spec->{columns}) eq 'HASH' ? (columns => {%{$spec->{columns}}}) : ()),
    };
}

1;
