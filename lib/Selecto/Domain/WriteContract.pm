package Selecto::Domain::WriteContract;

use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use JSON::PP ();
use Scalar::Util qw(blessed reftype);
use Selecto::Domain::QueryContract ();
use Selecto::Domain::SourceRelationships ();
use Selecto::OperationBudget ();
use Selecto::Error ();

my %OP = map { $_ => 1 } qw(insert update delete upsert);
my @FLAGS = qw(insertable updatable immutable write_once server_managed);
my @OWNERSHIP = qw(composition shared_association join_association derived deferred owned shared_reference join_only);
my @MODES = qw(append_only delta full_set replace_one link_delta);
my @MUTATIONS = qw(create update delete reorder link unlink);
my @OMISSION = qw(unchanged delete_missing reject_missing retain_missing);
my @TENANT = qw(recursive membership explicit none);
sub _copy {
    my ($value) = @_;
    my $copy = eval { Selecto::Domain::QueryContract->copy_declaration($value) };
    if (my $error = $@) {
        die $error unless blessed($error) && ref($error) eq 'Selecto::Error';
        Selecto::Error->throw('invalid_write_contract', 'write contract requires bounded plain metadata');
    }
    return $copy;
}
sub _string { defined($_[0]) && !defined(reftype($_[0])) && (B::svref_2object(\$_[0])->FLAGS & B::SVp_POK()) }
sub _id { _string($_[0]) && $_[0] =~ /\S/ }
sub _bool { ref($_[0]) eq 'JSON::PP::Boolean' }
sub _true { _bool($_[0]) && ${$_[0]} == 1 }
sub _integer {
    return 0 if !defined($_[0]) || defined(reftype($_[0]));
    my $flags = B::svref_2object(\$_[0])->FLAGS;
    return ($flags & B::SVp_IOK()) && !($flags & B::SVp_POK());
}
sub _enum { my ($value, @allowed) = @_; return _string($value) && grep { $value eq $_ } @allowed }
sub _boolean { my $value = $_[0] ? 1 : 0; return bless \$value, 'JSON::PP::Boolean' }
sub _work { $_[0]{work}->consume_count('max_expression_nodes', $_[1] // 1, label => 'write contract work') }
sub _error {
    my ($state, $code, $path, %details) = @_;
    my $error = {code => $code, path => $path, message => 'invalid portable write declaration', %details};
    $state->{output}->check_tree($error, label => 'write diagnostics');
    push @{$state->{errors}}, $error;
}
sub _object {
    my ($state, $value, $path, $code) = @_;
    return $value if ref($value) eq 'HASH';
    _error($state, $code // 'invalid_section_shape', $path, expected => 'object');
    return {};
}
sub _optional_bool {
    my ($state, $spec, $key, $path, $code) = @_;
    _error($state, $code, [@$path, $key]) if defined($spec->{$key}) && !_bool($spec->{$key});
}
sub _known {
    my ($state, $field) = @_;
    return _string($field) && exists($state->{fields}{$field});
}
sub _unsafe {
    my ($state, $value) = @_;
    _work($state);
    if (ref($value) eq 'ARRAY') {
        return 1 if @$value && _enum($value->[0], qw(unsafe_sql unsafe_fragment));
        return 1 if grep { _unsafe($state, $_) } @$value;
    } elsif (ref($value) eq 'HASH') {
        return 1 if grep { _unsafe($state, $value->{$_}) } keys %$value;
    }
    return 0;
}
sub _relation_fields {
    my ($state, $relation, $path) = @_;
    unless (ref($relation) eq 'HASH') { _error($state, 'invalid_section_shape', $path); return {} }
    _error($state, 'missing_required_keys', $path, keys => [grep { !exists $relation->{$_} } qw(primary_key fields columns)])
        if grep { !exists $relation->{$_} } qw(primary_key fields columns);
    my $columns = _object($state, $relation->{columns}, [@$path, 'columns']);
    my $fields = $relation->{fields};
    _error($state, 'invalid_fields', [@$path, 'fields'])
        unless ref($fields) eq 'ARRAY' && !grep { !_string($_) } @$fields;
    my %known = map { $_ => 1 } keys %$columns;
    if (ref($fields) eq 'ARRAY') {
        for my $field (@$fields) {
            _work($state);
            next unless _string($field);
            $known{$field} = 1;
            _error($state, 'source_field_missing_column', [@$path, 'columns', $field]) unless exists $columns->{$field};
        }
    }
    for my $field (sort keys %$columns) {
        _work($state);
        _object($state, $columns->{$field}, [@$path, 'columns', $field], 'invalid_column_definition');
    }
    return \%known;
}
sub _normalize {
    my ($state, $domain) = @_;
    my $source = ref($domain->{source}) eq 'HASH' ? $domain->{source} : {};
    return $domain if exists($domain->{writes}) && ref($domain->{writes}) ne 'HASH';
    my $writes = $domain->{writes} //= {};
    for my $pair (['columns', 'fields'], ['associations', 'relationships']) {
        my ($from, $to) = @$pair;
        next unless ref($source->{$from}) eq 'HASH';
        for my $id (sort keys %{$source->{$from}}) {
            _work($state);
            my $entry = $source->{$from}{$id};
            next unless ref($entry) eq 'HASH' && exists $entry->{write};
            my $spec = delete $entry->{write};
            if ($to eq 'relationships' && ref($spec) eq 'HASH') {
                for my $pair (['cardinality','cardinality'], ['parent_key','owner_key'], ['child_key','related_key']) {
                    $spec->{$pair->[0]} = $entry->{$pair->[1]}
                        if !exists($spec->{$pair->[0]}) && defined($entry->{$pair->[1]});
                }
            }
            $writes->{$to} = {} unless exists $writes->{$to};
            next unless ref($writes->{$to}) eq 'HASH';
            if (exists $writes->{$to}{$id}) {
                delete $writes->{$to}{$id};
                _error($state, 'duplicate_write_authoring', ['source', $from, $id, 'write'],
                    canonical_path => ['writes', $to, $id]);
            } else { $writes->{$to}{$id} = $spec }
        }
    }
    return $domain;
}
sub _new_state {
    my ($given) = @_;
    my $raw = _copy($given);
    my $state = {errors => [], output => Selecto::OperationBudget->new(code => 'invalid_write_contract'),
        work => Selecto::OperationBudget->new(code => 'invalid_write_contract')};
    # This boundary consumes the complete plain declaration. Callers passing
    # normalize() output explicitly select its domain; unrelated authored keys
    # never replace the supplied source or write policy.
    $state->{domain} = _normalize($state, $raw);
    return $state;
}
sub _operations {
    my ($state, $writes) = @_;
    return unless defined $writes->{operations};
    my $operations = _object($state, $writes->{operations}, ['writes','operations']);
    for my $id (sort keys %$operations) {
        _work($state);
        my $path = ['writes','operations',$id];
        _error($state, 'unknown_write_operation', $path) unless $OP{$id};
        my $spec = _object($state, $operations->{$id}, $path, 'invalid_write_operation_spec');
        _optional_bool($state, $spec, $_, $path, 'invalid_write_operation_option') for qw(enabled bulk require_filter);
        if (defined(my $cardinality = $spec->{expected_cardinality})) {
            my $valid = _enum($cardinality, 'many');
            if (ref($cardinality) eq 'ARRAY' && @$cardinality >= 2 && _string($cardinality->[0])) {
                my ($kind, $a, $b) = @$cardinality;
                $valid = @$cardinality == 2 && _integer($a)
                    && (($kind eq 'exactly' && $a > 0) || ($kind =~ /\A(?:at_most|at_least)\z/ && $a >= 0));
                $valid ||= @$cardinality == 3 && $kind eq 'between' && _integer($a) && _integer($b) && $a >= 0 && $b >= $a;
            }
            _error($state, 'invalid_write_cardinality', [@$path,'expected_cardinality']) unless $valid;
        }
        if (defined(my $fields = $spec->{fields})) {
            if (ref($fields) ne 'ARRAY') { _error($state,'invalid_write_operation_fields',[@$path,'fields']) }
            else { for my $field (@$fields) { _work($state); _error($state,'write_operation_field_not_found',[@$path,'fields'],field=>$field) unless _known($state,$field) } }
        }
        _error($state,'unsafe_write_fragment',$path) if _unsafe($state,$spec);
    }
}
sub _fields {
    my ($state, $writes) = @_;
    return unless defined $writes->{fields};
    my $fields = _object($state,$writes->{fields},['writes','fields']);
    for my $field (sort keys %$fields) {
        _work($state);
        my $path=['writes','fields',$field];
        _error($state,'write_field_not_found',$path,field=>$field) unless _known($state,$field);
        my $spec=_object($state,$fields->{$field},$path,'invalid_write_field_spec');
        _optional_bool($state,$spec,$_,$path,'invalid_write_field_option') for @FLAGS;
        _error($state,'unsafe_write_fragment',$path) if _unsafe($state,$spec);
    }
}
sub _scope {
    my ($state,$writes)=@_;
    my $scope = defined($writes->{scopes}) ? $writes->{scopes} : $writes->{scope};
    return unless defined $scope;
    $scope=_object($state,$scope,['writes','scope']);
    return unless defined $scope->{tenant};
    my $tenant=_object($state,$scope->{tenant},['writes','scope','tenant'],'invalid_tenant_scope');
    _optional_bool($state,$tenant,'required',['writes','scope','tenant'],'invalid_tenant_required');
    _error($state,'tenant_scope_field_not_found',['writes','scope','tenant','field'])
        if defined($tenant->{field}) && !_known($state,$tenant->{field});
    _error($state,'unsafe_write_fragment',['writes','scope','tenant']) if _unsafe($state,$tenant);
}
sub _rel_error { _error($_[0],'invalid_write_relationship_option',$_[1]) }
sub _policy {
    my ($state,$policy,$path,$booleans,$integers,$enums)=@_;
    _optional_bool($state,$policy,$_,$path,'invalid_write_relationship_option') for @$booleans;
    for my $key (sort keys %$integers) {
        next unless defined $policy->{$key};
        _rel_error($state,[@$path,$key]) unless _integer($policy->{$key}) && $policy->{$key} >= $integers->{$key};
    }
    for my $key (sort keys %$enums) {
        _rel_error($state,[@$path,$key]) if defined($policy->{$key}) && !_enum($policy->{$key},@{$enums->{$key}});
    }
    _rel_error($state,[@$path,'max_items']) if _integer($policy->{min_items}) && _integer($policy->{max_items}) && $policy->{max_items} < $policy->{min_items};
}
sub _relationship {
    my ($state,$id,$value)=@_;
    my $path=['writes','relationships',$id];
    my $spec=_object($state,$value,$path,'invalid_write_relationship');
    _policy($state,$spec,$path,[qw(enabled writable delete_missing)],{}, {cardinality=>[qw(one many)],ownership=>\@OWNERSHIP,strategy=>['sync']});
    if (defined(my $ops=$spec->{allowed_ops})) {
        if (ref($ops) ne 'ARRAY') { _rel_error($state,[@$path,'allowed_ops']) }
        else { for my $op (@$ops) { _work($state); _error($state,'invalid_write_relationship_operation',[@$path,'allowed_ops']) unless _enum($op,sort keys %OP) } }
    }
    if (defined(my $fields=$spec->{identity_fields})) {
        _rel_error($state,[@$path,'identity_fields']) unless ref($fields) eq 'ARRAY' && @$fields && !grep { !_string($_) } @$fields;
    }
    _rel_error($state,[@$path,$_]) for grep { defined($spec->{$_}) && !_string($spec->{$_}) } qw(child_key parent_key);
    _rel_error($state,[@$path,'domain']) if defined($spec->{domain}) && ref($spec->{domain}) ne 'HASH';
    _rel_error($state,[@$path,'path_id']) if defined($spec->{path_id}) && !_id($spec->{path_id});
    if (defined $spec->{read}) {
        my $read=_object($state,$spec->{read},[@$path,'read'],'invalid_write_relationship_option');
        _policy($state,$read,[@$path,'read'],['allowed'],{default_depth=>0,max_depth=>1,max_rows=>1,max_bytes=>1,max_complexity=>1},{});
    }
    my $write=$spec->{write};
    if (defined $write) {
        $write=_object($state,$write,[@$path,'write'],'invalid_write_relationship_option');
        _policy($state,$write,[@$path,'write'],\@MUTATIONS,{min_items=>0,max_items=>1,max_mutations=>1},{omission=>\@OMISSION});
        if (defined(my $modes=$write->{modes})) {
            _rel_error($state,[@$path,'write','modes']) unless ref($modes) eq 'ARRAY' && @$modes && !grep { !_enum($_,@MODES) } @$modes;
        }
    } else { _policy($state,$spec,$path,[],{min_items=>0,max_items=>1},{}) }
    if (defined $spec->{capabilities}) {
        my $caps=_object($state,$spec->{capabilities},[@$path,'capabilities'],'invalid_write_relationship_option');
        for my $op (sort keys %$caps) { _work($state); _rel_error($state,[@$path,'capabilities',$op]) unless _id($op) && _id($caps->{$op}) }
    }
    if (defined(my $tenant=$spec->{tenant_scope})) {
        if (ref($tenant) eq 'HASH') { _policy($state,$tenant,[@$path,'tenant_scope'],[],{},{mode=>\@TENANT}) }
        else { _rel_error($state,[@$path,'tenant_scope']) unless _enum($tenant,@TENANT) }
    }
    for my $key (qw(ordering conflict idempotency offline validation assurance output)) {
        _rel_error($state,[@$path,$key]) if defined($spec->{$key}) && ref($spec->{$key}) ne 'HASH';
    }
    my $modes = ref($write) eq 'HASH' && ref($write->{modes}) eq 'ARRAY' ? $write->{modes} : [];
    if (_true($spec->{writable}) || _true($spec->{enabled}) || @$modes) {
        _error($state,'missing_write_relationship_policy',[@$path,$_]) for grep { !defined($spec->{$_}) } qw(cardinality ownership);
    }
    _semantics($state,$spec,$write,$path) if ref($spec->{write}) eq 'HASH';
    _error($state,'unsafe_write_fragment',$path) if _unsafe($state,$spec);
}
sub _semantics {
    my ($state,$spec,$write,$path)=@_;
    my $ownership=_string($spec->{ownership}) ? $spec->{ownership} : '';
    $ownership={owned=>'composition',shared_reference=>'shared_association',join_only=>'join_association'}->{$ownership}//$ownership;
    my @modes=ref($write->{modes}) eq 'ARRAY' ? grep { _enum($_,@MODES) } @{$write->{modes}} : ();
    my @ops=grep { _true($write->{$_}) } @MUTATIONS;
    if (ref($spec->{allowed_ops}) eq 'ARRAY') {
        my %mapping=(insert=>'create',update=>'update',delete=>'delete',nested_insert=>'create',nested_update=>'update');
        push @ops,map { $mapping{$_} } grep { _string($_) && $mapping{$_} } @{$spec->{allowed_ops}};
    }
    my $shared=$ownership eq 'shared_association'||$ownership eq 'join_association';
    _error($state,'shared_relationship_target_mutation',[@$path,'write']) if $shared && grep { /\A(?:create|update|delete)\z/ } @ops;
    _error($state,'read_only_relationship_mutation',[@$path,'write']) if $ownership eq 'derived' && (@modes||@ops);
    if (!$shared && grep { $_ eq 'link_delta' } @modes) { _error($state,'invalid_link_delta_ownership',[@$path,'write','modes']) }
    elsif ($shared && grep { $_ ne 'link_delta' } @modes) { _error($state,'invalid_association_mutation_mode',[@$path,'write','modes']) }
    _error($state,'invalid_relationship_cardinality_mode',[@$path,'write','modes'])
        if (_enum($spec->{cardinality},'one') && (grep { $_ eq 'append_only'||$_ eq 'full_set' } @modes))
            || (_enum($spec->{cardinality},'many') && (grep { $_ eq 'replace_one' } @modes));
    my $identities=ref($spec->{identity_fields}) eq 'ARRAY' ? $spec->{identity_fields} : defined($spec->{identity_fields}) ? [$spec->{identity_fields}] : [];
    _error($state,'nested_identity_required',[@$path,'identity_fields'])
        if !@$identities && ((grep { /\A(?:delta|full_set|replace_one|link_delta)\z/ } @modes) || (grep { /\A(?:update|delete|link|unlink)\z/ } @ops));
    _error($state,'nested_omission_policy_required',[@$path,'write','omission'])
        if !defined($write->{omission}) && !defined($spec->{delete_missing}) && grep { $_ eq 'full_set' } @modes;
    my $read=$spec->{read};
    _error($state,'nested_read_bounds_required',[@$path,'read'])
        if ref($read) eq 'HASH' && _true($read->{allowed}) && (!defined($read->{max_depth})||!defined($read->{max_rows}));
    my $offline=$spec->{offline};
    _error($state,'offline_nested_controls_required',[@$path,'offline'])
        if ref($offline) eq 'HASH' && _true($offline->{eligible}) && @modes && (ref($spec->{idempotency}) ne 'HASH'||ref($spec->{conflict}) ne 'HASH');
}
sub _constraints {
    my ($state,$writes)=@_;
    my $constraints=$writes->{constraints};
    return unless defined $constraints;
    return if ref($constraints) eq 'ARRAY';
    $constraints=_object($state,$constraints,['writes','constraints']);
    if (defined $constraints->{optimistic_lock}) {
        my $lock=_object($state,$constraints->{optimistic_lock},['writes','constraints','optimistic_lock'],'invalid_optimistic_lock');
        _error($state,'optimistic_lock_field_not_found',['writes','constraints','optimistic_lock','field']) unless _known($state,$lock->{field});
    }
    if (defined $constraints->{foreign_keys}) {
        my $keys=_object($state,$constraints->{foreign_keys},['writes','constraints','foreign_keys'],'invalid_foreign_keys');
        for my $field (sort keys %$keys) {
            _work($state);
            my $path=['writes','constraints','foreign_keys',$field];
            unless (_known($state,$field)) { _error($state,'foreign_key_field_not_found',$path); next }
            unless (ref($keys->{$field}) eq 'HASH') { _error($state,'invalid_foreign_key_constraint',$path); next }
            my $spec=$keys->{$field};my $source=$spec->{source};
            my $context=ref($source) eq 'ARRAY' && @$source==2 && _enum($source->[0],'context') && _string($source->[1]) && length($source->[1])
                || ref($source) eq 'HASH' && _enum($source->{kind},'context') && _string($source->{key}) && length($source->{key});
            _error($state,defined($source)?'invalid_foreign_key_source':'missing_foreign_key_source',[@$path,'source']) unless _enum($source,'input')||$context;
            my $reference=$spec->{references};
            if (ref($reference) ne 'HASH') { _error($state,'missing_foreign_key_reference',[@$path,'references']) }
            elsif (!_id($reference->{relation})||!_string($reference->{field})) { _error($state,'invalid_foreign_key_reference',[@$path,'references']) }
            else { _foreign_tenant($state,$reference,$path) }
            _optional_bool($state,$spec,'required',$path,'invalid_foreign_key_required');
        }
    }
    _error($state,'unsafe_write_fragment',['writes','constraints']) if _unsafe($state,$constraints);
}
sub _foreign_tenant {
    my ($state,$reference,$path)=@_;
    my $field=$reference->{tenant_field};
    return if !defined($field) || _bool($field) && !$$field;
    unless (_id($field)) { _error($state,'invalid_foreign_key_tenant_field',[@$path,'references','tenant_field']); return }
    my $raw=$state->{domain};my $schemas=ref($raw->{schemas}) eq 'HASH'?$raw->{schemas}:{};
    my @relations=([undef,$raw->{source}],map {[$_,$schemas->{$_}]} sort keys %$schemas);
    for my $entry (@relations) {
        _work($state);
        my ($id,$relation)=@$entry;next unless ref($relation) eq 'HASH';
        my $table=$relation->{source_table}//$relation->{table}//$id;
        next unless _string($table)&&$table eq $reference->{relation};
        my $fields=ref($relation->{fields}) eq 'ARRAY'?$relation->{fields}:[];
        my $columns=ref($relation->{columns}) eq 'HASH'?$relation->{columns}:{};
        _error($state,'unknown_foreign_key_tenant_field',[@$path,'references','tenant_field'])
            unless exists($columns->{$field})||grep {_string($_)&&$_ eq $field} @$fields;
    }
}
sub _transitions {
    my ($state,$writes)=@_;
    return unless defined $writes->{transitions};
    my $transitions=_object($state,$writes->{transitions},['writes','transitions']);
    for my $field (sort keys %$transitions) {
        _work($state);my $path=['writes','transitions',$field];
        _error($state,'transition_field_not_found',$path) unless _known($state,$field);
        my $graph=_object($state,$transitions->{$field},$path);
        for my $from (sort keys %$graph) {
            _work($state);my $targets=$graph->{$from};
            if (ref($targets) ne 'ARRAY') { _error($state,'invalid_transition_targets',[@$path,$from]); next }
            for my $i (0..$#$targets) { _work($state);_error($state,'invalid_transition_state',[@$path,$from,$i]) unless _string($targets->[$i]) }
        }
    }
}
sub _validate {
    my ($state)=@_;my $raw=$state->{domain};
    my $source=_object($state,$raw->{source},['source']);
    _error($state,'missing_required_keys',['source'],keys=>['source_table']) unless exists $source->{source_table};
    $state->{root_fields}=_relation_fields($state,$source,['source']);
    my $schemas=_object($state,$raw->{schemas},['schemas']);
    _relation_fields($state,$schemas->{$_},['schemas',$_]) for sort keys %$schemas;
    my $fields=Selecto::Domain::SourceRelationships->declared_field_ids($raw);
    $state->{fields}={map {$_=>1} @$fields};
    my $writes=_object($state,$raw->{writes},['writes']);
    _operations($state,$writes);_fields($state,$writes);_scope($state,$writes);
    if (defined $writes->{relationships}) {
        my $relationships=_object($state,$writes->{relationships},['writes','relationships']);
        for my $id(sort keys %$relationships) { _work($state);_relationship($state,$id,$relationships->{$id}) }
    }
    _constraints($state,$writes);_transitions($state,$writes);
    return $state;
}
sub normalize {
    my ($class,$given)=@_;my $state=_new_state($given);
    return _copy({domain=>$state->{domain},errors=>$state->{errors},warnings=>[]});
}
sub validate {
    my ($class,$given)=@_;my $state=_validate(_new_state($given));
    return _copy({valid=>_boolean(!@{$state->{errors}}),errors=>$state->{errors},warnings=>[]});
}
sub compile {
    my ($class,$given)=@_;my $state=_validate(_new_state($given));
    Selecto::Error->throw('invalid_domain','domain write declaration failed validation',{errors=>$state->{errors}}) if @{$state->{errors}};
    my $raw=$state->{domain};my $writes=$raw->{writes};my $operations=$writes->{operations};
    Selecto::Error->throw('write_policy_missing','domain declares no writes.operations',{required=>['writes','operations']})
        unless ref($operations) eq 'HASH'&&keys %$operations;
    my $fields=$writes->{fields}//{};
    Selecto::Error->throw('invalid_domain','writes.fields must be a map') unless ref($fields) eq 'HASH';
    for my $field(sort keys %$fields) {
        _work($state);Selecto::Error->throw('invalid_domain','write field is not defined on the source relation',{field=>$field}) unless $state->{root_fields}{$field};
    }
    my $scope=defined($writes->{scopes})?$writes->{scopes}:$writes->{scope}//{};
    if (defined $scope->{tenant}) {
        my $tenant=$scope->{tenant};
        Selecto::Error->throw('invalid_domain','tenant scope must explicitly be required') unless _true($tenant->{required});
        Selecto::Error->throw('invalid_domain','tenant scope field must exist on the source relation') unless _string($tenant->{field})&&$state->{root_fields}{$tenant->{field}};
    }
    my $contract={source=>$raw->{source},operations=>{map {$_=>$operations->{$_}} grep {_true($operations->{$_}{enabled})} sort keys %$operations},
        fields=>$fields,scope=>$scope,relationships=>$writes->{relationships}//{},constraints=>$writes->{constraints}//{},
        transitions=>$writes->{transitions}//{},rules=>$raw->{rules}//{},fingerprint=>$raw->{domain_fingerprint},fields_declared=>_boolean(keys %$fields)};
    $state->{output}->check_tree($contract,label=>'compiled write contract');
    return _copy($contract);
}
sub _access {
    my ($given, %args) = @_;
    my $copy = _copy({contract => $given, %args});
    Selecto::Error->throw('invalid_write_contract', 'compiled write contract must be a plain object')
        unless ref($copy->{contract}) eq 'HASH';
    return $copy;
}
sub operation_enabled {
    my ($class, $given, $operation) = @_;
    my $copy = _access($given, operation => $operation);
    $operation = $copy->{operation};
    my $operations = $copy->{contract}{operations};
    return _boolean(_string($operation) && ref($operations) eq 'HASH'
        && ref($operations->{$operation}) eq 'HASH' && _true($operations->{$operation}{enabled}));
}
sub field_spec {
    my ($class, $given, $field) = @_;
    my $copy = _access($given, field => $field);
    $field = $copy->{field};
    my $fields = $copy->{contract}{fields};
    return undef unless _string($field) && ref($fields) eq 'HASH' && exists $fields->{$field};
    return $fields->{$field};
}
sub writable {
    my ($class, $given, $operation, $field) = @_;
    my $copy = _access($given, operation => $operation, field => $field);
    $operation = $copy->{operation};
    return _boolean(0) unless _enum($operation, qw(insert upsert update));
    my $spec = $class->field_spec($copy->{contract}, $copy->{field});
    return _boolean(ref($spec) eq 'HASH' && _true($spec->{$operation eq 'update' ? 'updatable' : 'insertable'}));
}
sub require_write_policy {
    my ($class, $given, $operation) = @_;
    my $copy = _access($given, operation => $operation);
    return 1 if _enum($copy->{operation}, 'delete') || _true($copy->{contract}{fields_declared});
    Selecto::Error->throw('write_policy_missing', 'domain declares no writes.fields',
        {operation => $copy->{operation}, required => ['writes', 'fields']});
}
sub foreign_keys {
    my ($class, $given) = @_;
    my $copy = _access($given)->{contract};
    return {} unless ref($copy->{constraints}) eq 'HASH' && ref($copy->{constraints}{foreign_keys}) eq 'HASH';
    return $copy->{constraints}{foreign_keys};
}

1;

__END__

=head1 NAME

Selecto::Domain::WriteContract - bounded explicit portable write metadata

=head1 METHODS

C<normalize($plain_domain)> returns an independent C<domain>, C<errors>, and
C<warnings>. Only explicit colocated C<write> declarations relocate to the
canonical fields/relationships registries. Duplicate declarations are removed
and diagnosed rather than merged. Association keys may supply declared
cardinality/parent/child metadata, never mutation or ownership grants.

C<validate($plain_domain)> reports canonical Boolean C<valid> and structured
C<errors>/C<warnings> for operations, fields, tenant scope, relationship shapes
and nested semantics, constraints/foreign-key metadata and transitions.
C<compile($plain_domain)> returns a plain independent contract snapshot or a
C<Selecto::Error>. A nonempty declared operation registry is required; only
explicitly true enabled operations survive. Assignment fields and required
tenant scope must belong to the actual root. No read structure or catalog
introspection grants writes. Deletes can compile without fields;
C<require_write_policy($snapshot,$operation)> refuses other operations until
fields are declared. C<operation_enabled>, C<field_spec>, C<writable>, and
C<foreign_keys> expose copied metadata. C<writable> reports the explicit grant;
consumers must separately enforce immutable/write_once/server_managed narrowing.

The complete input is callback-free, tie-free bounded plain metadata before
copying or interpretation. Strict portable Boolean flags accept canonical JSON
booleans, not numeric/string truthiness. Generated diagnostics, field inventory,
work and output are bounded. Snapshots retain original operation/field specs,
complete scope/relationship/constraint/transition and rule metadata. Rule/native
execution, SQL returning/conflict/unique enforcement and catalogs remain separate
consumer boundaries. Existing native Domain.parse and legacy write behavior are
unchanged; this metadata API never invokes their getters or dispatches SQL.

=cut
