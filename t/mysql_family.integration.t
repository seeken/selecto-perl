use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Selecto;

eval { require Selecto::Certification; 1 }
    or plan skip_all => 'Selecto::Certification is not installed';

plan skip_all => 'DBD::MariaDB is not installed' unless eval { require DBD::MariaDB; 1 };

sub product_domain {
    return Selecto::Domain->new(
        name => 'Products',
        table => 'selecto_perl_mysql_products',
        fields => { id => 'integer', name => 'string', amount => 'decimal' },
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
        is($engine->execute_write($upsert)->affected_rows, 1, "$backend normalizes native upsert rows");
        is($engine->execute_write($upsert)->affected_rows, 1, "$backend normalizes no-op upsert rows");

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
