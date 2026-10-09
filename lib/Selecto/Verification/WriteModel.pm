package Selecto::Verification::WriteModel;
use 5.034; use strict; use warnings; no overloading;
use Scalar::Util qw(blessed reftype);
use JSON::PP ();
use Selecto::Error ();
use Selecto::Write ();
use Selecto::Write::Operation ();
use Selecto::Domain::QueryContract ();

# Shared finite-model mechanics, not a simulated compiler or authorization path.
sub atom { return {'$atom' => $_[0]}; }
sub copy { return Selecto::Domain::QueryContract->copy_declaration({value=>$_[0]})->{value}; }
sub capture {
    my ($callback)=@_; my ($value,$error);
    { local $@; my $ok=eval {$value=$callback->();1}; $error=$@ unless $ok; }
    return {value=>$value,error=>$error};
}
sub typed { my ($r)=@_; return defined($r->{error}) && (blessed($r->{error})//'') eq 'Selecto::Error'; }
sub code { my ($r)=@_; return typed($r) ? ($r->{error}->details->{code}//$r->{error}->code) : undef; }
sub successful { return !defined($_[0]{error}); }
sub is { return (blessed($_[0])//'') eq $_[1]; }
sub compile {
    require Selecto::Write::PortableCommand;
    return Selecto::Write::PortableCommand->compile(@_);
}
sub options {
    my ($options,@allowed)=@_; my %allowed=map {$_=>1} @allowed;
    Selecto::Error->throw('invalid_argument','unknown finite write model option') if grep {!$allowed{$_}} keys %$options;
    for my $key (keys %$options) {
        Selecto::Error->throw('invalid_argument','finite model overrides must be explicit host callbacks') unless ref($options->{$key}) eq 'CODE';
    }
}
sub check {
    my ($model,$enumerate,$invariants)=@_; my (@counterexamples,$states,$checks); $states=$checks=0;
    $enumerate->(sub {
        my ($labels,$state)=@_; ++$states;
        for my $invariant (@$invariants) {
            ++$checks; my ($passed,$exception);
            {local $@; my $ok=eval {$passed=$invariant->[1]->($state);1};$exception=$@ unless $ok;}
            next if $passed && !defined($exception);
            my $result_error = ref($state->{result}) eq 'HASH' && defined($state->{result}{error}) ? (typed($state->{result}) ? code($state->{result}) : 'unexpected_exception') : undef;
            push @counterexamples,{state=>{%$labels},invariant=>$invariant->[0],
                defined($result_error) && !ref($result_error) ? (actual_error=>substr($result_error,0,128)) : (),
                defined($exception) ? (check_error=>((blessed($exception)//'') eq 'Selecto::Error' ? $exception->code : 'unexpected_exception')) : ()};
        }
    });
    return {proof_level=>'bounded_exhaustive',model=>$model,state_count=>$states,check_count=>$checks,
        invariant_count=>scalar(@$invariants),counterexamples=>\@counterexamples};
}
sub domain {
    my ($relation,$fields,%opts)=@_; $relation//='items'; $fields//=[qw(id tenant_id name)];
    my %columns=map {$_=>{type=>($_ eq 'id' && !$opts{string_ids})?'integer':'string'}} @$fields;
    my $d={source=>{source_table=>$relation,primary_key=>'id',fields=>[@$fields],columns=>\%columns,associations=>{}},schemas=>{},
        writes=>{operations=>{insert=>{enabled=>JSON::PP::true},update=>{enabled=>JSON::PP::true,require_filter=>JSON::PP::true}},
        fields=>{tenant_id=>{insertable=>JSON::PP::true,immutable=>JSON::PP::true},name=>{insertable=>JSON::PP::true,updatable=>JSON::PP::true}},
        scope=>{tenant=>{required=>JSON::PP::true,field=>'tenant_id',satisfied_by=>['trusted_context']}},relationships=>{}}};
    $d->{writes}{fields}{name}{required_on}=['insert'] if $opts{required_name};
    if ($opts{exactly}) {$_->{expected_cardinality}=['exactly',1] for values %{$d->{writes}{operations}};}
    return $d;
}
sub nested_domain {
    my ($policy)=@_; $policy//='valid';
    my $child=domain('children',[qw(id tenant_id parent_id name)],string_ids=>1,required_name=>1,exactly=>1);
    my $root=domain('parents',[qw(id tenant_id name)],string_ids=>1,required_name=>1,exactly=>1); $root->{joins}={};$child->{joins}={};
    # Original nested model uses the default trusted_context/prefix source list.
    delete $root->{writes}{scope}{tenant}{satisfied_by}; delete $child->{writes}{scope}{tenant}{satisfied_by};
    $root->{writes}{relationships}{children}={writable=>JSON::PP::true,cardinality=>'many',ownership=>'owned',
        allowed_ops=>[qw(insert update delete)],domain=>$child,child_key=>$policy eq 'invalid_child_key'?'missing_parent_id':'parent_id',
        identity_fields=>['id'],strategy=>'sync',delete_missing=>JSON::PP::true} unless $policy eq 'absent';
    return $root;
}
sub operation {
    my ($domain,$type,$values,$id)=@_; $id//=atom('id'); my $op=Selecto::Write::Operation->new($domain)->operation($type,$values);
    return $type eq 'update'||$type eq 'delete' ? $op->filter([$id,7]) : $op;
}
sub literal {
    my ($value)=@_;
    if (is($value,'Selecto::Write::Expression') && $value->kind eq 'literal') {return $value->arguments->[0];}
    return $value unless defined(reftype($value)); return undef;
}
sub predicate_values {
    my ($expr,$field)=@_; return [] unless is($expr,'Selecto::Expression');
    my $args=$expr->arguments;
    return [map {@{predicate_values($_,$field)}} @{$args->[0]}] if $expr->kind eq 'and' && ref($args->[0]) eq 'ARRAY';
    return [] unless $expr->kind eq 'eq' && @$args==2 && is($args->[0],'Selecto::Expression')
        && $args->[0]->kind eq 'field' && $args->[0]->arguments->[0] eq $field
        && is($args->[1],'Selecto::Expression') && $args->[1]->kind eq 'literal';
    return [$args->[1]->arguments->[0]];
}
sub command_tenants {
    my ($cmd)=@_; my @values;
    my $a=$cmd->assignments; push @values,literal($a->{tenant_id}) if exists $a->{tenant_id};
    push @values,@{predicate_values($cmd->predicate,'tenant_id')},@{predicate_values($cmd->scope_predicate,'tenant_id')};
    return \@values;
}
sub commands {
    my ($write)=@_;
    return [$write] if is($write,'Selecto::Write::Command');
    return $write->commands if is($write,'Selecto::Write::Batch');
    return [map {$_->{command}} @{$write->nodes}] if is($write,'Selecto::Write::Graph');
    return [];
}
sub emitted_tenants {return [map {@{command_tenants($_)}} @{commands($_[0])}];}
sub neutral {
    my ($write)=@_; for my $cmd (@{commands($write)}) {my $m=$cmd->metadata;return 0 if grep {exists $m->{$_}} qw(adapter connection repo driver dialect);}
    return 1;
}
# Complete plain canonical Work Items example used by the highest trust model.
# The archive action is its original optional-reason/simple-set declaration,
# rather than the certification fixture's unrelated urgent/cases specialization.
# Declared callbacks remain metadata markers; no callback execution is claimed.
sub work_items {
    return JSON::PP->new->decode(<<'MODEL_DOMAIN_JSON');
{"actions":{"archive":{"capability":"work_items.archive","execution":{"kind":"updato","operation":"update","set":{"state":"archived"}},"inputs":{"reason":{"required":false,"type":"string"}},"label":"Archive work item","scope":"row","transition":{"field":"state","from":"done","to":"archived"},"type":"transition"}},"capabilities":{"selecto.exported_views.manage":{"operations":["create"]},"selecto.exports.download":{"operations":["export"]},"selecto.scheduled_exports.manage":{"operations":["create"]},"work_items.archive":{"action":"archive","operations":["action","update"]},"work_items.assign":{"operations":["choice_source","update"]},"work_items.private_metric":{"operations":["select","filter","export"]},"work_items.published_views":{"operations":["published_view"]},"work_items.read":{"operations":["select","filter"]}},"choice_sources":{"owner_choices":{"capability":"work_items.assign","caption_source":"owners.name","constraint_policy":{"domain_of_interest":"fail_closed"},"domain":"users","filters":[["eq","owners.tenant_id",["context","tenant_id"]]],"label_field":"name","order_by":["owners.name"],"presentation":{"cardinality":"one","control":"autocomplete","mode":"searchable"},"source_path":"owners","source_relationship":"owner","value_field":"id","value_source":"owners.id"},"state_choices":{"domain":"work_item_states","label_field":"state","presentation":{"cardinality":"one","control":"select","mode":"static"},"value_field":"state"}},"default_selected":["id","title","state","priority"],"filters":{"owner":{"capability":"work_items.assign","field":"owner_id","type":"integer"},"private_metric":{"capability":"work_items.private_metric","field":"private_metric","type":"integer"},"state":{"capability":"work_items.read","field":"state","type":"string"}},"joins":{"owner":{"type":"left"}},"name":"Work Items","published_views":{"manager_rollup":{"capability":"work_items.published_views","columns":{"state":{"type":"string"},"total":{"type":"integer"}},"database_name":"reporting.work_item_manager_rollup","kind":"materialized_view","query":{"kind":"declared_callback"},"refresh":{"concurrently":true}}},"required_order_by":[["priority","desc"]],"schemas":{"owners":{"associations":{},"columns":{"active":{"type":"boolean"},"id":{"type":"integer"},"name":{"type":"string"},"tenant_id":{"type":"integer"}},"fields":["id","name","active","tenant_id"],"primary_key":"id","source_table":"users","tenant_field":"tenant_id"}},"source":{"associations":{"owner":{"field":"owner","owner_key":"owner_id","queryable":"owners","related_key":"id"}},"columns":{"archived_at":{"name":"Archived At","type":"utc_datetime"},"id":{"name":"ID","type":"integer"},"owner_id":{"choice_source":"owner_choices","name":"Owner","reference":{"caption_source":"owners.name","choice_source":"owner_choices","value_source":"owners.id"},"type":"integer"},"priority":{"name":"Priority","type":"integer"},"private_metric":{"capability":"work_items.private_metric","name":"Private Metric","type":"integer"},"state":{"choice_source":"state_choices","name":"State","reference":{"caption_source":"state","choice_source":"state_choices","value_source":"state"},"type":"string"},"tenant_id":{"name":"Tenant","type":"integer"},"title":{"name":"Title","type":"string"}},"fields":["id","title","state","priority","owner_id","private_metric","archived_at","tenant_id"],"primary_key":"id","source_table":"work_items"},"source_relationships":{"owner":{"filters":[["eq","owners.active",true]],"source_field":"owner_id","source_path":"owners","target_domain":"users","target_field":"id"}},"writes":{"fields":{"archived_at":{"updatable":true},"owner_id":{"updatable":true},"priority":{"updatable":true},"state":{"updatable":true}},"operations":{"update":{"enabled":true,"require_filter":true}},"scope":{"tenant":{"field":"tenant_id","required":true,"satisfied_by":["trusted_context"]}},"transitions":{"state":{"archived":[],"done":["archived"],"in_progress":["done","archived"],"open":["in_progress","archived"]}}}}
MODEL_DOMAIN_JSON
}

1;

=head1 DESCRIPTION

Internal mechanics shared by the six public finite write verification models.
The models enumerate their original authored state spaces and invoke public
portable APIs. Reports count executed states and checks; counterexamples retain
bounded scalar labels rather than serializing native objects or credentials.
Explicit host callback overrides support fault controls and do not grant writes.
The finite proofs do not certify arbitrary adapters or database rollback.

=cut
