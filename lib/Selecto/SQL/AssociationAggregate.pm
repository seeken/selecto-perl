package Selecto::SQL::AssociationAggregate;
use 5.034;
use strict;
use warnings;
use Selecto::Error;
use Selecto::Expression;

# All identifiers and ASTs were admitted by Domain. Keep the correlation in
# this scalar scope; none of these joins may escape into the owner query.
sub compile {
    my ($class, $sql, $domain, $path, $spec, $params) = @_;
    Selecto::Error->throw('unsupported_feature', 'association_aggregate requires PostgreSQL, SQLite or DuckDB')
        unless $sql->name =~ /\A(?:postgresql|sqlite|duckdb)\z/;
    my $name = $spec->{association};
    my $edge = $domain->associations->{$name};
    my $alias = 'aa_' . $name;
    my $outer = $sql->_root_alias;
    local $sql->{_join_aliases} = {%{$sql->{_join_aliases} // {}}, $name => $alias};
    local $sql->{_selecto_field_prefix};
    local $sql->{_selecto_pair_parent_types} = $sql->_exact_identity_compare
        ? $sql->_association_parent_types($domain, $name) : undef;
    my $from = $sql->_association_source_sql($edge) . ' AS ' . $sql->quote_identifier($alias);
    my (@where, @joins);
    my $bridge = $edge->through;
    if ($bridge) {
        my $ba = 'aat_' . $name;
        my @on = ($sql->_qualified($ba, $bridge->{related_key}) . ' = ' .
            $sql->_join_target_key($sql->_qualified($alias, $edge->related_key), $bridge->{target_key_cast}));
        if (defined $bridge->{source_scope_key}) {
            my $exact = $sql->_association_identity_exact($edge, $bridge->{target_scope_key}, undef);
            push @on, $sql->_identity_equal_sql($sql->_qualified($ba,$bridge->{through_scope_key}),
                $sql->_qualified($alias,$bridge->{target_scope_key}),$exact);
        }
        push @on, $sql->_constant_join_predicates($alias,$edge->where,$params,$edge->fields),
            $sql->_tenant_bound_sql($edge,$alias,$params);
        $from = $sql->_physical_source_sql($bridge->{table}) . ' AS ' . $sql->quote_identifier($ba) .
            ' INNER JOIN ' . $from . ' ON ' . join(' AND ', @on);
    }
    my $condition = exists($spec->{where})
        ? Selecto::SQL::_prefix_fields(Selecto::Expression->from_filter_ast($spec->{where}), "$name.") : undef;
    # _prefix_fields is a plain recursive function, not an adapter method.
    # Build every to-one path required by the filter before binding WHERE.
    my %paths;
    for my $field ($condition ? Selecto::Expression->field_references($condition) : ()) {
        my @bits = split /\./, $field;
        pop @bits;
        while (@bits > 1) { $paths{join('.', @bits)} = 1; pop @bits }
    }
    for my $p (sort { scalar(split /\./,$a) <=> scalar(split /\./,$b) || $a cmp $b } keys %paths) {
        my $nested = $domain->resolve_association($p)->{association};
        Selecto::Error->throw('invalid_domain', 'aggregate filters require direct left or inner to-one joins')
            if $nested->through || $nested->cardinality ne 'one' || defined($nested->join_strategy)
                || $nested->join_type !~ /\A(?:left|inner)\z/;
        my $na = 'aa_' . ($p =~ s/\./_/gr);
        $sql->{_join_aliases}{$p} = $na;
        my $parent = $p =~ s/\.[^.]+$//r;
        my $pa = $sql->{_join_aliases}{$parent};
        local $sql->{_selecto_pair_parent_types} = $sql->_exact_identity_compare
            ? $sql->_association_parent_types($domain,$p) : undef;
        my @on = ($sql->_qualified($na,$nested->related_key) . ' = ' .
            $sql->_association_owner_sql($domain,$p,$params,$pa),
            $sql->_join_condition_sql($nested,$pa,$na));
        if (defined $nested->source_scope_key) {
            push @on, $sql->_identity_equal_sql($sql->_qualified($pa,$nested->source_scope_key),
                $sql->_qualified($na,$nested->target_scope_key),
                $sql->_association_identity_exact($nested,$nested->target_scope_key,$nested->source_scope_key));
        }
        push @on, $sql->_constant_join_predicates($na,$nested->where,$params,$nested->fields),
            $sql->_tenant_pair_sql($nested,$pa,$na),$sql->_tenant_bound_sql($nested,$na,$params);
        push @joins, ($nested->join_type eq 'inner' ? ' INNER JOIN ' : ' LEFT JOIN ') .
            $sql->_association_source_sql($nested) . ' AS ' . $sql->quote_identifier($na) . ' ON ' . join(' AND ',@on);
    }
    if ($bridge) {
        my $ba = 'aat_' . $name;
        my @keys = @{$spec->{through_owner_keys} // [$bridge->{owner_key}]};
        my @correlations = map {
            $sql->_qualified($ba,$_) . ' = ' . $sql->_association_owner_sql($domain,$name,$params,$outer)
        } @keys;
        push @where, '(' . join(' OR ',@correlations) . ')';
        push @where, $sql->_qualified($ba,$spec->{through_exclude_owner_field}) . ' <> ' .
            $sql->_association_owner_sql($domain,$name,$params,$outer)
            if exists $spec->{through_exclude_owner_field};
        if (defined $bridge->{source_scope_key}) {
            push @where, $sql->_identity_equal_sql($sql->_qualified($ba,$bridge->{through_scope_key}),
                $sql->_qualified($outer,$bridge->{source_scope_key}),
                $sql->_association_identity_exact($edge,$bridge->{target_scope_key},undef));
        }
        push @where,$sql->_constant_join_predicates($ba,$bridge->{where},$params);
    } else {
        push @where, $sql->_qualified($alias,$edge->related_key) . ' = ' .
            $sql->_association_owner_sql($domain,$name,$params,$outer),
            $sql->_join_condition_sql($edge,$outer,$alias);
        if (defined $edge->source_scope_key) {
            push @where,$sql->_identity_equal_sql($sql->_qualified($outer,$edge->source_scope_key),
                $sql->_qualified($alias,$edge->target_scope_key),
                $sql->_association_identity_exact($edge,$edge->target_scope_key,$edge->source_scope_key));
        }
        push @where,$sql->_constant_join_predicates($alias,$edge->where,$params,$edge->fields),
            $sql->_tenant_bound_sql($edge,$alias,$params);
    }
    push @where,$sql->_tenant_pair_sql($edge,$outer,$alias);
    push @where,$sql->_compile_expression($domain,$condition,$params) if $condition;
    my $value = uc($spec->{function}) . '(' . $sql->_qualified($alias,$spec->{field}) . ')';
    $value = 'CASE WHEN COUNT(*) = 0 THEN NULL ELSE ' . $value . ' END'
        if $spec->{function} eq 'count';
    my $result = '(SELECT ' . $value . ' FROM ' . $from . join('',@joins) .
        ' WHERE ' . join(' AND ',@where) . ')';
    if (exists $spec->{default}) {
        push @$params,$spec->{default};
        $result = 'COALESCE(' . $result . ', ' . $sql->placeholder(scalar @$params) . ')';
    }
    return $result;
}
1;
