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
use Selecto::QueryEnforcement ();
use Selecto::Write ();

# Round-3 review R18 R24 R25 R26 R28 on MySQL and MariaDB:
# - R24: query-member filters (CTE and lateral members) are host scope:
#   text ranges and prefixes compare bytes, TIMESTAMP compares by epoch and a
#   text match on a TIMESTAMP is refused;
# - R25: a write's scope is its scope predicate and query enforcement; the
#   caller's own predicate on the same column keeps the server's collation;
# - R26/R18: a column declared integer over VARCHAR storage (decided from
#   the catalog of its own relation) compares the canonical integer text by
#   bytes, and other scope compares on it are refused; a same-named column
#   of another type elsewhere changes nothing;
# - R28: a temporary table named like a column identifier is no shadow.
my $x = 'Selecto::Expression';
my @backends;
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL']) {
    my ($kind, $env) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    push @backends, [$kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_client_found_rows => 1});
        $dbh->do(q{SET time_zone = '+00:00'});
        return $dbh;
    }];
}
plan skip_all => 'no MySQL or MariaDB test database' unless @backends;

sub outcome {
    my ($code) = @_;
    my $value = eval { $code->() };
    return 'ok ' . (ref($value) eq 'ARRAY' ? join(',', map { $_ // 'null' } @$value) : $value // '') if !$@;
    return blessed($@) && $@->can('code') ? $@->code . '/' . ((ref($@->details) eq 'HASH' ? $@->details->{reason} : undef) // '') : "died: $@";
}
sub relation {
    my ($table, %columns) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
        columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    my $dbh = $connect->();
    my $adapter = sub { Selecto->adapter($name => (dbh => $dbh)) };

    # R24
    $dbh->do('DROP TABLE IF EXISTS ' . join(', ', qw(ssp_root ssp_mem)));
    $dbh->do('CREATE TABLE ssp_root (id INT PRIMARY KEY, k VARCHAR(8)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO ssp_root VALUES (1, 'x')});
    $dbh->do('CREATE TABLE ssp_mem (id INT PRIMARY KEY, root_id INT, org_key VARCHAR(8), ts TIMESTAMP NULL, amount INT) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO ssp_mem VALUES (1, 1, 't1', '2024-01-01 03:00:00', 1), (2, 1, 'T1', '2023-12-31 20:00:00', 10),
        (3, 1, 't1 ', '2024-01-02 00:00:00', 100), (4, 1, 'tı', '2023-12-31 21:00:00', 1000)});
    my %filters = (
        'between' => [['between', 'org_key', 't1', 't1'], 'ok 1'],
        'gte and lte' => [['and', ['gte', 'org_key', 't1'], ['lte', 'org_key', 't1']], 'ok 1'],
        'starts_with' => [['starts_with', 'org_key', 't1'], 'ok 101'],
        'TIMESTAMP range' => [['gte', 'ts', '2024-01-01 00:00:00'], 'ok 101'],
        'TIMESTAMP text match' => [['starts_with', 'ts', '2024'], 'query_rule_not_evaluable/timestamp_operator'],
    );
    for my $label (sort keys %filters) {
        my ($filter, $want) = @{$filters{$label}};
        my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Members', source => relation('ssp_root', id => 'integer', k => 'string'),
            schemas => {mem => relation('ssp_mem', id => 'integer', root_id => 'integer', org_key => 'string', ts => 'utc_datetime', amount => 'integer')},
            joins => {}, query_members => {
                ctes => {tot => {source => 'mem', query => {select => ['root_id', {as => 'total', aggregate => 'sum', field => 'amount'}],
                    filter => $filter, group_by => ['root_id']}, join => {owner_key => 'id', related_key => 'root_id', type => 'left'}}},
                laterals => {lat => {source => 'mem', query => {select => [{as => 'total', aggregate => 'sum', field => 'amount'}], filter => $filter},
                    correlations => {root_id => 'id'}, join_type => 'left'}}}});
        my $engine = Selecto::Engine->new(adapter => $adapter->(), domain => $domain);
        for my $member ('tot', $name eq 'mysql' ? ('lat') : ()) {
            is(outcome(sub { [map { $_->[1] } @{$engine->all($engine->query->with_member($member)->select('id', "$member.total"))->{rows}}] }),
                $want, "$name member $member $label filter is host scope");
        }
    }

    # R25
    my $writes = Selecto::Domain->parse({schema_version => 1, name => 'Writes', source => relation('ssp_w', id => 'integer', k => 'string', note => 'string'),
        schemas => {}, joins => {}, writes => {operations => {update => {enabled => 1, bulk => 1, expected_cardinality => 'many'}},
            fields => {note => {updatable => 1}}}});
    for my $mode (qw(query_enforcement scope_predicate)) {
        $dbh->do('DROP TABLE IF EXISTS ssp_w');
        $dbh->do('CREATE TABLE ssp_w (id INT PRIMARY KEY, k VARCHAR(8), note VARCHAR(8)) ENGINE=InnoDB');
        $dbh->do(q{INSERT INTO ssp_w VALUES (1, 'a', 'n'), (2, 'B', 'n'), (3, 'b', 'n'), (4, 'A', 'n')});
        my $engine = Selecto::Engine->new(adapter => $adapter->(), domain => $writes);
        my %extra = $mode eq 'query_enforcement'
            ? (query_enforcement => Selecto::QueryEnforcement->capture($writes, $engine->query->where($x->in('k', ['a', 'B']))))
            : (scope_predicate => $x->in('k', ['a', 'B']));
        is(outcome(sub { $engine->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'ssp_w',
            assignments => {note => 'u'}, predicate => $x->eq('k', 'b'), %extra))->affected_rows }), 'ok 1',
            "$name $mode: the caller's k = 'b' keeps the collation, the scope stays exact");
        is(join(' ', map { join ':', @$_ } @{$dbh->selectall_arrayref('SELECT id, note FROM ssp_w ORDER BY id')}), '1:n 2:u 3:n 4:n',
            "$name $mode: only the in-scope 'B' row changed");
    }

    # A scope range on a non-text column (decided by the catalog) compiles
    # natively with its original value, once (QEW004).
    {
        my $engine = Selecto::Engine->new(adapter => $adapter->(), domain => $writes);
        my $preview = $engine->adapter->preview_write(Selecto::Write::Command->new(operation => 'update', relation => 'ssp_w',
            assignments => {note => 'u'}, predicate => $x->eq('note', 'n'), scope_predicate => $x->gt('id', 0)));
        unlike($preview->{sql}, qr/COLLATION|BINARY\) >/, "$name: a scope range on an INT column compiles natively");
        is_deeply($preview->{params}, ['u', 'n', 0], "$name: with its original value, once");
        $preview = $engine->adapter->preview_write(Selecto::Write::Command->new(operation => 'update', relation => 'ssp_w',
            assignments => {note => 'u'}, predicate => $x->eq('id', 1), scope_predicate => $x->gte('k', 'a')));
        like($preview->{sql}, qr/CAST\(CONVERT\(`k` USING utf8mb4\) AS BINARY\) >= CAST/, "$name: on a VARCHAR column by bytes");
        unlike($preview->{sql}, qr/COLLATION/, "$name: decided by the catalog, not COLLATION()");
    }

    # R26 and R18
    $dbh->do('DROP TABLE IF EXISTS ' . join(', ', qw(ssp_codes ssp_ints)));
    $dbh->do('CREATE TABLE ssp_codes (id INT PRIMARY KEY, code VARCHAR(8), note VARCHAR(8)) ENGINE=InnoDB');
    $dbh->do(q{INSERT INTO ssp_codes VALUES (1, '1', 'n'), (2, '01', 'n'), (3, ' 1', 'n'), (4, '1x', 'n'), (5, '1 ', 'n'), (6, '5', 'n')});
    my $codes = sub {
        my ($required) = @_;
        my $engine = Selecto::Engine->new(adapter => $adapter->(), domain => Selecto::Domain->parse({schema_version => 1, name => 'Codes',
            source => relation('ssp_codes', id => 'integer', code => 'integer', note => 'string'), schemas => {}, joins => {}})
            ->with_required_predicate($required));
        return outcome(sub { [map { $_->[0] } @{$engine->all($engine->query->select('id')->order_by('id'))->{rows}}] });
    };
    is($codes->($x->eq('code', 1)), 'ok 1', "$name: an integer column stored as text matches only the canonical text");
    is($codes->($x->eq('code', '01')), 'ok 1', "$name: a non-canonical integer literal is canonicalized");
    is($codes->($x->in('code', [1, 5])), 'ok 1,6', "$name: IN too");
    is($codes->($x->eq('code', '1x')), 'query_rule_not_evaluable/integer_text_storage', "$name: a non-integer literal is refused");
    is($codes->($x->gte('code', 5)), 'query_rule_not_evaluable/integer_text_storage', "$name: a range on it is refused");
    $dbh->do('CREATE TABLE ssp_ints (id INT PRIMARY KEY, code INT) ENGINE=InnoDB');
    $dbh->do('INSERT INTO ssp_ints VALUES (1, 10), (2, 5), (3, 4)');
    my $ints = Selecto::Engine->new(adapter => $adapter->(), domain => Selecto::Domain->parse({schema_version => 1, name => 'Ints',
        source => {%{relation('ssp_ints', id => 'integer', code => 'integer')},
            associations => {o => {queryable => 'o', owner_key => 'id', related_key => 'id'}}},
        schemas => {o => relation('ssp_codes', id => 'integer', code => 'string')}, joins => {o => {type => 'left'}}})
        ->with_required_predicate($x->gte('code', 5)));
    is(outcome(sub { [map { $_->[0] } @{$ints->all($ints->query->select('id', 'o.code')->order_by('id'))->{rows}}] }), 'ok 1,2',
        "$name: an INT scope column compares by value whatever a same-named column elsewhere stores");

    # R28
    $dbh->do('DROP TABLE IF EXISTS note');
    $dbh->do('CREATE TABLE note (id INT PRIMARY KEY) ENGINE=InnoDB');
    $dbh->do('CREATE TEMPORARY TABLE note (id INT)');
    my $plain = Selecto::Engine->new(adapter => $adapter->(), domain => Selecto::Domain->parse({schema_version => 1, name => 'Plain',
        source => relation('ssp_codes', id => 'integer', note => 'string'), schemas => {}, joins => {}}));
    is(outcome(sub { scalar @{$plain->all($plain->query->select('id', 'note')->order_by('id'))->{rows}} }), 'ok 6',
        "$name: a temporary table named like a selected column is no shadow");
    $dbh->do('DROP TEMPORARY TABLE note');
    $dbh->do('DROP TABLE IF EXISTS note');

    $dbh->do('DROP TABLE IF EXISTS ' . join(', ', qw(ssp_root ssp_mem ssp_w ssp_codes ssp_ints)));
    $dbh->disconnect;
}
done_testing;
