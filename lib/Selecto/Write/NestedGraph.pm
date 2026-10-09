package Selecto::Write::NestedGraph;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed reftype);
use JSON::PP ();
use B ();
use bytes ();
use Selecto::Error ();
use Selecto::Domain::WriteContract ();
use Selecto::Domain::QueryContract ();
use Selecto::OperationBudget ();
use Selecto::Write ();
use Selecto::Write::Operation ();
use Selecto::Limits ();
use Selecto::RuleTest ();

sub _fail { Selecto::Error->throw($_[0] // 'invalid_graph', $_[1], {path=>$_[2] // [], %{$_[3] // {}}}) }
sub _copy { Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value} }
sub _true { ref($_[0]) eq 'JSON::PP::Boolean' ? ${$_[0]} == 1 : defined($_[0]) && !defined(reftype($_[0])) && $_[0] =~ /\A(?:1|true)\z/ }
sub _id { defined($_[0]) && !defined(reftype($_[0])) && (B::svref_2object(\$_[0])->FLAGS & B::SVp_POK()) && $_[0] =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/ }
sub _json { JSON::PP->new->canonical->allow_nonref->encode($_[0]) }
sub _object_values {
    my ($given,$path)=@_;
    return $given if ref($given) eq 'HASH';
    _fail('invalid_graph','nested values require an object or ordered assignment pairs',$path) unless ref($given) eq 'ARRAY';
    require Selecto::Write::PortableCommand;
    my %values;
    for my $pair (@$given) {
        _fail('invalid_graph','nested ordered values require field/value pairs',$path) unless ref($pair) eq 'ARRAY' && @$pair==2;
        my $key=Selecto::Write::PortableCommand->identifier($pair->[0]);
        _fail('duplicate_assignment_identifier','nested normalized assignment identifiers must be unique',$path,{fields=>[$key]}) if exists $values{$key};
        $values{$key}=$pair->[1];
    }
    return \%values;
}
sub _split {
    my ($given,$contract,$path)=@_;
    my $values=_object_values($given,$path);
    my (%flat,%nested);
    for my $key (sort keys %$values) {
        if (exists $contract->{relationships}{$key}) { $nested{$key}=$values->{$key} }
        else { $flat{$key}=$values->{$key} }
    }
    return (\%flat,\%nested);
}
sub nested {
    my ($class,$operation)=@_;
    my $state=Selecto::Write::Operation::snapshot($operation);
    return 0 unless ref($state->{values}) eq 'HASH' || ref($state->{values}) eq 'ARRAY';
    my $contract=eval {Selecto::Domain::WriteContract->compile($state->{domain})};
    return 0 unless $contract;
    my $values=_object_values($state->{values},[]);
    return scalar grep {exists $contract->{relationships}{$_}} keys %$values;
}
sub _primary {
    my ($domain,$path)=@_; my $key=$domain->{source}{primary_key} // $domain->{primary_key} // 'id';
    _fail('invalid_graph','nested domain must declare a usable primary key',$path) unless _id($key);
    return $key;
}
sub _operation {
    my ($operation,$state,$values)=@_;
    # The public builder retains private captured-policy lifecycle evidence.
    # Rebuilding from a plain snapshot would discard that execution obligation.
    return $operation->operation($state->{type},$values);
}
sub _returning {
    my ($command,$fields)=@_;my $metadata=$command->metadata;
    my $returning=$metadata->{returning} // [];
    _fail('invalid_graph','nested returning must be a field list',[]) unless ref($returning) eq 'ARRAY';
    my %seen;$metadata->{returning}=[grep {!$seen{$_}++} @$returning,@$fields];
    return $command->with_metadata($metadata);
}
sub _mode {
    my ($given)=@_;return undef unless defined($given) && !defined(reftype($given));
    return 'append_only' if $given eq 'append' || $given eq 'append_only';
    return $given if $given =~ /\A(?:delta|full_set|replace_one|link_delta)\z/;
    return undef;
}
sub _allowed {
    my ($spec)=@_;my %allowed;
    for my $op (@{$spec->{allowed_ops} // []}) { my $kind=$op eq 'insert'?'create':$op; $allowed{$kind}=1 }
    if (ref($spec->{write}) eq 'HASH') { $allowed{$_}=1 for grep {_true($spec->{write}{$_})} qw(create update delete reorder link unlink) }
    return \%allowed;
}
sub _identity {
    my ($attrs,$fields)=@_; return {map {exists($attrs->{$_}) && defined($attrs->{$_}) ? ($_=>$attrs->{$_}) : ()} @$fields};
}
sub _token {
    my ($entry,$fields)=@_;
    return ['client',"$entry->{client_identity}"] if defined $entry->{client_identity};
    my $identity=_identity($entry->{attrs},$fields);
    return undef unless @$fields && keys(%$identity)==@$fields;
    return ['server',[map {[$_,$identity->{$_}]} @$fields]];
}
sub _entry {
    my ($operation,$attrs,$spec,$path)=@_;
    $attrs=_object_values($attrs,$path);
    _fail('invalid_graph','nested relationship items must be objects',$path) unless ref($attrs) eq 'HASH';
    my %values=%$attrs;my $client=defined($spec->{client_identity}) ? delete($values{$spec->{client_identity}}) : undef;
    _fail('invalid_graph','client identity must be a scalar',$path) if defined($client) && defined(reftype($client));
    return {operation=>$operation,attrs=>\%values,client_identity=>$client,stable_paths=>ref($spec->{write}) eq 'HASH' || defined($spec->{client_identity})};
}
sub _op_values {
    my ($payload,$operation,$path)=@_;my $values=$payload->{$operation} // [];
    $values=[$values] if ref($values) eq 'HASH';
    _fail('invalid_graph','nested delta operation requires objects',$path,{operation=>$operation})
        unless ref($values) eq 'ARRAY' && !grep {ref($_) ne 'HASH'} @$values;
    return $values;
}
sub _entries {
    my ($given,$spec,$parent_type,$fields,$path,$evaluation)=@_;
    my $write=$spec->{write} // {};my @declared=map {_mode($_)} @{$write->{modes} // []};
    @declared=('full_set') if !@declared && ($spec->{strategy} // '') eq 'sync';
    my $explicit=ref($given) eq 'HASH' && exists($given->{mode});
    my $mode=$explicit ? _mode($given->{mode}) : undef;
    _fail('invalid_graph','nested mutation representation is unknown',$path) if $explicit && !defined $mode;
    $mode //= ref($given) eq 'HASH' && (exists($given->{link}) || exists($given->{unlink})) ? 'link_delta'
        : ref($given) eq 'HASH' && (grep {exists($given->{$_})} qw(create update delete)) && (grep {$_ eq 'delta'} @declared) ? 'delta'
        : $spec->{cardinality} eq 'one' && (grep {$_ eq 'replace_one'} @declared) ? 'replace_one'
        : ref($given) eq 'ARRAY' && $parent_type eq 'insert' && (grep {$_ eq 'append_only'} @declared) ? 'append_only'
        : ref($given) eq 'ARRAY' && (grep {$_ eq 'full_set'} @declared) ? 'full_set'
        : ref($given) eq 'ARRAY' && (grep {$_ eq 'append_only'} @declared) ? 'append_only'
        : @declared ? $declared[0] : $parent_type eq 'insert' ? 'append_only' : 'full_set';
    _fail('invalid_graph','nested representation is not declared by relationship',$path,{representation=>$mode})
        if @declared && !grep {defined($_) && $_ eq $mode} @declared;
    my $payload=$given;
    if (ref($given) eq 'HASH') {
        $payload=$given->{value} // $given if $mode eq 'replace_one';
        $payload=$given->{items} // $given->{set} // $given if $mode eq 'full_set';
        $payload=$given->{items} // $given->{create} // $given if $mode eq 'append_only';
    }
    my @entries;
    if ($mode eq 'full_set' || $mode eq 'append_only') {
        my $values=$spec->{cardinality} eq 'one' ? !defined($payload) ? [] : ref($payload) eq 'HASH' || ref($payload) eq 'ARRAY' ? [$payload] : undef : $payload;
        _fail('invalid_graph','nested payload has invalid collection cardinality',$path) unless ref($values) eq 'ARRAY';
        my $min=$write->{min_items} // $spec->{min_items} // (_true($spec->{required})?1:0);
        my $max=$write->{max_items} // $spec->{max_items} // ($spec->{cardinality} eq 'one'?1:undef);
        _fail('invalid_graph','nested relationship item bounds are invalid',$path)
            unless !ref($min) && $min =~ /\A[0-9]+\z/ && (!defined($max) || !ref($max) && $max =~ /\A[0-9]+\z/ && $max >= $min);
        _fail('invalid_graph','nested relationship violates its item bounds',$path,{minimum=>$min,maximum=>$max,actual=>scalar @$values})
            if @$values<$min || defined($max) && @$values>$max;
        @entries=map {_entry($mode eq 'full_set'?'auto':'create',$_,$spec,$path)} @$values;
    } elsif ($mode eq 'delta' || $mode eq 'link_delta') {
        _fail('invalid_graph','nested mutation representation requires an object',$path) unless ref($payload) eq 'HASH';
        my @ops=$mode eq 'delta'?qw(create update delete):qw(link unlink);
        for my $op (@ops) {push @entries,map {_entry($op,$_,$spec,$path)} @{_op_values($payload,$op,$path)}}
        _fail('invalid_graph','nested mutation requires at least one change',$path) unless @entries;
        my $max=$write->{max_mutations} // $write->{max_items} // $spec->{max_items};
        _fail('invalid_graph','nested mutation exceeds its declared bound',$path) if defined($max) && @entries>$max;
    } elsif ($mode eq 'replace_one') {
        _fail('invalid_graph','replace_one requires one object relationship',$path) unless $spec->{cardinality} eq 'one' && ref($payload) eq 'HASH';
        my @ops=grep {exists($payload->{$_}) && defined($payload->{$_})} qw(create update delete);
        _fail('invalid_graph','replace_one accepts one create, update or delete',$path) if @ops>1;
        my $op=@ops?$ops[0]:keys(%{_identity($payload,$fields)})==@$fields?'update':'create';
        @entries=(_entry($op,@ops?$payload->{$op}:$payload,$spec,$path));
    }
    my %seen;
    for my $entry (@entries) {
        my $token=_token($entry,$fields);
        _fail('invalid_graph','nested create requires a stable client identity',$path)
            if defined($spec->{client_identity}) && !defined($entry->{client_identity})
                && ($entry->{operation} eq 'create' || $entry->{operation} eq 'auto' && !defined($token));
        _fail('invalid_graph','nested link requires a complete shared identity',$path) if $entry->{operation} eq 'link' && !defined($token);
        _fail('invalid_graph','nested mutation contains a duplicate stable identity',$path) if defined($token) && $seen{_json($token)}++;
    }
    _validation(\@entries,$spec,$mode,$path,$evaluation);
    return ($mode,\@entries);
}
sub _test {
    my ($state,$test,$value,$path)=@_;
    my $compiled=Selecto::RuleTest->compile($test,$state->{limits},0,\$state->{work});
    my ($ok,$code)=Selecto::RuleTest->evaluate($compiled,$value,1,$state->{limits},\$state->{work});
    _fail('invalid_graph','nested relationship violates its declared validation rule',$path,{rule=>$code}) unless $ok;
}
sub _validation {
    my ($entries,$spec,$mode,$path,$state)=@_;my $validation=$spec->{validation} // {};
    _fail('invalid_graph','nested validation requires an object',$path) unless ref($validation) eq 'HASH';
    _fail('invalid_graph','unsupported nested validation policy',$path) if grep {!/\A(?:field_rules|unique_fields|aggregate_rules)\z/} keys %$validation;
    my @rows=map {$_->{attrs}} grep {$_->{operation} ne 'delete' && $_->{operation} ne 'unlink'} @$entries;
    my $field_rules=$validation->{field_rules} // [];
    _fail('invalid_graph','field_rules must be a list',$path) unless ref($field_rules) eq 'ARRAY';
    for my $rule (@$field_rules) {
        _fail('invalid_graph','nested number rule is malformed',$path) unless ref($rule) eq 'HASH' && _id($rule->{field}) && ($rule->{type} // '') eq 'number';
        my @tests;
        push @tests,{op=>'presence.required'} if _true($rule->{required});
        my %numeric=(greater_than=>'number.gt',greater_than_or_equal_to=>'number.gte',less_than=>'number.lt',less_than_or_equal_to=>'number.lte');
        push @tests,{op=>$numeric{$_},bound=>$rule->{$_}} for grep {defined($rule->{$_})} sort keys %numeric;
        my $declared=$rule->{rules} // $rule->{validators} // $rule->{validations} // [];
        $declared=[$declared] if ref($declared) eq 'HASH';
        _fail('invalid_graph','nested numeric validators require portable test objects',$path) unless ref($declared) eq 'ARRAY' && !grep {ref($_) ne 'HASH'} @$declared;
        push @tests,@$declared;
        _fail('invalid_graph','nested numeric rule declares no test',$path) unless @tests;
        for my $row (@rows) {
            my $value=$row->{$rule->{field}};
            next if (!defined($value) || !ref($value) && $value eq '') && !_true($rule->{required});
            _test($state,@tests==1?$tests[0]:{op=>'all',rules=>\@tests},$value,[@$path,$rule->{field}]);
        }
    }
    my $unique=$validation->{unique_fields} // [];
    _fail('invalid_graph','unique_fields must be a field list',$path) unless ref($unique) eq 'ARRAY' && !grep {!_id($_)} @$unique;
    if (@$unique) {
        my @complete=grep {my $row=$_; !grep {!exists($row->{$_}) || !defined($row->{$_}) || !ref($row->{$_}) && $row->{$_} eq ''} @$unique} @rows;
        _test($state,{op=>'collection.unique_by',paths=>[map {[$_]} @$unique]},\@complete,$path);
    }
    my $aggregate=$validation->{aggregate_rules} // [];
    _fail('invalid_graph','aggregate_rules must be a list',$path) unless ref($aggregate) eq 'ARRAY';
    for my $rule (@$aggregate) {
        _fail('invalid_graph','nested aggregate rule is malformed',$path) unless ref($rule) eq 'HASH' && ($rule->{operation} // '') eq 'sum' && _id($rule->{field});
        my $modes=$rule->{representations} // ['full_set']; $modes=[$modes] unless ref($modes);
        _fail('invalid_graph','aggregate representations are invalid',$path) unless ref($modes) eq 'ARRAY' && !grep {!defined _mode($_)} @$modes;
        next unless grep {_mode($_) eq $mode} @$modes;
        _test($state,{op=>'collection.sum',path=>[$rule->{field}],map {defined($rule->{$_->[0]})?($_->[1]=>$rule->{$_->[0]}):()} (['minimum','min'],['maximum','max'])},\@rows,$path);
    }
}
sub _policy {
    my ($spec,$mode,$parent_type,$path)=@_;
    _fail('write_policy_missing','nested relationship declares no allowed write operations',$path) unless exists($spec->{allowed_ops}) || ref($spec->{write}) eq 'HASH';
    _fail('write_relation_mismatch','nested relationship is not writable',$path)
        unless _true($spec->{writable}) || _true($spec->{enabled}) || ref($spec->{write}) eq 'HASH' && @{$spec->{write}{modes} // []};
    my $owner=$spec->{ownership} // '';
    my $composition=$owner eq 'owned' || $owner eq 'composition';
    my $shared=$owner =~ /\A(?:shared_reference|shared_association|join_only|join_association)\z/;
    _fail('invalid_graph','nested mutation representation conflicts with ownership',$path)
        if $mode eq 'link_delta' ? !$shared : !$composition;
    my $allowed=_allowed($spec);my $required=$parent_type eq 'insert' || $parent_type eq 'update' && $mode eq 'append_only' ? 'create' : undef;
    _fail('write_operation_not_enabled','nested operation is not allowed by relationship',$path) if defined($required) && !$allowed->{$required};
    return $allowed;
}
sub _relationships {
    my ($state,$contract,$nested,$parent_type,$parent_id,$parent_key,$parent_path,$depth)=@_;
    _fail('invalid_graph','nested write exceeds maximum relationship depth',$parent_path) if $depth>32;
    for my $relationship (sort keys %$nested) {
        my $path_bytes=bytes::length($relationship);$path_bytes+=bytes::length($_) for @$parent_path;
        $state->{generated}->consume_count('max_state_bytes',$path_bytes,label=>'generated nested path bytes');
        my $path=[@$parent_path,$relationship];my $spec=$contract->{relationships}{$relationship};
        _fail('invalid_graph','nested relationship has invalid cardinality',$path)
            unless ref($spec) eq 'HASH' && ($spec->{cardinality} // '') =~ /\A(?:one|many)\z/;
        my $domain=$spec->{domain};
        _fail('write_policy_missing','nested relationship requires complete child domain',$path) unless ref($domain) eq 'HASH';
        my $child_contract=Selecto::Domain::WriteContract->compile($domain);
        my $child_key=$spec->{child_key} // $spec->{foreign_key};
        _fail('invalid_graph','nested relationship must declare an existing child_key',$path)
            unless _id($child_key) && exists($child_contract->{source}{columns}{$child_key});
        my $fields=$spec->{identity_fields} // [_primary($domain,$path)];
        _fail('invalid_graph','nested identity fields are invalid',$path) unless ref($fields) eq 'ARRAY' && @$fields && !grep {!_id($_) || !exists($child_contract->{source}{columns}{$_})} @$fields;
        my $conflict=$spec->{conflict} // {};my $extra=$conflict->{child_fields} // $conflict->{child_field} // [];$extra=[$extra] unless ref($extra);
        _fail('invalid_graph','nested conflict fields are invalid',$path) unless ref($extra) eq 'ARRAY' && !grep {!_id($_) || !exists($child_contract->{source}{columns}{$_})} @$extra;
        my %predicate_seen;my @predicate=grep {!$predicate_seen{$_}++} @$fields,@$extra;
        my ($mode,$entries)=_entries($nested->{$relationship},$spec,$parent_type,$fields,$path,$state->{validation});
        my $allowed=_policy($spec,$mode,$parent_type,$path);
        my $strategy=$parent_type eq 'update' && $mode eq 'full_set'?'sync':'ordered';
        _fail('invalid_graph','nested parent operation is unsupported',$path) unless $parent_type eq 'insert' || $parent_type eq 'update';
        my $write=ref($spec->{write}) eq 'HASH'?$spec->{write}:{};
        my $delete_missing=$strategy eq 'sync' && (($write->{omission} // '') eq 'delete_missing' || _true($spec->{delete_missing}));
        _fail('write_operation_not_enabled','delete_missing requires relationship delete permission',$path) if $delete_missing && !$allowed->{delete};
        my @children;
        for my $index (0 .. $#$entries) {
            my $entry=$entries->[$index];my $attrs=$entry->{attrs};
            _fail('invalid_graph','caller cannot supply generated relationship foreign key',$path,{field=>$child_key}) if exists $attrs->{$child_key};
            my $token=_token($entry,$fields);my $segment=!defined($token)?($entry->{stable_paths}?"index=$index":$index):$token->[0] eq 'client'?"client_id=$token->[1]":join(',',map {$_->[0].'='.$_->[1]} @{$token->[1]});
            my $row_bytes=$path_bytes+bytes::length($segment);
            $state->{generated}->consume_count('max_state_bytes',$row_bytes*3,label=>'generated nested row and metadata bytes');
            my $row_path=$spec->{cardinality} eq 'one'?$path:[@$path,$segment];
            my ($flat,$child_nested)=_split($attrs,$child_contract,$row_path);
            my $identity=_identity($flat,$fields);my $semantic=$entry->{operation};my ($type,$values,$filters);
            if ($semantic eq 'create' || $semantic eq 'link' || $semantic eq 'auto' && keys(%$identity)!=@$fields) {($type,$values,$filters)=('insert',$flat,[])}
            else {
                my $predicate=_identity($flat,\@predicate);
                _fail('invalid_graph','nested mutation requires complete identity and conflict fields',$row_path) unless keys(%$predicate)==@predicate;
                $filters=[map {[$_,$predicate->{$_}]} @predicate];
                if ($semantic eq 'delete' || $semantic eq 'unlink') {($type,$values)=('delete',{})}
                else {my %drop=map {$_=>1} @predicate;($type,$values)=('update',{map {$drop{$_}?():($_=>$flat->{$_})} keys %$flat});
                    _fail('invalid_graph','nested update requires writable scalar changes',$row_path) unless keys %$values}
            }
            my $effective=$semantic eq 'auto'?($type eq 'insert'?'create':'update'):$semantic;
            my $grant=ref($spec->{write}) eq 'HASH'?$effective:$type eq 'insert'?'create':$type;
            _fail('write_operation_not_enabled','nested child operation is not allowed by relationship',$row_path,{operation=>$effective}) unless $allowed->{$grant};
            my $op=Selecto::Write::Operation->new($domain)->operation($type,$values)->filters($filters);
            my $compiled=Selecto::Write::PortableCommand->compile_flat($op,%{$state->{options}},context=>$state->{context});
            _fail('tenant_mismatch','nested child context differs from root context',$row_path) unless _json($compiled->{context}) eq _json($state->{context});
            my $command=$compiled->{command};
            my $metadata=$command->metadata;
            $metadata->{nested_graph}={relationship=>$relationship,path=>$row_path,strategy=>$strategy,identity_fields=>$fields,
                identity=>_identity($attrs,$fields),client_identity=>$entry->{client_identity},semantic_operation=>$effective,
                ownership=>$spec->{ownership},mutation_mode=>$mode,identity_mapping=>_true($spec->{output}{identity_mapping} // defined($spec->{client_identity}))?1:0};
            $command=$command->with_metadata($metadata);
            # Native IDs encode structural components rather than interpolated path text.
            $state->{generated}->consume_count('max_state_bytes',2*bytes::length($parent_id)+2*bytes::length($relationship)+32,label=>'generated native graph identities');
            my $id='nested:'._json([$parent_id,$relationship,$index]);
            my $node={id=>$id,command=>$command,bindings=>[{field=>$child_key,from=>$parent_id,key=>$parent_key}]};
            $state->{budget}->check_tree($node,label=>'cumulative lowered graph',allowed_classes=>[qw(Selecto::Write::Command Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement)]);
            _fail('invalid_graph','nested graph exceeds native node limit',$row_path) if @{$state->{nodes}}>=1000;
            push @{$state->{nodes}},$node;push @children,$id;
            $state->{internal_returning}{$id}=[@$fields,keys(%$child_nested)?(_primary($domain,$row_path)):()];
            _relationships($state,$child_contract,$child_nested,$type,$id,_primary($domain,$row_path),$row_path,$depth+1) if keys %$child_nested;
        }
        if ($delete_missing) {
            my $set={parent=>$parent_id,relationship=>$relationship,nodes=>\@children,delete_missing=>1};
            $state->{budget}->check_tree($set,label=>'cumulative owned sets');push @{$state->{owned_sets}},$set;
        }
        $state->{budget}->check_tree({path=>$path,strategy=>$strategy,identity_fields=>$fields,mutation_mode=>$mode,delete_missing=>$delete_missing?1:0},label=>'nested relationship metadata');
    }
}
sub compile {
    my ($class,$operation,%given)=@_;
    require Selecto::Write::PortableCommand;
    return Selecto::Write::PortableCommand->_with_field_validator_scope(sub {$class->_compile($operation,%given)});
}
sub _compile {
    my ($class,$operation,%given)=@_;
    require Selecto::Write::PortableCommand;
    my $snapshot=Selecto::Write::Operation::snapshot($operation);
    my %options=%given;my $resolver=delete $options{choice_membership_resolver};
    my $admitted=_copy(\%options);$admitted->{choice_membership_resolver}=$resolver if defined $resolver;
    _fail('invalid_choice_resolver','choice resolver must be trusted code',[]) if defined($resolver) && ref($resolver) ne 'CODE';
    my $contract=Selecto::Domain::WriteContract->compile($snapshot->{domain});
    _fail('invalid_graph','nested writes support insert and update',[]) unless ($snapshot->{type} // '') =~ /\A(?:insert|update)\z/;
    my ($flat,$nested)=_split($snapshot->{values},$contract,[]);
    _fail('invalid_graph','nested root update requires writable scalar changes',[]) if $snapshot->{type} eq 'update' && !keys %$flat;
    my $compiled=Selecto::Write::PortableCommand->compile_flat(_operation($operation,$snapshot,$flat),%$admitted);
    my $key=_primary($snapshot->{domain},[]);my $root=$compiled->{command};
    my $state={nodes=>[{id=>'root',command=>$root,bindings=>[]}],owned_sets=>[],context=>$compiled->{context},options=>$admitted,
        internal_returning=>{root=>[$key]},validation=>{limits=>Selecto::Limits->new,work=>0},generated=>Selecto::OperationBudget->new(code=>'invalid_graph'),budget=>Selecto::OperationBudget->new(code=>'invalid_graph')};
    $state->{budget}->check_tree($state->{nodes}[0],label=>'lowered root',allowed_classes=>[qw(Selecto::Write::Command Selecto::Expression Selecto::Write::Expression Selecto::QueryEnforcement)]);
    _relationships($state,$contract,$nested,$snapshot->{type},'root',$key,[],1);
    my $metadata={contract_fingerprint=>$contract->{fingerprint},root_returning=>$snapshot->{returning} // 'none',
        membership_parent_lock=>$snapshot->{type} eq 'update'?{parent_key=>$key}:undef};
    my $graph=Selecto::Write::Graph->new(nodes=>$state->{nodes},owned_sets=>$state->{owned_sets},metadata=>$metadata);
    # Preserve the portable compiled projection, after Graph privately captures
    # caller-visible intent. Native Engine governance discards these preview
    # keys, rechecks public policy, then derives its own binding/owned-sync keys.
    for my $node (@{$graph->{nodes}}) {
        $node->{command}=_returning($node->{command},$state->{internal_returning}{$node->{id}} // []);
    }
    return {command=>$graph,context=>_copy($state->{context})};
}
1;

__END__

=head1 NAME

Selecto::Write::NestedGraph - declared relationship mutation lowering

=head1 DESCRIPTION

C<compile($operation, %trusted_options)> compiles complete bounded portable
insert/update intent into native graph commands and generated foreign-key
bindings. Relationship ownership, allowed semantic operations, mutation modes,
stable identity, collection bounds and validation are checked before dispatch.
Full-set updates retain explicit owned-set cleanup. Each child uses its own
complete write contract. Command metadata describes the lowering; configured
native Engine governance remains authoritative for every row and cleanup.

No adapter, SQL or connection is used by this compiler. Stored prospective
collection rules are enforced by the native engine's whole-graph admission.
Compilation cannot supply stored state or authorize a write.

=cut
