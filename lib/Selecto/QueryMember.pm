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
our $DEFAULT_MAX_DEPTH = 100;
my $MAX_DEPTH_LIMIT = 10_000;

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
        _keys($spec, [qw(kind source base step step_join columns join max_depth)], $label);
        my $max_depth = $spec->{max_depth} // $DEFAULT_MAX_DEPTH;
        _fail("$label max_depth must be an integer from 1 to $MAX_DEPTH_LIMIT")
            unless !ref($max_depth) && "$max_depth" =~ /\A[1-9][0-9]*\z/ && $max_depth <= $MAX_DEPTH_LIMIT;
        # Every recursive member is depth-bounded so a cyclic or
        # attacker-shaped hierarchy stops at max_depth instead of running
        # until the database gives up.
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
            max_depth => 0 + $max_depth,
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
    my $member = Selecto::Domain->parse({
        schema_version => 1,
        name => "$source",
        source => {%{dclone($relation)}, associations => {}},
        schemas => {},
        joins => {},
    });
    return _scoped_member_domain($domain, $member, $relation, $label);
}

# A member reads its own relation, so the root's request scope does not reach
# it through any join. When the member relation declares a tenant_field, the
# root's tenant conditions are re-expressed on that field and required of the
# member too. A scoped root whose tenant condition cannot be carried over
# fails closed rather than reading every tenant's rows.
sub _scoped_member_domain {
    my ($domain, $member, $relation, $label) = @_;
    my $required = $domain->required_predicate;
    my $member_tenant = $relation->{tenant_field};
    return $member unless defined($required) && defined($member_tenant);
    my $root_tenant = $domain->tenant_field;
    my @conjuncts = $required->kind eq 'and' ? @{$required->arguments->[0]} : ($required);
    my @carried;
    if (defined $root_tenant) {
        for my $conjunct (@conjuncts) {
            my $rewritten = eval { _rename_fields($conjunct, {"$root_tenant" => "$member_tenant"}) };
            push @carried, $rewritten if $rewritten;
        }
    }
    Selecto::Error->throw(
        'missing_tenant_scope',
        "$label reads a tenant-scoped relation but the root tenant scope cannot be applied to it",
        {tenant_field => "$member_tenant"},
    ) unless @carried;
    return $member->with_required_predicate(@carried == 1 ? $carried[0] : Selecto::Expression->all(@carried));
}

# Copies an expression tree, renaming field references by $map. Dies when the
# tree references a field outside $map, so partial rewrites never survive.
sub _rename_fields {
    my ($value, $map) = @_;
    if (Scalar::Util::blessed($value) && $value->isa('Selecto::Expression')) {
        if ($value->kind eq 'field') {
            my $name = $value->arguments->[0];
            die "unmapped field\n" unless exists $map->{$name};
            return Selecto::Expression->field($map->{$name});
        }
        my $copy = Selecto::Expression->new($value->kind, map { _rename_fields($_, $map) } @{$value->arguments});
        return defined($value->alias_name) ? $copy->as($value->alias_name) : $copy;
    }
    return [map { _rename_fields($_, $map) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => _rename_fields($value->{$_}, $map)) } keys %$value} if ref($value) eq 'HASH';
    die "unsupported expression node\n" if ref($value);
    return $value;
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

=head1 SYNOPSIS

  # In a canonical domain:
  query_members => {
      ctes => {
          usage_totals => {
              source => 'usage_session',   # a key of the domain's schemas
              query  => {select => ['equipment_id', {as => 'sessions', aggregate => 'count'}],
                         group_by => ['equipment_id']},
              join   => {owner_key => 'id', related_key => 'equipment_id', type => 'left'},
          },
          category_tree => {
              kind   => 'recursive', source => 'category',
              base   => {select => ['id', 'code', {as => 'depth', value => ['literal', 0, 'integer']}],
                         filter => ['is_null', 'parent_id']},
              step   => {select => ['id', 'code',
                         {as => 'depth', value => ['add', ['previous', 'depth'], ['literal', 1]]}]},
              step_join => {owner_key => 'parent_id', related_key => 'id'},
              join      => {owner_key => 'category_id', related_key => 'id', type => 'inner'},
              max_depth => 50,
          },
      },
      laterals => {
          latest_ticket => {
              source => 'ticket',
              query  => {select => ['summary'], order_by => [['opened_at', 'desc']], limit => 1},
              correlations => {equipment_id => 'id'},
              join_type    => 'left',
          },
      },
      unnests => {
          legacy_tags => {array_field => 'legacy_tags', as => 'tag_rows', ordinality => 'position'},
      },
  },

  # In a query:
  my $query = $engine->query
      ->with_member('category_tree')
      ->select('name', 'category_tree.depth');

=head1 DESCRIPTION

Query members are reusable CTE, recursive CTE, lateral and array-expansion
sources declared as data in the domain, activated by name with
L<Selecto::Query/with_member>. A member's query is rooted at a relation in
the domain's own C<schemas> and is written as data, never SQL, so the same
contract runs in every Selecto runtime.

Member queries accept C<select> (field names,
C<< {as => ..., value => VALUE_AST} >> using L<Selecto::ValueExpression>, or
C<< {as => ..., aggregate => 'count'|'sum'|'avg'|'min'|'max', field => ...} >>),
C<filter> (a filter AST), C<group_by>, C<order_by> (C<[[field, 'asc']]>) and
C<limit>. C<['previous', column]> reads the previous level's row and is
accepted only in a recursive C<step>.

Every recursive member is depth-bounded: C<max_depth> defaults to 100 (at
most 10,000) and adds a trailing C<selecto_depth> column, which a member may
not declare itself.

A member reads its own relation, so the root's request scope does not reach
it through a join. When the root domain carries a required predicate and the
member's source schema declares C<tenant_field>, the root's tenant
conditions are re-expressed on the member's tenant field. A scoped root
whose predicate has no tenant condition fails with C<missing_tenant_scope>
for such a member, so declare C<tenant_field> on every schema holding tenant
data.

Members are validated when the domain is parsed and are part of its
fingerprint. Naming an undeclared member fails with C<unknown_query_member>.
Member groups this runtime does not execute are ignored until a query
activates them.

This module's Perl interface (C<validate>, C<expand>, C<build_query>) is
used internally by L<Selecto::Domain> and the SQL compiler and may change;
the data format above is the public contract.

=head1 SEE ALSO

L<Selecto>, L<Selecto::Query>, L<Selecto::Domain>, L<Selecto::ValueExpression>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
