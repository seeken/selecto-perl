use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();

open my $fixture, '<', 't/fixtures/query_enforced_scalar_v1.json' or die $!;
my $document = JSON::PP->new->decode(do { local $/; <$fixture> });
close $fixture;
is($document->{format}, 'selecto.query-enforced-scalar.v1', 'central scalar fixture format');
is(scalar @{$document->{cases}}, 239, 'complete central scalar case count');
open my $edge_fixture, '<', 't/fixtures/query_enforced_scalar_edges_v1.json' or die $!;
my $edges = JSON::PP->new->decode(do { local $/; <$edge_fixture> });
close $edge_fixture;
is($edges->{format}, 'selecto.query-enforced-scalar-edges.v1', 'central scalar edge format');
is(scalar @{$edges->{cases}}, 489, 'complete central scalar edge count');
for my $case (@{$document->{cases}}, @{$edges->{cases}}) {
    my $predicate = Selecto::Expression->new($case->{op},
        Selecto::Expression->field('subject'),
        $case->{op} eq 'in' ? $case->{expected} : Selecto::Expression->literal($case->{expected}));
    my ($actual, @warnings);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval { $actual = Selecto::QueryEnforcement::evaluate($predicate, {subject => $case->{actual}}); 1 };
        if (!$ok) {
            my $error = $@;
            die $error unless ref($error) && $error->isa('Selecto::Error');
            $actual = $error->code;
        }
    }
    is($actual, $case->{outcome}, "$case->{id}: public candidate comparator");
    is_deeply(\@warnings, [], "$case->{id}: no numeric warnings or diagnostic values");
}
{
    local $Math::BigInt::accuracy = 1;
    local $Math::BigInt::precision = -1;
    is(Selecto::QueryEnforcement::evaluate(Selecto::Expression->gt('subject', '9007199254740992'),
        {subject => '9007199254740993'}), 'true', 'host BigInt rounding defaults do not affect admission');
}
done_testing;
