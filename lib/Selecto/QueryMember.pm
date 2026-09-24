package Selecto::QueryMember;

use 5.034;
use strict;
use warnings;
use Scalar::Util ();
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::Expression ();

# Named query members declared as data in a domain's query_members section.
#
# A member's query is rooted at a relation in the domain's own `schemas`
# section. Queries are data (select, filter AST, group_by, order_by, limit),
# never SQL or callbacks, so the same contract runs in every runtime.
#
#   query_members => {
#       ctes => {
#           usage_totals => {source => 'usage_session', query => {...},
#               join => {owner_key => 'id', related_key => 'equipment_id', type => 'left'}},
#           category_tree => {kind => 'recursive', source => 'category',
#               base => {...}, step => {...},            # step may use ['previous', column]
#               step_join => {owner_key => 'parent_id', related_key => 'id'},
#               columns => [...], join => {...}},
#       },
#       laterals => {latest => {source => 'ticket', query => {...},
#           correlations => {equipment_id => 'id'}, join_type => 'left'}},
#       unnests => {tags => {array_field => 'tags', as => 'tag_rows', ordinality => 'position'}},
#   }
#
# Members are activated by name: $query->with_member('usage_totals').

my %GROUPS = map { $_ => 1 } qw(ctes laterals unnests);
my %QUERY_KEYS = map { $_ => 1 } qw(select filter group_by order_by limit);
my %AGGREGATES = map { $_ => 1 } qw(count sum avg min max);
my $IDENTIFIER = qr/\A[A-Za-z_][A-Za-z0-9_]*\z/;

# Validates every data member of a domain. Groups this runtime does not
# execute (for example Elixir `values` or function members) are left alone and
# fail only if a query activates them.
sub validate {
    my ($class, $domain) = @_;
    my $members = _members($domain);
    for my $group (sort keys %$members) {
        next unless $GROUPS{$group};
        my $specs = $members->{$group};
        _fail("query_members.$group must be an object") unless ref($specs) eq 'HASH';
        for my $name (sort keys %$specs) {
            _fail("query member name $name must be an identifier") unless $name =~ $IDENTIFIER;
            $class->_source($domain, $group, $name, $specs->{$name});
        }
    }
    return 1;
}

# Returns $query with every activated member added as a query source.
sub expand {
    my ($class, $domain, $query) = @_;
    my $members = _members($domain);
    my $expanded = $query->without_members;
    for my $name (@{$query->members}) {
        my @found = grep { ref($members->{$_}) eq 'HASH' && exists $members->{$_}{$name} } sort keys %$members;
        Selecto::Error->throw('unknown_query_member', "query member $name is not declared by the domain",
            {member => $name}) unless @found;
        Selecto::Error->throw('invalid_domain', "query member $name is declared in several groups",
            {member => $name, groups => \@found}) if @found > 1;
        my ($group) = @found;
        Selecto::Error->throw('unsupported_query_member', "query member group $group is not supported",
            {member => $name, group => $group}) unless $GROUPS{$group};
        $expanded = $class->_source($domain, $group, $name, $members->{$group}{$name}, $expanded);
    }
    return $expanded;
}

sub _members {
    my ($domain) = @_;
    my $contract = $domain->contract // {};
    my $members = $contract->{query_members} // {};
    _fail('query_members must be an object') unless ref($members) eq 'HASH';
    return $members;
}

