package Selecto::Verification::WriteSafety;
use 5.034; use strict; use warnings;
use JSON::PP (); use Selecto::Verification::WriteModel ();
my $M='Selecto::Verification::WriteModel';
sub verify {
    my ($class,%opts)=@_;Selecto::Verification::WriteModel::options(\%opts,qw(apply_scope validate_scope applied_scope));
    my $apply=$opts{apply_scope}//sub {$_[0]->apply_execution_scope};
    my $validate=$opts{validate_scope}//sub {$_[0]->validate_tenant_scope};
    my $applied=$opts{applied_scope}//sub {$_[0]->applied_scope};
    return Selecto::Verification::WriteModel::check('selecto_updato.write_scope.v1',sub {
        my ($emit)=@_;
        for my $type(qw(insert update upsert delete)){for my $context(qw(none tenant_id)){for my $unrelated(0,1){
            my $d={source=>'items',columns=>{map {$_=>{type=>($_ eq 'id'||$_ eq 'quantity')?'integer':'string'}} qw(id account_id name quantity status)},
                readonly=>[qw(id account_id)],writable=>[qw(name quantity status)],writes=>{scope=>{tenant=>{required=>JSON::PP::true,field=>'account_id',satisfied_by=>['trusted_context']}}}};
            my $values=$type eq 'delete'?{}:$type eq 'update'?{quantity=>2}:{name=>'item',quantity=>1};
            my $before=Selecto::Verification::WriteModel::operation($d,$type,$values,'id');
            $before=$before->with_tenant({tenant_id=>'tenant-a'}) if $context eq 'tenant_id';
            $before=$before->filter(['status','active']) if $unrelated;
            my $after=Selecto::Verification::WriteModel::capture(sub {$apply->($before)});
            my $validation=Selecto::Verification::WriteModel::successful($after)?Selecto::Verification::WriteModel::capture(sub {$validate->($after->{value})}):$after;
            my $audit=Selecto::Verification::WriteModel::successful($after)?Selecto::Verification::WriteModel::capture(sub {$applied->($after->{value})}):$after;
            $emit->({type=>$type,context=>$context,unrelated_filter=>$unrelated},{type=>$type,context=>$context,unrelated=>$unrelated,before=>$before,after=>$after,validation=>$validation,audit=>$audit});
        }}}
    },[
        ['required_scope_fails_closed',sub {my($s)=@_;return !!Selecto::Verification::WriteModel::successful($s->{validation})==($s->{context} eq 'tenant_id')}],
        ['trusted_context_becomes_targeting_filter',sub {my($s)=@_;return 1 if $s->{context} ne 'tenant_id';return 0 unless Selecto::Verification::WriteModel::successful($s->{after});my $f=$s->{after}{value}->snapshot->{filters};return 1==grep {ref($_) eq 'ARRAY'&&@$_==2&&!ref($_->[0])&&$_->[0] eq 'account_id'&&$_->[1] eq 'tenant-a'} @$f}],
        ['unrelated_filters_cannot_satisfy_scope',sub {my($s)=@_;return 1 unless $s->{context} eq 'none'&&$s->{unrelated};return Selecto::Verification::WriteModel::typed($s->{validation})&&$s->{validation}{error}->code eq 'missing_tenant_scope'}],
        ['scope_application_preserves_operation',sub {my($s)=@_;return 0 unless Selecto::Verification::WriteModel::successful($s->{after});my($a,$b)=($s->{before}->snapshot,$s->{after}{value}->snapshot);return JSON::PP->new->canonical->encode([@{$a}{qw(type values)}]) eq JSON::PP->new->canonical->encode([@{$b}{qw(type values)}])}],
        ['applied_scope_is_auditable',sub {my($s)=@_;return 0 unless Selecto::Verification::WriteModel::successful($s->{audit});my$a=$s->{audit}{value};return !defined($a) if $s->{context} eq 'none';return ref($a) eq 'HASH'&&ref($a->{tenant}) eq 'HASH'&&$a->{tenant}{required}&&$a->{tenant}{field} eq 'account_id'&&ref($a->{tenant}{sources}) eq 'ARRAY'&&grep {ref($_) eq 'HASH'&&($_->{source}//'') eq 'trusted_context'} @{$a->{tenant}{sources}}}],
    ]);
}
1;
