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

# The recorder answers only the MySQL-family session check, as a UTC,
# utf8mb4, strict session that decodes exactly (with no open server
# transaction); every other direct select is unknown to it.
sub selectrow_array {
    my ($self, $sql) = @_;
    return TestSelecto::DBH::session_state() if TestSelecto::DBH::state_query($sql);
    die "TestSelecto::DBH has no answer for $sql\n" unless TestSelecto::DBH::session_query($sql);
    return TestSelecto::DBH::session_row($sql);
}
sub session_query { return $_[0] =~ /SELECT VERSION\(\), \@\@SESSION\.time_zone\b/ ? 1 : 0; }
# The MySQL-family session comparison after reads and writes: unchanged.
sub state_query { return $_[0] eq 'SELECT @@SESSION.time_zone, @@SESSION.sql_mode' ? 1 : 0; }
sub session_state { return ('UTC', 'STRICT_TRANS_TABLES'); }
sub session_row {
    my ($sql) = @_;
    # VERSION() first: a MariaDB adapter's statements carry its SET STATEMENT
    # prefix, and the server family must match the adapter's.
    return (($sql =~ /\ASET STATEMENT / ? '11.4.5-MariaDB' : '8.4.5'), 'UTC', 'UTC', 'utf8mb4', 'utf8mb4', 'utf8mb4', 'STRICT_TRANS_TABLES', "\x{1F600}",
        '2024-03-10 02:30:00.500000', ($sql =~ /\@\@SESSION\.transaction_read_only\z/ ? (1, 0) : ()));
}
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
