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

my %GROUPS = map { $_ => 1 } qw(ctes values subqueries laterals unnests);
my %QUERY_KEYS = map { $_ => 1 } qw(select filter group_by order_by limit);
my %AGGREGATES = map { $_ => 1 } qw(count sum avg min max);
my $IDENTIFIER = qr/\A[A-Za-z_][A-Za-z0-9_]*\z/;
our $DEFAULT_MAX_DEPTH = 100;
my $MAX_DEPTH_LIMIT = 10_000;

# Validate native data plans and inert portable callback declarations. Native
# activation still requires the configured host's explicit callback registry;
# a portable marker is never itself executable.
sub validate {
    my ($class, $domain) = @_;
    my $members = _members($domain);
    for my $group (sort keys %$members) {
        next unless $GROUPS{$group};
        my $specs = $members->{$group};
        _fail("query_members.$group must be an object") unless ref($specs) eq 'HASH';
        for my $name (sort keys %$specs) {
            _fail("query member name $name must be an identifier") unless $name =~ $IDENTIFIER;
            my $spec = $specs->{$name};
            if (ref($spec) eq 'HASH' && (_callback($spec->{query}) || _callback($spec->{query_builder})
                    || $group eq 'laterals' && ref($spec->{source}) eq 'ARRAY')) {
                require Selecto::Domain::QueryMembers;
                my $report = Selecto::Domain::QueryMembers->validate({query_members => {$group => {$name => $spec}}});
                _fail("query member $name declaration is invalid") unless $report->{valid};
                next;
            }
            $class->_source($domain, $group, $name, $specs->{$name});
        }
    }
    return 1;
}

