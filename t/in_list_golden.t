use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use B ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::Limits;
use Selecto::OperationBudget;
use Selecto::Query;

# Golden SQL, parameters and refusals for IN lists. Value admission for IN
# members runs in bulk (Selecto::OperationBudget::_consume_values); every list
# must still compile to one placeholder per member, in order, bind each member
# as the same scalar it was given (JSON booleans as 1 and 0), and be refused at
# exactly the same limits with the same codes, messages and details.

{
    package InGolden::DBH;
    sub new { bless {}, shift }
}

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'In golden',
    source => {source_table => 'records', primary_key => 'id', fields => [qw(id name price)],
        columns => {id => {type => 'integer'}, name => {type => 'string'}, price => {type => 'decimal'}},
        associations => {}},
    schemas => {}, joins => {},
});
my %adapters = map { $_ => Selecto->adapter($_ => (dbh => InGolden::DBH->new)) } qw(postgresql sqlite);
my %marker = (postgresql => sub { '$' . $_[0] }, sqlite => sub { '?' });

sub engine {
    my ($adapter, @limits) = @_;
    return Selecto::Engine->new(domain => $domain, adapter => $adapters{$adapter},
        limits => Selecto::Limits->new(@limits));
}

sub ast_query {
    my ($field, $values, @limits) = @_;
    my $filter = Selecto::Expression->from_filter_ast(['in', $field, $values], 0,
        Selecto::OperationBudget->new(limits => Selecto::Limits->new(@limits), code => 'invalid_query'));
    return Selecto::Query->new->select('id')->where($filter)->order_by('id', 'asc');
}

sub api_query {
    my ($field, $values, @limits) = @_;
    local $Selecto::Expression::_CONSTRUCTION_LIMITS = Selecto::Limits->new(@limits);
    return Selecto::Query->new->select('id')->where(Selecto::Expression->in($field, $values))->order_by('id', 'asc');
}

sub expected_sql {
    my ($adapter, $field, $count) = @_;
    return qq{SELECT "s0"."id" FROM "records" AS "s0" WHERE "s0"."$field" IN (}
        . join(', ', map { $marker{$adapter}->($_) } 1 .. $count) . qq{) ORDER BY "s0"."id" ASC};
}

# Numeric and string flags of a bound scalar: DBI drivers that bind by type
# (DBD::SQLite) must see the same kind of value as before.
sub kind_of {
    my ($value) = @_;
    return 'undef' unless defined $value;
    my $flags = B::svref_2object(\$value)->FLAGS;
    return join '', ($flags & (B::SVf_IOK | B::SVf_NOK) ? 'num' : ''), ($flags & B::SVf_POK ? 'str' : '');
}

sub error_of {
    my ($run) = @_;
    return eval { $run->(); 1 } ? 'ok'
        : blessed($@) && $@->isa('Selecto::Error') ? $@->to_hash : "$@";
}

sub refusal {
    my ($message, $maximum) = @_;
    return {type => 'invalid_query', message => $message, details => defined($maximum) ? {maximum => $maximum} : {}};
}

