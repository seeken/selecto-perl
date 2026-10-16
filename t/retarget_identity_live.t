use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::Statement;

# A retarget rebinds its target row on the target relation's full identity:
# its key, its declared tenant_field and the scope column the last hop pairs
# on (a bridge's too). The fixture's target keys repeat across tenants and
# scopes ('t8', 'T7', 't7 ', site 'S1'), so a key-only correlation returns
# another tenant's SECRET rows. The comparison is NULL-safe, byte-exact on
# MySQL/MariaDB, and MariaDB runs every library statement with its subquery
# cache off (the cache keys a correlated subquery under the collation).

my $x = 'Selecto::Expression';
my $json = JSON::PP->new->canonical;
my $dir = 't/fixtures/retarget_identity';
sub slurp { open my $fh, '<:encoding(UTF-8)', $_[0] or die "$_[0]: $!"; local $/; return <$fh> }
my $index = $json->decode(slurp("$dir/index.json"));
my @setup = grep { /\S/ } split /;\n/, slurp("$dir/setup.sql");

my @backends = (['sqlite', 'sqlite', sub {
    DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1})
}]);
if (my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL}) {
    push @backends, ['postgresql', 'postgresql', sub {
        require Selecto::Certification;
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($url);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 1});
        $dbh->do('SET client_min_messages TO warning');
        return $dbh;
    }] if eval { require DBD::Pg; 1 };
}
for my $spec (['mysql', 'SELECTO_PERL_TEST_MYSQL_URL', 0], ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL', 0],
    ['mariadb semijoin=off', 'SELECTO_PERL_TEST_MARIADB_URL', 1]) {
    my ($label, $env, $semijoin_off) = @$spec;
    next unless defined($ENV{$env}) && $ENV{$env} ne '' && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    my $kind = $label =~ /\Amariadb/ ? 'mariadb' : 'mysql';
    push @backends, [$label, $kind, sub {
        my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{$env}, $kind);
        my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mariadb_client_found_rows => 1});
        # Without semijoins MariaDB plans the retarget as a correlated
        # subquery, which its subquery cache would answer by collation.
        $dbh->do(q{SET SESSION optimizer_switch='semijoin=off'}) if $semijoin_off;
        return $dbh;
    }];
}

