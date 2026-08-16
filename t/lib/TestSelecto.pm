package TestSelecto;

use 5.034;
use strict;
use warnings;
use Selecto;

sub people_domain {
    return Selecto::Domain->new(
        name => 'People',
        table => 'people',
        fields => { id => 'integer', name => 'string', active => 'boolean', score => 'decimal' },
    );
}

sub orders_domain {
    return Selecto::Domain->new(
        name => 'Orders',
        table => 'orders',
        fields => { id => 'integer', person_id => 'integer', total => 'decimal' },
        associations => {
            person => {
                table => 'people',
                fields => { id => 'integer', name => 'string' },
                owner_key => 'person_id',
                related_key => 'id',
                join_type => 'left',
            },
        },
    );
}

package TestSelecto::DBH;

use 5.034;
use strict;
use warnings;

sub new {
    my ($class, @specs) = @_;
    return bless { specs => [@specs], prepared => [], events => [] }, $class;
}

sub prepare {
    my ($self, $sql) = @_;
    my $spec = shift(@{$self->{specs}}) // {};
    my $sth = TestSelecto::STH->new(owner => $self, sql => $sql, spec => $spec);
    push @{$self->{prepared}}, $sth;
    return $sth;
}

sub begin_work { push @{$_[0]->{events}}, 'BEGIN'; return 1; }
sub commit     { push @{$_[0]->{events}}, 'COMMIT'; return 1; }
sub rollback   { push @{$_[0]->{events}}, 'ROLLBACK'; return 1; }
sub prepared   { return [@{$_[0]->{prepared}}]; }
sub events     { return [@{$_[0]->{events}}]; }

package TestSelecto::STH;

use 5.034;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        owner => $args{owner}, sql => $args{sql}, spec => $args{spec},
        params => [], index => 0, pg_type => $args{spec}{types} // [],
    }, $class;
}

sub execute { my ($self, @params) = @_; $self->{params} = [@params]; return 1; }
sub fetchrow_array {
    my ($self) = @_;
    my $rows = $self->{spec}{rows} // [];
    return if $self->{index} >= @$rows;
    return @{$rows->[$self->{index}++]};
}
sub rows   { return $_[0]->{spec}{affected} // scalar(@{$_[0]->{spec}{rows} // []}); }
sub sql    { return $_[0]->{sql}; }
sub params { return [@{$_[0]->{params}}]; }

1;

