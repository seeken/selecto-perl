package TestSelecto;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Selecto;

sub people_domain {
    return Selecto::Domain->new(
        name => 'People',
        table => 'people',
        fields => { id => 'integer', name => 'string', active => 'boolean', score => 'decimal' },
    );
}

# A canonical domain over root fields only whose writes contract enables
# insert, update, upsert and delete and grants every field as insertable and
# updatable. Adapter, dialect and transaction tests write through it, because
# engines refuse to write a domain without a declared write policy.
#
#   my $domain = TestSelecto::writable_domain(
#       name => 'Items', table => 'items', fields => {id => 'integer', name => 'string'},
#       tenant_field => 'tenant_id',           # optional
#       required_predicate => $expression,     # optional
#   );
sub writable_domain {
    my (%args) = @_;
    my $fields = $args{fields};
    my @names = sort keys %$fields;
    my $true = JSON::PP::true;
    my $domain = Selecto::Domain->parse({
        schema_version => 1,
        name => $args{name},
        source => {
            source_table => $args{table},
            primary_key => $args{primary_key} // 'id',
            fields => \@names,
            columns => {map { ($_ => {type => $fields->{$_}}) } @names},
            associations => {},
            (defined($args{tenant_field}) ? (tenant_field => $args{tenant_field}) : ()),
        },
        schemas => {},
        joins => {},
        writes => {
            operations => {map { ($_ => {enabled => $true,
                ($_ eq 'upsert' ? (conflict_targets => $args{conflict_targets} // [[$args{primary_key} // 'id']]) : ())}) }
                qw(insert update upsert delete)},
            fields => {map { ($_ => {insertable => $true, updatable => $true}) } @names},
        },
    }, strict => 1);
    return defined($args{required_predicate})
        ? $domain->with_required_predicate($args{required_predicate})
        : $domain;
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

sub begin_work { push @{$_[0]->{events}}, 'BEGIN'; $_[0]{AutoCommit} = 0; return 1; }
sub commit     { push @{$_[0]->{events}}, 'COMMIT'; return 1; }
sub rollback   { push @{$_[0]->{events}}, 'ROLLBACK'; return 1; }
sub do         { push @{$_[0]->{events}}, $_[1]; return '0E0'; }
sub errstr     { return $_[0]->{errstr}; }
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

sub execute {
    my ($self, @params) = @_;
    $self->{params} = [@params];
    if (defined $self->{spec}{execute_error}) {
        $self->{errstr} = $self->{spec}{execute_error};
        $self->{owner}{errstr} = $self->{errstr};
        return undef;
    }
    return 1;
}
sub fetchrow_array {
    my ($self) = @_;
    my $rows = $self->{spec}{rows} // [];
    return if $self->{index} >= @$rows;
    return @{$rows->[$self->{index}++]};
}
# Like DBI, every fetched row is a fresh array the caller may modify.
sub fetchall_arrayref {
    my ($self) = @_;
    my $rows = $self->{spec}{rows} // [];
    my @remaining = map { [@$_] } @{$rows}[$self->{index} .. $#$rows];
    $self->{index} = @$rows;
    return \@remaining;
}
sub rows   { return $_[0]->{spec}{affected} // scalar(@{$_[0]->{spec}{rows} // []}); }
sub err    { return defined($_[0]->{errstr}) ? 1 : undef; }
sub errstr { return $_[0]->{errstr}; }
sub sql    { return $_[0]->{sql}; }
sub params { return [@{$_[0]->{params}}]; }

1;
