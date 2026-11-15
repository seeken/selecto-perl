use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();
use Selecto::SQLite ();

my $x = 'Selecto::Expression';
my $engine = Selecto::Engine->new(domain => TestSelecto::people_domain(),
    adapter => Selecto::PostgreSQL->new(dbh => TestSelecto::DBH->new));
my $base = $engine->query->select('id');
my ($a, $b, $c) = ($x->gte('id', 1), $x->any($x->eq('name', 'A'), $x->eq('name', 'B')), $x->lt('id', 9));
my $query = $base->where($a)->where($b)->where($c);
is_deeply($query->predicate->arguments->[0][0]->arguments->[0], [$a, $b], 'three calls form an ordered nested AND tree');
is($query->predicate->kind, 'and', 'outer predicate is AND');
my $compiled = $engine->compile($query);
is_deeply($compiled->params, [1, 'A', 'B', 9], 'bound values retain call and explicit OR order');
like($compiled->sql, qr/AND.*OR.*AND/s, 'SQL retains OR grouping inside AND');
ok(!defined($base->predicate), 'persistent base branch unchanged');
is_deeply($engine->compile($query->replace_where($c))->params, [9], 'replace_where replaces composed caller predicate');
ok(!defined($query->clear_where->predicate), 'clear_where restores unfiltered caller state');
ok(!defined($query->replace_where([])->predicate), 'empty replacement clears predicate');
is_deeply($query->where->predicate, $query->predicate, 'empty where append is a no-op');
is_deeply($query->where([])->predicate, $query->predicate, 'empty array append is a no-op');
is_deeply($engine->compile($base->filter($a)->filter($c))->params, [1, 9], 'filter alias composes once');
my $selected = $base->select('name')->select('id', $x->field('name')->as('label'));
is_deeply($engine->compile($selected)->columns, [qw(id name id label)], 'select calls preserve order duplicates and aliases');
is_deeply($engine->compile($selected->select([]))->columns, [qw(id name id label)], 'empty select append does not reset');
is_deeply($engine->compile($selected->replace_selections('name'))->columns, ['name'], 'explicit selection replacement');
is_deeply($selected->clear_selections->selections, [], 'clear restores empty initial selections');
is_deeply($selected->replace_selections([])->selections, [], 'empty replacement clears selections');
is_deeply($engine->compile($selected->clear_selections->select('name'))->columns, ['name'], 'append after clear starts a new list');
is_deeply($engine->compile($base)->columns, ['id'], 'selection branch unchanged');
for my $operation (qw(select replace_selections clear_selections where replace_where clear_where)) {
    my $set = $base->union($base);
    eval { $set->$operation() };
    isa_ok($@, 'Selecto::Error', "$operation retains set mutation restriction");
}
for my $backend ('sqlite', ($ENV{SELECTO_PERL_TEST_POSTGRES_URL} ? 'postgresql' : ())) {
    subtest "$backend live authority combinations" => sub {
        if ($backend eq 'sqlite') { plan skip_all => 'DBD::SQLite unavailable' unless eval { require DBD::SQLite; 1 }; }
        my $dbh;
        if ($backend eq 'sqlite') {
            $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
                {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        } else {
            require Mojo::URL;
            my $url = Mojo::URL->new($ENV{SELECTO_PERL_TEST_POSTGRES_URL});
            $dbh = DBI->connect('dbi:Pg:dbname=' . substr($url->path->to_string, 1)
                . ';host=' . $url->host . ';port=' . $url->port,
                $url->username, $url->password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        }
        $dbh->do('CREATE TEMP TABLE compose_spec_people (id integer, tenant_id integer, active integer, name text)');
        $dbh->do(q{INSERT INTO compose_spec_people VALUES (1,7,1,'A'),(2,8,1,'B'),(3,7,0,'B'),(4,7,1,'B')});
        my $domain = Selecto::Domain->new(name => 'Composition', table => 'compose_spec_people',
            tenant_field => 'tenant_id', fields => {id => 'integer', tenant_id => 'integer', active => 'integer', name => 'string'},
            required_predicate => $x->eq('active', 1));
        my $adapter = $backend eq 'sqlite' ? Selecto::SQLite->new(dbh => $dbh) : Selecto::PostgreSQL->new(dbh => $dbh);
        my $scoped = Selecto::Engine->new(domain => $domain, adapter => $adapter)->with_tenant(7);
        for my $filter_mode (qw(compose replace clear empty_replace)) {
            for my $select_mode (qw(compose replace clear empty_replace)) {
                my $q = $scoped->query->select('id')->where($x->gte('id', 1))->where($x->any($x->eq('id', 1), $x->gte('id', 2)));
                $q = $q->replace_where($x->gte('id', 1)) if $filter_mode eq 'replace';
                $q = $q->clear_where if $filter_mode eq 'clear';
                $q = $q->replace_where([]) if $filter_mode eq 'empty_replace';
                $q = $q->select('id') if $select_mode eq 'compose';
                $q = $q->replace_selections('id') if $select_mode eq 'replace';
                $q = $q->clear_selections->select('id') if $select_mode eq 'clear';
                $q = $q->replace_selections([])->select('id') if $select_mode eq 'empty_replace';
                my $rows = $scoped->all($q->order_by('id'))->{rows};
                is_deeply([map { $_->[0] } @$rows], [1,4], "$filter_mode/$select_mode retains tenant and domain predicates");
            }
        }
        $dbh->do('DROP TABLE compose_spec_people');
        $dbh->disconnect;
    };
}
done_testing;
