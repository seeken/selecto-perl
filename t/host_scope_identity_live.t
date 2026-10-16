use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Write ();
use Selecto::WriteRules ();

# Host-trusted scope compares exactly only on text columns. A declared
# temporal column compares as PostgreSQL does (a byte comparison would widen
# <> and NOT IN and break the ISO 'T' form). Internal reads that apply a
# command's trusted scope (graph read anchors, data-rule candidates) compare
# it as host identity, never as a caller filter.

my $x = 'Selecto::Expression';
my @backends;
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        $dbh->do('SET client_min_messages TO warning');
        $dbh->do(q{SET TIME ZONE 'UTC'});
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        return DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1});
    }];
}
plan skip_all => 'no live PostgreSQL, MySQL or MariaDB is configured' unless @backends;

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $my = $name ne 'postgresql';

    subtest "$name host comparisons on declared temporal columns behave as PostgreSQL" => sub {
        my $stamp = $my ? 'TIMESTAMP(3) NULL' : 'TIMESTAMP(3)';
        my $reset = sub {
            $dbh->do('DROP TABLE IF EXISTS selecto_hs_times');
            $dbh->do("CREATE TABLE selecto_hs_times (id INT PRIMARY KEY, at $stamp, day DATE, name VARCHAR(20))");
            $dbh->do(q{INSERT INTO selecto_hs_times VALUES (1, '2024-01-01 10:00:00', '2024-01-01', 'a'),
                (2, '2024-01-01 10:00:00', '2024-01-01', 'a'), (3, '2024-01-01 10:00:00.5', '2024-01-02', 'a')});
        };
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Times',
            source => relation('selecto_hs_times', id => 'integer', at => 'naive_datetime', day => 'date', name => 'string'),
            schemas => {}, joins => {},
            writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
                fields => {name => {updatable => 1}}}});
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $changed = sub { [map { $_->[0] } @{$dbh->selectall_arrayref(q{SELECT id FROM selecto_hs_times WHERE name = 'x' ORDER BY id})}] };
        for my $case (
            ['at <> instant', $x->ne('at', '2024-01-01 10:00:00'), [3]],
            ['at NOT IN', $x->not($x->in('at', ['2024-01-01 10:00:00'])), [3]],
            ['at = instant', $x->eq('at', '2024-01-01 10:00:00'), [1, 2]],
            ['at = ISO form', $x->eq('at', '2024-01-01T10:00:00'), [1, 2]],
            ['day = date', $x->eq('day', '2024-01-01'), [1, 2]],
            ['day <> date', $x->ne('day', '2024-01-01'), [3]],
        ) {
            my ($label, $predicate, $expected) = @$case;
            $reset->();
            my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain->with_required_predicate($predicate));
            my $rows = eval { $engine->all($engine->query->select('id')->order_by('id'))->{rows} };
            is_deeply([map { $_->[0] } @{$rows // []}], $expected, "required $label reads the PostgreSQL rows")
                or diag(blessed($@) ? $@->code . ' ' . $@->message : $@);
            is(code_of(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update',
                relation => 'selecto_hs_times', assignments => {name => q(x)}, predicate => $x->gt(q(id), 0), expected_count => scalar(@$expected))) }), q(ok),
                "required $label update runs");
            is_deeply($changed->(), $expected, "required $label updates the PostgreSQL rows");
            $reset->();
            my $plain = Selecto::Engine->new(adapter => $adapter, domain => $domain);
            is(code_of(sub { $plain->execute_write(Selecto::Write::Command->new(operation => 'update',
                relation => 'selecto_hs_times', assignments => {name => 'x'}, predicate => $x->gt(q(id), 0), expected_count => scalar(@$expected),
                scope_predicate => $predicate)) }), 'ok', "scope $label update runs");
            is_deeply($changed->(), $expected, "scope $label updates the PostgreSQL rows");
        }
        # A write compiled outside the engine declares no column types: an
        # undeclared column compares its bytes only when it holds text, so a
        # temporal column still matches the ISO form and excludes nothing more.
        for my $case (['= ISO form', $x->eq('at', '2024-01-01T10:00:00'), 2], ['<> instant', $x->ne('at', '2024-01-01 10:00:00'), 1],
            ['org text', $x->eq('name', 'A'), 0]) {
            my ($label, $predicate, $expected) = @$case;
            $reset->();
            my $result;
            is(code_of(sub { $result = $adapter->execute_write_unsafe(Selecto::Write::Command->new(operation => 'update',
                relation => 'selecto_hs_times', assignments => {name => 'x'}, predicate => $x->gt('id', 0), expected_count => $expected,
                scope_predicate => $predicate)) }), 'ok', "an untyped scope $label update runs");
            is($result && $result->affected_rows, $expected, "an untyped scope $label updates the PostgreSQL rows");
        }
        $dbh->do('DROP TABLE selecto_hs_times');
    };

    subtest "$name graph read anchors and rule candidates apply the trusted scope exactly" => sub {
        my $reset = sub {
            $dbh->do('DROP TABLE IF EXISTS selecto_hs_children');
            $dbh->do('DROP TABLE IF EXISTS selecto_hs_roots');
            $dbh->do('CREATE TABLE selecto_hs_roots (id INT PRIMARY KEY, org_key VARCHAR(16) NOT NULL, name VARCHAR(20))');
            $dbh->do('CREATE TABLE selecto_hs_children (id INT PRIMARY KEY, root_id INT, note VARCHAR(20))');
            $dbh->do(q{INSERT INTO selecto_hs_roots VALUES (1, 't1', 'own'), (2, 'T1', 'upper'), (3, 't1 ', 'padded')});
        };
        my $child = {schema_version => 1, name => 'Children',
            source => relation('selecto_hs_children', id => 'integer', root_id => 'integer', note => 'string'),
            schemas => {}, joins => {},
            writes => {operations => {insert => {enabled => 1}}, fields => {id => {insertable => 1}, note => {insertable => 1}}}};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Roots',
            source => relation('selecto_hs_roots', id => 'integer', org_key => 'string', name => 'string'),
            schemas => {}, joins => {},
            writes => {operations => {update => {enabled => 1}}, fields => {name => {updatable => 1}},
                relationships => {children => {writable => 1, parent_key => 'id', child_key => 'root_id',
                    allowed_ops => ['insert'], domain => $child}}}});
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $domain);
        my $anchor = sub {
            my ($id, %scope) = @_;
            my $command = Selecto::Write::Command->new(operation => 'update', relation => 'selecto_hs_roots',
                predicate => $x->eq('id', $id), %scope);
            return $command;
        };
        my $graph = sub {
            my ($root) = @_;
            return Selecto::Write::Graph->new(nodes => [
                {id => 'root', reference_only => 1, command => $root},
                {id => 'child', command => Selecto::Write::Command->new(operation => 'insert', relation => 'selecto_hs_children',
                    assignments => {id => 10, note => 'n'}), bindings => [{from => 'root', key => 'id', field => 'root_id'}]},
            ]);
        };
        my $children = sub { [map { $_->[0] } @{$dbh->selectall_arrayref('SELECT root_id FROM selecto_hs_children ORDER BY id')}] };
        for my $id (2, 3) {
            for my $case (
                ['scope predicate', sub { $anchor->($id, scope_predicate => $x->eq('org_key', 't1')) }],
                ['literal-left scope predicate', sub { $anchor->($id, scope_predicate => $x->eq($x->literal('t1'), $x->field('org_key'))) }],
                ['query enforcement', sub { $engine->enforce_query($anchor->($id), $engine->query->where($x->eq('org_key', 't1'))) }],
            ) {
                my ($label, $build) = @$case;
                $reset->();
                isnt(code_of(sub { $engine->execute_graph($graph->($build->())) }), 'ok',
                    "a read anchor on another tenant's root $id under a $label is refused");
                is_deeply($children->(), [], 'no child was bound to it');
            }
        }
        $reset->();
        is(code_of(sub { $engine->execute_graph($graph->($anchor->(1, scope_predicate => $x->eq('org_key', 't1')))) }), 'ok',
            'a read anchor on the own root binds its child');
        is_deeply($children->(), [1], 'the child belongs to the own root');

        # A data-rule candidate read applies the command's scope as host identity.
        $reset->();
        my $ruled = Selecto::Domain->new(name => 'Rules', table => 'selecto_hs_roots',
            fields => {id => 'integer', org_key => 'string', name => 'string'},
            rules => {schema => 'selecto.data_rules.v1',
                definitions => {name => {version => 1, test => {op => 'presence.required'}}}, normalizers => {},
                bindings => {stored => {subject => {scope => 'candidate', path => ['name']},
                    rule => {id => 'name', version => 1}, operations => ['update']}}});
        my $rule_engine = Selecto::Engine->new(adapter => Selecto->adapter($name => (dbh => $dbh)), domain => $ruled);
        for my $id (2, 3) {
            my $command = Selecto::Write::Command->new(operation => 'update', relation => 'selecto_hs_roots',
                assignments => {name => 'x'}, predicate => $x->eq('id', $id), expected_count => 1,
                scope_predicate => $x->eq('org_key', 't1'));
            is(code_of(sub { Selecto::WriteRules->candidate($rule_engine, $command) }), 'cardinality_mismatch',
                "a rule candidate never reads another tenant's row $id");
        }
        $dbh->do('DROP TABLE IF EXISTS selecto_hs_children');
        $dbh->do('DROP TABLE IF EXISTS selecto_hs_roots');
    };
    $dbh->disconnect;
}

done_testing;
