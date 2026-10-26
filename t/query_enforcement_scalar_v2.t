use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();
use Math::BigInt ();

# The central query_enforced_scalar v2 corpora (specification 2.37, copied
# byte for byte from selecto_backend_certification priv/fixtures: the
# main corpus at 2539564 (branch scalar-v2-domains), the edges at 11d845a): every case runs through the public candidate evaluator with the
# case's declared column type, metadata level and backend.
sub load {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $document = JSON::PP->new->decode(do { local $/; <$fh> });
    close $fh;
    return $document;
}
my $main = load('t/fixtures/query_enforced_scalar_v2.json');
my $edges = load('t/fixtures/query_enforced_scalar_edges_v2.json');
is($main->{format}, 'selecto.query-enforced-scalar.v2', 'main corpus format');
is($edges->{format}, 'selecto.query-enforced-scalar-edges.v2', 'edge corpus format');
is(scalar @{$main->{cases}}, 714, 'main corpus count');
is(scalar @{$edges->{cases}}, 532, 'edge corpus count');
my %prefix;
$prefix{substr($_->{id}, 0, 1)}++ for @{$main->{cases}};
is_deeply(\%prefix, {S => 239, T => 212, N => 119, I => 103, U => 31, X => 10}, 'main corpus layout');
is(scalar(grep { ($_->{metadata} // '') eq 'base_verified' } @{$main->{cases}}), 34, 'base_verified cases');
is(scalar(grep { ($_->{metadata} // '') eq 'unverified' } @{$main->{cases}}), 14, 'unverified cases');
is(scalar(grep { ($_->{backend} // '') eq 'mysql_family' } @{$main->{cases}}), 11, 'mysql_family cases');

my $x = 'Selecto::Expression';
my ($passed, $total) = (0, 0);
for my $case (@{$main->{cases}}, @{$edges->{cases}}) {
    my $backend = $case->{backend} // 'other';
    my %options = (backend => $backend);
    my $field = {type => $case->{column_type}, metadata => $case->{metadata} // 'verified', backend => $backend};
    my $class = Selecto::QueryEnforcement::classify_type($case->{column_type}, %options)->{class};
    my $form = $case->{form} // '';
    my $fields = {subject => $field, subject_peer => $field};
    my ($op, $expected) = ($case->{op}, $case->{expected});
    my $right = $form eq 'column_pair' ? $x->field('subject_peer') : undef;
    my $predicate = $op eq 'in' || $op eq 'not_in'
        ? $x->in('subject', [@$expected])
        : $x->new($op, $x->field('subject'), $right // $x->literal($expected));
    $predicate = $x->not($predicate) if $op eq 'not_in';
    my $candidate = $form eq 'absent_field' ? {} : $form eq 'column_pair'
        ? {subject => $case->{actual}, subject_peer => $expected} : {subject => $case->{actual}};
    my ($outcome, @warnings);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $outcome = eval { Selecto::QueryEnforcement::evaluate($predicate, $candidate, $fields, %options) };
        if (!defined $outcome) {
            my $error = $@;
            die $error unless ref($error) && $error->isa('Selecto::Error');
            $outcome = $error->code;
        }
    }
    my $ok = $class eq $case->{type_class} && $outcome eq $case->{outcome} && !@warnings;
    $total++;
    $passed++ if $ok;
    ok($ok, "$case->{id}: " . ($case->{column_type} // 'undeclared') . " $op")
        or diag("class $class (want $case->{type_class}), outcome $outcome (want $case->{outcome}) @warnings");
}
is($passed, $total, "all $total v2 cases match (714 main + 532 edges)");
{
    # Host Math::BigInt rounding defaults must not affect admission.
    local $Math::BigInt::accuracy = 1;
    local $Math::BigInt::precision = -1;
    my $integer = {subject => {type => 'bigint', metadata => 'verified'}};
    is(Selecto::QueryEnforcement::evaluate($x->gt('subject', '9007199254740992'), {subject => '9007199254740993'}, $integer),
        'true', 'host BigInt accuracy and precision do not affect an exact integer comparison');
    is(Selecto::QueryEnforcement::evaluate($x->eq('subject', '9007199254740992'), {subject => '9007199254740993'}, $integer),
        'false', 'nor equality');
    my $decimal = {subject => {type => 'numeric(20,3)', metadata => 'verified'}};
    is(scalar(eval { Selecto::QueryEnforcement::evaluate($x->ne('subject', '1'), {subject => '1.0004'}, $decimal) } // $@->code),
        'query_rule_not_evaluable', 'nor the stored-unchanged scale check');
}
done_testing;