for my $backend (@backends) {
    my ($label, $kind, $connect) = @$backend;
    subtest "$label retargets rebind the full target identity" => sub {
        my $dbh = $connect->();
        $dbh->do($_) for @setup;
        my $adapter = Selecto->adapter($kind => (dbh => $dbh));
        for my $item (@$index) {
            for my $bound (@{$item->{bounds}}) {
                my $contract = $json->decode(slurp("$dir/$item->{v}.json"));
                push @{$contract->{required_filters} //= []}, @{$bound->{required}} if $bound->{required};
                my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse($contract), adapter => $adapter,
                    ($bound->{tenant} ? (scope => {tenant => $bound->{tenant}}) : ()));
                for my $path (@{$item->{paths}}) {
                    my $query = $engine->query;
                    $query = $path->{kind} eq 'join' ? $query->select('id', $path->{field})
                        : $path->{kind} eq 'collection' ? $query->select('id', $x->related_collection($path->{assoc}, [$path->{field}]))
                        : $query->retarget($path->{target}, strategy => $path->{strategy})->select('id', 'label');
                    my $rows = eval { $engine->all($query)->{rows} };
                    my $name = "$item->{v} bound by $bound->{label}: $path->{name}";
                    if (!$rows) {
                        my $error = $@;
                        fail("$name runs: " . (blessed($error) ? $error->code . ' ' . $error->message : $error));
                        next;
                    }
                    my $text = $json->encode($rows);
                    unlike($text, qr/SECRET/, "$name returns no other tenant's or scope's row");
                    like($text, qr/mine/, "$name returns the own row");
                }
            }
        }
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(rs_items rs_acc rs_reg rs2_items rs2_acc rs2_reg th_bridge sp_items sp_acc);
    };

    # An unbound retarget (shared root, no tenant boundary) keeps a target row
    # whose tenant column is NULL: the rebinding is NULL-safe.
    subtest "$label unbound retargets keep NULL-tenant rows" => sub {
        my $dbh = $connect->();
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(rn_items rn_acc);
        $dbh->do('CREATE TABLE rn_items (id INT PRIMARY KEY, account_id INT)');
        $dbh->do('CREATE TABLE rn_acc (id INT NOT NULL, org_key VARCHAR(16) NULL, label VARCHAR(20))');
        $dbh->do('INSERT INTO rn_items VALUES (1, 101)');
        $dbh->do(q{INSERT INTO rn_acc VALUES (101, NULL, 'null-tenant')});
        my $relation = sub {
            my ($table, %columns) = @_;
            return {source_table => $table, primary_key => 'id', fields => [sort keys %columns],
                columns => {map { ($_ => {type => $columns{$_}}) } keys %columns}, associations => {}};
        };
        my $source = $relation->('rn_items', id => 'integer', account_id => 'integer');
        $source->{associations} = {a => {queryable => 'acc', owner_key => 'account_id', related_key => 'id', cardinality => 'one'}};
        my $engine = Selecto::Engine->new(adapter => Selecto->adapter($kind => (dbh => $dbh)),
            domain => Selecto::Domain->parse({schema_version => 1, name => 'Shared', source => $source,
                schemas => {acc => {%{$relation->('rn_acc', id => 'integer', org_key => 'string', label => 'string')},
                    tenant_field => 'org_key'}}, joins => {}}));
        for my $strategy (qw(in exists)) {
            my $rows = eval { $engine->all($engine->query->retarget('a', strategy => $strategy)->select('id', 'label'))->{rows} };
            is_deeply($rows, [[101, 'null-tenant']], "$strategy keeps the NULL-tenant target row")
                or diag(blessed($@) ? $@->code . ' ' . $@->message : $@);
        }
        $dbh->do("DROP TABLE IF EXISTS $_") for qw(rn_items rn_acc);
    };
}

# MariaDB's subquery cache, through the adapter's own execution path: a
# correlated byte comparison must not reuse the result cached for 't7' when
# the outer row holds 'T7'.
SKIP: {
    skip 'SELECTO_PERL_TEST_MARIADB_URL is not configured', 1
        unless defined($ENV{SELECTO_PERL_TEST_MARIADB_URL}) && $ENV{SELECTO_PERL_TEST_MARIADB_URL} ne ''
            && eval { require DBD::MariaDB; require Selecto::Certification; 1 };
    my ($dsn, $user, $password) = Selecto::Certification::_connection_parts($ENV{SELECTO_PERL_TEST_MARIADB_URL}, 'mariadb');
    my $dbh = DBI->connect($dsn, $user, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('DROP TABLE IF EXISTS selecto_mdb_cache');
    $dbh->do('CREATE TABLE selecto_mdb_cache (id INT PRIMARY KEY, org_key VARCHAR(16)) DEFAULT CHARSET=utf8mb4');
    $dbh->do(q{INSERT INTO selecto_mdb_cache VALUES (1, 't7'), (2, 't7'), (3, 'T7')});
    my $adapter = Selecto->adapter(mariadb => (dbh => $dbh));
    my $bytes = sub { "CAST(CONVERT($_[0] USING utf8mb4) AS BINARY)" };
    my $result = $adapter->execute_query(Selecto::Statement->new(
        sql => 'SELECT t.id, (SELECT COUNT(*) FROM selecto_mdb_cache AS rs WHERE ' . $bytes->('rs.org_key') . ' = '
            . $bytes->('t.org_key') . ') FROM selecto_mdb_cache AS t ORDER BY t.id',
        params => [], columns => [qw(id same)]));
    is_deeply($result->{rows}, [[1, 2], [2, 2], [3, 1]], 'each row counts only its byte-equal rows');
    $dbh->do('DROP TABLE selecto_mdb_cache');
}

done_testing;
