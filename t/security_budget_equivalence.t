use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::Limits;
use Selecto::OperationBudget;
use Selecto::Query;
use Selecto::Write;

# Selecto::OperationBudget's admission checks were inlined for speed. This is
# the implementation they replaced, verbatim, as the oracle: the optimized
# budget must accept and refuse exactly the same inputs at exactly the same
# thresholds, with the same codes, messages, details and counters.
{
    package Reference::OperationBudget;
    use bytes ();
    use JSON::PP ();
    use Scalar::Util qw(blessed refaddr reftype);
    sub new {
        my ($class, %args) = @_;
        my $limits = $args{limits} // Selecto::Limits->new;
        return bless {limits => $limits, code => $args{code} // 'resource_limit_exceeded', counts => {}}, $class;
    }
    sub limits { $_[0]->{limits} }
    sub _check {
        my ($self, $limit, $count, $label) = @_;
        return $self->limits->check_count($limit, $count, $self->{code}, $label);
    }
    sub consume_count {
        my ($self, $limit, $count, %options) = @_;
        $self->{counts}{$limit} += $count;
        return $self->_check($limit, $self->{counts}{$limit}, $options{label} // $limit);
    }
    sub consume_value {
        my ($self, $value, %options) = @_;
        my $label = $options{label} // 'parameter';
        $value = $value ? 1 : 0 if JSON::PP::is_bool($value);
        my $bytes = $self->limits->check_bytes('max_value_bytes', $value, $self->{code}, $label);
        $self->consume_count('max_parameter_bytes', $bytes, label => 'operation parameter bytes');
        return $value;
    }
    sub consume_parameters {
        my ($self, $values, %options) = @_;
        Selecto::Error->throw($self->{code}, 'parameters must be an array') unless ref($values) eq 'ARRAY';
        $self->consume_count('max_generated_parameters', scalar(@$values), label => 'generated parameters');
        $self->consume_value($_, %options) for @$values;
        return $values;
    }
    sub check_tree {
        my ($self, $value, %options) = @_;
        my $label = $options{label} // 'input';
        my $byte_limit = $options{bytes_limit} // 'max_state_bytes';
        my $response = $byte_limit eq 'max_response_bytes' || $byte_limit eq 'max_import_preview_bytes';
        my $nodes_limit = $options{nodes_limit} // ($response ? 'max_response_nodes' : 'max_expression_nodes');
        my $depth_limit = $options{depth_limit} // ($response ? 'max_response_depth' : 'max_expression_depth');
        my $scalar_limit = $options{scalar_limit};
        my %allowed = map { $_ => 1 } @{$options{allowed_classes} // []};
        my (%active, @stack);
        push @stack, [$value, 0, 0];
        $self->consume_count($nodes_limit, 1, label => "$label nodes");
        my $bytes = 0;
        while (@stack) {
            my ($node, $depth, $leave) = @{pop @stack};
            if ($leave) { delete $active{$leave}; next }
            $self->_check($depth_limit, $depth, "$label depth");
            if (!ref($node) || JSON::PP::is_bool($node)) {
                my $scalar = JSON::PP::is_bool($node) ? ($node ? 1 : 0) : $node;
                my $size = defined($scalar) ? bytes::length($scalar) : 0;
                $self->_check($scalar_limit, $size, "$label value bytes") if defined $scalar_limit;
                $bytes += $size;
            } else {
                my $type = reftype($node) // '';
                Selecto::Error->throw($self->{code}, "$label contains an unsupported reference")
                    if ($type ne 'ARRAY' && $type ne 'HASH') || (blessed($node) && !$allowed{blessed($node)});
                my $id = refaddr($node);
                Selecto::Error->throw($self->{code}, "$label contains a cycle") if $active{$id};
                $active{$id} = 1;
                push @stack, [undef, 0, $id];
                my $count = $type eq 'ARRAY' ? scalar(@$node) : scalar(keys %$node);
                $self->consume_count($nodes_limit, $count, label => "$label nodes");
                if ($type eq 'ARRAY') {
                    push @stack, [$node->[$_], $depth + 1, 0] for reverse 0 .. $#$node;
                } else {
                    for my $key (keys %$node) {
                        $bytes += bytes::length($key);
                        $self->_check($byte_limit, ($self->{counts}{"tree_bytes:$byte_limit"} // 0) + $bytes, "$label bytes");
                        push @stack, [$node->{$key}, $depth + 1, 0];
                    }
                }
            }
            $self->_check($byte_limit, ($self->{counts}{"tree_bytes:$byte_limit"} // 0) + $bytes, "$label bytes");
        }
        $self->{counts}{"tree_bytes:$byte_limit"} += $bytes;
        return $bytes;
    }
}

sub outcome {
    my ($budget, $calls) = @_;
    my @results;
    my $ok = eval {
        for my $call (@$calls) {
            my ($method, @arguments) = @$call;
            my $result = $budget->$method(@arguments);
            push @results, ref($result) ? 'ref' : $result;
        }
        1;
    };
    my $error = $@;
    return {results => \@results, counts => {%{$budget->{counts}}}, ($ok ? () : (error =>
        blessed($error) && $error->isa('Selecto::Error') ? $error->to_hash : "$error"))};
}

sub same_outcome {
    my ($limits, $calls, $name) = @_;
    my $new = outcome(Selecto::OperationBudget->new(limits => $limits, code => 'limited'), $calls);
    my $old = outcome(Reference::OperationBudget->new(limits => $limits, code => 'limited'), $calls);
    return is_deeply($new, $old, $name);
}

my $shared = ['ab', 'é'];
my $cycle = [1]; push @$cycle, $cycle;
my %trees = (
    scalar => 'abc',
    utf8 => ['ééé', 'x'],
    empty => [],
    empty_hash => {},
    flat => [1 .. 12],
    nested => [[1, [2, [3, [4, [5]]]]], {k => 'v', key => [1, 2, {deep => 'é'}]}],
    booleans => [JSON::PP::true, JSON::PP::false, !!1, !!0, undef, 0, ''],
    shared => [$shared, $shared, {a => $shared}],
    hash => {alpha => 'a', beta => ['b', 'bb'], gamma => {delta => undef, 'ε' => 'ζ'}},
    expression => [Selecto::Expression->all(Selecto::Expression->eq('a', 'x'),
        Selecto::Expression->in('b', [1, 2, 3]))->as('c')],
    disallowed => [bless({}, 'Some::Class')],
    code => [sub { 1 }],
    cycle => $cycle,
);

subtest 'check_tree matches the reference at every threshold' => sub {
    for my $name (sort keys %trees) {
        for my $classes ([], ['Selecto::Expression']) {
            for my $nodes (1 .. 24) {
                same_outcome(Selecto::Limits->new(max_expression_nodes => $nodes),
                    [[check_tree => $trees{$name}, allowed_classes => $classes]], "$name nodes $nodes");
            }
            for my $depth (1 .. 7) {
                same_outcome(Selecto::Limits->new(max_expression_depth => $depth),
                    [[check_tree => $trees{$name}, allowed_classes => $classes]], "$name depth $depth");
            }
            for my $bytes (1 .. 70) {
                same_outcome(Selecto::Limits->new(max_state_bytes => $bytes),
                    [[check_tree => $trees{$name}, allowed_classes => $classes],
                     [check_tree => $trees{$name}, allowed_classes => $classes, label => 'again']],
                    "$name cumulative bytes $bytes");
            }
            for my $scalar (1 .. 4) {
                same_outcome(Selecto::Limits->new(max_value_bytes => $scalar),
                    [[check_tree => $trees{$name}, allowed_classes => $classes, scalar_limit => 'max_value_bytes']],
                    "$name scalar bytes $scalar");
            }
        }
        for my $nodes (1, 5, 20) {
            same_outcome(Selecto::Limits->new(max_response_nodes => $nodes, max_response_depth => 3),
                [[check_tree => $trees{$name}, bytes_limit => 'max_response_bytes']], "$name response limits $nodes");
        }
    }
};

subtest 'parameter admission matches the reference at every threshold' => sub {
    my @values = ('a', 'éé', 12345, undef, JSON::PP::true, JSON::PP::false, !!0, '', 'abcdef');
    for my $value_bytes (1 .. 7) {
        for my $parameter_bytes (1 .. 14) {
            my $limits = Selecto::Limits->new(max_value_bytes => $value_bytes, max_parameter_bytes => $parameter_bytes);
            same_outcome($limits, [map { [consume_value => $_, label => 'value'] } @values],
                "values $value_bytes/$parameter_bytes");
            same_outcome($limits, [[consume_parameters => \@values, label => 'statement parameter']],
                "parameters $value_bytes/$parameter_bytes");
        }
    }
    for my $count (1 .. 10) {
        same_outcome(Selecto::Limits->new(max_generated_parameters => $count),
            [[consume_parameters => [1 .. 9]], [consume_parameters => [1]]], "parameter count $count");
    }
    same_outcome(Selecto::Limits->new, [[consume_value => ['a reference']]], 'references keep their refusal');
    same_outcome(Selecto::Limits->new, [[consume_parameters => 'not an array']], 'non-array parameters refused');
    same_outcome(Selecto::Limits->new(max_filter_values => 3),
        [[consume_count => 'max_filter_values', 2], [consume_count => 'max_filter_values', 2, label => 'members']],
        'consume_count accumulates and refuses alike');
};

sub code_of { my ($run) = @_; return eval { $run->(); 1 } ? 'ok' : blessed($@) && $@->can('code') ? $@->code : "$@" }

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Budget equivalence',
    source => {source_table => 'records', primary_key => 'id', fields => [qw(id name tenant_id)],
        columns => {id => {type => 'integer'}, name => {type => 'string', text_case => 'uppercase'},
            tenant_id => {type => 'integer'}}, associations => {}},
    schemas => {}, joins => {},
    writes => {operations => {insert => {enabled => 1}, update => {enabled => 1}},
        fields => {id => {insertable => 1}, name => {insertable => 1, updatable => 1}, tenant_id => {insertable => 1}}},
});

{
    package Budget::DBH;
    sub new { bless {}, shift }
}
my $adapter = Selecto->adapter(postgresql => (dbh => Budget::DBH->new));

subtest 'compile still admits queries and parameters at the same limits' => sub {
    my $query = Selecto::Query->new->select('id')->where(Selecto::Expression->in('id', [1 .. 5]));
    my $parameters = scalar @{Selecto::Engine->new(domain => $domain, adapter => $adapter)->compile($query)->params};
    is $parameters, 5, 'five parameters compiled';
    my $nodes = 0;
    my $probe = Selecto::OperationBudget->new;
    $probe->check_tree($query, label => 'query',
        allowed_classes => [qw(Selecto::Query Selecto::Expression Selecto::Domain Selecto::Domain::Association)]);
    $nodes = $probe->{counts}{max_expression_nodes};
    my $engine = sub { Selecto::Engine->new(domain => $domain, adapter => $adapter, limits => Selecto::Limits->new(@_)) };
    is code_of(sub { $engine->(max_expression_nodes => $nodes)->compile($query) }), 'ok', 'exact node budget accepted';
    is code_of(sub { $engine->(max_expression_nodes => $nodes - 1)->compile($query) }), 'invalid_query', 'one node under refused';
    is code_of(sub { $engine->(max_generated_parameters => 5)->compile($query) }), 'ok', 'exact parameter count accepted';
    is code_of(sub { $engine->(max_generated_parameters => 4)->compile($query) }), 'invalid_query', 'one parameter over refused';
    is code_of(sub { $engine->(max_parameter_bytes => 5)->compile($query) }), 'ok', 'exact parameter bytes accepted';
    is code_of(sub { $engine->(max_parameter_bytes => 4)->compile($query) }), 'invalid_query', 'one byte over refused';

    # Direct adapter compilation, outside an engine, still admits the query
    # and its parameters itself.
    my $direct = sub {
        my %limits = @_;
        local $adapter->{_selecto_compile_limits} = Selecto::Limits->new(%limits);
        return $adapter->compile($domain, $query);
    };
    is code_of(sub { $direct->(max_expression_nodes => $nodes) }), 'ok', 'adapter accepts the exact node budget';
    is code_of(sub { $direct->(max_expression_nodes => $nodes - 1) }), 'invalid_query', 'adapter alone refuses one node under';
    is code_of(sub { $direct->(max_generated_parameters => 4) }), 'invalid_query', 'adapter alone refuses one parameter over';

    # The engine marks only the query it admitted; a different query the
    # adapter compiles while that mark is set is still admitted by the adapter.
    {
        local $adapter->{_selecto_compile_limits} = Selecto::Limits->new(max_expression_nodes => $nodes - 1);
        local $adapter->{_selecto_admitted_query} = Selecto::Query->new->select('id');
        is code_of(sub { $adapter->compile($domain, $query) }), 'invalid_query', 'unmarked query still admitted';
    }
};

subtest 'governed writes refuse at the same limits' => sub {
    my $command = Selecto::Write::Command->new(operation => 'insert', relation => 'records',
        assignments => {id => 1, name => 'abc', tenant_id => 7});
    my $engine = sub { Selecto::Engine->new(domain => $domain, adapter => $adapter, limits => Selecto::Limits->new(@_)) };
    is code_of(sub { $engine->()->preview_write($command) }), 'ok', 'ordinary governed write admitted';
    is code_of(sub { $engine->(max_value_bytes => 2)->preview_write($command) }), 'invalid_write', 'value bytes over refused';
    is code_of(sub { $engine->(max_expression_nodes => 2)->preview_write($command) }), 'invalid_write', 'write tree nodes refused';
    is code_of(sub { Selecto::Expression->in('id', [1 .. 100]) }), 'ok', 'default membership boundary accepted';
    is code_of(sub { Selecto::Expression->in('id', [1 .. 101]) }), 'invalid_query', 'default membership boundary plus one refused';
};

subtest 'copies stay independent' => sub {
    my $metadata = $domain->field_metadata('name');
    $metadata->{text_case} = 'lowercase';
    $metadata->{internal} = 1;
    is $domain->field_metadata('name')->{text_case}, 'uppercase', 'field_metadata still returns a caller-owned copy';
    ok $domain->field_is_public('name'), 'changing a copy does not change the domain';
    my $writes = $domain->writes;
    $writes->{operations}{delete} = {enabled => 1};
    ok !exists $domain->writes->{operations}{delete}, 'writes still returns a caller-owned copy';

    my $command = Selecto::Write::Command->new(operation => 'insert', relation => 'records',
        assignments => {name => 'a', tags => ['x']}, metadata => {note => {deep => 1}});
    my $copy = $command->with_metadata({other => [1]})->with_assignments({name => 'b', tags => ['y']});
    is_deeply $command->assignments, {name => 'a', tags => ['x']}, 'original assignments unchanged';
    is_deeply $command->metadata, {note => {deep => 1}}, 'original metadata unchanged';
    is_deeply $copy->metadata, {other => [1]}, 'copy carries its own metadata';
    my $read = $copy->assignments;
    push @{$read->{tags}}, 'z';
    is_deeply $copy->assignments->{tags}, ['y'], 'accessors still return deep copies';

    my $query = Selecto::Query->new->select('id');
    my $applied = $query->applied_query_library;
    push @{$applied->{segments}}, 'leak';
    my $next = $query->limit(5)->order_by('id');
    is_deeply $next->applied_query_library->{segments}, [], 'query copies do not share caller changes';
    my $with = $query->with_applied_query_library({segments => ['s'], projections => [], projection => undef,
        ordering => undef, views => []});
    is_deeply $with->limit(1)->applied_query_library->{segments}, ['s'], 'applied library carried by copies';
    is_deeply $query->applied_query_library->{segments}, [], 'source query unchanged';
};

done_testing;
