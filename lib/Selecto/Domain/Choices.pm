package Selecto::Domain::Choices;
use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use Scalar::Util qw(reftype);
use Selecto::Domain::QueryContract ();
use Selecto::Domain::ChoiceSources ();
use Selecto::Domain::StaticFilters ();
use Selecto::Domain::Choices::Result ();
use Selecto::Domain::Choices::OptionsResult ();
use Selecto::Error ();
use Selecto::OperationBudget ();

sub _copy {Selecto::Domain::QueryContract->copy_declaration($_[0])}
sub _string {Selecto::Domain::StaticFilters->string($_[0])}
sub _error {Selecto::Error->throw($_[0],$_[1],$_[2]//{})}
sub _domain {
    my($given)=@_;my$domain=_copy($given);
    $domain=$domain->{domain} if exists($domain->{authored_domain})&&ref($domain->{domain})eq'HASH';
    my$report=Selecto::Domain::ChoiceSources->validate($domain);
    _error('invalid_domain_contract','choice source domain declaration is invalid',{errors=>$report->{errors}})unless${$report->{valid}};
    return$domain;
}
sub _binding {
    my($domain,$field)=@_;
    _error('invalid_choice_field','choice field must be a string')unless _string($field);
    my$source=$domain->{source}{columns}//{};my$projection=ref($domain->{columns})eq'HASH'?$domain->{columns}:{};
    my($column,$path);
    if(ref($source->{$field})eq'HASH'){$column=$source->{$field};$path=['source','columns',$field]}
    unless($column){
        my$found=_join_column($domain,$domain->{source},$domain->{joins}//{},'',$field,
            Selecto::OperationBudget->new(code=>'invalid_choice_request'));
        if($found){
            _error('field_not_found','choice field is absent or ambiguous in its declared join',{field=>$field,path=>[$field]})
                unless $found->{column};
            ($column,$path)=@{$found}{qw(column path)};
        }
    }
    if(!$column&&$field=~/\A([^.]+)\.(.+)\z/s){
        my($schema,$id)=($1,$2);my$spec=$domain->{schemas}{$schema};
        if(ref($spec)eq'HASH'&&ref($spec->{columns})eq'HASH'&&ref($spec->{columns}{$id})eq'HASH'){
            $column=$spec->{columns}{$id};$path=['schemas',$schema,'columns',$id];
        }
    }
    my$projected=ref($projection->{$field})eq'HASH'?$projection->{$field}:{};
    if($column){$column={%$column,%$projected}}
    elsif(keys%$projected){$column=$projected;$path=['columns',$field]}
    else{_error('field_not_found','choice field is not declared',{field=>$field,path=>[$field]})}
    my$reference=ref($column->{reference})eq'HASH'?$column->{reference}:{};
    my($choice,$kind);
    if(_string($reference->{choice_source})){($choice,$kind)=($reference->{choice_source},'reference')}
    elsif(_string($column->{choice_source})){($choice,$kind)=($column->{choice_source},'choice_source')}
    else{_error('field_choice_source_not_bound','choice field has no choice source binding',{field=>$field,path=>[$field,'choice_source']})}
    return _copy({field=>$field,path=>$path,column=>$column,choice_source=>$choice,binding_kind=>$kind,reference=>$reference});
}
sub _join_column {
    my($domain,$relation,$joins,$prefix,$field,$budget)=@_;
    my$state={local=>[]};
    _join_candidates($domain,$relation,$joins,$prefix,$field,$budget,$state);
    return$state->{full} if$state->{full};
    return unless@{$state->{local}};
    return@{$state->{local}}==1?$state->{local}[0]:{column=>undef};
}
sub _join_candidates {
    my($domain,$relation,$joins,$prefix,$field,$budget,$state)=@_;
    return unless ref($relation)eq'HASH'&&ref($joins)eq'HASH';
    my$associations=ref($relation->{associations})eq'HASH'?$relation->{associations}:{};
    for my$id(sort keys%$joins){
        $budget->consume_count('max_expression_nodes',1,label=>'choice join resolution');
        my$join=$joins->{$id};my$a=$associations->{$id};
        next unless ref($join)eq'HASH'&&ref($a)eq'HASH'&&_string($a->{queryable});
        my$target=$a->{queryable}eq'source'?$domain->{source}:$domain->{schemas}{$a->{queryable}};
        next unless ref($target)eq'HASH';
        my$source_path=$a->{queryable}eq'source'?['source']:['schemas',$a->{queryable}];
        # Bound prefix occurrences before concatenating another alias.
        {use bytes;$budget->consume_count('max_state_bytes',length($prefix)+2*length($id)+length($field)+2,label=>'choice alias resolution bytes')}
        my$alias=$prefix.$id.'.';
        my$columns=ref($target->{columns})eq'HASH'?$target->{columns}:{};
        if(index($field,$alias)==0){
            my$local=substr($field,length($alias));
            if(!$state->{full}||length($alias)>$state->{full}{prefix_length}){
                $state->{full}={column=>ref($columns->{$local})eq'HASH'?$columns->{$local}:undef,
                    path=>[@$source_path,'columns',$local],prefix_length=>length($alias)};
            }
        }
        if(length($prefix)&&index($field,$id.'.')==0){
            my$local=substr($field,length($id)+1);
            push@{$state->{local}},{column=>ref($columns->{$local})eq'HASH'?$columns->{$local}:undef,
                path=>[@$source_path,'columns',$local]};
        }
        _join_candidates($domain,$target,$join->{joins},$alias,$field,$budget,$state);
    }
    return;
}
sub binding {my($class,$given,$field)=@_;my$input=_copy({domain=>$given,field=>$field});_binding(_domain($input->{domain}),$input->{field})}
sub _policy {
    my($value)=@_;return{}unless ref($value)eq'HASH';my%policy;
    for my$key(qw(source_relationship choice_source domain_of_interest)){
        my$v=$value->{$key};$policy{$key}=$v if _string($v)&&$v=~/\A(?:best_effort|fail_closed)\z/;
    }
    return\%policy;
}
sub _map_attr {
    my($attrs,$key)=@_;my$value=$attrs->{$key}//{};
    _error('invalid_choice_request',"choice request $key must be an object")unless ref($value)eq'HASH';return$value;
}
sub _list_attr {
    my($attrs,$key)=@_;my$value=$attrs->{$key}//[];
    _error('invalid_choice_request',"choice request $key must be an array")unless ref($value)eq'ARRAY';return$value;
}
sub _integer {
    my($value,$minimum)=@_;return defined($value)&&!defined(reftype($value))
        &&(B::svref_2object(\$value)->FLAGS&B::SVf_IOK())&&$value>=$minimum;
}
sub _request {
    my($domain,$target,$value,$attrs,$options,$direct)=@_;
    my$binding=$direct?{}:_binding($domain,$target);my$choice=$direct?$target:$binding->{choice_source};
    _error('invalid_choice_request','choice source identity must be a string')unless _string($choice);
    my$config=$domain->{choice_sources}{$choice};
    _error('choice_source_not_found','choice source is not declared',{choice_source=>$choice,path=>['choice_sources',$choice]})unless ref($config)eq'HASH';
    my$relationship=$config->{source_relationship};my$relation;
    if(defined$relationship){
        $relation=$domain->{source_relationships}{$relationship};
        _error('source_relationship_not_found','choice source relationship is not declared',{source_relationship=>$relationship})unless ref($relation)eq'HASH';
    }
    my$filters=_list_attr($attrs,'filters');
    my$policy={%{_policy($config->{constraint_policy})},%{_policy($attrs->{constraint_policy})}};
    my$request={domain=>$domain->{name},field=>$direct?undef:$binding->{field},
        choice_source=>$choice,choice_source_config=>$config,source_relationship=>$relationship,
        source_relationship_config=>$relation,field_binding=>$binding,reference=>$binding->{reference}//{},
        actor=>$attrs->{actor},tenant=>$attrs->{tenant},record=>_map_attr($attrs,'record'),context=>_map_attr($attrs,'context'),
        filters=>$filters,constraint_policy=>$policy,metadata=>_map_attr($attrs,'metadata'),
        constraint_filters=>{source_relationship=>$relation?($relation->{filters}//[]):[],choice_source=>$config->{filters}//[],domain_of_interest=>$filters}};
    if($options){
        my$search=$attrs->{search};my$limit=$attrs->{limit};my$offset=$attrs->{offset}//0;
        _error('invalid_choice_request','choice options search must be a string or null')if defined($search)&&!_string($search);
        _error('invalid_choice_request','choice options limit must be a positive integer or null')if defined($limit)&&!_integer($limit,1);
        _error('invalid_choice_request','choice options offset must be a non-negative integer')unless _integer($offset,0);
        @{$request}{qw(search limit offset cursor order_by)}=($search,$limit,$offset,$attrs->{cursor},_list_attr($attrs,'order_by'));
    }else{$request->{value}=$value}
    return _copy($request);
}
sub request {
    my($class,$given,$field,$value,$attrs)=@_;
    my$input=_copy({domain=>$given,field=>$field,value=>$value,attrs=>$attrs//{}});
    _error('invalid_choice_request','choice request attributes must be an object')unless ref($input->{attrs})eq'HASH';
    return _request(_domain($input->{domain}),$input->{field},$input->{value},$input->{attrs},0,0);
}
sub options_request {
    my($class,$given,$target,$attrs)=@_;
    my$input=_copy({domain=>$given,target=>$target,attrs=>$attrs//{}});
    my$a=$input->{attrs};_error('invalid_choice_request','choice request attributes must be an object')unless ref($a)eq'HASH';
    my$by=exists($a->{by})?delete($a->{by}):'field';
    _error('invalid_options_request_target','options request by must be field or choice_source')unless _string($by)&&$by=~/\A(?:field|choice_source)\z/;
    return _request(_domain($input->{domain}),$input->{target},undef,$a,1,$by eq'choice_source');
}
sub choice_source_options_request {
    my($class,$domain,$choice,$attrs)=@_;$attrs=_copy($attrs//{});return$class->options_request($domain,$choice,{%$attrs,by=>'choice_source'});
}
sub _resolved {
    my($request,$resolver,$options)=@_;
    my$model=$options?'Selecto::Domain::Choices::OptionsResult':'Selecto::Domain::Choices::Result';
    return$model->unknown('resolver_required',{request=>$request})unless defined$resolver;
    return$model->unknown('invalid_resolver',{request=>$request})unless ref($resolver)eq'CODE';
    # The resolver is an explicit trusted host argument. It receives an isolated
    # request. Native results may explicitly provide their own request, matching
    # the host-provider contract; otherwise the canonical request is attached.
    my$result=$resolver->(_copy($request));
    my$outcome;
    if(ref($result)eq'ARRAY'&&!defined(tied(@$result))&&@$result==2
        &&!defined(tied($result->[0]))&&!defined(tied($result->[1]))
        &&_string($result->[0])&&$result->[0]=~/\A(?:ok|error)\z/){
        ($outcome,$result)=@$result;
    }
    return$model->unknown('invalid_resolver_result',{request=>$request})
        unless Selecto::Domain::Choices::Result->is_native($result,$model);
    my$data=$result->as_hash;$data->{request}//=$request;
    $data->{outcome}=$outcome if defined$outcome;
    return$model->new($data);
}
sub validate_choice {my($class,$domain,$field,$value,$attrs,$resolver)=@_;return _resolved($class->request($domain,$field,$value,$attrs),$resolver,0)}
sub valid_choice {my($class,@args)=@_;my$result=$class->validate_choice(@args);return$result->status eq'valid'&&$result->outcome eq'ok'}
sub list_options {my($class,$domain,$target,$attrs,$resolver)=@_;return _resolved($class->options_request($domain,$target,$attrs),$resolver,1)}
sub valid {shift;Selecto::Domain::Choices::Result->valid(@_)}
sub invalid {shift;Selecto::Domain::Choices::Result->invalid(@_)}
sub unknown {shift;Selecto::Domain::Choices::Result->unknown(@_)}
sub options_resolved {shift;Selecto::Domain::Choices::OptionsResult->resolved(@_)}
sub options_unknown {shift;Selecto::Domain::Choices::OptionsResult->unknown(@_)}
sub options_error {shift;Selecto::Domain::Choices::OptionsResult->error(@_)}
1;

=head1 DESCRIPTION

Choice metadata and explicit host-provider boundaries. C<binding>, C<request>
and C<options_request> admit complete bounded portable declarations, validate
the source/schema/query, relationship and choice metadata sections, and
return independent plain metadata. Rich references take precedence over compact
bindings; source/schema/actual association alias columns merge declared presentation columns. Options
may target fields or a declared choice source via C<by =E<gt> 'choice_source'>.
Actual complete join paths take priority over unique nested shorthand, then
schema fields. Declared join namespaces with absent or ambiguous fields refuse
instead of taking metadata from a coincident schema or projection column.

Requests preserve declared relationship/choice constraints and host filters,
context, actor, tenant, record, policy, search, paging, cursor and ordering.
Constraints are provider metadata. No SQL, target lookup or capability grant is
inferred. Missing providers produce C<unknown/resolver_required>.
Other policy registries retain their own public validators; a declared
capability reference proves metadata identity without granting authorization.

C<validate_choice($domain,$field,$value,$attrs,$resolver)> and
C<list_options($domain,$target,$attrs,$resolver)> take an explicit trusted CODE
argument, separate from portable attributes. It receives a request copy and
must return the appropriate native result built by C<valid>, C<invalid>,
C<unknown>, C<options_resolved>, C<options_unknown> or C<options_error>.
Tagged C<['ok', $result]> and C<['error', $result]> host results preserve their
transport outcome through C<outcome>; an error-tagged valid result remains false
through C<valid_choice>.
Serialized result hashes and forged objects are not native decisions. Provider
exceptions propagate to the host. Unknown/invalid membership returns false
through C<valid_choice>. Native result getters return independent copies.

=cut
