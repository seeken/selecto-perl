use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use lib 't/lib';
use TestSelecto;
use Selecto;

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';

plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };

sub product_domain {
    return TestSelecto::writable_domain(
        name => 'Products',
        table => 'selecto_perl_mysql_products',
        fields => { id => 'integer', name => 'string', amount => 'decimal' },
        conflict_targets => [['id'], ['name']],
    );
}

for my $specification (
    ['mysql', 'SELECTO_PERL_TEST_MYSQL_URL'],
    ['mariadb', 'SELECTO_PERL_TEST_MARIADB_URL'],
) {
    my ($backend, $environment) = @$specification;
    subtest "$backend live DBI adapter" => sub {
        plan skip_all => "$environment is not configured"
            unless defined($ENV{$environment}) && $ENV{$environment} ne '';
        my ($dsn, $username, $password) =
            Selecto::Certification::_connection_parts($ENV{$environment}, $backend);
        my $dbh = DBI->connect($dsn, $username, $password, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            mariadb_client_found_rows => 1,
        });

        $dbh->do('DROP TABLE IF EXISTS selecto_perl_mysql_products');
        $dbh->do('CREATE TABLE selecto_perl_mysql_products (id integer primary key, name varchar(80) not null, amount decimal(12,2), unique(name))');
        $dbh->do(q{INSERT INTO selecto_perl_mysql_products VALUES (1, 'Renée 東京', 10.50)});

        my $adapter = Selecto->adapter($backend => (dbh => $dbh));
        my $engine = Selecto::Engine->new(domain => product_domain(), adapter => $adapter);
        my $result = $engine->all($engine->query->select('id', 'name', 'amount')->order_by('id'));
        is_deeply(
            $result,
            { columns => ['id', 'name', 'amount'], rows => [[1, 'Renée 東京', '10.5']] },
            "$backend executes a public query with Unicode and exact decimal normalization",
        );

        my $upsert = Selecto::Write::Command->new(
            operation => 'upsert',
            relation => 'selecto_perl_mysql_products',
            assignments => { id => 9, name => 'Renée 東京', amount => 20.25 },
            metadata => { conflict_target => ['name'], upsert_update_fields => ['amount'] },
        );
        # PostgreSQL ON CONFLICT semantics: the declared target's row is
        # updated; a collision on another unique key fails the insert.
        my $by_name = $engine->execute_write($upsert);
        is($by_name->affected_rows, 1, "$backend upserts on the declared target");
        is_deeply($dbh->selectall_arrayref('SELECT id, amount FROM selecto_perl_mysql_products ORDER BY id'),
            [[1, '20.25']], "$backend updates the target's row, never inserting or moving its key");
        my $by_id = eval {
            $engine->execute_write($upsert->with_metadata({conflict_target => ['id'], upsert_update_fields => ['amount']}));
            1;
        };
        ok(!$by_id && $@->code eq 'query_error', "$backend fails an insert that collides on another unique key");
        is($dbh->selectrow_array('SELECT amount FROM selecto_perl_mysql_products WHERE id = 1'),
            '20.25', "$backend never changes the row selected by another unique key");
        eval { $engine->execute_write($upsert->with_scope_predicate(Selecto::Expression->eq('id', 1))) };
        is($@->code, 'unsupported_scope_predicate', "$backend refuses a scoped upsert");

        my $first = Selecto::Write::Command->new(
            operation => 'insert', relation => 'selecto_perl_mysql_products',
            assignments => { id => 2, name => 'must-roll-back', amount => 30 },
        );
        my $missing = Selecto::Write::Command->new(
            operation => 'update', relation => 'selecto_perl_mysql_products',
            assignments => { amount => 99 },
            predicate => Selecto::Expression->eq('id', 999),
        );
        eval { $engine->execute_batch(Selecto::Write::Batch->new($first, $missing)) };
        is($@->code, 'cardinality_mismatch', "$backend reports a portable batch error");
        is($dbh->selectrow_array('SELECT count(*) FROM selecto_perl_mysql_products'), 1, "$backend rolls back the batch atomically");

        $dbh->do('DROP TABLE selecto_perl_mysql_products');
        $dbh->disconnect;
    };
}

done_testing;