# Builds (and so validates) a member. With $query, adds it as a source.
sub _source {
    my ($class, $domain, $group, $name, $spec, $query) = @_;
    my $label = "query member $name";
    _fail("$label must be an object") unless ref($spec) eq 'HASH';
    if ($group eq 'unnests') {
        _keys($spec, [qw(array_field field as alias ordinality)], $label);
        my $field = $spec->{array_field} // $spec->{field};
        _fail("$label requires array_field") unless defined($field) && !ref($field);
        $domain->resolve($field);
        my $as = $spec->{as} // $spec->{alias} // $name;
        return 1 unless $query;
        return $query->array_rowset($field, $as,
            (defined($spec->{ordinality}) ? (ordinality => $spec->{ordinality}) : ()));
    }
    my $member_domain = _source_domain($domain, $spec->{source}, $label);
    if ($group eq 'laterals') {
        _keys($spec, [qw(source query correlations join_type columns)], $label);
        my $member = build_query($member_domain, $spec->{query}, "$label query");
        my $correlations = $spec->{correlations};
        _fail("$label correlations must be a non-empty object")
            unless ref($correlations) eq 'HASH' && keys %$correlations;
        for my $child (sort keys %$correlations) {
            $member_domain->resolve($child);
            $domain->resolve($correlations->{$child});
        }
        return 1 unless $query;
        return $query->lateral_join($name, $member_domain, $member,
            correlations => {%$correlations},
            type => $spec->{join_type} // 'left',
            (defined($spec->{columns}) ? (columns => [@{$spec->{columns}}]) : ()),
        );
    }
    my $kind = $spec->{kind} // 'plain';
    my $join = _join($domain, $spec->{join}, $label);
    if ($kind eq 'recursive') {
        _keys($spec, [qw(kind source base step step_join columns join)], $label);
        my $base = build_query($member_domain, $spec->{base}, "$label base");
        my $step = build_query($member_domain, $spec->{step}, "$label step", allow_previous => 1);
        my $step_join = $spec->{step_join};
        _fail("$label step_join requires owner_key and related_key")
            unless ref($step_join) eq 'HASH' && defined($step_join->{owner_key})
                && defined($step_join->{related_key});
        $member_domain->resolve($step_join->{owner_key});
        return 1 unless $query;
        return $query->with_recursive_cte($name, $member_domain, $base, $step,
            (defined($spec->{columns}) ? (columns => [@{$spec->{columns}}]) : ()),
            join => $join,
            recursive_join => {
                owner_key => $step_join->{owner_key}, related_key => $step_join->{related_key},
                type => 'inner',
            },
        );
    }
    _fail("$label kind must be plain or recursive") unless $kind eq 'plain';
    _keys($spec, [qw(kind source query columns join)], $label);
    my $member = build_query($member_domain, $spec->{query}, "$label query");
    return 1 unless $query;
    return $query->with_cte($name, $member_domain, $member,
        (defined($spec->{columns}) ? (columns => [@{$spec->{columns}}]) : ()),
        join => $join,
    );
}

