package Selecto::Domain::Choices::OptionsResult;
use 5.034;
use strict;
use warnings;
use parent 'Selecto::Domain::Choices::Result';
use Selecto::Domain::QueryContract ();
sub resolved {
    my($class,$options,$given)=@_;my$attrs=Selecto::Domain::QueryContract->copy_declaration($given//{});
    return$class->new({%$attrs,status=>'resolved',reason_code=>$attrs->{reason_code}//'options_resolved',options=>$options});
}
sub error {my($class,$reason,$given)=@_;my$attrs=Selecto::Domain::QueryContract->copy_declaration($given//{});$class->new({%$attrs,status=>'error',reason_code=>$reason//'options_error'})}
sub options {$_[0]->as_hash->{options}}
sub total_count {$_[0]->as_hash->{total_count}}
sub next_cursor {$_[0]->as_hash->{next_cursor}}
1;