# Returns $query with every activated member added as a query source.
sub expand {
    my ($class, $domain, $query, $engine) = @_;
    my $members = _members($domain);
    # Expand only after the original intent and configured authority have been
    # validated. Transient plans are never exposed as declaration authority.
    my $expanded = Selecto::Query->new(%{$query->without_members});
    # The trusted engine tenant bounds every member over a tenant-scoped
    # relation, whether or not the root relation is itself tenant-scoped.
    my $tenant = $engine ? $engine->scope->{tenant} : undef;
    for my $activation (@{$query->members}) {
        my ($requested, $name) = $activation =~ /\A([^:]+):(.+)\z/ ? ($1, $2) : (undef, $activation);
        my @found = grep { (!defined($requested) || $_ eq $requested) && ref($members->{$_}) eq 'HASH' && exists $members->{$_}{$name} } sort keys %$members;
        Selecto::Error->throw('unknown_query_member', "query member $name is not declared by the domain",
            {member => $name}) unless @found;
        Selecto::Error->throw('invalid_domain', "query member $name is declared in several groups",
            {member => $name, groups => \@found}) if @found > 1;
        my ($group) = @found;
        Selecto::Error->throw('unsupported_query_member', "query member group $group is not supported",
            {member => $name, group => $group}) unless $GROUPS{$group};
        my $spec = $members->{$group}{$name};
        if (($group eq 'ctes' || $group eq 'subqueries') && (_callback($spec->{query}) || _callback($spec->{query_builder}))) {
            _fail('callback member requires a configured engine') unless $engine;
            require Selecto::QueryBinding;
            my ($child_domain, $child) = Selecto::QueryBinding->builder($engine, $group, $name);
            if ($group eq 'ctes') {
                my $join = defined($spec->{join}) ? _pairs($spec->{join}, "query member $name join") : undef;
                delete $join->{fields} if $join && ($join->{fields} // '') eq 'infer';
                $expanded = $expanded->with_cte($name, $child_domain, $child,
                    (defined($spec->{columns}) ? (columns => $spec->{columns}) : ()), join => $join);
            } else {
                $expanded = $expanded->subquery_join($spec->{join_id} // $name, $child_domain, $child,
                    on => $spec->{on}, type => $spec->{type} // 'left',
                    (defined($spec->{columns}) ? (columns => $spec->{columns}) : ()));
            }
        } else {
            $expanded = $class->_source($domain, $group, $name, $spec, $expanded, $tenant);
        }
    }
    return $expanded;
}

sub _callback { ref($_[0]) eq 'HASH' && keys(%{$_[0]}) == 1 && !ref($_[0]{kind}) && ($_[0]{kind} // '') eq 'declared_callback' }
sub _pairs {
    my ($given, $label) = @_;
    return {%$given} if ref($given) eq 'HASH';
    _fail("$label must be an object or keyword pairs") unless ref($given) eq 'ARRAY';
    my %pairs;
    for my $pair (@$given) {
        _fail("$label has malformed or duplicate keys")
            unless ref($pair) eq 'ARRAY' && @$pair == 2 && defined($pair->[0]) && !ref($pair->[0]) && !exists($pairs{$pair->[0]});
        $pairs{$pair->[0]} = $pair->[1];
    }
    return \%pairs;
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
    my ($class, $domain, $group, $name, $spec, $query, $tenant) = @_;
    my $label = "query member $name";
    _fail("$label must be an object") unless ref($spec) eq 'HASH';
    if ($group eq 'values') {
        my $join = defined($spec->{join}) ? _pairs($spec->{join}, "$label join") : undef;
        delete $join->{fields} if $join && ($join->{fields} // '') eq 'infer';
        my $base = $query // Selecto::Query->new;
        my $result = $base->with_values($spec->{rows} // $spec->{data}, columns => $spec->{columns},
            as => $spec->{as} // $spec->{alias} // $name, (defined($join) ? (join => $join) : ()));
        $domain->resolve($join->{owner_key}) if $join;
        return $query ? $result : 1;
    }
    if ($group eq 'laterals' && ref($spec->{source}) eq 'ARRAY') {
        my $source = $spec->{source};
        _fail("$label requires a declared function tuple")
            unless @$source == 3 && !ref($source->[0]) && $source->[0] eq 'function';
        my $base = $query // Selecto::Query->new;
        my $result = $base->function_lateral($source->[1], $source->[2],
            as => $spec->{as} // $name, type => $spec->{join_type} // 'inner',
            (defined($spec->{columns}) ? (columns => $spec->{columns}) : ()));
        return $query ? $result : 1;
    }
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
    my $member_domain = _source_domain($domain, $spec->{source}, $label, $tenant);
    if ($group eq 'subqueries') {
        _keys($spec, [qw(source query columns on type join_id kind capability)], $label);
        my $child = build_query($member_domain, $spec->{query}, "$label query");
        my $base = $query // Selecto::Query->new;
        my $result = $base->subquery_join($spec->{join_id} // $name, $member_domain, $child,
            on => $spec->{on}, type => $spec->{type} // 'left',
            (defined($spec->{columns}) ? (columns => $spec->{columns}) : ()));
        return $query ? $result : 1;
    }
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
    my ($domain, $source, $label, $tenant) = @_;
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
    $member = bless {%$member, _read_prefix => $domain->{_read_prefix}}, ref($member) if defined $domain->{_read_prefix};
    return __PACKAGE__->bound_source_domain($domain, $member, label => $label, tenant => $tenant);
}

# A member reads its own relation, so the root's request scope does not reach
# it through any join. When the member relation declares a tenant_field, the
# root's trusted tenant boundary is required of the member too: the root's
# tenant conditions re-expressed on the member's tenant field and, when the
# root relation has no tenant field of its own, the trusted engine tenant. A
# scoped root whose boundary cannot be carried over fails closed with
# missing_tenant_scope rather than reading every tenant's rows (lesson 39).
# The same rule bounds inline CTE, lateral and subquery sources at compile;
# there an inline source already confined to the root's attached tenant
# prefix (schema-per-tenant) is admitted as it is (allow_prefix).
sub bound_source_domain {
    my ($class, $root, $source, %options) = @_;
    my $member_tenant = $source->tenant_field;
    return $source unless defined $member_tenant;
    my $required = $root->required_predicate;
    my $root_tenant = $root->tenant_field;
    my $tenant = $options{tenant};
    my $prefix = $options{allow_prefix} ? $root->{_read_prefix} : undef;
    return $source unless defined($required) || defined($tenant) || defined($prefix);
    my @carried;
    if (defined($required) && defined($root_tenant)) {
        my @conjuncts = $required->kind eq 'and' ? @{$required->arguments->[0]} : ($required);
        for my $conjunct (@conjuncts) {
            my $rewritten = eval { _rename_fields($conjunct, {"$root_tenant" => "$member_tenant"}) };
            push @carried, $rewritten if $rewritten;
        }
    }
    # A tenant-scoped root already carries the engine tenant in its required
    # predicate (Selecto::Engine::read_domain); a root without a tenant field
    # does not, so the trusted tenant is applied to the member directly.
    push @carried, Selecto::Expression->eq("$member_tenant", $tenant)
        if defined($tenant) && !defined($root_tenant);
    unless (@carried) {
        return $source if defined($prefix) && defined($source->{_read_prefix})
            && "$source->{_read_prefix}" eq "$prefix";
        Selecto::Error->throw(
            'missing_tenant_scope',
            ($options{label} // 'query source') . ' reads a tenant-scoped relation but the root tenant scope cannot be applied to it',
            {tenant_field => "$member_tenant"},
        );
    }
    # Conditions the source already requires (an owned query's own engine
    # boundary, or an earlier expansion) are not repeated.
    require Selecto::SQL;
    my $existing = $source->required_predicate;
    my %present = map { (Selecto::SQL::_value_key($_) => 1) }
        defined($existing) ? ($existing->kind eq 'and' ? @{$existing->arguments->[0]} : $existing) : ();
    @carried = grep { !$present{Selecto::SQL::_value_key($_)}++ } @carried;
    return $source unless @carried;
    my $carried = @carried == 1 ? $carried[0] : Selecto::Expression->all(@carried);
    return $source->with_required_predicate(defined($existing) ? Selecto::Expression->all($existing, $carried) : $carried);
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

Query members are reusable CTE, recursive CTE, VALUES, derived-subquery, lateral and array-expansion
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
it through a join. When the member's source schema declares C<tenant_field>,
the root's trusted tenant boundary is required of the member too: the root's
tenant conditions (its required predicate, which carries the engine tenant on
a tenant-scoped root) are re-expressed on the member's tenant field, and on a
root relation without a tenant field the trusted engine tenant is applied to
it directly. A scoped root whose boundary cannot be carried fails with
C<missing_tenant_scope> for such a member, so declare C<tenant_field> on every
schema holding tenant data. The same rule bounds inline CTE, recursive CTE,
lateral and subquery sources (L<Selecto::Query/with_cte> and friends) over a
domain that declares C<tenant_field>.

Members are validated when the domain is parsed and are part of its
fingerprint. Naming an undeclared member fails with C<unknown_query_member>.
All five groups receive structural validation. Native activation remains
subject to adapter support; SQLite refuses lateral table-function execution.
Portable C<{kind =E<gt> 'declared_callback'}> markers are inert metadata.
An application may separately configure explicit C<ctes:id> or C<subqueries:id>
host builders on L<Selecto::Engine>; those callbacks must return compatible
configured queries. They are trusted application code, not portable imports.
Use family-specific query methods when an ID occurs in more than one group.

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
