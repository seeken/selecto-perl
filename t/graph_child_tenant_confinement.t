use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::Write ();

# Lesson 33: a graph child, and an owned-sync row, that stores the root's
# tenant column is confined to the root's admitted tenants exactly as the
# root is, even when only the root's required predicate (no engine tenant)
# bounds them: tenant 7's graph cannot insert, re-tag, update or delete a
# tenant 8 row, and owned-sync cleanup never deletes one. Refusals happen
# before any DML.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}

sub domain {
    my ($t, $owned) = @_;
    my $child = {schema_version => 1, name => 'Children',
        source => {source_table => $t->{children}, primary_key => 'id', fields => [qw(id parent_id tenant_id note)],
            columns => {map { ($_ => {type => $_ eq 'note' ? 'string' : 'integer'}) } qw(id parent_id tenant_id note)},
            associations => {}},
        schemas => {}, joins => {},
        writes => {operations => {map { ($_ => {enabled => 1}) } qw(insert update delete)},
            fields => {id => {insertable => 1}, tenant_id => {insertable => 1, updatable => 1},
                note => {insertable => 1, updatable => 1}}}};
    return Selecto::Domain->parse({schema_version => 1, name => 'Parents',
        source => {source_table => $t->{parents}, primary_key => 'id', fields => [qw(id tenant_id label)],
            columns => {id => {type => 'integer'}, tenant_id => {type => 'integer'}, label => {type => 'string'}},
            associations => {}, tenant_field => 'tenant_id'},
        schemas => {}, joins => {},
        writes => {
            operations => {update => {enabled => 1}},
            fields => {label => {updatable => 1}},
            relationships => {children => {writable => 1, parent_key => 'id', child_key => 'parent_id',
                allowed_ops => [qw(insert update delete)], domain => $child,
                ($owned ? (ownership => 'owned', strategy => 'sync', identity_fields => ['id'], delete_missing => 1) : ())}},
        }})->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    for my $owned (0, 1) {
        my $path = $owned ? 'owned-sync rows' : 'graph children';
        subtest "$path stay inside the root's tenants on $name" => sub {
            my $dbh = $connect->();
            my $suffix = $$ . '_' . int(rand(1_000_000));
            my %t = map { ($_ => "selecto_conf_${_}_$suffix") } qw(parents children);
            my $reset = sub {
                $dbh->do("DROP TABLE IF EXISTS $t{$_}") for qw(children parents);
                $dbh->do("CREATE TABLE $t{parents} (id integer primary key, tenant_id integer, label text)");
                $dbh->do("CREATE TABLE $t{children} (id integer primary key, parent_id integer, tenant_id integer, note text)");
                $dbh->do("INSERT INTO $t{parents} VALUES (1, 7, 'mine'), (3, 8, 'theirs')");
                # 13 is a tenant 8 row sitting under tenant 7's parent.
                $dbh->do("INSERT INTO $t{children} VALUES (10, 1, 7, 'keep'), (13, 1, 8, 'foreign')");
            };
            my $children = sub { $dbh->selectall_arrayref("SELECT id, parent_id, tenant_id, note FROM $t{children} ORDER BY id") };
            my $engine = Selecto::Engine->new(domain => domain(\%t, $owned), adapter => Selecto->adapter($name => (dbh => $dbh)));
            plan skip_all => "$name does not implement owned-set sync"
                if $owned && !$engine->adapter->write_capabilities->{owned_set_sync};
            my $graph = sub {
                my (@commands) = @_;
                my @ids = map { "child$_" } 0 .. $#commands;
                return Selecto::Write::Graph->new(nodes => [
                    {id => 'root', command => Selecto::Write::Command->new(operation => 'update', relation => $t{parents},
                        assignments => {label => 'touched'}, predicate => Selecto::Expression->eq('id', 1), expected_count => 1)},
                    map { {id => $ids[$_], command => $commands[$_],
                        bindings => [{from => 'root', key => 'id', field => 'parent_id'}]} } 0 .. $#commands,
                ], ($owned ? (owned_sets => [{parent => 'root', relationship => 'children', nodes => \@ids,
                    delete_missing => JSON::PP::true}]) : ()));
            };
            my $command = sub {
                my ($operation, $id, %assignments) = @_;
                return Selecto::Write::Command->new(operation => $operation, relation => $t{children},
                    ($operation eq 'delete' ? () : (assignments => \%assignments)),
                    ($operation eq 'insert' ? () : (predicate => Selecto::Expression->eq('id', $id))), expected_count => 1);
            };
            my $keep = $command->('update', 10, note => 'kept');

            for my $attack (
                ['insert with a foreign tenant_id', 'tenant_mismatch', $command->('insert', undef, id => 20, tenant_id => 8, note => 'x')],
                ['update re-tagging its row to tenant 8', 'tenant_mismatch', $command->('update', 10, tenant_id => 8)],
                ['update of a tenant 8 row', 'cardinality_mismatch', $command->('update', 13, note => 'pwned')],
                ($owned ? () : (['delete of a tenant 8 row', 'cardinality_mismatch', $command->('delete', 13)])),
            ) {
                my ($label, $code, $child) = @$attack;
                $reset->();
                my @dml;
                $dbh->sqlite_trace(sub { push @dml, $_[0] if $_[0] =~ /\A\s*(?:INSERT|UPDATE|DELETE)/i }) if $name eq 'sqlite';
                is(code_of(sub { $engine->execute_graph($graph->($owned ? ($child, $keep) : $child)) }),
                    $code, "$label is refused ($code)");
                is_deeply(\@dml, [], "$label: refused before any DML") if $name eq 'sqlite' && $code eq 'tenant_mismatch';
                $dbh->sqlite_trace(undef) if $name eq 'sqlite';
                is_deeply($children->(), [[10, 1, 7, 'keep'], [13, 1, 8, 'foreign']], "$label: every row is unchanged");
            }

            $reset->();
            is(code_of(sub { $engine->execute_graph($graph->($command->('insert', undef, id => 21, tenant_id => 7, note => 'new'),
                $command->('update', 10, note => 'edited'))) }), 'ok', 'tenant 7 inserts and edits its own rows');
            is_deeply($children->(), [[10, 1, 7, 'edited'], [13, 1, 8, 'foreign'], [21, 1, 7, 'new']],
                $owned ? 'sync cleanup never deletes the tenant 8 row' : 'its rows changed, the tenant 8 row did not');
            $dbh->do("DROP TABLE $t{$_}") for qw(children parents);
        };
    }
}

done_testing;
