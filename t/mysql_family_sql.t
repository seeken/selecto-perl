use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;
use Selecto::Write ();

# A recorder handle that reports a server version, so version-gated features
# compile without a server.
package VersionedDBH {
    our @ISA = ('TestSelecto::DBH');
    sub selectrow_array {
        my ($self, $sql) = @_;
        return $self->{version} if $sql eq 'SELECT VERSION()';
        return;
    }
}

my $x = 'Selecto::Expression';
my $domain = Selecto::Domain->new(
    name => 'Orders', table => 'orders',
    fields => {id => 'integer', person_id => 'integer', state => 'string', total => 'decimal', score => 'integer'},
);

sub compile_for {
    my ($name, $version, $build) = @_;
    my $dbh = TestSelecto::DBH->new;
    bless $dbh, 'VersionedDBH';
    $dbh->{version} = $version;
    my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
    return $engine->compile($build->($engine->query));
}

for my $case (['mysql', '8.4.11'], ['mariadb', '11.4.13-MariaDB-ubu2404']) {
    my ($name, $version) = @$case;
    my $adapter = Selecto->adapter($name => (dbh => bless({%{TestSelecto::DBH->new}, version => $version}, 'VersionedDBH')));
    ok($adapter->supports($_), "$name supports $_") for qw(cte recursive_cte window_functions set_operations rollup json_rowset);
    ok($adapter->supports('lateral_join'), "$name supports lateral joins (lowered on MariaDB)");
    my $old = Selecto->adapter($name => (dbh => bless({%{TestSelecto::DBH->new},
        version => $name eq 'mysql' ? '5.7.44' : '10.1.48-MariaDB'}, 'VersionedDBH')));
    ok(!$old->supports('cte'), "$name refuses CTEs on an old server");

    # PostgreSQL NULL placement: a leading IS NULL key in every ORDER BY.
    my $plain = compile_for($name, $version, sub { $_[0]->select('id')->order_by('state', 'desc') });
    like($plain->sql, qr/ORDER BY \(`s0`\.`state` IS NULL\) DESC, `s0`\.`state` DESC\z/, "$name orders NULLs first descending");

    my $set = compile_for($name, $version, sub {
        my $base = $_[0]->select('id');
        $base->where($x->lte('id', 2))->union($base->where($x->eq('id', 3)))->order_by('id');
    });
    like($set->sql, qr/\) AS `__selecto_set` ORDER BY \(`__selecto_set`\.`id` IS NULL\) ASC, `__selecto_set`\.`id` ASC\z/,
        "$name orders a set operation by qualified output columns");

    # Lessons 49/49a: an aggregate aliased like a source column is ordered by
    # the derived table's qualified column, never by a bare alias.
    my $grouped = compile_for($name, $version, sub {
        $_[0]->select('person_id', $x->max('score')->as('score'))->group_by('person_id')->order_by($x->max('score'))
    });
    like($grouped->sql, qr/\) AS `__selecto_ordered` ORDER BY \(`__selecto_ordered`\.`score` IS NULL\) ASC, `__selecto_ordered`\.`score` ASC\z/,
        "$name orders a grouped aggregate through the derived table");
    unlike($grouped->sql, qr/ORDER BY \(`score`/, "$name never orders by a bare output alias");

    my $window = compile_for($name, $version, sub {
        $_[0]->select('id', $x->row_number(order_by => [['total', 'asc']])->as('position'))
    });
    like($window->sql, qr/ROW_NUMBER\(\) OVER \(ORDER BY \(`s0`\.`total` IS NULL\) ASC, `s0`\.`total` ASC\)/,
        "$name window ordering places NULLs as PostgreSQL");
    my $range = eval { compile_for($name, $version, sub {
        $_[0]->select('id', $x->window_sum('total', order_by => [['total', 'asc']],
            frame => {type => 'range', start => {preceding => 1}, end => 'current_row'})->as('s'))
    }); 1 };
    ok(!$range && $@->code eq 'unsupported_feature', "$name refuses a RANGE offset frame it cannot NULL-order");

    my $rollup = compile_for($name, $version, sub {
        $_[0]->select('state', $x->count->as('n'), $x->grouping('state')->as('g'))->group_by_rollup('state')->order_by('state')
    });
    like($rollup->sql, qr/UNION ALL/, "$name rolls up with grouped UNION ALL branches");
    unlike($rollup->sql, qr/GROUPING\(|WITH ROLLUP|NULLS (?:FIRST|LAST)/, "$name rollup avoids GROUPING() and NULLS clauses");
    like($rollup->sql, qr/MIN\(CASE WHEN 1 = 0 THEN `s0`\.`state` END\)/, "$name rolled-up dimensions keep their type");

    my $lateral = compile_for($name, $version, sub {
        my $child = $_[0]->select('id')->where($x->eq('state', 'open'))->order_by('id', 'desc')->limit(1);
        $_[0]->lateral_join('latest', $domain, $child, columns => ['order_id'], correlations => {person_id => 'id'})
            ->select('id', $x->field('latest.order_id')->as('latest_id'))->where($x->gt('id', 0))
    });
    if ($name eq 'mariadb') {
        unlike($lateral->sql, qr/LATERAL/, 'mariadb lowers a lateral join');
        like($lateral->sql, qr/ROW_NUMBER\(\) OVER \(PARTITION BY `l_latest`\.`person_id` ORDER BY \(`l_latest`\.`id` IS NULL\) DESC, `l_latest`\.`id` DESC\)/,
            'mariadb ranks lowered lateral rows per parent in the child order');
        like($lateral->sql, qr/`__selecto_lateral_row` > 0 AND `latest`\.`__selecto_lateral_row` <= 1/, 'mariadb keeps the child limit');
    } else {
        like($lateral->sql, qr/LEFT JOIN LATERAL/, 'mysql keeps native LATERAL');
    }
    is_deeply($lateral->params, ['open', 0], "$name binds lateral parameters in text order");

    # Lesson 48: anonymous parameters bind in SQL text order.
    my $ordered = compile_for($name, $version, sub {
        $_[0]->select('id', $x->value(['coalesce', ['field', 'state'], ['literal', 'none', 'string']])->as('label'))
            ->where($x->eq('state', 'open'))
    });
    is_deeply($ordered->params, ['none', 'open'], "$name binds SELECT parameters before WHERE parameters");

    # A format zone PostgreSQL would read differently (the host's 'local'
    # zone, offsets) is refused before execution.
    my $dated = Selecto::Domain->new(name => 'Events', table => 'events',
        fields => {id => 'integer', at => 'utc_datetime'});
    my $events = Selecto::Engine->new(domain => $dated, adapter => Selecto->adapter($name =>
        (dbh => bless({%{TestSelecto::DBH->new}, version => $version}, 'VersionedDBH'))));
    for my $zone ('local', '+0500') {
        my $refused = eval { $events->compile($events->query->select($x->datetime_format('at', 'day', timezone => $zone)->as('d'))); 1 }
            ? 'compiled' : $@->code;
        is($refused, 'invalid_query', "$name refuses the format zone $zone");
    }
    ok(eval { $events->compile($events->query->select($x->datetime_format('at', 'day', timezone => 'Europe/Paris')->as('d'))) },
        "$name compiles an IANA format zone");

    # Tenant identity compares exactly on a text tenant column (bound twice,
    # in text order); a numeric tenant column compiles as before.
    for my $tenant_type ('string', 'integer') {
        my $relation = sub {
            my ($table, %columns) = @_;
            return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
                columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {},
                tenant_field => 'tenant_id'};
        };
        my $source = $relation->('orders', id => 'integer', tenant_id => $tenant_type, state => 'string');
        $source->{associations} = {lines => {queryable => 'line', owner_key => 'id', related_key => 'order_id'}};
        my $tenanted = Selecto::Domain->parse({schema_version => 1, name => 'Orders', source => $source,
            schemas => {line => $relation->('lines', id => 'integer', order_id => 'integer', tenant_id => $tenant_type)},
            joins => {}});
        my $dbh = bless({%{TestSelecto::DBH->new}, version => $version}, 'VersionedDBH');
        my $engine = Selecto::Engine->new(domain => $tenanted, adapter => Selecto->adapter($name => (dbh => $dbh)),
            scope => {tenant => 't1'});
        my $statement = $engine->compile($engine->query->select('id', 'lines.id')->where($x->eq('state', 'open')));
        if ($tenant_type eq 'string') {
            like($statement->sql, qr/\(`s0`\.`tenant_id` = \? AND CAST\(CONVERT\(`s0`\.`tenant_id` USING utf8mb4\) AS BINARY\) = CAST\(\? AS BINARY\)\)/,
                "$name binds a text tenant exactly");
            like($statement->sql, qr/\(`s0`\.`tenant_id` = `j_lines`\.`tenant_id` AND CAST\(CONVERT\(`s0`\.`tenant_id` USING utf8mb4\) AS BINARY\) = CAST\(CONVERT\(`j_lines`\.`tenant_id` USING utf8mb4\) AS BINARY\)\)/,
                "$name pairs text tenants exactly");
            is_deeply($statement->params, ['t1', 't1', 'open'], "$name binds the tenant twice in text order");
            # Write predicates on a text tenant column are exact or refused.
            my $write = sub {
                my ($predicate) = @_;
                my $command = Selecto::Write::Command->new(operation => 'delete', relation => 'orders',
                    predicate => $predicate, metadata => {__selecto_tenant_fields => ['tenant_id'],
                        __selecto_insert_types => {tenant_id => 'string'}});
                return eval { Selecto->adapter($name => (dbh => $dbh))->_compile_write($command)->{sql} }
                    // (ref($@) ? $@->code : "died: $@");
            };
            like($write->($x->eq('tenant_id', 't1')), qr/AS BINARY\) = CAST\(\? AS BINARY\)/, "$name writes compare a text tenant exactly");
            is($write->($x->in('tenant_id', ['t1', undef])), 'unsupported_feature', "$name refuses a write tenant IN with NULL");
            is($write->($x->eq('tenant_id', undef)), 'unsupported_feature', "$name refuses a write tenant comparison with NULL");
            # A literal-first comparison in a host required predicate is exact too.
            my $reversed = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)),
                domain => $tenanted->with_required_predicate($x->eq($x->literal('t1'), $x->field('tenant_id'))));
            my $sql = $reversed->compile($reversed->query->select('id'))->sql;
            like($sql, qr/CAST\(CONVERT\(`s0`\.`tenant_id` USING utf8mb4\) AS BINARY\) = CAST\(\? AS BINARY\)/,
                "$name compares a literal-first tenant predicate exactly");
            # A tenant comparison that cannot be rendered exactly is refused.
            for my $case (
                ['a NULL', $x->eq('tenant_id', undef)],
                ['a computed value', $x->eq('tenant_id', $x->value(['coalesce', ['field', 'state'], ['literal', 't1', 'string']]))],
                ['an IN list with NULL', $x->in('tenant_id', ['t1', undef])],
            ) {
                my ($label, $predicate) = @$case;
                my $plain = Selecto::Engine->new(domain => $tenanted, adapter => Selecto->adapter($name => (dbh => $dbh)));
                my $refused = eval { $plain->compile($plain->query->select('id')->where($predicate)); 'compiled' }
                    // (ref($@) ? $@->code : "died: $@");
                is($refused, 'unsupported_feature', "$name refuses a tenant comparison with $label");
            }
        } else {
            unlike($statement->sql, qr/BINARY/, "$name compiles a numeric tenant without a byte comparison");
            is_deeply($statement->params, ['t1', 'open'], "$name binds a numeric tenant once");
        }
    }
}

done_testing;
