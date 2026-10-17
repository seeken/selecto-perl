use 5.034;
use strict;
use warnings;
no warnings 'recursion';
use Test::More;
use Scalar::Util qw(blessed);
use Selecto::Domain;
use Selecto::Expression;

# A host predicate nested past the expression depth limit (built around the
# expression constructors' own depth check) is refused with a typed depth
# error, not reported as a modified domain or a serializer failure.
my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Deep',
    source => {source_table => 'deep_rows', primary_key => 'id', fields => [qw(id org_key)],
        columns => {id => {type => 'integer'}, org_key => {type => 'string'}}, associations => {}},
    schemas => {}, joins => {}});
for my $depth (40, 2000) {
    my $predicate = Selecto::Expression->eq('org_key', 't1');
    $predicate = bless {kind => 'not', arguments => [$predicate]}, 'Selecto::Expression' for 1 .. $depth;
    my $error = eval { $domain->with_required_predicate($predicate); 1 } ? undef : $@;
    ok(blessed($error) && $error->isa('Selecto::Error'), "depth $depth is refused with a typed error");
    is($error && $error->code, 'invalid_query', 'invalid_query');
    is($error && $error->details->{reason}, 'expression_depth', 'naming the expression depth');
}
my $shallow = Selecto::Expression->eq('org_key', 't1');
$shallow = Selecto::Expression->not(Selecto::Expression->not($shallow)) for 1 .. 10;
ok(eval { $domain->with_required_predicate($shallow); 1 }, 'a predicate within the limit is accepted');
done_testing;
