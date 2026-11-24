use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Selecto;
use lib 't/lib';
use TestSavedViews ();

for my $backend (TestSavedViews->backends) {
    my ($name, $connect) = @$backend;
    subtest "exact revision values on $name" => sub {
        my $dbh = $connect->();
        $dbh->do('CREATE TABLE sv_values (id INTEGER PRIMARY KEY, name VARCHAR(100), stamp TIMESTAMP, precise DECIMAL(30,10))');
        $dbh->do(q{INSERT INTO sv_values VALUES (1, 'original', '2026-10-05 12:34:56.123456', 123456789.1234567890)});
        my $raw = {name => 'RevisionValues', source => {source_table => 'sv_values', primary_key => 'id',
            fields => [qw(id name stamp precise)], columns => {id => {type => 'integer'}, name => {type => 'string'},
                stamp => {type => 'naive_datetime'}, precise => {type => 'decimal'}}, associations => {}}, schemas => {},
            writes => {operations => {update => {enabled => JSON::PP::true}}, fields => {name => {updatable => JSON::PP::true}},
                row_revision => {column => 'stamp'}}};
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $engine = sub { Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => $adapter) };
        my $e = $engine->();
        my $token = $e->all($e->query->select('name'))->{row_revisions}[0];
        like($token, qr/2026-10-05[ T]12:34:56/, 'timestamp column token returned');
        is($e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'sv_values', assignments => {name => 'fresh'},
            predicate => Selecto::Expression->eq('id', 1))->row_revision($token))->affected_rows, 1, 'timestamp token compares in DML');
        if ($name eq 'postgresql') {
            $raw->{source}{columns}{stamp} = {type => 'utc_datetime', storage => 'naive_utc'};
            $dbh->do("SET TimeZone = 'America/Denver'");
            $e = $engine->();
            my $storage_token = $e->all($e->query->select('name')->use_timezone('America/New_York'))->{row_revisions}[0];
            is($storage_token, $token, 'display and session zones do not change a naive storage token');
            is($e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'sv_values', assignments => {name => 'naive UTC storage'},
                predicate => Selecto::Expression->eq('id', 1))->row_revision($storage_token))->affected_rows, 1, 'naive UTC timestamp token compares against actual storage');
            $dbh->do("SET TimeZone = 'UTC'");
            $raw->{source}{columns}{stamp} = {type => 'naive_datetime'};
            $e = $engine->();
        }
        $dbh->do('UPDATE sv_values SET stamp = NULL WHERE id=1');
        is($e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'sv_values', assignments => {name => 'null timestamp'},
            predicate => Selecto::Expression->eq('id', 1))->row_revision(undef))->affected_rows, 1, 'explicit null token compares with IS NULL in DML');
        $raw->{writes}{row_revision} = {columns => [qw(name stamp precise)]};
        $e = $engine->();
        my $before = $e->all($e->query->select('name'))->{row_revisions}[0];
        is($e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'sv_values', assignments => {name => 'computed'},
            predicate => Selecto::Expression->eq('id', 1))->row_revision($before))->affected_rows, 1, 'computed timestamp/decimal inputs match their locked read');
        my $after = $e->all($e->query->select('name'))->{row_revisions}[0];
        isnt($before, $after, 'changing one declared input changes the computed revision');
        if ($name eq 'sqlite') {
            $dbh->do('UPDATE sv_values SET precise = 1.0000000000000002 WHERE id=1');
            my $one = $e->all($e->query->select('name'))->{row_revisions}[0];
            $dbh->do('UPDATE sv_values SET precise = 1.0000000000000004 WHERE id=1');
            isnt($e->all($e->query->select('name'))->{row_revisions}[0], $one, 'adjacent stored doubles cannot share a rounded revision');
        }
        if ($name eq 'postgresql') {
            $raw->{source}{fields} = [@{$raw->{source}{fields}}, 'xmin'];
            $raw->{source}{columns}{xmin} = {type => 'string', internal => 1};
            $raw->{writes}{row_revision} = {column => 'xmin'};
            $e = $engine->();
            my $xmin = $e->all($e->query->select('name'))->{row_revisions}[0];
            is($e->execute_write(Selecto::Write::Command->new(operation => 'update', relation => 'sv_values', assignments => {name => 'system version'},
                predicate => Selecto::Expression->eq('id', 1))->row_revision($xmin))->affected_rows, 1, 'PostgreSQL system xmin token works without a schema change');
        }
        $dbh->do('DROP TABLE sv_values');
        $dbh->disconnect;
    };
}
done_testing;