# A member's root relation: a relation in the domain's own schemas section.
sub _source_domain {
    my ($domain, $source, $label) = @_;
    _fail("$label requires a source naming a domain schema")
        unless defined($source) && !ref($source) && "$source" =~ $IDENTIFIER;
    my $schemas = ($domain->contract // {})->{schemas} // {};
    my $relation = $schemas->{$source};
    _fail("$label source $source is not a schema of this domain", {source => "$source"})
        unless ref($relation) eq 'HASH';
    require Selecto::Domain;
    return Selecto::Domain->parse({
        schema_version => 1,
        name => "$source",
        source => {%{dclone($relation)}, associations => {}},
        schemas => {},
        joins => {},
    });
}

sub _join {
    my ($domain, $join, $label) = @_;
    _fail("$label join requires owner_key and related_key")
        unless ref($join) eq 'HASH' && defined($join->{owner_key}) && defined($join->{related_key});
    _keys($join, [qw(owner_key related_key type)], "$label join");
    $domain->resolve($join->{owner_key});
    my $type = $join->{type} // 'left';
    _fail("$label join type must be left or inner") unless $type eq 'left' || $type eq 'inner';
    return {owner_key => "$join->{owner_key}", related_key => "$join->{related_key}", type => $type};
}

# A Selecto::Query from member query data, checked against its root domain.
sub build_query {
    my ($domain, $data, $label, %options) = @_;
    _fail("$label must be an object") unless ref($data) eq 'HASH';
    _keys($data, [sort keys %QUERY_KEYS], $label);
    my $select = $data->{select};
    _fail("$label select must be a non-empty array") unless ref($select) eq 'ARRAY' && @$select;
    require Selecto::Query;
    my $query = Selecto::Query->new;
    my @selections = map { _selection($domain, $_, $label, %options) } @$select;
    $query = $query->select(@selections);
    if (defined $data->{filter}) {
        my $filter = Selecto::Expression->from_filter_ast($data->{filter});
        $domain->resolve($_) for _filter_fields($filter);
        $query = $query->where($filter);
    }
    if (defined $data->{group_by}) {
        _fail("$label group_by must be an array of fields") unless ref($data->{group_by}) eq 'ARRAY';
        $domain->resolve($_) for @{$data->{group_by}};
        $query = $query->group_by(@{$data->{group_by}});
    }
    if (defined $data->{order_by}) {
        _fail("$label order_by must be an array of [field, direction]")
            unless ref($data->{order_by}) eq 'ARRAY';
        for my $order (@{$data->{order_by}}) {
            my ($field, $direction) = ref($order) eq 'ARRAY' ? @$order : ($order, 'asc');
            _fail("$label order_by entries name a field") unless defined($field) && !ref($field);
            $domain->resolve($field);
            $query = $query->order_by($field, $direction // 'asc');
        }
    }
    $query = $query->limit($data->{limit}) if defined $data->{limit};
    return $query;
}

sub _selection {
    my ($domain, $entry, $label, %options) = @_;
    if (defined($entry) && !ref($entry)) {
        $domain->resolve($entry);
        return "$entry";
    }
    _fail("$label select entries are field names or objects") unless ref($entry) eq 'HASH';
    my $as = $entry->{as};
    _fail("$label computed selections need an alias (as)") unless defined($as) && "$as" =~ $IDENTIFIER;
    if (exists $entry->{value}) {
        _keys($entry, [qw(as value)], "$label selection $as");
        my $expression = Selecto::Expression->value($entry->{value}, %options);
        require Selecto::ValueExpression;
        $domain->resolve($_) for Selecto::ValueExpression->dependencies($expression->arguments->[0]);
        return $expression->as($as);
    }
    _keys($entry, [qw(as aggregate field)], "$label selection $as");
    my $aggregate = $entry->{aggregate} // '';
    _fail("$label selection $as aggregate must be one of " . join(', ', sort keys %AGGREGATES))
        unless $AGGREGATES{$aggregate};
    if ($aggregate eq 'count') {
        return Selecto::Expression->count->as($as) unless defined $entry->{field};
        $domain->resolve($entry->{field});
        return Selecto::Expression->count_field($entry->{field})->as($as);
    }
    _fail("$label selection $as $aggregate requires a field") unless defined $entry->{field};
    $domain->resolve($entry->{field});
    return Selecto::Expression->$aggregate($entry->{field})->as($as);
}

sub _filter_fields {
    my ($expression) = @_;
    my @fields;
    my @pending = ($expression);
    while (@pending) {
        my $node = shift @pending;
        if (ref($node) eq 'ARRAY') { push @pending, @$node; next; }
        next unless Scalar::Util::blessed($node) && $node->isa('Selecto::Expression');
        if ($node->kind eq 'field') { push @fields, $node->arguments->[0]; next; }
        push @pending, @{$node->arguments};
    }
    return @fields;
}

sub _keys {
    my ($spec, $allowed, $label) = @_;
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$spec;
    _fail("$label contains unsupported keys", {keys => \@unknown}) if @unknown;
}

sub _fail {
    my ($message, $details) = @_;
    Selecto::Error->throw('invalid_query_member', $message, $details // {});
}

1;

__END__

=head1 NAME

Selecto::QueryMember - named query members declared as domain data

=head1 DESCRIPTION

Validates the C<ctes>, C<laterals>, and C<unnests> groups of a domain's
C<query_members> section and expands members a query activates with
C<Selecto::Query-E<gt>with_member> into CTE, lateral, and array rowset sources.

=cut
