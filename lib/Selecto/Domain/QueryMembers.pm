package Selecto::Domain::QueryMembers;

use 5.034;
use strict;
use warnings;
no overloading;
use JSON::PP ();
use B ();
use Selecto::Domain::QueryContract ();
use Selecto::OperationBudget ();
use Selecto::Error ();

my @GROUPS=qw(ctes values subqueries laterals unnests);
my %JOIN_TYPE=map{$_=>1}qw(left inner right full);
sub _name {defined($_[0])&&!ref($_[0])&&(B::svref_2object(\$_[0])->FLAGS & B::SVp_POK())&&$_[0]=~/\S/}
sub _callback {ref($_[0])eq'HASH'&&keys(%{$_[0]})==1&&_name($_[0]{kind})&&$_[0]{kind}eq'declared_callback'}
sub _error {
    my($s,$code,$path)=@_;my$e={code=>$code,path=>[@$path],message=>'invalid query-member declaration'};
    $s->{budget}->check_tree($e,label=>'query-member diagnostics');push@{$s->{errors}},$e;
}
sub _common {
    my ($s, $group, $id, $spec) = @_;
    my $path = ['query_members', $group, $id];
    my @names = $group eq 'subqueries' ? ('join_id') : $group eq 'unnests' ? ('ordinality') : ();
    if ($group eq 'values' || $group eq 'laterals' || $group eq 'unnests') {
        push @names, exists($spec->{as}) ? 'as' : exists($spec->{alias}) ? 'alias' : 'alias_name';
    }
    for my $key (@names) {
        next unless exists($spec->{$key}) && defined($spec->{$key});
        my $code = $key eq 'ordinality' ? 'invalid_query_member_ordinality'
            : $key eq 'join_id' ? 'invalid_query_member_join_id' : 'invalid_query_member_alias';
        _error($s, $code, [@$path, $key]) unless _name($spec->{$key});
    }
    if (($group eq 'ctes' || $group eq 'values') && exists($spec->{join})) {
        my $value = $spec->{join};
        _error($s, 'invalid_query_member_join', [@$path, 'join'])
            if defined($value) && ref($value) ne 'HASH' && ref($value) ne 'ARRAY' && ref($value) ne 'JSON::PP::Boolean';
    }
    if (($group eq 'laterals' || $group eq 'unnests') && exists($spec->{options})) {
        my $value = $spec->{options};
        _error($s, 'invalid_query_member_options', [@$path, 'options'])
            unless ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
    }
    if ($group eq 'subqueries' || $group eq 'laterals') {
        my $preferred = $group eq 'subqueries' ? 'type' : 'join_type';
        my $fallback = $preferred eq 'type' ? 'join_type' : 'type';
        my $key = exists($spec->{$preferred}) ? $preferred : $fallback;
        if (exists $spec->{$key}) {
            _error($s, 'invalid_query_member_join_type', [@$path, $key])
                unless _name($spec->{$key}) && $JOIN_TYPE{$spec->{$key}};
        }
    }
}
sub _spec {
    my($s,$group,$id,$spec)=@_;my$p=['query_members',$group,$id];_common($s,$group,$id,$spec);
    if($group eq'values'){
        my$key=exists($spec->{rows})?'rows':'data';
        _error($s,'invalid_query_member_rows',[@$p,$key])unless ref($spec->{$key})eq'ARRAY';
        _error($s,'invalid_query_member_columns',[@$p,'columns'])if exists($spec->{columns})&&ref($spec->{columns})ne'ARRAY';
    }elsif($group eq'unnests'){
        my$key=exists($spec->{array_field})?'array_field':'field';my$v=$spec->{$key};
        _error($s,'invalid_query_member_field',[@$p,$key])unless _name($v)||ref($v)eq'ARRAY'&&@$v;
    }elsif($group eq'laterals'){
        my$key=exists($spec->{query})?'query':exists($spec->{source})?'source':'lateral_source';my$v=$spec->{$key};
        my$data=ref($spec->{query})eq'HASH'&&!_callback($spec->{query});
        if($data){_data($s,$group,$id,$spec)}
        else{_error($s,'invalid_query_member_source',[@$p,$key])unless _callback($v)||ref($v)eq'ARRAY'&&@$v}
    }else{
        if(($group eq'subqueries'&&ref($spec->{query})eq'HASH'&&!_callback($spec->{query}))||$group eq'ctes'&&((_name($spec->{kind})&&$spec->{kind}eq'recursive')||ref($spec->{query})eq'HASH'&&!_callback($spec->{query}))){
            _data($s,$group,$id,$spec);
        }else{
            my@keys=$group eq'ctes'&&((_name($spec->{type})&&$spec->{type}eq'recursive')||exists($spec->{base_query})||exists($spec->{recursive_query}))
                ?qw(base_query recursive_query):(exists($spec->{query_builder})?'query_builder':'query');
            _error($s,'invalid_query_member_query',[@$p,$_])for grep{!_callback($spec->{$_})}@keys;
        }
        if($group eq'subqueries'){
            _error($s,'invalid_query_member_kind',[@$p,'kind'])if defined($spec->{kind})&&(!_name($spec->{kind})||$spec->{kind}ne'join');
            _error($s,'invalid_query_member_on',[@$p,'on'])if exists($spec->{on})&&ref($spec->{on})ne'ARRAY';
        }
    }
}
sub _data {
    my($s,$group,$id,$spec)=@_;my$p=['query_members',$group,$id];
    my$valid=_name($spec->{source});
    my@queries=_name($spec->{kind})&&$spec->{kind}eq'recursive'?@{$spec}{qw(base step)}:($spec->{query});
    for my$q(@queries){$valid=0 unless ref($q)eq'HASH'&&ref($q->{select})eq'ARRAY'&&@{$q->{select}}}
    if($group eq'laterals'){$valid=0 unless ref($spec->{correlations})eq'HASH'&&keys(%{$spec->{correlations}})}
    elsif($group eq'ctes'){$valid=0 unless ref($spec->{join})eq'HASH'&&_name($spec->{join}{owner_key})&&_name($spec->{join}{related_key})}
    else{$valid=0 unless ref($spec->{on})eq'ARRAY'&&@{$spec->{on}}}
    _error($s,'invalid_query_member_spec',$p)unless$valid;
}
sub _state {
    my($raw)=@_;my$s={errors=>[],groups=>{},budget=>Selecto::OperationBudget->new(code=>'invalid_query_members')};
    my$members=$raw->{query_members}//{};
    unless(ref($members)eq'HASH'){_error($s,'invalid_section_shape',['query_members']);$members={}}
    for my$group(@GROUPS){
        my$specs=$members->{$group}//{};$s->{groups}{$group}=[];
        unless(ref($specs)eq'HASH'){_error($s,'invalid_query_member_group',['query_members',$group]);next}
        for my$id(sort keys%$specs){
            _error($s,'invalid_query_member_id',['query_members',$group,$id])unless _name($id);
            my$spec=$specs->{$id};
            unless(ref($spec)eq'HASH'){_error($s,'invalid_query_member_spec',['query_members',$group,$id]);next}
            _spec($s,$group,$id,$spec);
            my$descriptor={%$spec,id=>$id};
            $s->{budget}->check_tree($descriptor,label=>'query-member projection');push@{$s->{groups}{$group}},$descriptor;
        }
    }
    return$s;
}
sub validate {
    my($class,$given)=@_;my$raw=Selecto::Domain::QueryContract->copy_declaration($given);my$s=_state($raw);my$valid=@{$s->{errors}}?0:1;
    return Selecto::Domain::QueryContract->copy_declaration({valid=>bless(\$valid,'JSON::PP::Boolean'),errors=>$s->{errors},warnings=>[]});
}
sub project {
    my($class,$given)=@_;my$raw=Selecto::Domain::QueryContract->copy_declaration($given);my$s=_state($raw);
    Selecto::Error->throw('invalid_query_members','query-member declaration failed validation',{errors=>$s->{errors}})if@{$s->{errors}};
    return Selecto::Domain::QueryContract->copy_declaration({projection=>'query_members',query_members=>$s->{groups},declaration=>$raw});
}
1;

=head1 NAME

Selecto::Domain::QueryMembers - bounded plain named-member declaration metadata

=head1 METHODS

C<validate($complete_plain_contract)> accumulates member-family, ID and
specification diagnostics. C<project> returns sorted descriptors for all five
families and an independent copy of the entire declaration. Portable
C<{kind =E<gt> 'declared_callback'}> markers remain inert metadata; this API
never invokes a callback or turns such a marker into an executable source.
Native source activation separately validates executable source shapes,
columns, parameter types, joins, policy and tenant scope. Complete callback-free
input, generated descriptors and diagnostics use trusted cumulative budgets.

=cut
