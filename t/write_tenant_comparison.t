use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed refaddr);
use Selecto;

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# A governed write compares the tenant column with the engine's trusted tenant
# in its scope and its post-image scope. The comparison is built once per
# write and shared; what is kept between writes is only the column's field
# expression, per domain object. The tenant is read from the engine on every
# write and bound as a parameter: no tenant reaches another engine's write,
# whether the engines share a base engine (with_scope), a domain or neither.
my $E = 'Selecto::Expression';
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, AutoCommit => 1});
$dbh->do('CREATE TABLE items (id INTEGER PRIMARY KEY, tenant_id INTEGER, name TEXT)');
my $reset = sub { $dbh->do('DELETE FROM items'); $dbh->do(q{INSERT INTO items VALUES (1, 1, 'a'), (2, 2, 'b'), (3, 1, 'c')}) };
my $names = sub { join ',', map { $_->[0] } @{$dbh->selectall_arrayref('SELECT name FROM items ORDER BY id')} };

# legacy: writes.scope.tenant names the column; bound: source.tenant_field.
sub raw {
    my ($kind) = @_;
    return {schema_version => 1, name => 'Items',
        source => {source_table => 'items', primary_key => 'id', fields => [qw(id tenant_id name)],
            columns => {id => {type => 'integer'}, tenant_id => {type => 'integer'}, name => {type => 'string'}},
            associations => {}, ($kind eq 'bound' ? (tenant_field => 'tenant_id') : ())},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}, delete => {enabled => 1}}, fields => {name => {updatable => 1}},
            ($kind eq 'legacy' ? (scope => {tenant => {field => 'tenant_id', required => 1, satisfied_by => ['trusted_context']}}) : ())}};
}
sub base { return Selecto::Engine->new(domain => Selecto::Domain->parse(raw($_[0])), adapter => Selecto->adapter(sqlite => (dbh => $dbh))) }
sub update_cmd {
    my ($id, $name) = @_;
    return Selecto::Write::Command->new(relation => 'items', operation => 'update',
        assignments => {name => $name // 'changed'}, predicate => $E->eq('id', $id));
}
# Every tenant_id comparison in an expression, as [refaddr, value, refaddr of its field].
sub tenant_comparisons {
    my ($expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my ($left, $right) = @{$expression->arguments};
    return ([refaddr($expression), $right->arguments->[0], refaddr($left)])
        if $expression->kind eq 'eq' && blessed($left) && $left->kind eq 'field' && $left->arguments->[0] eq 'tenant_id';
    return map { ref($_) eq 'ARRAY' ? (map { tenant_comparisons($_) } @$_) : tenant_comparisons($_) } @{$expression->arguments};
}
my @keep;    # governed commands stay alive, so no address is reused
sub governed {
    my ($engine, $command) = @_;
    my $governed = $engine->governed_write($command);
    push @keep, $governed;
    return ([tenant_comparisons($governed->scope_predicate)], [tenant_comparisons($governed->metadata->{__selecto_post_image_scope})]);
}

for my $kind (qw(legacy bound)) {
    subtest "$kind tenant column" => sub {
        my $base = base($kind);
        my %engine = map { ($_ => $base->with_scope(tenant => $_)) } 1, 2;
        for my $tenant (1, 2, 1, 2, 2, 1) {
            my ($scope, $post) = governed($engine{$tenant}, update_cmd(1));
            is_deeply([map { $_->[1] } @$scope], [$tenant], "tenant $tenant: its scope compares with its tenant only");
            # (The post-image scope is the scope and the tenant conditions: the comparison twice.)
            is_deeply([map { $_->[1] } @$post], [$tenant, $tenant], "tenant $tenant: and so does its post-image scope");
            is_deeply([map { $_->[0] } @$post], [($scope->[0][0]) x 2], 'one comparison, shared');
        }
        my ($first) = governed($engine{1}, update_cmd(1));
        my ($second) = governed($engine{1}, update_cmd(1));
        isnt($first->[0][0], $second->[0][0], 'each write builds its own comparison');

        $reset->();
        $engine{2}->execute_write(update_cmd(2, 'two'));
        my $error = eval { $engine{1}->execute_write(update_cmd(2, 'leak')); undef } // $@;
        ok($error, "tenant 1 cannot update tenant 2's row");
        $engine{1}->execute_write(update_cmd(3, 'one'));
        is($names->(), 'a,two,one', 'each write reached only its own tenant');
        is($engine{1}->execute_write(Selecto::Write::Command->new(relation => 'items', operation => 'delete',
            predicate => $E->eq('id', 3)))->affected_rows, 1, 'a delete runs under its tenant');
        $error = eval { $engine{1}->execute_write(Selecto::Write::Command->new(relation => 'items', operation => 'delete',
            predicate => $E->eq('id', 2))); undef } // $@;
        ok($error, "and cannot delete tenant 2's row");
        is($names->(), 'a,two', 'which is still there');
    };
}

subtest 'never across domains' => sub {
    # Two domain objects with the same tenant column: each keeps its own field
    # expression, and a domain built again starts afresh.
    my @field;
    for my $kind (qw(legacy legacy bound)) {
        my ($scope) = governed(base($kind)->with_scope(tenant => 7), update_cmd(1));
        my ($again) = governed(base($kind)->with_scope(tenant => 8), update_cmd(1));
        is_deeply([map { $_->[1] } @$scope, @$again], [7, 8], "$kind: each engine's own tenant");
    }
    my $one = base('legacy')->with_scope(tenant => 1);
    my $two = base('legacy')->with_scope(tenant => 1);
    my $field_of = sub { my ($scope) = governed($_[0], update_cmd(1)); return $scope->[0][2] };
    is($field_of->($one), $field_of->($one), 'one domain keeps its tenant field expression');
    isnt($field_of->($one), $field_of->($two), 'another domain object does not share it');
};

subtest 'an engine copied during a write' => sub {
    # with_scope copies are shallow: a copy made from a writing engine does not
    # take that write's comparisons.
    my $base = base('bound');
    my $engine = $base->with_scope(tenant => 1);
    local $engine->{_tenant_comparisons} = [refaddr($engine), {tenant_id => $E->eq('tenant_id', 1)}];
    my $copy = bless {%$engine}, ref($engine);
    $copy->{scope} = {%{$engine->{scope}}, tenant => 2};
    is_deeply([map { $_->[1] } tenant_comparisons($copy->_tenant_comparison('tenant_id'))], [2],
        "the copy compares with its own tenant");
};

done_testing;
