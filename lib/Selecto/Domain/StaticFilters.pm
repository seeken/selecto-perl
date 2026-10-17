package Selecto::Domain::StaticFilters;
use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use Scalar::Util qw(reftype);
use Selecto::Domain::QueryContract ();
use Selecto::OperationBudget ();
use Selecto::Error ();

my %FIELD = map {$_=>1} qw(eq neq not_eq gt gte lt lte like case_insensitive_like contains
    starts_with ends_with between in not_in text_search match_against array_contains array_contained array_overlap array_eq);
sub string { defined($_[1]) && !defined(reftype($_[1])) && (B::svref_2object(\$_[1])->FLAGS & B::SVf_POK()) }
sub path {
    my ($class,$value)=@_;
    return 0 unless $class->string($value);
    $value =~ s/\A\s+|\s+\z//g;
    return length($value) && $value !~ /\A\.|\.\z|\.\./;
}
sub _error {
    my($state,$kind,$path)=@_;
    my$diagnostic={code=>"invalid_$state->{owner}_filter_$kind",path=>$path,$state->{owner}=>$state->{id}};
    $state->{budget}->check_tree($diagnostic,label=>'static filter diagnostics');
    push @{$state->{errors}},$diagnostic;
}
sub _filter {
    my($state,$filter,$path)=@_;
    $state->{budget}->consume_count('max_expression_nodes',1,label=>'static filter work');
    unless(ref($filter)eq'ARRAY'&&@$filter){_error($state,'expression',$path);return}
    my$op=$filter->[0];my$operator=__PACKAGE__->string($op)&&$op=~/\S/;
    my$field=$operator&&$FIELD{$op};my$logical=$operator&&($op eq'and'||$op eq'or');my$unary=$operator&&$op eq'not';
    if(@$filter==2&&$logical){
        unless(ref($filter->[1])eq'ARRAY'){_error($state,'operands',$path);return}
        _filter($state,$filter->[1][$_],[@$path,$_]) for 0..$#{$filter->[1]};
    }elsif(@$filter==2&&$unary){_filter($state,$filter->[1],[@$path,'operand'])}
    elsif((@$filter==3||@$filter==4)&&$field){_error($state,'path',[@$path,'field']) unless __PACKAGE__->path($filter->[1])}
    else{_error($state,($field||$logical||$unary)?'operands':$operator?'operator':'expression',$path)}
}
sub validate_expression {
    my($class,$expression,$owner,$id,$path)=@_;
    my$input=Selecto::Domain::QueryContract->copy_declaration({expression=>$expression,owner=>$owner,id=>$id,path=>$path});
    Selecto::Error->throw('invalid_static_filter','static filter owner and path are invalid')
        unless $class->string($input->{owner})&&$input->{owner}=~/\A(?:source_relationship|choice_source)\z/
            &&$class->string($input->{id})&&ref($input->{path})eq'ARRAY';
    return $class->_validate_admitted($input->{expression},$input->{owner},$input->{id},$input->{path},
        Selecto::OperationBudget->new(code=>'invalid_static_filter'));
}
# Internal callers have already admitted the entire declaration. Reuse their
# operation budget, rather than copying a long owner/path once per filter.
sub _validate_admitted {
    my($class,$expression,$owner,$id,$path,$budget)=@_;
    my$state={owner=>$owner,id=>$id,errors=>[],budget=>$budget};
    _filter($state,$expression,$path);
    return $state->{errors};
}
1;

=head1 DESCRIPTION

Portable static constraint grammar used by choice sources. Values remain
inert provider metadata. Known field operators accept
the portable three/four-item forms, logical lists and unary C<not>. Public
validation admits bounded plain input before inspecting it and accumulates
bounded structured diagnostics. It does not execute SQL or resolve context.

=cut
