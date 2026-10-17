package Selecto::Domain::ChoiceSources;
use 5.034;
use strict;
use warnings;
no overloading;
use bytes ();
use JSON::PP ();
use Selecto::Domain::QueryContract ();
use Selecto::Domain::Schema ();
use Selecto::Domain::SourceRelationships ();
use Selecto::Domain::StaticFilters ();
use Selecto::OperationBudget ();

my%CONTROL=map{$_=>1}qw(select autocomplete table_picker);
my%MODE=map{$_=>1}qw(static searchable async inline);
my%CARDINALITY=map{$_=>1}qw(one many);
my%POLICY=map{$_=>1}qw(source_relationship choice_source domain_of_interest);
sub _string { Selecto::Domain::StaticFilters->string($_[0]) }
sub _error {
    my($state,$code,$path,%extra)=@_;
    my$d={code=>$code,path=>$path,%extra};
    $state->{budget}->check_tree($d,label=>'choice source diagnostics');
    push @{$state->{errors}},$d;
}
sub _object {
    my($state,$value,$path)=@_;
    return$value if ref($value)eq'HASH';
    _error($state,'invalid_section_shape',$path);return{};
}
sub _choice {
    my($state,$id,$spec)=@_;my$path=['choice_sources',$id];
    $state->{budget}->consume_count('max_expression_nodes',1,label=>'choice source work');
    unless(ref($spec)eq'HASH'){_error($state,'invalid_section_shape',$path);return}
    my@missing=grep{!exists$spec->{$_}}qw(domain value_field label_field);
    _error($state,'choice_source_missing_required_keys',$path,keys=>\@missing)if@missing;
    for my$key(qw(domain value_field label_field)){
        _error($state,"invalid_choice_source_$key",[@$path,$key])if defined($spec->{$key})&&!_string($spec->{$key});
    }
    for my$key(qw(source_path value_source caption_source description_source)){
        _error($state,"invalid_choice_source_$key",[@$path,$key])
            if defined($spec->{$key})&&!Selecto::Domain::StaticFilters->path($spec->{$key});
    }
    if(defined$spec->{filters}){
        if(ref($spec->{filters})ne'ARRAY'){_error($state,'invalid_choice_source_filters',[@$path,'filters'])}
        else{for my$i(0..$#{$spec->{filters}}){
            my$errors=Selecto::Domain::StaticFilters->_validate_admitted($spec->{filters}[$i],'choice_source',$id,[@$path,'filters',$i],$state->{budget});
            _error($state,$_->{code},$_->{path},choice_source=>$id)for@$errors;
        }}
    }
    if(defined$spec->{order_by}){
        if(ref($spec->{order_by})ne'ARRAY'){_error($state,'invalid_choice_source_order_by',[@$path,'order_by'])}
        else{for my$i(0..$#{$spec->{order_by}}){
            my$entry=$spec->{order_by}[$i];my$p=[@$path,'order_by',$i];
            if(ref($entry)eq'ARRAY'&&@$entry==2){
                _error($state,'invalid_choice_source_order_by_entry',$p)unless Selecto::Domain::StaticFilters->path($entry->[0]);
                _error($state,'invalid_choice_source_order_by_direction',$p)unless _string($entry->[1])&&$entry->[1]=~/\A(?:asc|desc)\z/;
            }else{_error($state,'invalid_choice_source_order_by_entry',$p)unless Selecto::Domain::StaticFilters->path($entry)}
        }}
    }
    if(defined$spec->{presentation}){
        if(ref($spec->{presentation})ne'HASH'){_error($state,'invalid_choice_source_presentation',[@$path,'presentation'])}
        else{for my$pair(['control',\%CONTROL],['mode',\%MODE],['cardinality',\%CARDINALITY]){
            my($key,$allowed)=@$pair;my$value=$spec->{presentation}{$key};
            _error($state,"invalid_choice_source_presentation_$key",[@$path,'presentation',$key])if defined($value)&&(!_string($value)||!$allowed->{$value});
        }}
    }
    if(defined$spec->{constraint_policy}){
        if(ref($spec->{constraint_policy})ne'HASH'){_error($state,'invalid_choice_source_constraint_policy',[@$path,'constraint_policy'])}
        else{for my$key(sort keys%{$spec->{constraint_policy}}){
            my$p=[@$path,'constraint_policy',$key];my$value=$spec->{constraint_policy}{$key};
            if(!$POLICY{$key}){_error($state,'invalid_choice_source_constraint_policy_key',$p)}
            elsif(!_string($value)||$value!~/\A(?:best_effort|fail_closed)\z/){_error($state,'invalid_choice_source_constraint_policy_mode',$p)}
        }}
    }
    for my$pair(['source_relationship','relationships','invalid_choice_source_relationship','choice_source_relationship_not_found'],
                 ['capability','capabilities','invalid_choice_source_capability','choice_source_capability_not_found']){
        my($key,$registry,$invalid,$missing)=@$pair;my$value=$spec->{$key};next unless defined$value;
        if(!_string($value)){_error($state,$invalid,[@$path,$key])}
        elsif(!exists$state->{$registry}{$value}){_error($state,$missing,[@$path,$key],$key=>$value)}
    }
}
sub _bindings {
    my($state,$domain,$sources)=@_;
    my@columns=([$domain->{source}{columns},['source','columns'],'']);
    for my$id(sort keys%{$domain->{schemas}//{}}){
        my$schema=$domain->{schemas}{$id};next unless ref($schema)eq'HASH';
        push@columns,[$schema->{columns},['schemas',$id,'columns'],"$id."];
    }
    push@columns,[$domain->{columns},['columns'],''];
    my%fields=map{$_=>1}@{Selecto::Domain::SourceRelationships->declared_field_ids($domain)};
    for my$group(@columns){
        my($columns,$path,$prefix)=@$group;next unless ref($columns)eq'HASH';
        for my$id(sort keys%$columns){
            my$column=$columns->{$id};next unless ref($column)eq'HASH';
            $state->{budget}->consume_count('max_expression_nodes',1,label=>'choice binding work');
            $state->{budget}->consume_count('max_state_bytes',do { use bytes; length($prefix) }+do { use bytes; length($id) },label=>'generated binding identifiers');
            my$field=$prefix.$id;my$p=[@$path,$id];
            if(defined$column->{choice_source}){
                if(!_string($column->{choice_source})){_error($state,'invalid_field_choice_source',[@$p,'choice_source'],field=>$field)}
                elsif(!exists$sources->{$column->{choice_source}}){_error($state,'field_choice_source_not_found',[@$p,'choice_source'],field=>$field)}
            }
            next unless defined$column->{reference};
            if(ref($column->{reference})ne'HASH'){_error($state,'invalid_field_reference',[@$p,'reference'],field=>$field);next}
            my$ref=$column->{reference};my$rp=[@$p,'reference'];
            if(defined$ref->{choice_source}){
                if(!_string($ref->{choice_source})){_error($state,'invalid_field_reference_choice_source',[@$rp,'choice_source'],field=>$field)}
                elsif(!exists$sources->{$ref->{choice_source}}){_error($state,'field_reference_choice_source_not_found',[@$rp,'choice_source'],field=>$field)}
            }
            for my$key(qw(value_source caption_source)){
                _error($state,"invalid_field_reference_$key",[@$rp,$key],field=>$field)if defined($ref->{$key})&&!_string($ref->{$key});
            }
            if(defined$ref->{caption_field}){
                if(!_string($ref->{caption_field})){_error($state,'invalid_field_reference_caption_field',[@$rp,'caption_field'],field=>$field)}
                elsif(!$fields{$ref->{caption_field}}){_error($state,'field_reference_caption_field_not_found',[@$rp,'caption_field'],field=>$field)}
            }
        }
    }
}
sub validate {
    my($class,$given)=@_;my$domain=Selecto::Domain::QueryContract->copy_declaration($given);
    my$state={errors=>[],budget=>Selecto::OperationBudget->new(code=>'invalid_choice_sources')};
    for my$report(Selecto::Domain::Schema->validate($domain),Selecto::Domain::SourceRelationships->validate($domain)){
        _error($state,$_->{code},$_->{path})for@{$report->{errors}};
    }
    $state->{relationships}=_object($state,$domain->{source_relationships}//{},['source_relationships']);
    $state->{capabilities}=_object($state,$domain->{capabilities}//{},['capabilities']);
    my$sources=_object($state,exists($domain->{choice_sources})?$domain->{choice_sources}:{},['choice_sources']);
    _choice($state,$_, $sources->{$_})for sort keys%$sources;
    _bindings($state,$domain,$sources) if ref($domain->{source})eq'HASH'&&ref($domain->{schemas})eq'HASH';
    my$valid=@{$state->{errors}}?0:1;
    return Selecto::Domain::QueryContract->copy_declaration({valid=>bless(\$valid,'JSON::PP::Boolean'),errors=>$state->{errors},warnings=>[],
        validated_sections=>[qw(source schemas query_contract query_library events operations experiences source_relationships choice_sources)]});
}
1;

=head1 DESCRIPTION

C<validate($plain_domain)> validates bounded complete portable source/schema and
query metadata, source relationships and choice declarations. Choice validation
covers required identities, paths, nested static constraints, ordering,
presentation, constraint policies, relationship and capability references.
Registry references establish metadata identity, without granting capabilities
or proving external membership. Inputs and generated diagnostics are bounded.

=cut
