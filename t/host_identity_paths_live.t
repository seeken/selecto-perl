use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::CannedPage ();
use Selecto::CoDomain ();
use Selecto::Write ();

# Host-installed scope reaches tenant or site identity along every path, and
# compares there as PostgreSQL compares it (on MySQL and MariaDB: by utf8mb4
# bytes for text, under default case- and accent-folding, PAD SPACE
# collations). PostgreSQL is the oracle: every backend must return its rows.
#   - a computed field (a predicate body, a value expression and its CASE
#     conditions, a nested computed field, a joined relation's computed
#     field) referenced by a host predicate;
#   - an association's where policy on joins, collections, association_exists
#     and through bridges;
#   - a retarget onto an association confined by a where policy (all
#     backends: the policy is applied to the target rows themselves);
#   - a co-domain lookup's request scope and a canned page's dataset
#     predicate and request scope;
#   - query members' authored filters, and member correlations pairing an
#     INT tenant with a text column.
# Caller filters stay plain.

my $x = 'Selecto::Expression';
my $json = JSON::PP->new->canonical;
my @backends = (['sqlite', sub {
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1})
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
my %my_url;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    $my_url{$kind} = $ENV{$env};
    push @backends, [$kind, sub { my_connect($kind) }];
}
plan skip_all => 'no live PostgreSQL, MySQL or MariaDB is configured' unless @backends > 1;

sub my_connect {
    my ($kind) = @_;
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($my_url{$kind}, $kind);
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
        mariadb_client_found_rows => 1});
    $dbh->do(q{SET time_zone = '+00:00'});
    return $dbh;
}

sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return $value unless $@;
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error')
        ? 'ERR ' . $error->code . (($error->details // {})->{reason} ? '/' . $error->details->{reason} : '') : "DIED $error";
}

sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => ref($columns{$_}) ? $columns{$_} : defined($columns{$_}) ? {type => $columns{$_}} : {}) } keys %columns},
        associations => {}};
}

sub ids { '[' . join(',', sort { $a <=> $b } map { $_->[0] } @{$_[0]}) . ']' }

