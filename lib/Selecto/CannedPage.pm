package Selecto::CannedPage;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Query ();

# A canned page is deliberately HTTP-neutral. The host supplies an authorized
# engine for every request; the page never accepts a client-selected adapter.
sub new {
    my ($class, %args) = @_;
    my %top_keys = map { $_ => 1 } qw(id version domain dataset views controls initial_state);
    _fail('page definition contains unsupported keys')
        if grep { !$top_keys{$_} } keys %args;
    _fail('page definition version is unsupported')
        if defined($args{version}) && ($args{version} !~ /\A\d+\z/ || $args{version} != 1);
    _fail('page id is invalid') unless _id($args{id});
    _fail('page requires a Selecto domain') unless blessed($args{domain})
        && $args{domain}->isa('Selecto::Domain');
    my $domain = $args{domain};
    my $dataset = $args{dataset};
    _fail('dataset must be an object') unless ref($dataset) eq 'HASH';
    my $base = $dataset->{query};
    _fail('dataset requires a Selecto query') unless _query($base);
    _plain_query($base, 'dataset');
    _fail('dataset query cannot select, group, order, or paginate')
        if @{$base->selections} || @{$base->groups} || @{$base->orders}
            || defined($base->limit_value) || defined($base->offset_value);
    my $key = $dataset->{entity_key};
    $key = [$key] if defined($key) && !ref($key);
    _fail('dataset needs the root primary key as its entity key') unless ref($key) eq 'ARRAY' && @$key == 1
        && defined($key->[0]) && !ref($key->[0])
        && $key->[0] eq $domain->primary_key;
    # COUNT(DISTINCT field) is portable. Composite identities need a portable
    # derived-relation count and are rejected until that exists.
    my $views = $args{views};
    _fail('page needs at least one view') unless ref($views) eq 'ARRAY' && @$views;
    my (%view_ids, @views);
    for my $view (@$views) {
        _fail('view must be an object') unless ref($view) eq 'HASH';
        _fail('view id is invalid or duplicated') unless _id($view->{id}) && !$view_ids{$view->{id}}++;
        _fail('view kind must be detail or aggregate')
            unless ($view->{kind} // '') =~ /\A(?:detail|aggregate)\z/;
        _fail('view requires a Selecto query') unless _query($view->{query});
        _plain_query($view->{query}, 'view');
        _fail('view query cannot carry a predicate or pagination')
            if defined($view->{query}->predicate) || defined($view->{query}->limit_value)
                || defined($view->{query}->offset_value);
        _fail('view needs selections') unless @{$view->{query}->selections};
        _fail('detail view cannot contain groups')
            if $view->{kind} eq 'detail' && @{$view->{query}->groups};
        _fail('aggregate view needs groups')
            if $view->{kind} eq 'aggregate' && !@{$view->{query}->groups};
        if ($view->{kind} eq 'detail') {
            for my $selection (@{$view->{query}->selections}) {
                _fail('detail selections must be entity-grain fields')
                    unless $selection->kind eq 'field';
                my $resolved = $domain->resolve($selection->arguments->[0]);
                _fail('detail selections cannot traverse a many association')
                    if grep { $_->cardinality eq 'many' } @{$resolved->{associations}};
            }
            for my $order (@{$view->{query}->orders}) {
                _fail('detail orders must be entity-grain fields')
                    unless $order->[0]->kind eq 'field';
                my $resolved = $domain->resolve($order->[0]->arguments->[0]);
                _fail('detail orders cannot traverse a many association')
                    if grep { $_->cardinality eq 'many' } @{$resolved->{associations}};
            }
        } else {
            # Joined filter rows can multiply ordinary aggregates. Only a
            # distinct entity count is safe for the first portable profile.
            for my $selection (@{$view->{query}->selections}) {
                my $kind = $selection->kind;
                _fail('aggregate selections must be group fields or distinct entity count')
                    unless $kind eq 'field' || $kind eq 'count_distinct';
                if ($kind eq 'count_distinct') {
                    my $operand = $selection->arguments->[0];
                    _fail('aggregate distinct count must use the entity key')
                        unless $operand->kind eq 'field'
                            && $operand->arguments->[0] eq $key->[0];
                }
            }
            my $groups = $view->{query}->groups;
            my $selections = $view->{query}->selections;
            _fail('aggregate view must project its group fields first')
                if @$selections < @$groups;
            for my $index (0 .. $#$groups) {
                _fail('aggregate view must project its group fields first')
                    unless $groups->[$index]->kind eq 'field'
                        && $selections->[$index]->kind eq 'field'
                        && $groups->[$index]->arguments->[0]
                            eq $selections->[$index]->arguments->[0];
                $domain->resolve($groups->[$index]->arguments->[0]);
            }
        }
        push @views, {%$view};
    }
    my $controls = $args{controls} // [];
    _fail('controls must be an array') unless ref($controls) eq 'ARRAY';
    _fail('page supports at most 20 controls') if @$controls > 20;
    my (%control_ids, @controls);
    for my $control (@$controls) {
        _fail('control must be an object') unless ref($control) eq 'HASH';
        _fail('control id is invalid or duplicated')
            unless _id($control->{id}) && !$control_ids{$control->{id}}++;
        _fail('control kind must be text, range, or facet')
            unless ($control->{kind} // '') =~ /\A(?:text|range|facet)\z/;
        _fail('control field is invalid') unless defined($control->{field})
            && !ref($control->{field}) && $control->{field} =~ /\A[A-Za-z][A-Za-z0-9_.]*\z/;
        my $resolved = $domain->resolve($control->{field});
        if ($control->{kind} eq 'facet') {
            _fail('only OR checkbox facets with exclude-self counts are supported')
                if ($control->{selection} // 'any') ne 'any'
                    || ($control->{count_scope} // 'exclude_self') ne 'exclude_self';
            _fail('facet options must be an object')
                if defined($control->{values}) && ref($control->{values}) ne 'HASH';
            my $source = $control->{values}{source} // 'dataset';
            _fail('facet source must be dataset or fixed')
                unless $source eq 'dataset' || $source eq 'fixed';
            if ($source eq 'fixed') {
                my $options = $control->{values}{options};
                _fail('fixed facet needs 1 to 100 options')
                    unless ref($options) eq 'ARRAY' && @$options && @$options <= 100;
                my %seen;
                for my $option (@$options) {
                    _fail('fixed facet option needs a value')
                        unless ref($option) eq 'HASH' && exists($option->{value});
                    my $value = _scalar($option->{value}, 'facet option');
                    _typed_value($resolved->{type}, $value, 'facet option');
                    _fail('fixed facet options must be unique') if $seen{$value}++;
                }
            }
            my $limit = $control->{values}{limit} // 30;
            _fail('facet option limit must be between 1 and 100')
                unless "$limit" =~ /\A\d+\z/ && $limit >= 1 && $limit <= 100;
            _fail('facet label field is invalid')
                if defined($control->{label_field})
                    && (ref($control->{label_field})
                        || !eval { $domain->resolve($control->{label_field}); 1 });
            _fail('facet option search needs a string field')
                if $control->{values}{searchable}
                    && ($domain->resolve($control->{label_field} // $control->{field})->{type} // '')
                        !~ /\A(?:string|text|varchar)\z/i;
        } elsif ($control->{kind} eq 'text') {
            _fail('text control needs a string field and starts_with operator')
                unless ($resolved->{type} // '') =~ /\A(?:string|text|varchar)\z/i
                    && ($control->{op} // 'starts_with') eq 'starts_with';
        } else {
            _fail('range control needs a numeric field')
                unless ($resolved->{type} // '')
                    =~ /\A(?:integer|bigint|smallint|decimal|numeric|float|double)\z/i;
        }
        push @controls, {%$control};
    }
    my $initial = $args{initial_state} // {};
    _fail('initial_state must be an object') unless ref($initial) eq 'HASH';
    my $initial_view = $initial->{view} // $views[0]{id};
    _fail('initial view is unknown') unless $view_ids{$initial_view};
    _fail('initial filters must be an object')
        if defined($initial->{filters}) && ref($initial->{filters}) ne 'HASH';
    my $page = bless {
        id => $args{id}, version => 1, domain => $domain,
        dataset => {query => $base, entity_key => $key->[0]},
        views => \@views, controls => \@controls,
        initial_state => {view => $initial_view, filters => $initial->{filters} // {}},
    }, $class;
    $page->normalize_state({}); # Validate authored defaults now.
    return $page;
}

sub id { $_[0]->{id} }
sub domain { $_[0]->{domain} }
sub version { $_[0]->{version} }
sub views { [map {{%$_}} @{$_[0]->{views}}] }
sub controls { [map {{%$_}} @{$_[0]->{controls}}] }

sub normalize_state {
    my ($self, $input) = @_;
    _fail('page state must be an object') unless ref($input) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(view filters facet_search drilldown page limit version);
    _fail('page state contains unknown keys') if grep { !$allowed{$_} } keys %$input;
    _fail('page version is unsupported') if defined($input->{version})
        && ($input->{version} !~ /\A\d+\z/ || $input->{version} != 1);
    my $view_id = $input->{view} // $self->{initial_state}{view};
    _fail('page view is unknown') unless grep { $_->{id} eq $view_id } @{$self->{views}};
    my $drilldown;
    if (exists($input->{drilldown})) {
        my $raw = $input->{drilldown};
        _fail('drilldown must be an object with view and values')
            unless ref($raw) eq 'HASH' && _id($raw->{view})
                && ref($raw->{values}) eq 'ARRAY'
                && !grep { $_ ne 'view' && $_ ne 'values' } keys %$raw;
        my ($source) = grep { $_->{id} eq $raw->{view} && $_->{kind} eq 'aggregate' }
            @{$self->{views}};
        _fail('drilldown source is unknown') unless $source;
        my $groups = $source->{query}->groups;
        _fail('drilldown value count does not match its groups')
            unless @{$raw->{values}} == @$groups;
        my @values;
        for my $index (0 .. $#$groups) {
            my $field = $groups->[$index]->arguments->[0];
            if (defined($raw->{values}[$index])) {
                my $value = _scalar($raw->{values}[$index], 'drilldown value');
                push @values, _typed_value($self->domain->resolve($field)->{type},
                    $value, 'drilldown value');
            } else {
                push @values, undef;
            }
        }
        $drilldown = {view => $source->{id}, values => \@values};
    }
    my $filters = exists($input->{filters}) ? $input->{filters} : $self->{initial_state}{filters};
    _fail('filters must be an object') unless ref($filters) eq 'HASH';
    my %controls = map { $_->{id} => $_ } @{$self->{controls}};
    _fail('unknown page filter') if grep { !exists($controls{$_}) } keys %$filters;
    my %normalized;
    for my $id (keys %$filters) {
        my $control = $controls{$id};
        my $value = $filters->{$id};
        if ($control->{kind} eq 'facet') {
            _fail('facet selection must be an array') unless ref($value) eq 'ARRAY';
            _fail('facet selection has too many values') if @$value > 100;
            my %seen;
            $normalized{$id} = [grep { !$seen{$_}++ }
                map {
                    my $item = _scalar($_, 'facet value');
                    _typed_value($self->domain->resolve($control->{field})->{type},
                        $item, 'facet value');
                } @$value];
            if (($control->{values}{source} // 'dataset') eq 'fixed') {
                my %allowed = map { ($_->{value} => 1) } @{$control->{values}{options}};
                _fail('facet selection is not a fixed option')
                    if grep { !$allowed{$_} } @{$normalized{$id}};
            }
        } elsif ($control->{kind} eq 'range') {
            _fail('range must be an object') unless ref($value) eq 'HASH';
            _fail('range contains unknown keys') if grep { $_ ne 'min' && $_ ne 'max' } keys %$value;
            my %range;
            $range{$_} = _typed_value($self->domain->resolve($control->{field})->{type},
                _scalar($value->{$_}, 'range bound'), 'range bound')
                for grep { exists($value->{$_}) && defined($value->{$_}) && "$value->{$_}" ne '' } qw(min max);
            $normalized{$id} = \%range;
        } else {
            $normalized{$id} = _scalar($value, 'text filter');
        }
    }
    my $page = $input->{page} // 1;
    my $limit = $input->{limit} // 25;
    _fail('page must be between 1 and 100000')
        unless "$page" =~ /\A\d+\z/ && $page >= 1 && $page <= 100_000;
    _fail('limit must be between 1 and 100')
        unless "$limit" =~ /\A\d+\z/ && $limit >= 1 && $limit <= 100;
    my $search = $input->{facet_search} // {};
    _fail('facet search must be an object') unless ref($search) eq 'HASH';
    my %facet_search;
    for my $id (keys %$search) {
        _fail('facet search is not enabled')
            unless $controls{$id} && $controls{$id}{kind} eq 'facet'
                && $controls{$id}{values}{searchable};
        $facet_search{$id} = _scalar($search->{$id}, 'facet search');
    }
    return {version => 1, view => $view_id, filters => \%normalized,
        facet_search => \%facet_search,
        (defined($drilldown) ? (drilldown => $drilldown) : ()),
        page => int($page), limit => int($limit)};
}

sub plan {
    my ($self, $input, $scope) = @_;
    _fail('request scope must be a Selecto expression')
        if defined($scope) && !(blessed($scope) && $scope->isa('Selecto::Expression'));
    my $state = $self->normalize_state($input);
    my ($view) = grep { $_->{id} eq $state->{view} } @{$self->{views}};
    my $key = $self->{dataset}{entity_key};
    my $predicate = $self->_predicate($state, undef, $scope);
    my $template = $view->{query};
    my @orders = @{$template->orders};
    push @orders, [Selecto::Expression->field($key), 'asc'] if $view->{kind} eq 'detail';
    push @orders, map { [$_, 'asc'] } @{$template->groups}
        if $view->{kind} eq 'aggregate';
    my $query = Selecto::Query->new(
        selections => $template->selections,
        predicate => $predicate,
        groups => $view->{kind} eq 'detail'
            ? [Selecto::Expression->field($key), @{$template->selections},
                map { $_->[0] } @{$template->orders}]
            : $template->groups,
        orders => \@orders,
        limit_value => $state->{limit} + 1,
        offset_value => ($state->{page} - 1) * $state->{limit},
    );
    my $total = Selecto::Query->new(
        selections => [Selecto::Expression->count_distinct($key)->as('total')],
        predicate => $predicate,
    );
    my (%facets, %selected_facets);
    for my $control (@{$self->{controls}}) {
        next unless $control->{kind} eq 'facet';
        my $field = $control->{field};
        my $count = Selecto::Expression->count_distinct($key)->as('count');
        my @selections = (Selecto::Expression->field($field)->as('value'));
        my @groups = ($field);
        if (defined($control->{label_field})) {
            push @selections, Selecto::Expression->field($control->{label_field})->as('label');
            push @groups, $control->{label_field};
        }
        push @selections, $count;
        my $facet_predicate = $self->_predicate($state, $control->{id}, $scope);
        my @option_predicates = (grep { defined } $facet_predicate,
            Selecto::Expression->not_null($field));
        if (($control->{values}{source} // 'dataset') eq 'fixed') {
            push @option_predicates, Selecto::Expression->in($field,
                [map { $_->{value} } @{$control->{values}{options}}]);
        }
        if (length($state->{facet_search}{$control->{id}} // '')) {
            push @option_predicates, Selecto::Expression->starts_with(
                $control->{label_field} // $field,
                $state->{facet_search}{$control->{id}},
            );
        }
        $facets{$control->{id}} = Selecto::Query->new(
            selections => \@selections,
            predicate => @option_predicates == 1 ? $option_predicates[0]
                : Selecto::Expression->all(\@option_predicates),
            groups => [map { Selecto::Expression->field($_) } @groups],
            orders => [[$count, 'desc'], [Selecto::Expression->field($field), 'asc']],
            limit_value => ($control->{values}{source} // 'dataset') eq 'fixed'
                ? undef : ($control->{values}{limit} // 30) + 1,
        );
        my $selected = $state->{filters}{$control->{id}} // [];
        if (@$selected) {
            my @parts = (grep { defined } $facet_predicate,
                Selecto::Expression->in($field, $selected));
            $selected_facets{$control->{id}} = Selecto::Query->new(
                selections => \@selections,
                predicate => @parts == 1 ? $parts[0] : Selecto::Expression->all(\@parts),
                groups => [map { Selecto::Expression->field($_) } @groups],
            );
        }
    }
    return {state => $state, view => {id => $view->{id}, kind => $view->{kind},
        label => $view->{label} // $view->{id}}, query => $query,
        total_query => $total, facet_queries => \%facets,
        selected_facet_queries => \%selected_facets};
}

sub run {
    my ($self, $engine, $input, $scope) = @_;
    _fail('page engine uses a different domain')
        unless blessed($engine) && $engine->can('domain') && $engine->can('all')
            && $engine->domain->fingerprint eq $self->domain->fingerprint;
    my $plan = $self->plan($input, $scope);
    my $rows = $engine->all($plan->{query});
    my $has_more = @{$rows->{rows}} > $plan->{state}{limit} ? 1 : 0;
    pop @{$rows->{rows}} if $has_more;
    my $total_rows = $engine->all($plan->{total_query})->{rows};
    my %facets;
    for my $control (@{$self->{controls}}) {
        next unless $control->{kind} eq 'facet';
        my $id = $control->{id};
        my $raw = $engine->all($plan->{facet_queries}{$id});
        my $limit = $control->{values}{limit} // 30;
        my $has_label = defined($control->{label_field});
        my @options = map {{
            value => $_->[0], label => $has_label ? $_->[1] : $_->[0],
            count => $_->[$has_label ? 2 : 1],
        }} grep { defined($_->[0]) } @{$raw->{rows}};
        my $fixed = ($control->{values}{source} // 'dataset') eq 'fixed';
        my $truncated = !$fixed && @options > $limit ? 1 : 0;
        splice @options, $limit if $truncated;
        if ($fixed) {
            my %found = map { ($_->{value} => $_) } @options;
            @options = map {{
                value => $_->{value}, label => $_->{label} // $_->{value},
                count => $found{$_->{value}}{count} // 0,
            }} @{$control->{values}{options}};
        }
        my %shown = map { (defined($_->{value}) ? $_->{value} : '') => 1 } @options;
        my $selected_rows = $plan->{selected_facet_queries}{$id}
            ? $engine->all($plan->{selected_facet_queries}{$id})->{rows} : [];
        for my $selected (@{$plan->{state}{filters}{$id} // []}) {
            next if $shown{$selected};
            my ($match) = grep { defined($_->[0]) && "$_->[0]" eq "$selected" } @$selected_rows;
            push @options, {value => $selected, label => $match && $has_label ? $match->[1] : $selected,
                count => $match ? $match->[$has_label ? 2 : 1] : 0};
        }
        $facets{$id} = {options => \@options, truncated => $truncated};
    }
    return {state => $plan->{state}, view => $plan->{view},
        columns => $rows->{columns}, rows => $rows->{rows},
        total => $total_rows->[0][0] // 0, has_more => $has_more, facets => \%facets};
}

sub _predicate {
    my ($self, $state, $exclude, $scope) = @_;
    my @expressions;
    push @expressions, $self->{dataset}{query}->predicate
        if defined $self->{dataset}{query}->predicate;
    push @expressions, $scope if defined $scope;
    if (my $drilldown = $state->{drilldown}) {
        my ($source) = grep { $_->{id} eq $drilldown->{view} } @{$self->{views}};
        my $groups = $source->{query}->groups;
        for my $index (0 .. $#$groups) {
            my $field = $groups->[$index]->arguments->[0];
            my $value = $drilldown->{values}[$index];
            push @expressions, defined($value)
                ? Selecto::Expression->eq($field, $value)
                : Selecto::Expression->is_null($field);
        }
    }
    for my $control (@{$self->{controls}}) {
        next if defined($exclude) && $exclude eq $control->{id};
        my $value = $state->{filters}{$control->{id}};
        next unless defined $value;
        my $field = $control->{field};
        if ($control->{kind} eq 'facet') {
            push @expressions, Selecto::Expression->in($field, $value) if @$value;
        } elsif ($control->{kind} eq 'range') {
            push @expressions, Selecto::Expression->gte($field, $value->{min}) if exists $value->{min};
            push @expressions, Selecto::Expression->lte($field, $value->{max}) if exists $value->{max};
        } elsif (length $value) {
            push @expressions, Selecto::Expression->starts_with($field, $value);
        }
    }
    return @expressions == 1 ? $expressions[0]
        : @expressions ? Selecto::Expression->all(\@expressions) : undef;
}

sub _query { blessed($_[0]) && $_[0]->isa('Selecto::Query') }
sub _id { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[a-z][a-z0-9_]*\z/ }
sub _scalar {
    my ($value, $label) = @_;
    _fail("$label must be a short scalar") if !defined($value) || ref($value) || length("$value") > 256;
    return "$value";
}
sub _typed_value {
    my ($type, $value, $label) = @_;
    my $kind = lc($type // '');
    _fail("$label must be an integer")
        if $kind =~ /\A(?:integer|bigint|smallint)\z/ && $value !~ /\A-?\d+\z/;
    _fail("$label must be a decimal")
        if $kind =~ /\A(?:decimal|numeric|float|double)\z/
            && $value !~ /\A-?\d+(?:\.\d+)?\z/;
    _fail("$label must be boolean")
        if $kind eq 'boolean' && $value !~ /\A[01]\z/;
    return $value;
}
sub _plain_query {
    my ($query, $label) = @_;
    _fail("$label cannot use advanced query sources or set operations")
        if @{$query->set_operations} || @{$query->ctes}
            || @{$query->lateral_joins} || @{$query->json_rowsets}
            || defined($query->timezone)
            || ($query->can('row_lock') && defined($query->row_lock));
}
sub _fail { Selecto::Error->throw('invalid_canned_page', $_[0]) }

1;
