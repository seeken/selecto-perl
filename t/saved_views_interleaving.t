use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed refaddr);
use lib 't/lib';
use TestSavedViews ();
use Selecto;

sub outcome (&) {
    my ($work) = @_;
    return 'ok' if eval { $work->(); 1 };
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    return $error->code;
}
for my $backend (TestSavedViews->backends) {
    my ($name) = @$backend;
    for my $kind (qw(column computed)) {
        subtest "$name $kind interleaved writers" => sub {
            my ($a, $b) = TestSavedViews->pair($backend);
            $b->do("SET lock_timeout = '30ms'") if $name eq 'postgresql';
            $b->do('SET innodb_lock_wait_timeout = 1') if $name =~ /\A(?:mysql|mariadb)\z/;
            $b->sqlite_busy_timeout(0) if $name eq 'sqlite';
            $a->do('CREATE TABLE sv_race (id INTEGER PRIMARY KEY, name VARCHAR(100), version INTEGER NOT NULL)');
            $a->do("INSERT INTO sv_race VALUES (1, 'original', 1)");
            my $domain = Selecto::Domain->parse({name => 'RacePanels', source => {source_table => 'sv_race', primary_key => 'id',
                fields => [qw(id name version)], columns => {id => {type => 'integer'}, name => {type => 'string'}, version => {type => 'integer'}}, associations => {}},
                schemas => {}, writes => {row_revision => $kind eq 'column' ? {column => 'version'} : {columns => [qw(name version)]},
                    operations => {update => {enabled => JSON::PP::true}},
                    fields => {name => {updatable => JSON::PP::true}, version => {updatable => JSON::PP::true}}}});
            my ($ea, $eb) = map { Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name => (dbh => $_))) } ($a, $b);
            my $read = sub { my ($engine) = @_; $engine->all($engine->query->select('name'))-> {row_revisions}[0] };
            my ($ta, $tb) = map { $read->($_) } ($ea, $eb);
            is($ta, $tb, 'two connections read the same initial revision');
            my $command = sub { my ($label, $token) = @_; Selecto::Write::Command->new(operation => 'update', relation => 'sv_race',
                assignments => {name => $label, version => 2}, predicate => Selecto::Expression->eq('id', 1))->row_revision($token) };
            my $b_result;
            my $attempt_b = sub { $b_result = outcome { $eb->execute_write($command->('writer B', $tb)) } };
            my $snapshot = \&Selecto::SQL::_row_revision_snapshot;
            my $execute = $ea->adapter->can('_execute_statement');
            my $adapter_class = ref($ea->adapter);
            my $a_result;
            {
                no strict 'refs';
                no warnings 'redefine';
                local *Selecto::SQL::_row_revision_snapshot = sub {
                    my @row = $snapshot->(@_);
                    $attempt_b->() if $kind eq 'computed' && refaddr($_[0]) == refaddr($ea->adapter) && !defined($b_result);
                    return @row;
                };
                local *{"${adapter_class}::_execute_statement"} = sub {
                    my ($adapter, $sth) = @_;
                    $attempt_b->() if $kind eq 'column' && refaddr($adapter) == refaddr($ea->adapter)
                        && !defined($b_result) && $sth->{Statement} =~ /\AUPDATE /;
                    return $execute->(@_);
                };
                $a_result = outcome { $ea->execute_write($command->('writer A', $ta)) };
            }
            ok(defined($b_result), 'writer B ran inside A\'s check/write interval');
            if ($b_result eq 'ok') {
                is($a_result, 'stale_revision', 'A cannot overwrite B after its protected read');
                is($read->($eb), $read->($ea), 'both connections observe the committed winner');
                is($b->selectrow_array('SELECT name FROM sv_race WHERE id=1'), 'writer B', 'B\'s committed update survives');
            } else {
                like($b_result, qr/\A(?:query_error|required_data_rule_pending)\z/, 'B is refused while A holds the write or row lock');
                is($a_result, 'ok', 'A commits under its lock');
                is(outcome { $eb->execute_write($command->('writer B', $tb)) }, 'stale_revision', 'B retries after commit and its old token is stale');
                is($b->selectrow_array('SELECT name FROM sv_race WHERE id=1'), 'writer A', 'A\'s committed update survives');
            }
            $a->do('DROP TABLE sv_race');
            $b->disconnect;
            $a->disconnect;
        };
    }
}
done_testing;