# Per-subtest expectations are PostgreSQL's answers, fixed here so a backend
# run alone is still checked.
for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $my = $name eq 'mysql' || $name eq 'mariadb';

    subtest "$name computed fields in host predicates compare as identity" => sub {
        my $dbh = $connect->();
        $dbh->do('DROP TABLE IF EXISTS selecto_hip_items');
        $dbh->do('CREATE TABLE selecto_hip_items (id INT PRIMARY KEY, org_key VARCHAR(16), site_id INT)');
        $dbh->do(q{INSERT INTO selecto_hip_items VALUES (1, 't1', 1), (2, 'T1', 1), (3, 't1 ', 1), (4, 'tı', 1)});
        my $case = sub { ['case', [$_[0], ['literal', 'y']], ['else', ['literal', 'n']]] };
        my $source = relation('selecto_hip_items', id => 'integer', org_key => 'string', site_id => 'integer',
            mine => {type => 'boolean', computed => {kind => 'predicate', expression => ['eq', 'org_key', 't1']}},
            mine_or => {type => 'boolean', computed => {kind => 'predicate', expression => ['or', ['eq', 'org_key', 't1'], ['eq', 'org_key', 'zz']]}},
            mine_not => {type => 'boolean', computed => {kind => 'predicate', expression => ['not', ['ne', 'org_key', 't1']]}},
            flag => {type => 'string', computed => {kind => 'expression', expression => $case->(['eq', 'org_key', 't1'])}},
            flag_in => {type => 'string', computed => {kind => 'expression', expression => $case->(['in', 'org_key', ['t1']])}},
            flag_nest => {type => 'string', computed => {kind => 'expression', expression => ['field', 'flag']}},
            flag_coal => {type => 'string', computed => {kind => 'expression',
                expression => ['coalesce', ['case', [['eq', 'org_key', 't1'], ['literal', 'y']]], ['literal', 'n']]}},
            flag_txt => {type => 'string', computed => {kind => 'expression',
                expression => ['case', [['gt', 'id', 0], ['field', 'org_key']], ['else', ['literal', 'x']]]}});
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'HostComputed', source => $source,
            schemas => {}, joins => {}});
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        for my $case (
            ['mine = true', $x->eq('mine', 1)],
            ['bare mine', $x->field('mine')],
            ['NOT (mine = false)', $x->not($x->eq('mine', 0))],
            ['mine IN (true)', $x->in('mine', [1])],
            ['mine_or', $x->eq('mine_or', 1)],
            ['mine_not', $x->eq('mine_not', 1)],
            ['flag = y', $x->eq('flag', 'y')],
            ['flag IN (y)', $x->in('flag', ['y'])],
            ['NOT (flag <> y)', $x->not($x->ne('flag', 'y'))],
            ['flag_in = y', $x->eq('flag_in', 'y')],
            ['nested computed flag', $x->eq('flag_nest', 'y')],
            ['coalesced CASE', $x->eq('flag_coal', 'y')],
            ['CASE yielding the tenant column', $x->eq('flag_txt', 't1')],
        ) {
            my ($label, $predicate) = @$case;
            my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain->with_required_predicate($predicate));
            my $statement = $engine->compile($engine->query->select('id'));
            my $markers = () = $statement->sql =~ /\?|\$\d+/g;
            is($markers, scalar(@{$statement->params}), "$label: one parameter per placeholder");
            is(outcome(sub { ids($engine->all($engine->query->select('id'))->{rows}) }), '[1]',
                "$label reads only the exact 't1' row");
        }
        # A caller filter on the same computed field stays a caller filter.
        my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain);
        unlike($engine->compile($engine->query->select('id')->where($x->eq('mine', 1)))->sql, qr/AS BINARY/,
            'a caller filter on a computed predicate compiles plainly');
        $dbh->do('DROP TABLE selecto_hip_items');
    };

    subtest "$name a joined relation's computed field compiles over the join" => sub {
        my $dbh = $connect->();
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_hip_j selecto_hip_ja);
        $dbh->do('CREATE TABLE selecto_hip_j (id INT PRIMARY KEY, acc_id INT)');
        $dbh->do('CREATE TABLE selecto_hip_ja (id INT PRIMARY KEY, site VARCHAR(8))');
        $dbh->do('INSERT INTO selecto_hip_j VALUES (1, 1), (2, 2), (3, 3), (4, 4)');
        $dbh->do(q{INSERT INTO selecto_hip_ja VALUES (1, 's1'), (2, 'S1'), (3, 's1 '), (4, 's2')});
        my $source = relation('selecto_hip_j', id => 'integer', acc_id => 'integer');
        $source->{associations} = {a => {queryable => 'acc', owner_key => 'acc_id', related_key => 'id'}};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'JoinedComputed', source => $source,
            schemas => {acc => relation('selecto_hip_ja', id => 'integer', site => 'string',
                is_s1 => {type => 'boolean', computed => {kind => 'predicate', expression => ['eq', 'site', 's1']}},
                flag => {type => 'string', computed => {kind => 'expression',
                    expression => ['case', [['eq', 'site', 's1'], ['literal', 'y']], ['else', ['literal', 'n']]]}})},
            joins => {a => {type => 'left'}}});
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        for my $case (['a.is_s1 = true', $x->eq('a.is_s1', 1)], ['a.flag = y', $x->eq('a.flag', 'y')]) {
            my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain->with_required_predicate($case->[1]));
            is(outcome(sub { ids($engine->all($engine->query->select('id'))->{rows}) }), '[1]', "$case->[0] reads the exact row");
        }
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_hip_j selecto_hip_ja);
    };

    subtest "$name association where policies confine joins, collections and retargets" => sub {
        my $dbh = $connect->();
        my $pg = $name eq 'postgresql';
        # [declared type (undef: undeclared), PostgreSQL DDL, MySQL DDL, pinned value, row values]
        my %types = (
            string => ['string', 'VARCHAR(40)', 'VARCHAR(40)', 's1', ['s1', 'S1', 's1 ', 's2', undef]],
            custom => ['site_code', 'VARCHAR(40)', 'VARCHAR(40)', 's1', ['s1', 'S1', 's1 ', 's2', undef]],
            uuid => ['uuid', 'CHAR(36)', 'CHAR(36)', 'aaaaaaaa-0000-0000-0000-000000000001',
                ['aaaaaaaa-0000-0000-0000-000000000001', 'AAAAAAAA-0000-0000-0000-000000000001',
                 'aaaaaaaa-0000-0000-0000-00000000000 ', 'bbbbbbbb-0000-0000-0000-000000000001', undef]],
            integer => ['integer', 'INT', 'INT', 1, [1, 2, 3, 4, undef]],
        );
        my @labels = ('mine', 'SECRET-case', 'SECRET-pad', 'SECRET-other', 'SECRET-null');
        for my $type (sort keys %types) {
            my ($declared, $pg_ddl, $my_ddl, $pin, $values) = @{$types{$type}};
            my $ddl = $pg ? $pg_ddl : $my_ddl;
            $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_hip_items selecto_hip_acc selecto_hip_reg selecto_hip_bridge);
            $dbh->do('CREATE TABLE selecto_hip_items (id INT PRIMARY KEY, org VARCHAR(16), acc_id INT)');
            $dbh->do("CREATE TABLE selecto_hip_acc (id INT NOT NULL, item_id INT, org VARCHAR(16), site $ddl NULL, reg_id INT, label VARCHAR(40))");
            $dbh->do("CREATE TABLE selecto_hip_reg (id INT NOT NULL, org VARCHAR(16), site $ddl NULL, label VARCHAR(40))");
            $dbh->do("CREATE TABLE selecto_hip_bridge (item_id INT, acc_id INT, org VARCHAR(16), bsite $ddl NULL)");
            $dbh->do(q{INSERT INTO selecto_hip_items VALUES (1, 't7', 101)});
            for my $index (0 .. 4) {
                # The same keys repeat across sites: only the policy tells them apart.
                $dbh->do('INSERT INTO selecto_hip_acc VALUES (?, ?, ?, ?, ?, ?)', undef, 101, 1, 't7', $values->[$index], 201, $labels[$index]);
                $dbh->do('INSERT INTO selecto_hip_reg VALUES (?, ?, ?, ?)', undef, 201, 't7', $values->[$index], "reg-$labels[$index]");
                $dbh->do('INSERT INTO selecto_hip_acc VALUES (?, ?, ?, ?, ?, ?)', undef, 301 + $index, 9, 't7', $values->[0], 0, "b-$labels[$index]");
                $dbh->do('INSERT INTO selecto_hip_bridge VALUES (?, ?, ?, ?)', undef, 1, 301 + $index, 't7', $values->[$index]);
            }
            my $site = defined($declared) ? {type => $declared} : {};
            my $acc = relation('selecto_hip_acc', id => 'integer', item_id => 'integer', org => 'string', site => $site,
                reg_id => 'integer', label => 'string');
            $acc->{associations} = {reg => {queryable => 'reg', owner_key => 'reg_id', related_key => 'id', where => {site => $pin}}};
            my $source = relation('selecto_hip_items', id => 'integer', org => 'string', acc_id => 'integer',
                has_a => {type => 'boolean', computed => {kind => 'association_exists', association => 'c'}});
            $source->{associations} = {
                a => {queryable => 'acc', owner_key => 'acc_id', related_key => 'id', where => {site => $pin}},
                c => {queryable => 'acc', owner_key => 'id', related_key => 'item_id', cardinality => 'many', where => {site => $pin}},
                tb => {queryable => 'acc', owner_key => 'id', related_key => 'id', cardinality => 'many',
                    through => {table => 'selecto_hip_bridge', owner_key => 'item_id', related_key => 'acc_id', where => {bsite => $pin}}},
                tt => {queryable => 'acc', owner_key => 'id', related_key => 'id', cardinality => 'many', where => {site => $pin},
                    through => {table => 'selecto_hip_bridge', owner_key => 'item_id', related_key => 'acc_id'}},
            };
            my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Policies', source => $source,
                schemas => {acc => $acc, reg => relation('selecto_hip_reg', id => 'integer', org => 'string', site => $site, label => 'string')},
                joins => {map { ($_ => {type => 'left'}) } qw(a c tb tt)}});
            my $adapter = Selecto->adapter($name => (dbh => $dbh));
            for my $bound (['unbound', $domain], ['required', $domain->with_required_predicate($x->eq('org', 't7'))]) {
                my $engine = Selecto::Engine->new(adapter => $adapter, domain => $bound->[1]);
                my $labels = sub {
                    my ($query) = @_;
                    return outcome(sub {
                        join ' ', sort map {
                            my $value = $_->[-1];
                            # Collections arrive as JSON text (MySQL family) or decoded.
                            $value = $json->decode($value) if defined($value) && !ref($value) && $value =~ /\A\[/;
                            ref($value) ? $json->encode($value) : $value // 'null';
                        }
                            @{$engine->all($query)->{rows}};
                    });
                };
                my $q = $engine->query;
                my @cases = (
                    ['join', $q->select('id', 'a.label'), 'mine'],
                    ['nested join', $q->select('id', 'a.reg.label'), 'reg-mine'],
                    ['to-many join', $q->select('id', 'c.label'), 'mine'],
                    ['collection', $q->select('id', $x->related_collection('c', ['label'])), '[{"label":"mine"}]'],
                    ['association_exists', $q->select('id', 'has_a'), 1],
                    ['through bridge policy', $q->select('id', 'tb.label'), 'b-mine'],
                    ['through bridge collection', $q->select('id', $x->related_collection('tb', ['label'])), '[{"label":"b-mine"}]'],
                    ['through target policy', $q->select('id', 'tt.label'), join(' ', sort map { "b-$_" } @labels)],
                    ['retarget in', $q->retarget('a', strategy => 'in')->select('id', 'label'), 'mine'],
                    ['retarget exists', $q->retarget('a', strategy => 'exists')->select('id', 'label'), 'mine'],
                    ['two-hop retarget', $q->retarget('a.reg', strategy => 'in')->select('id', 'label'), 'reg-mine'],
                    ['two-hop retarget exists', $q->retarget('a.reg', strategy => 'exists')->select('id', 'label'), 'reg-mine'],
                    ['to-many retarget', $q->retarget('c', strategy => 'exists')->select('id', 'label'), 'mine'],
                    ['through bridge retarget', $q->retarget('tb', strategy => 'in')->select('id', 'label'), 'b-mine'],
                    ['through target retarget', $q->retarget('tt', strategy => 'exists')->select('id', 'label'),
                        join(' ', sort map { "b-$_" } @labels)],
                );
                for my $case (@cases) {
                    my ($label, $query, $expected) = @$case;
                    is($labels->($query), $expected, "$type $bound->[0] $label");
                }
                # A declared integer pin compiles as before (no byte form).
                unlike($engine->compile($q->select('id', 'a.label'))->sql, qr/CONVERT\([`"]j_a[`"]\.[`"]site[`"]/,
                    'an integer pin compares plainly') if $type eq 'integer';
            }
        }
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(selecto_hip_items selecto_hip_acc selecto_hip_reg selecto_hip_bridge);
    };

    next if $name eq 'sqlite';

    subtest "$name canned page dataset predicate and request scope are host scope" => sub {
        my $dbh = $connect->();
        $dbh->do('DROP TABLE IF EXISTS selecto_hip_page');
        $dbh->do('CREATE TABLE selecto_hip_page (id INT PRIMARY KEY, title VARCHAR(40), site VARCHAR(16), brand VARCHAR(16))');
        $dbh->do(q{INSERT INTO selecto_hip_page VALUES (1, 'a', 's1', 'N'), (2, 'b', 'S1', 'N'), (3, 'c', 's1 ', 'N'), (4, 'd', 's2', 'N')});
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Items',
            source => relation('selecto_hip_page', id => 'integer', title => 'string', site => 'string', brand => 'string'),
            schemas => {}, joins => {}});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
        for my $case (['dataset predicate', $x->eq('site', 's1'), undef], ['request scope', undef, $x->eq('site', 's1')],
            ['request scope OR', undef, $x->any([$x->eq('site', 's1'), $x->eq('site', 'zz')])]) {
            my ($label, $dataset, $scope) = @$case;
            my $page = Selecto::CannedPage->new(id => 'p', domain => $domain,
                dataset => {query => defined($dataset) ? $engine->query->where($dataset) : $engine->query, entity_key => ['id']},
                views => [{id => 'list', kind => 'detail', query => $engine->query->select('id', 'title')->order_by('id')}],
                controls => [{id => 'brand', kind => 'facet', field => 'brand', values => {source => 'dataset', limit => 30}}],
                initial_state => {view => 'list', filters => {}});
            # Bounded execution (one round trip) is PostgreSQL's.
            for my $options (undef, $name eq 'postgresql' ? ({max_rows => 100}) : ()) {
                my $mode = $options ? 'bounded' : 'plain';
                my $result = outcome(sub {
                    my $run = $page->run($engine, {view => 'list', page => 1, limit => 25}, $scope, $options);
                    ids($run->{rows}) . " total=$run->{total} facet=" . join(',', map { $_->{count} } @{$run->{facets}{brand}{options}});
                });
                is($result, '[1] total=1 facet=1', "$label ($mode): rows, total and facet counts are exact");
            }
        }
        $dbh->do('DROP TABLE selecto_hip_page');
    };

    subtest "$name co-domain lookup scope and authored filters are host scope" => sub {
        my $dbh = $connect->();
        $dbh->do('DROP TABLE IF EXISTS selecto_hip_lookup');
        $dbh->do('CREATE TABLE selecto_hip_lookup (id INT PRIMARY KEY, title VARCHAR(40), site VARCHAR(16))');
        $dbh->do(q{INSERT INTO selecto_hip_lookup VALUES (1, 'Oak a', 's1'), (2, 'Oak b', 'S1'), (3, 'Oak c', 's1 '), (4, 'Oak d', 's2')});
        $dbh->do('CREATE FULLTEXT INDEX selecto_hip_lookup_ft ON selecto_hip_lookup (title)') if $my;
        my $search = {fields => ['title'], mode => 'prefix', configuration => 'simple'};
        my $result = {value_field => 'id', label_field => 'title'};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Items',
            source => relation('selecto_hip_lookup', id => 'integer', title => 'string', site => 'string'),
            schemas => {}, joins => {},
            query_library => {projections => {lookup => {fields => [qw(id title)]}}, segments => {s1 => {filters => [['eq', 'site', 's1']]}}},
            co_domains => {items => {domain => 'items', projection => 'lookup', search => $search, result => $result},
                seg => {domain => 'items', projection => 'lookup', segments => ['s1'], search => $search, result => $result}}});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
        for my $case (['request scope eq', 'items', $x->eq('site', 's1')],
            ['request scope OR', 'items', $x->any([$x->eq('site', 's1'), $x->eq('site', 'zz')])],
            ['request scope NOT (<>)', 'items', $x->not($x->ne('site', 's1'))],
            ['authored segment', 'seg', undef]) {
            my ($label, $co_domain, $scope) = @$case;
            my $found = outcome(sub {
                my $lookup = Selecto::CoDomain->lookup(source_domain => $domain, engine => $engine, co_domain => $co_domain,
                    query => 'oak', (defined($scope) ? (predicate => $scope) : ()));
                '[' . join(',', sort map { $_->{value} } @{$lookup->{results}}) . ']';
            });
            is($found, '[1]', "$label returns only the exact site's rows");
        }
        $dbh->do('DROP TABLE selecto_hip_lookup');
    };

    next unless $my;

    subtest "$name member correlations and authored member filters" => sub {
        my $dbh = $connect->();
        my @tables = qw(selecto_hip_m selecto_hip_mm selecto_hip_mt);
        $dbh->do("DROP TABLE IF EXISTS $_") for @tables;
        $dbh->do('CREATE TABLE selecto_hip_m (id INT PRIMARY KEY, org INT, acc_id INT, team_id INT)');
        $dbh->do('INSERT INTO selecto_hip_m VALUES (1, 7, 101, 501)');
        $dbh->do('CREATE TABLE selecto_hip_mm (id INT, acc_id INT, org VARCHAR(8), site VARCHAR(8), label VARCHAR(20))');
        $dbh->do('CREATE TABLE selecto_hip_mt (id INT, parent_id INT, org VARCHAR(8))');
        my @labels = ('mine', 'S-07', 'S-pad', 'S-lead', 'S-8');
        my @orgs = ('7', '07', '7 ', ' 7', '8');
        my @sites = ('s1', 'S1', 's1 ', 's2', 's1');
        for my $index (0 .. 4) {
            $dbh->do('INSERT INTO selecto_hip_mm VALUES (?, 101, ?, ?, ?)', undef, 401 + $index, $orgs[$index], $sites[$index], "m-$labels[$index]");
        }
        $dbh->do(q{INSERT INTO selecto_hip_mt VALUES (501, NULL, '7'), (502, 501, '7'), (503, 501, '07')});
        my $member = relation('selecto_hip_mm', id => 'integer', acc_id => 'integer', org => 'string', site => 'string', label => 'string');
        my $team = relation('selecto_hip_mt', id => 'integer', parent_id => 'integer', org => 'string');
        my $source = relation('selecto_hip_m', id => 'integer', org => 'integer', acc_id => 'integer', team_id => 'integer');
        $source->{tenant_field} = 'org';
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Members', source => $source,
            schemas => {mem => $member, team => $team}, joins => {},
            query_members => {
                laterals => {
                    lat => {source => 'mem', query => {select => ['label'], order_by => [['id', 'asc']], limit => 10},
                        correlations => {org => 'org', acc_id => 'acc_id'}, join_type => 'left'},
                    latf => {source => 'mem', query => {select => ['label'], filter => ['eq', 'site', 's1'],
                        order_by => [['id', 'asc']], limit => 10}, correlations => {acc_id => 'acc_id'}, join_type => 'left'},
                },
                ctes => {
                    cte => {source => 'mem', query => {select => ['org', 'label'], filter => ['gt', 'id', 0]},
                        join => {owner_key => 'org', related_key => 'org', type => 'left'}},
                    ctef => {source => 'mem', query => {select => ['acc_id', {as => 'n', aggregate => 'count'}],
                        filter => ['eq', 'site', 's1'], group_by => ['acc_id']}, join => {owner_key => 'acc_id', related_key => 'acc_id', type => 'left'}},
                },
                subqueries => {sub => {source => 'mem', query => {select => ['org', 'label'], filter => ['gt', 'id', 0]},
                    on => [{left => 'org', right => 'org'}], type => 'left'}},
                values => {vals => {rows => [['7', 'v-mine'], ['07', 'v-07'], ['7 ', 'v-pad'], [' 7', 'v-lead']],
                    columns => ['org', 'label'], join => [['owner_key', 'org'], ['related_key', 'org']]}},
            }});
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        for my $tenant (7, '7') {
            my $engine = Selecto::Engine->new(adapter => $adapter, domain => $domain, scope => {tenant => $tenant});
            my $labels = sub {
                my ($member_name, $column) = @_;
                return outcome(sub {
                    join ' ', sort map { $_->[1] // 'null' }
                        @{$engine->all($engine->query->with_member($member_name)->select('id', "$member_name.$column"))->{rows}};
                });
            };
            is($labels->('lat', 'label'), 'm-mine', "tenant $tenant: an INT tenant correlated with a text lateral column is exact");
            is($labels->('latf', 'label'), 'm-S-8 m-mine', "tenant $tenant: a lateral member's authored filter is exact");
            is($labels->('cte', 'label'), 'm-mine', "tenant $tenant: an INT tenant joined to a text CTE column is exact");
            is($labels->('ctef', 'n'), '2', "tenant $tenant: a CTE member's authored filter is exact");
            is($labels->('sub', 'label'), 'm-mine', "tenant $tenant: an INT tenant joined to a text subquery column is exact");
            is($labels->('vals', 'label'), 'v-mine', "tenant $tenant: an INT tenant joined to a VALUES column is exact");
        }
        $dbh->do("DROP TABLE IF EXISTS $_") for @tables;
    };

    subtest "$name an adapter of the other server family is refused" => sub {
        my $other = $name eq 'mysql' ? 'mariadb' : 'mysql';
        plan skip_all => "no $other server is configured" unless $my_url{$other};
        my $dbh = my_connect($other);
        $dbh->do('DROP TABLE IF EXISTS selecto_hip_family');
        $dbh->do('CREATE TABLE selecto_hip_family (id INT PRIMARY KEY, org_key VARCHAR(16))');
        $dbh->do(q{INSERT INTO selecto_hip_family VALUES (1, 't7'), (2, 'T7')});
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Family',
            source => relation('selecto_hip_family', id => 'integer', org_key => 'string'), schemas => {}, joins => {},
            writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
                fields => {org_key => {updatable => 1}}}});
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $dbh)));
        is(outcome(sub { $engine->all($engine->query->select('id')); 'ok' }), 'ERR invalid_connection/server_family',
            "a $name adapter on a $other server refuses a read");
        is(outcome(sub { my $stream = $engine->stream($engine->query->select('id')); 1 while $stream->next; 'ok' }),
            'ERR invalid_connection/server_family', 'and a stream');
        is(outcome(sub {
            $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'selecto_hip_family',
                assignments => {org_key => 'zz'}, predicate => $x->eq('id', 1)));
            'ok';
        }), 'ERR invalid_connection/server_family', 'and a write');
        is($dbh->selectrow_array('SELECT org_key FROM selecto_hip_family WHERE id = 1'), 't7', 'the refused write changed nothing');
        $dbh->do('DROP TABLE selecto_hip_family');
    };
}

done_testing;
