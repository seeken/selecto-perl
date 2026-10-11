package Selecto::Write::Context;

use 5.034;
use strict;
use warnings;
no overloading;
use JSON::PP ();
use Scalar::Util qw(reftype);
use Selecto::Domain::QueryContract ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::Identifier ();
use Selecto::OperationBudget ();

sub _fail { Selecto::Error->throw($_[0], $_[1], $_[2] // {}) }
sub _copy { Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value} }
sub identifier {
    my ($class,$value) = @_;
    $value=$value->{'$atom'} if ref($value) eq 'HASH' && keys(%$value)==1 && exists $value->{'$atom'};
    _fail('invalid_write_context','context key or field must be a nonblank identifier')
        unless defined($value) && !defined(reftype($value)) && $value =~ /\S/;
    return $value;
}
sub _entries {
    my ($value) = @_;
    return () unless defined $value;
    return map { [$_,$value->{$_}] } sort keys %$value if ref($value) eq 'HASH';
    _fail('invalid_write_context','context must be an object or ordered key/value pairs') unless ref($value) eq 'ARRAY';
    return map {
        _fail('invalid_write_context','context pair must contain a key and value') unless ref($_) eq 'ARRAY' && @$_==2;
        [__PACKAGE__->identifier($_->[0]),$_->[1]];
    } @$value;
}
sub _same {
    return JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1]);
}
sub _true {
    return ${$_[0]} == 1 if ref($_[0]) eq 'JSON::PP::Boolean';
    return defined($_[0]) && !ref($_[0]) && $_[0] eq '1';
}
sub _identity {
    my ($state,$key,$value) = @_;
    return unless defined $value;
    $value=__PACKAGE__->identifier($value) if $key eq 'tenant_field';
    _fail('invalid_write_context','tenant identity must be a nonblank scalar')
        unless !defined(reftype($value)) && $value =~ /\S/;
    _fail('tenant_mismatch','trusted tenant sources do not agree',{code=>'conflicting_trusted_tenant_context',field=>$key})
        if exists($state->{identity}{$key}) && !_same($state->{identity}{$key},$value);
    $state->{identity}{$key}=$value;
}
sub _filters {
    my ($state,$value) = @_;
    return unless defined $value;
    _fail('invalid_write_context','trusted required filters must be an array') unless ref($value) eq 'ARRAY';
    push @{$state->{filters}},@$value;
}
sub _tenant {
    my ($state,$value) = @_;
    return unless defined $value;
    if (!ref($value)) { _identity($state,'tenant_id',$value);return }
    my @entries=_entries($value);my $has_field=0;
    for my $entry (@entries) {
        my ($key,$item)=@$entry;
        if ($key eq 'tenant_id' || $key eq 'id') { _identity($state,'tenant_id',$item) }
        elsif ($key eq 'tenant_field') { _identity($state,$key,$item);$has_field=1 if defined $item }
        elsif ($key eq 'required_filters') { _filters($state,$item) }
        elsif ($key eq 'required' || $key eq 'require_tenant') {
            _fail('invalid_write_context','tenant required flag must be Boolean')
                unless !defined($item) || ref($item) eq 'JSON::PP::Boolean' || !ref($item) && $item =~ /\A[01]\z/;
            $state->{required}=1 if _true($item);
        }
    }
    # Apply the default only after every trusted source was compared. A
    # tenant shorthand must not invent a conflicting explicit field.
}
sub _execution {
    my ($state,$value) = @_;
    for my $entry (_entries($value)) {
        my ($key,$item)=@$entry;
        if ($key eq 'tenant') { _tenant($state,$item) }
        elsif ($key eq 'tenant_id' || $key eq 'tenant_field') { _identity($state,$key,$item) }
        elsif ($key eq 'required_filters') { _filters($state,$item) }
        elsif ($key eq 'required' || $key eq 'require_tenant') {
            _fail('invalid_write_context','tenant required flag must be Boolean')
                unless !defined($item) || ref($item) eq 'JSON::PP::Boolean' || !ref($item) && $item =~ /\A[01]\z/;
            $state->{required}=1 if _true($item);
        } else {
            _fail('invalid_write_context','trusted context key has conflicting values',{context_key=>$key})
                if exists($state->{values}{$key}) && !_same($state->{values}{$key},$item);
            $state->{values}{$key}=$item;
        }
    }
}
sub resolve {
    my ($class,$snapshot,$options) = @_;
    my $input=_copy({snapshot=>$snapshot,options=>$options//{}});
    $snapshot=$input->{snapshot};$options=$input->{options};
    _fail('invalid_write_context','operation snapshot must be an object') unless ref($snapshot) eq 'HASH';
    my $state={identity=>{},values=>{},filters=>[]};
    _tenant($state,$snapshot->{tenant});
    for my $container ($snapshot->{opts},$snapshot->{execution_scope},$options) {
        for my $entry (_entries($container)) {
            my ($key,$value)=@$entry;
            if ($key eq 'context') { _execution($state,$value) }
            elsif ($key eq 'tenant') { _tenant($state,$value) }
            elsif ($key eq 'tenant_id' || $key eq 'tenant_field') { _identity($state,$key,$value) }
            elsif ($key eq 'required_filters') { _filters($state,$value) }
            elsif ($key eq 'require_tenant' || $key eq 'required') {
                _fail('invalid_write_context','tenant required flag must be Boolean')
                    unless !defined($value) || ref($value) eq 'JSON::PP::Boolean' || !ref($value) && $value =~ /\A[01]\z/;
                $state->{required}=1 if _true($value);
            }
        }
    }
    my %context=(%{$state->{values}},%{$state->{identity}});
    $context{tenant_field}//='tenant_id' if defined $context{tenant_id};
    $context{required}=JSON::PP::true if $state->{required};
    my %seen;my @filters=grep{!$seen{JSON::PP->new->canonical->encode($_)}++}@{$state->{filters}};
    $context{required_filters}=\@filters if @filters;
    return _copy(\%context);
}
sub _foreign_keys {
    my ($contract)=@_;
    my $constraints=$contract->{constraints}//{};
    return {} if ref($constraints) eq 'ARRAY';
    _fail('invalid_domain','write constraints must be an object') unless ref($constraints) eq 'HASH';
    my $keys=$constraints->{foreign_keys}//{};
    _fail('invalid_domain','foreign keys must be an object') unless ref($keys) eq 'HASH';
    return $keys;
}
sub _source {
    my ($spec)=@_;
    _fail('invalid_domain','foreign key must have a declaration') unless ref($spec) eq 'HASH';
    my $source=$spec->{source};
    return ('input') if defined($source) && !ref($source) && $source eq 'input';
    return ('context',__PACKAGE__->identifier($source->[1]))
        if ref($source) eq 'ARRAY' && @$source==2 && __PACKAGE__->identifier($source->[0]) eq 'context';
    return ('context',__PACKAGE__->identifier($source->{key}))
        if ref($source) eq 'HASH' && defined($source->{kind}) && __PACKAGE__->identifier($source->{kind}) eq 'context';
    _fail('invalid_domain','foreign key source must be input or a context key');
}
sub materialize {
    my ($class,$contract,$values,$operation,$context)=@_;
    my $input=_copy({contract=>$contract,values=>$values,operation=>$operation,context=>$context});
    ($contract,$values,$operation,$context)=@{$input}{qw(contract values operation context)};
    _fail('invalid_write_context','contract, values and context must be objects')
        unless ref($contract) eq 'HASH' && ref($values) eq 'HASH' && ref($context) eq 'HASH';
    _fail('invalid_write','unsupported materialization operation') unless defined($operation) && !ref($operation) && $operation =~ /\A(?:insert|update|upsert|delete)\z/;
    my $keys=_foreign_keys($contract);
    for my $field (sort keys %$keys) {
        my $spec=$keys->{$field};my ($kind,$key)=_source($spec);
        if ($kind eq 'input') {
            _fail('missing_foreign_key','required foreign-key value is missing',{field=>$field})
                if ($operation eq 'insert' || $operation eq 'upsert') && _true($spec->{required}) && !exists($values->{$field});
            next;
        }
        next if $operation eq 'delete';
        next if $operation eq 'update' && !exists($values->{$field});
        if (!exists $context->{$key}) {
            _fail('missing_foreign_key_context','required foreign-key context is missing',{field=>$field,context_key=>$key})
                if ($operation eq 'insert' || $operation eq 'upsert') && _true($spec->{required});
            _fail('foreign_key_source_mismatch','foreign-key value must match trusted context',{field=>$field,context_key=>$key})
                if $operation eq 'update' && defined($values->{$field});
            next;
        }
        my $value=$context->{$key};
        _fail('invalid_write_context','foreign-key context value must be a scalar',{field=>$field,context_key=>$key})
            if defined(reftype($value)) && ref($value) ne 'JSON::PP::Boolean';
        _fail('foreign_key_source_mismatch','foreign-key value must match trusted context',{field=>$field,context_key=>$key})
            if exists($values->{$field}) && !_same($values->{$field},$value);
        $values->{$field}=$value if $operation eq 'insert' || $operation eq 'upsert';
    }
    return _copy($values);
}
sub foreign_key_guards {
    my ($class,$domain,$contract,$values,$operation,$context)=@_;
    my $input=_copy({domain=>$domain,contract=>$contract,values=>$values,operation=>$operation,context=>$context});
    ($domain,$contract,$values,$operation,$context)=@{$input}{qw(domain contract values operation context)};
    _fail('invalid_write_context','guard inputs must be objects') if grep {ref($_) ne 'HASH'} ($domain,$contract,$values,$context);
    _fail('invalid_write','unsupported guard operation') unless defined($operation) && !ref($operation) && $operation =~ /\A(?:insert|update|upsert|delete)\z/;
    return [] if $operation eq 'delete';
    my $keys={%{_foreign_keys($contract)}};my @guards;
    my $work=Selecto::OperationBudget->new(code=>'invalid_write_context');
    my $output=Selecto::OperationBudget->new(code=>'invalid_write_context');
    my $scope=ref($contract->{scope}) eq 'HASH' ? $contract->{scope}{tenant} : undef;
    my $source=ref($contract->{source}) eq 'HASH' ? $contract->{source} : {};
    my $schemas=$domain->{schemas}//{};
    _fail('invalid_domain','domain schemas and associations must be objects')
        unless ref($schemas) eq 'HASH' && ref($source->{associations}//{}) eq 'HASH';
    for my $name (sort keys %{$source->{associations}//{}}) {
        $work->consume_count('max_expression_nodes',1,label=>'foreign-key work');
        my $association=$source->{associations}{$name};next unless ref($association) eq 'HASH';
        my $field=$association->{owner_key};next unless defined($field) && !ref($field) && exists($values->{$field}) && !exists($keys->{$field});
        next if $field eq ($source->{primary_key}//'id') || ($association->{cardinality}//'one') ne 'one'
            || defined($association->{through}) || defined($association->{values});
        my $queryable=$association->{queryable};
        my $target=defined($queryable) && !ref($queryable) ? ($queryable eq 'source' ? $source : $schemas->{$queryable}) : undef;
        next if ref($target) eq 'HASH' && defined($target->{values});
        my $relation=ref($target) eq 'HASH' ? $target->{source_table}//$target->{table} : $association->{table};
        next unless defined($relation);
        my $related=$association->{related_key}//(ref($target) eq 'HASH' ? $target->{primary_key}//'id' : 'id');
        $keys->{$field}={source=>'input',references=>{relation=>$relation,field=>$related,
            (defined($association->{target_scope_key}) ? (tenant_field=>$association->{target_scope_key}) : ())}};
    }
    for my $field (sort keys %$keys) {
        $work->consume_count('max_expression_nodes',1,label=>'foreign-key work');
        my $spec=$keys->{$field};my ($kind)=_source($spec);
        next unless exists($values->{$field}) && defined($values->{$field});
        my $value=$values->{$field};
        _fail('invalid_write','a guarded foreign key must be a literal scalar',{field=>$field})
            if defined(reftype($value));
        my $target=$spec->{references};
        _fail('invalid_domain','foreign key references must name a relation and field',{field=>$field}) unless ref($target) eq 'HASH';
        my $relation=Selecto::Identifier::checked($class->identifier($target->{relation}));
        my $target_field=Selecto::Identifier::checked($class->identifier($target->{field}));
        my $root=$contract->{source};my @candidates;
        push @candidates,[$root,ref($scope) eq 'HASH' ? $scope->{field}//$root->{tenant_field} : $root->{tenant_field}]
            if ref($root) eq 'HASH' && ($root->{source_table}//$root->{table}//'') eq $relation;
        for my $key (sort keys %$schemas) {
            $work->consume_count('max_expression_nodes',1,label=>'foreign-key work');
            my $schema=$schemas->{$key};next unless ref($schema) eq 'HASH';
            push @candidates,[$schema,$schema->{tenant_field}] if ($schema->{source_table}//$schema->{table}//$key) eq $relation;
        }
        my ($tenant_field,$shared);
        if (exists $target->{tenant_field}) {
            my $declared=$target->{tenant_field};
            $shared=1 if !defined($declared) || ref($declared) eq 'JSON::PP::Boolean' && !$$declared;
            $tenant_field=Selecto::Identifier::checked($class->identifier($declared)) unless $shared;
        } else {
            my %fields=map{defined($_->[1]) ? ($class->identifier($_->[1])=>1) : ()}@candidates;
            _fail('invalid_domain','foreign-key tenant scope is ambiguous',{code=>'ambiguous_foreign_key_tenant_field',field=>$field}) if keys(%fields)>1;
            ($tenant_field)=keys %fields;
        }
        for my $candidate (@candidates) {
            next unless defined $tenant_field;
            my $r=$candidate->[0];
            _fail('invalid_domain','referenced fields and columns need declared containers')
                unless ref($r->{fields}//[]) eq 'ARRAY' && ref($r->{columns}//{}) eq 'HASH';
            $work->consume_count('max_expression_nodes',scalar(@{$r->{fields}//[]})+scalar(keys%{$r->{columns}//{}}),label=>'foreign-key work');
            my %fields=((map{($class->identifier($_)=>1)}@{$r->{fields}//[]}),
                (map{($_=>1)}keys%{$r->{columns}//{}}));
            _fail('invalid_domain','foreign-key tenant field is not declared',{code=>'unknown_foreign_key_tenant_field',field=>$field}) unless $fields{$tenant_field};
        }
        _fail('invalid_domain','input foreign key on tenant-scoped writes needs referenced tenant metadata',
            {code=>'foreign_key_tenant_scope_undeclared',field=>$field})
            if !$shared && !defined($tenant_field) && $kind eq 'input' && ref($scope) eq 'HASH' && defined($context->{tenant_id});
        my $guard={field=>$field,relation=>$relation,target_field=>$target_field,value=>$value};
        if (defined $tenant_field) {
            _fail('missing_tenant_scope','tenant-scoped foreign key requires trusted tenant context',{field=>$field}) unless defined $context->{tenant_id};
            # The trusted context tenant is the column the engine tenant
            # binds. On a two-column root (writes.scope.tenant and
            # source.tenant_field on different columns) that is the
            # tenant_field column (lesson 47a); it never guards another
            # tenant column, such as the pinned site column: the governing
            # engine pairs that column with its own set (item 34), and this
            # description carries no set, so it cannot be executed as it
            # stands.
            my $scope_field=ref($scope) eq 'HASH' && defined($scope->{field}) ? $class->identifier($scope->{field}) : undef;
            my $root_field=ref($root) eq 'HASH' && defined($root->{tenant_field}) ? $class->identifier($root->{tenant_field}) : undef;
            my $other_column=defined($scope_field) && defined($root_field) && $scope_field ne $root_field && $tenant_field ne $root_field;
            @{$guard}{qw(tenant_field tenants)}=($tenant_field,$other_column ? [] : [$context->{tenant_id}]);
        }
        $output->check_tree($guard,label=>'foreign-key guards');push @guards,$guard;
    }
    return _copy(\@guards);
}
sub required_predicate {
    my ($class,$contract,$context)=@_;
    my $input=_copy({contract=>$contract,context=>$context});($contract,$context)=@{$input}{qw(contract context)};
    _fail('invalid_write_context','contract and context must be objects') unless ref($contract) eq 'HASH' && ref($context) eq 'HASH';
    my $source=$contract->{source}//{};
    _fail('invalid_write_context','trusted filter declarations need plain field containers')
        unless ref($source) eq 'HASH' && ref($source->{columns}//{}) eq 'HASH'
            && ref($source->{fields}//[]) eq 'ARRAY' && ref($context->{required_filters}//[]) eq 'ARRAY';
    my %fields=map{($_=>1)}keys%{$source->{columns}//{}};
    $fields{$class->identifier($_)}=1 for @{$source->{fields}//[]};
    my @predicates;
    for my $filter (@{$context->{required_filters}//[]}) {
        _fail('invalid_write_context','trusted filter must have two or three elements') unless ref($filter) eq 'ARRAY' && (@$filter==2 || @$filter==3);
        my ($field,$operator,$value)=@$filter==2 ? ($filter->[0],'eq',$filter->[1]) : @$filter;
        $field=Selecto::Identifier::checked($class->identifier($field));$operator=$class->identifier($operator);
        _fail('undeclared_write_identifier','trusted filter must name a stored root field',{field=>$field}) unless $fields{$field};
        my %aliases=('='=>'eq','!='=>'neq','<>'=>'neq','>'=>'gt','>='=>'gte','<'=>'lt','<='=>'lte');$operator=$aliases{$operator}//$operator;
        _fail('invalid_write_context','unsupported trusted filter comparison') unless $operator =~ /\A(?:eq|neq|gt|gte|lt|lte|in|is_null|not_null)\z/;
        if ($operator eq 'in') { _fail('invalid_write_context','IN needs a nonempty value list') unless ref($value) eq 'ARRAY' && @$value;push @predicates,Selecto::Expression->in($field,$value) }
        elsif ($operator eq 'is_null' || $operator eq 'not_null') { _fail('invalid_write_context','null tests must have null values') if defined $value;push @predicates,Selecto::Expression->$operator($field) }
        else { _fail('invalid_write_context','trusted filter comparison requires a scalar') if ref($value) && ref($value) ne 'JSON::PP::Boolean';push @predicates,Selecto::Expression->$operator($field,$value) }
    }
    return undef unless @predicates;
    return $predicates[0] if @predicates==1;
    return Selecto::Expression->all(@predicates);
}
sub _scope {
    my ($snapshot)=@_;
    _fail('invalid_write_context','operation snapshot and domain must be objects')
        unless ref($snapshot) eq 'HASH' && ref($snapshot->{domain}) eq 'HASH';
    my $writes=$snapshot->{domain}{writes};
    return undef unless defined $writes;
    _fail('invalid_domain','write policy must be an object') unless ref($writes) eq 'HASH';
    my $scope=$writes->{scope}//$writes->{scopes};
    return undef unless defined $scope;
    _fail('invalid_domain','write scope must be an object') unless ref($scope) eq 'HASH';
    return undef unless defined $scope->{tenant};
    _fail('invalid_domain','tenant scope must be an object') unless ref($scope->{tenant}) eq 'HASH';
    return $scope->{tenant};
}
sub apply_tenant_scope {
    my ($class,$snapshot,$options)=@_;
    $snapshot=_copy($snapshot);my $context=$class->resolve($snapshot,$options);
    $snapshot->{tenant}={map{exists($context->{$_}) ? ($_=>$context->{$_}) : ()}qw(tenant_id tenant_field required required_filters)};
    my $scope=_scope($snapshot);my $field=$scope ? $scope->{field} : $context->{tenant_field}//'tenant_id';
    _fail('invalid_write_context','operation filters must be an array') unless ref($snapshot->{filters}//[]) eq 'ARRAY';
    $field=$class->identifier($field);my @filters=(@{$snapshot->{filters}//[]},@{$context->{required_filters}//[]});
    if (defined $context->{tenant_id}) {
        # Preserve authored representations (including ambiguous originals),
        # but do not create an atom/string ambiguity by adding a duplicate
        # trusted equality next to the caller's existing matching equality.
        my $present=grep {ref($_) eq 'ARRAY' && @$_==2 && $class->identifier($_->[0]) eq $field
            && _same($_->[1],$context->{tenant_id})} @filters;
        push @filters,[$field,$context->{tenant_id}] unless $present;
    }
    my %seen;$snapshot->{filters}=[grep{!$seen{JSON::PP->new->canonical->encode($_)}++}@filters];
    return _copy($snapshot);
}
sub apply_execution_scope {
    my ($class,$snapshot,$options)=@_;
    $snapshot=_copy($snapshot);my $scope=_scope($snapshot);
    return $snapshot unless $scope;
    my $context=$class->resolve($snapshot,$options);
    $snapshot->{execution_scope}=_copy($options//{});
    my $sources=$scope->{satisfied_by}//['trusted_context'];
    _fail('invalid_write_context','tenant satisfied_by must be an array') unless ref($sources) eq 'ARRAY';
    my $trusted=grep{$class->identifier($_) eq 'trusted_context'}@$sources;
    if ($trusted) { $snapshot=$class->apply_tenant_scope($snapshot,$options) }
    else {
        _fail('invalid_write_context','operation filters must be an array') unless ref($snapshot->{filters}//[]) eq 'ARRAY';
        my @filters=(@{$snapshot->{filters}//[]},@{$context->{required_filters}//[]});
        my %seen;$snapshot->{filters}=[grep{!$seen{JSON::PP->new->canonical->encode($_)}++}@filters];
    }
    if ($trusted && defined $context->{tenant_id}) {
        my $field=$class->identifier($scope->{field});
        $snapshot->{applied_scope}={tenant=>{required=>_true($scope->{required})?JSON::PP::true:JSON::PP::false,
            field=>$field,sources=>[{source=>'trusted_context',field=>$field,value=>$context->{tenant_id},filter=>[$field,$context->{tenant_id}]}]}};
    }
    return _copy($snapshot);
}
sub validate_tenant_scope {
    my ($class,$snapshot,$options)=@_;$snapshot=_copy($snapshot);
    my $context=$class->resolve($snapshot,$options);my $scope=_scope($snapshot);
    my $domain=$snapshot->{domain};my $required=$scope ? _true($scope->{required}) : _true($domain->{tenant_required})||_true($domain->{require_tenant})||_true($context->{required});
    return 1 unless $required;
    my $sources=$scope ? $scope->{satisfied_by}//['trusted_context'] : ['trusted_context','filter'];
    _fail('invalid_write_context','tenant satisfied_by and filters must be arrays')
        unless ref($sources) eq 'ARRAY' && ref($snapshot->{filters}//[]) eq 'ARRAY';
    my $field=$class->identifier($scope ? $scope->{field} : $context->{tenant_field}//'tenant_id');
    for my $source (@$sources) {
        $source=$class->identifier($source);
        return 1 if $source eq 'trusted_context' && defined $context->{tenant_id};
        if ($source eq 'filter') {
            for my $filter (@{$snapshot->{filters}//[]}) {
                next unless ref($filter) eq 'ARRAY' && @$filter==2;
                return 1 if $class->identifier($filter->[0]) eq $field && defined($filter->[1])
                    && (!defined($context->{tenant_id}) || _same($context->{tenant_id},$filter->[1]));
            }
        }
        if ($source eq 'payload' && ref($snapshot->{values}) eq 'HASH' && defined($snapshot->{values}{$field})) {return 1}
    }
    _fail('missing_tenant_scope','tenant scope is required for this write operation');
}
sub applied_scope {
    my ($class,$snapshot)=@_;
    $snapshot=_copy($snapshot);
    _fail('invalid_write_context','operation snapshot must be an object') unless ref($snapshot) eq 'HASH';
    return _copy($snapshot->{applied_scope});
}

1;

__END__

=head1 NAME

Selecto::Write::Context - bounded trusted portable write context

=head1 DESCRIPTION

C<resolve($snapshot, $options)> returns an independent canonical context.
Context objects and ordered key/value pairs are admitted completely before
interpretation; plain C<{'$atom' =E<gt> 'name'}> identifier markers preserve
portable atom/string ambiguities without constructing dynamic symbols.
Conflicting tenant identities, fields or repeated context values fail closed.
Callbacks, tied input, unknown objects, cycles and excessive work are refused.

C<materialize($contract, $values, $operation, $context)> injects context-owned
foreign keys on insert/upsert and checks caller-authored values against their
trusted source. Updates check only assigned foreign-key fields.
C<foreign_key_guards($domain, $contract, $values, $operation, $context)>
returns bound parent-existence guards using the authored reference and tenant
metadata. C<required_predicate($contract, $context)> lowers trusted required
filters against stored root fields.

C<apply_execution_scope>, C<apply_tenant_scope>, C<validate_tenant_scope> and
C<applied_scope> expose independent portable scope snapshots. Applying scope
does not change write payloads or erase authored identifier ambiguities.

Compilation context does not authorize native execution. A host configures
the engine separately with C<write_context>; its private structural identity
binds the complete context. Native governance materializes context keys before
field policy checks and re-derives executable reference guards from that
engine's own domain. Legacy C<scope =E<gt> {tenant =E<gt> ...}> must agree with
any independently supplied context tenant. Read context grants no writes.

=cut