my %lists = (
    ints_1 => [7],
    ints_2 => [1, 2],
    ints_100 => [1 .. 100],
    ints_500 => [map { 2 * $_ + 1 } 0 .. 499],
    ints_1000 => [1 .. 1000],
    decimals => ['12.50', '0.10', '-3.5', '1000', '0.00001'],
    strings => ['a', 'é', 'ü' x 10, '', ' x ', q{q'uote}, 'x' x 300],
    nulls => [undef, 1, undef],
    mixed => [1, 'b', '2.5', undef, 0],
);

subtest 'SQL and parameters for IN lists of several sizes and types' => sub {
    for my $name (sort keys %lists) {
        my $values = $lists{$name};
        my $count = @$values;
        my @kinds = map { kind_of($_) } @$values;
        for my $field (qw(id name price)) {
            for my $via (['ast', \&ast_query], ['api', \&api_query]) {
                my ($label, $build) = @$via;
                for my $adapter (sort keys %adapters) {
                    my $statement = engine($adapter, max_filter_values => 1000)
                        ->compile($build->($field, $values, max_filter_values => 1000));
                    my $case = "$name $field $label $adapter";
                    is $statement->sql, expected_sql($adapter, $field, $count), "$case SQL";
                    is_deeply $statement->params, $values, "$case parameters";
                    is_deeply [map { kind_of($_) } @{$statement->params}], \@kinds, "$case parameter kinds";
                }
            }
        }
    }
};

subtest 'JSON booleans in a filter AST bind as 1 and 0' => sub {
    my $values = [JSON::PP::true, JSON::PP::false, 1, 0];
    for my $adapter (sort keys %adapters) {
        my $statement = engine($adapter)->compile(ast_query('id', $values));
        is $statement->sql, expected_sql($adapter, 'id', 4), "$adapter SQL";
        is_deeply $statement->params, [1, 0, 1, 0], "$adapter parameters";
        ok !grep({ ref } @{$statement->params}), "$adapter binds plain scalars";
    }
    my $statement = engine('postgresql')->compile(Selecto::Query->new->select('id')->where(
        Selecto::Expression->from_filter_ast(['and', ['in', 'id', [JSON::PP::true, 5]], ['not', ['in', 'name', [undef, 'x']]]]))
        ->order_by('id', 'asc'));
    is $statement->sql, 'SELECT "s0"."id" FROM "records" AS "s0" WHERE ("s0"."id" IN ($1, $2)) AND (NOT ("s0"."name" IN ($3, $4))) ORDER BY "s0"."id" ASC',
        'nested IN lists number their parameters in order';
    is_deeply $statement->params, [1, 5, undef, 'x'], 'nested IN parameters in order';
};

subtest 'IN lists are refused at the same limits' => sub {
    is error_of(sub { ast_query('id', [1 .. 100]) }), 'ok', 'default member limit accepted (AST)';
    is_deeply error_of(sub { ast_query('id', [1 .. 101]) }),
        refusal('in members exceeds its resource limit', 100), 'default member limit plus one refused (AST)';
    is error_of(sub { api_query('id', [1 .. 100]) }), 'ok', 'default member limit accepted (API)';
    is_deeply error_of(sub { api_query('id', [1 .. 101]) }),
        refusal('expression members exceeds its resource limit', 100), 'default member limit plus one refused (API)';
    is error_of(sub { ast_query('id', $lists{ints_500}, max_filter_values => 500) }), 'ok', 'raised member limit accepted';
    is_deeply error_of(sub { ast_query('id', [@{$lists{ints_500}}, 1001], max_filter_values => 500) }),
        refusal('in members exceeds its resource limit', 500), 'raised member limit plus one refused';

    my @limits = (max_filter_values => 1000);
    my $query = ast_query('id', $lists{ints_500}, @limits);
    is error_of(sub { engine('postgresql', @limits, max_generated_parameters => 500)->compile($query) }), 'ok',
        'exact generated parameter count accepted';
    is_deeply error_of(sub { engine('postgresql', @limits, max_generated_parameters => 499)->compile($query) }),
        refusal('generated parameters exceeds its resource limit', 499), 'one generated parameter over refused';

    my $bytes = 0;
    $bytes += length("$_") for @{$lists{ints_500}};
    is error_of(sub { engine('postgresql', @limits, max_parameter_bytes => $bytes)->compile(
        ast_query('id', $lists{ints_500}, @limits, max_parameter_bytes => $bytes)) }), 'ok', 'exact parameter bytes accepted';
    is_deeply error_of(sub { ast_query('id', $lists{ints_500}, @limits, max_parameter_bytes => $bytes - 1) }),
        refusal('operation parameter bytes exceeds its resource limit', $bytes - 1), 'one parameter byte over refused (AST)';
    is_deeply error_of(sub { engine('postgresql', @limits, max_parameter_bytes => $bytes - 1)->compile($query) }),
        refusal('operation parameter bytes exceeds its resource limit', $bytes - 1), 'one parameter byte over refused (compile)';

    is error_of(sub { ast_query('name', ['é' x 2048]) }), 'ok', 'exact UTF-8 value bytes accepted';
    is_deeply error_of(sub { ast_query('name', ['a', 'é' x 2048 . 'x']) }),
        refusal('in member exceeds its resource limit', 4096), 'one UTF-8 value byte over refused (AST)';
    is_deeply error_of(sub { api_query('name', ['a', 'y' x 4097]) }),
        refusal('expression member exceeds its resource limit', 4096), 'one value byte over refused (API)';

    is_deeply error_of(sub { ast_query('id', []) }), refusal('in filter requires a non-empty literal list'),
        'empty AST list refused';
    is_deeply error_of(sub { ast_query('id', [1, [2]]) }), refusal('in filter requires a non-empty literal list'),
        'reference member refused (AST)';
    is_deeply error_of(sub { api_query('id', [1, [2]]) }), refusal('expression member must be a scalar'),
        'reference member refused (API)';
    is_deeply error_of(sub { engine('postgresql')->compile(api_query('id', [])) }),
        refusal('IN requires at least one value'), 'empty API list refused at compile';
};

done_testing;
