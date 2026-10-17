package Selecto::Domain::Choices::Result;
use 5.034;
use strict;
use warnings;
no overloading;
use B ();
use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(reftype);
use Selecto::Domain::QueryContract ();
use Selecto::Domain::StaticFilters ();
use Selecto::Error ();
fieldhash my%STATE;
my%CLASS=map{$_=>1}qw(Selecto::Domain::Choices::Result Selecto::Domain::Choices::OptionsResult);
sub _fail {Selecto::Error->throw('invalid_choice_result',$_[0])}
sub new {
    my($class,$given)=@_;$given//={};
    _fail('unknown choice result model')unless Selecto::Domain::StaticFilters->string($class)&&$CLASS{$class};
    my$input=Selecto::Domain::QueryContract->copy_declaration($given);
    my$options=$class eq'Selecto::Domain::Choices::OptionsResult';
    my$status=$input->{status}//'unknown';
    _fail('unknown choice result status')unless Selecto::Domain::StaticFilters->string($status)
        &&($options?$status=~/\A(?:resolved|unknown|error)\z/:$status=~/\A(?:valid|invalid|unknown)\z/);
    my$state={status=>$status,reason_code=>exists($input->{reason_code})?$input->{reason_code}:'resolver_required',
        request=>$input->{request},user_message=>$input->{user_message},metadata=>$input->{metadata}//{}};
    $state->{outcome}=$input->{outcome}//(($status eq($options?'resolved':'valid'))?'ok':'error');
    _fail('choice result outcome must be ok or error')unless Selecto::Domain::StaticFilters->string($state->{outcome})&&$state->{outcome}=~/\A(?:ok|error)\z/;
    _fail('choice result metadata must be an object')unless ref($state->{metadata})eq'HASH';
    _fail('choice result request must be an object or null')if defined($state->{request})&&ref($state->{request})ne'HASH';
    _fail('choice result reason must be a string or null')if defined($state->{reason_code})&&!Selecto::Domain::StaticFilters->string($state->{reason_code});
    _fail('choice result user message must be a string or null')if defined($state->{user_message})&&!Selecto::Domain::StaticFilters->string($state->{user_message});
    if($options){
        $state->{options}=$input->{options}//[];$state->{total_count}=$input->{total_count};$state->{next_cursor}=$input->{next_cursor};
        _fail('choice options must be an array')unless ref($state->{options})eq'ARRAY';
        my$total=$state->{total_count};
        _fail('choice option total_count must be a non-negative integer or null')if defined($total)
            &&(defined(reftype($total))||!(B::svref_2object(\$total)->FLAGS&B::SVf_IOK())||$total<0);
    }
    $state=Selecto::Domain::QueryContract->copy_declaration($state);
    my$marker=0;my$self=bless\$marker,$class;$STATE{$self}={class=>$class,data=>$state};return$self;
}
my $state_of = sub {
    my($self)=@_;_fail('unrecognized choice result')unless defined(reftype($self))&&reftype($self)eq'SCALAR'&&$CLASS{ref($self)}&&exists$STATE{$self}
        &&$STATE{$self}{class}eq ref($self);
    return$STATE{$self}{data};
};
sub is_native {
    my($class,$value,$expected)=@_;
    return Selecto::Domain::StaticFilters->string($expected)&&defined(reftype($value))&&reftype($value)eq'SCALAR'&&ref($value)eq$expected&&exists$STATE{$value}
        &&$STATE{$value}{class}eq$expected;
}
sub as_hash {Selecto::Domain::QueryContract->copy_declaration($state_of->($_[0]))}
sub status {$state_of->($_[0])->{status}}
sub reason_code {$state_of->($_[0])->{reason_code}}
sub outcome {$state_of->($_[0])->{outcome}}
sub request {Selecto::Domain::QueryContract->copy_declaration({value=>$state_of->($_[0])->{request}})->{value}}
sub valid {my($class,$reason,$attrs)=@_;$attrs=Selecto::Domain::QueryContract->copy_declaration($attrs//{});$class->new({%$attrs,status=>'valid',reason_code=>$reason//'choice_valid'})}
sub invalid {my($class,$reason,$attrs)=@_;$attrs=Selecto::Domain::QueryContract->copy_declaration($attrs//{});$class->new({%$attrs,status=>'invalid',reason_code=>$reason//'choice_invalid'})}
sub unknown {my($class,$reason,$attrs)=@_;$attrs=Selecto::Domain::QueryContract->copy_declaration($attrs//{});$class->new({%$attrs,status=>'unknown',reason_code=>$reason//'resolver_required'})}
1;

=head1 DESCRIPTION

Native membership results keep admitted metadata in private field-hash state;
getters return independent copies. Raw objects and portable serialized hashes
cannot impersonate a constructed native decision. C<new>, C<valid>, C<invalid>
and C<unknown> validate status and bounded plain metadata without callbacks.

=cut
