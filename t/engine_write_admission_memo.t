use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Write::FieldValidators ();

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

# A governed write admits the domain's write contract (a full validating copy and walk of
# every field validator). The contract and the engine's limits are fixed for the life of an
# engine, so a successful admission is remembered per engine, per domain and limits object;
# a failed one never is.
my $E = 'Selecto::Expression';
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, AutoCommit => 1});
$dbh->do('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)');

sub raw {
    return {schema_version => 1, name => 'Items',
        source => {source_table => 'items', primary_key => 'id', fields => [qw(id name)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}}, fields => {name => {updatable => 1}}}};
}
sub engine {
    my (%opts) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse($opts{raw} // raw()),
        adapter => Selecto->adapter(sqlite => (dbh => $dbh)), %opts{grep { $_ ne 'raw' } keys %opts});
}
sub update_cmd {
    return Selecto::Write::Command->new(relation => 'items', operation => 'update',
        assignments => {name => 'changed'}, predicate => $E->eq('id', 1));
}

my $admissions = 0;
{
    no warnings 'redefine';
    my $original = \&Selecto::Write::FieldValidators::admit_domain;
    *Selecto::Write::FieldValidators::admit_domain = sub { $admissions++; goto &$original };
}

subtest 'one admission per engine across repeated governed writes' => sub {
    my $engine = engine();
    $admissions = 0;
    ok(eval { $engine->governed_write(update_cmd()); 1 }, "first write is governed: $@");
    is($admissions, 1, 'the first write admits the contract');
    $engine->governed_write(update_cmd()) for 1 .. 5;
    is($admissions, 1, 'five more writes on the same engine do not admit it again');
};

subtest 'a different engine or a different limits object admits again' => sub {
    my $first = engine();
    $first->governed_write(update_cmd());
    $admissions = 0;
    my $second = engine();
    $second->governed_write(update_cmd());
    is($admissions, 1, 'a second engine admits its own domain');
    my $tight = engine(limits => Selecto::Limits->new(max_expression_nodes => 5_000));
    $admissions = 0;
    $tight->governed_write(update_cmd());
    is($admissions, 1, 'an engine with its own limits admits under them');
    $tight->governed_write(update_cmd());
    is($admissions, 1, '...and then remembers it');
};

subtest 'a refused admission is never remembered' => sub {
    my $engine = engine();
    my ($attempts, $refused) = (0, 0);
    {
        no warnings 'redefine';
        my $inner = \&Selecto::Write::FieldValidators::admit_domain;
        local *Selecto::Write::FieldValidators::admit_domain = sub {
            $attempts++;
            Selecto::Error->throw('invalid_write_contract', 'forced refusal') if $refused++ < 2;
            goto &$inner;
        };
        my @codes = map {
            eval { $engine->governed_write(update_cmd()); 1 } ? 'ok'
                : (blessed($@) && $@->isa('Selecto::Error') ? $@->code : die $@)
        } 1 .. 3;
        is_deeply(\@codes, ['invalid_write_contract', 'invalid_write_contract', 'ok'],
            'each refused write is refused again; the first success is accepted');
    }
    is($attempts, 3, 'every refused attempt re-ran the admission');
};

done_testing;
