use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Time::HiRes qw(sleep);
use Selecto;
use Selecto::API ();
use Selecto::API::EngineHandler ();
use Selecto::Write::Operation ();
use Selecto::Write::Expression ();
use lib 't/lib';
use TestSavedViews ();
use TestSelecto ();

sub declaration {
    return {schema_version => 1, name => 'ClockPanels', domain_version => '1.0.0', domain_fingerprint => 'sha256:clock-panels', source => {source_table => 'sv_clock_panels', primary_key => 'id',
        fields => [qw(id name created_on modified_on)], associations => {}, columns => {
            id => {type => 'integer'}, name => {type => 'string'},
            created_on => {type => 'datetime'}, modified_on => {type => 'datetime'}}}, schemas => {},
        writes => {
            operations => {insert => {enabled => JSON::PP::true}, update => {enabled => JSON::PP::true, bulk => JSON::PP::true,
                expected_cardinality => 'many'}, delete => {enabled => JSON::PP::true},
                upsert => {enabled => JSON::PP::true, conflict_targets => [['id']]}},
            # Even explicit caller grants cannot override a host binding.
            fields => {map { $_ => {insertable => JSON::PP::true, updatable => JSON::PP::true} } qw(id name created_on modified_on)},
            host_bound_fields => {created_on => {mode => 'created_at'}, modified_on => {mode => 'modified_at'}}}};
}
sub command {
    my ($operation, $values, $id) = @_;
    return Selecto::Write::Command->new(operation => $operation, relation => 'sv_clock_panels',
        assignments => $values // {}, defined($id) ? (predicate => Selecto::Expression->eq('id', $id)) : ());
}
sub refuses {
    my ($code, $work, $label) = @_;
    my $error;
    eval { $work->(); 1 } or $error = $@;
    is(blessed($error) ? $error->code : 'ok/untyped', $code, $label);
    return $error;
}

subtest 'timestamp declarations and discovery' => sub {
    ok(Selecto::Domain->validate_write_contract(declaration())->{valid}, 'portable declaration accepted');
    my $domain = Selecto::Domain->parse(declaration());
    my $api = Selecto::API->new(domain => $domain, base_path => '/api', publish_domain => 1);
    my $described = JSON::PP->new->decode($api->request({method => 'GET', path => '/api/domain'})->{body});
    my %fields = map { $_->{path} => $_ } @{$api->openapi_document->{'x-selecto'}{fields}};
    for my $field (qw(created_on modified_on)) {
        ok($described->{source}{columns}{$field}{read_only}, "$field read-only in describe");
        ok($fields{$field}{read_only}, "$field read-only in OpenAPI");
        ok(!exists($domain->contract->{source}{columns}{$field}{read_only}), 'discovery leaves original contract unchanged');
    }
    for my $spec ({mode => 'created_at', source => ['context', 'clock']},
        {mode => 'modified_at', source => undef}, {mode => 'created_at', sql => 'CURRENT_TIMESTAMP'},
        {mode => 'created_by'}) {
        my $raw = declaration();
        $raw->{writes}{host_bound_fields}{created_on} = $spec;
        ok(!Selecto::Domain->validate_write_contract($raw)->{valid}, 'invalid source/options rejected by portable validator');
        refuses('invalid_domain', sub { Selecto::Domain->parse($raw) }, 'native parser rejects same declaration');
    }
    my $raw = declaration();
    $raw->{writes}{host_bound_fields} = {absent => {mode => 'created_at'}};
    refuses('invalid_domain', sub { Selecto::Domain->parse($raw) }, 'timestamp must name a stored root field');
    # Existing context bindings receive the same discovery annotation.
    $raw = declaration();
    $raw->{writes}{host_bound_fields} = {id => {mode => 'owner', source => ['context', 'user_id']}};
    my $owner_api = Selecto::API->new(domain => Selecto::Domain->parse($raw));
    ok($owner_api->domain->{source}{columns}{id}{read_only}, 'owner is also described as read-only');
};

subtest 'all supported SQL dialects compile database clocks' => sub {
    my $domain = Selecto::Domain->parse(declaration());
    for my $name (qw(sqlite postgresql mysql mariadb)) {
        my $adapter = Selecto->adapter($name => (dbh => TestSelecto::DBH->new));
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
        my $governed = $engine->governed_write(command('insert', {id => 1, name => 'Clock'}));
        my $statement = $adapter->preview_write($governed);
        is(() = $statement->{sql} =~ /CURRENT_TIMESTAMP/g, 2, "$name insert has two database expressions");
        is_deeply($statement->{params}, [1, 'Clock'], "$name binds no Perl clock");
        $statement = $adapter->preview_write($engine->governed_write(command('update', {name => 'Next'}, 1)));
        is(() = $statement->{sql} =~ /CURRENT_TIMESTAMP/g, 1, "$name update has one database expression");
    }
};

for my $backend (TestSavedViews->backends) {
    my ($name, $connect) = @$backend;
    subtest "timestamp writes on $name" => sub {
        my $dbh = $connect->();
        $dbh->do('CREATE TABLE sv_clock_panels (id INTEGER PRIMARY KEY, name VARCHAR(100), created_on TIMESTAMP, modified_on TIMESTAMP)');
        my $raw = declaration();
        my $domain = Selecto::Domain->parse($raw);
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $engine = Selecto::Engine->new(domain => $domain, adapter => $adapter);
        my $handler = Selecto::API::EngineHandler->new(bounded_results => 0);
        my $read = sub { $dbh->selectrow_arrayref('SELECT created_on, modified_on FROM sv_clock_panels WHERE id=1') };
        my $before = $dbh->selectrow_array('SELECT CURRENT_TIMESTAMP');
        is($engine->execute_write(command('insert', {id => 1, name => 'First'}))->affected_rows, 1, 'native insert needs no clock context');
        my $initial = $read->();
        my $after = $dbh->selectrow_array('SELECT CURRENT_TIMESTAMP');
        ok(defined($initial->[0]) && defined($initial->[1]), 'insert fills both timestamps');
        is($initial->[0], $initial->[1], 'insert clocks agree within the statement');
        ok($initial->[0] ge $before && $initial->[0] le $after, 'insert uses current database time');
        sleep 1.1; # SQLite and default MySQL TIMESTAMP have second precision.
        is($engine->execute_write(command('update', {name => 'Second'}, 1))->affected_rows, 1, 'native update succeeds');
        my $updated = $read->();
        is($updated->[0], $initial->[0], 'update preserves creator timestamp');
        isnt($updated->[1], $initial->[1], 'update refreshes modifier timestamp');
        for my $field (qw(created_on modified_on)) {
            for my $operation (qw(insert update)) {
                for my $value ('2001-01-01 00:00:00', undef, Selecto::Write::Expression->current_timestamp) {
                    my $error = refuses('host_bound_field', sub {
                        $engine->execute_write(command($operation, {id => 9, name => 'Spoof', $field => $value},
                            $operation eq 'update' ? 1 : undef));
                    }, "$operation refuses caller $field even with explicit grants");
                    is($error->details->{field}, $field, 'refusal names field') if blessed($error);
                }
                refuses('host_bound_field', sub {
                    $handler->write($engine, {operation => $operation, assignments => {name => 'Spoof', $field => '2001-01-01'},
                        $operation eq 'update' ? (filters => [{field => 'id', op => 'eq', value => 1}]) : ()});
                }, "API refuses $field on $operation");
                refuses('host_bound_field', sub {
                    my $op = Selecto::Write::Operation->new($raw);
                    $op = $operation eq 'insert' ? $op->insert({id => 9, $field => '2001-01-01'})
                        : $op->update({$field => '2001-01-01'})->filter(['id', 1]);
                    $op->compile;
                }, "portable refuses $field on $operation");
            }
        }
        is_deeply($read->(), $updated, 'refused assignments leave both clocks unchanged');
        refuses('host_bound_upsert_unsupported', sub {
            $engine->execute_write(command('upsert', {id => 1, name => 'No upsert'}));
        }, 'native upsert retains existing refusal');
        refuses('host_bound_upsert_unsupported', sub {
            Selecto::Write::Operation->new($raw)->upsert({id => 1, name => 'No upsert'})->compile;
        }, 'portable upsert retains existing refusal');
        my $compiled = Selecto::Write::Operation->new($raw)->insert({id => 2, name => 'Portable'})->compile;
        is($engine->execute_write($compiled->{command}->with_metadata({}))->affected_rows, 1,
            'generated database expressions retain provenance through command copies');
        refuses('host_bound_field', sub {
            $engine->execute_write($compiled->{command}->with_assignments({%{$compiled->{command}->assignments},
                created_on => Selecto::Write::Expression->literal('2001-01-01')}));
        }, 'changing generated expression loses trusted provenance');
        refuses('host_bound_field', sub {
            $engine->execute_write(Selecto::Write::Command->new(operation => 'insert', relation => 'sv_clock_panels',
                assignments => $compiled->{command}->assignments, metadata => $compiled->{command}->metadata));
        }, 'reconstructed expression assignments cannot forge provenance');
        my $portable = Selecto::Write::Operation->new($raw)->update({name => 'Portable update'})->filter(['id', 2])->compile;
        is($engine->execute_write($portable->{command})->affected_rows, 1, 'portable update re-enters native governance');
        is($engine->write->insert->assignments(id => 3, name => 'Fluent')->execute->affected_rows, 1, 'fluent insert');
        $handler->write($engine, {operation => 'update', assignments => {name => 'API update'},
            filters => [{field => 'id', op => 'eq', value => 3}]});
        ok($dbh->selectrow_array('SELECT modified_on IS NOT NULL FROM sv_clock_panels WHERE id=3'), 'API update keeps timestamp filled');
        # Seed old modification times to distinguish every touched row without clock-resolution races.
        $dbh->do(q{UPDATE sv_clock_panels SET modified_on='2001-01-01 00:00:00'});
        my $created = $dbh->selectall_arrayref('SELECT id, created_on FROM sv_clock_panels ORDER BY id');
        my $bulk = command('update', {name => 'Bulk'})->_with(predicate => Selecto::Expression->gt('id', 0), expected_count => undef);
        is($engine->execute_write($bulk)->affected_rows, 3, 'governed bulk update touches all rows');
        is($dbh->selectrow_array(q{SELECT COUNT(*) FROM sv_clock_panels WHERE modified_on > '2001-01-01 00:00:00'}), 3,
            'bulk update refreshes every modifier');
        is_deeply($dbh->selectall_arrayref('SELECT id, created_on FROM sv_clock_panels ORDER BY id'), $created,
            'bulk update preserves every creator');
        is($engine->execute_write(command('delete', {}, 3))->affected_rows, 1, 'timestamp-only delete needs no context or audit update');
        # No new modes: ordinary explicit timestamp assignments retain their behavior.
        delete $raw->{writes}{host_bound_fields};
        my $ordinary = Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => $adapter);
        is($ordinary->execute_write(command('insert', {id => 4, name => 'Ordinary', created_on => '2001-01-01 00:00:00'}))->affected_rows,
            1, 'undeclared timestamp remains caller-writable');
        ok(!defined($dbh->selectrow_array('SELECT modified_on FROM sv_clock_panels WHERE id=4')), 'no undeclared modifier fill');
        $ordinary->execute_write(command('update', {name => 'Ordinary update'}, 4));
        ok(!defined($dbh->selectrow_array('SELECT modified_on FROM sv_clock_panels WHERE id=4')), 'no undeclared update clock');
        my $trusted = declaration();
        delete @{$trusted->{writes}{fields}}{qw(created_on modified_on)};
        my $trusted_engine = Selecto::Engine->new(domain => Selecto::Domain->parse($trusted), adapter => $adapter);
        is($trusted_engine->execute_write(command('insert', {id => 5, name => 'Host only'}))->affected_rows, 1,
            'host clocks need no caller field grants');
        $trusted->{writes}{fields}{created_on} = {required => JSON::PP::true};
        $trusted->{writes}{fields}{modified_on} = {required => JSON::PP::true};
        my $required = Selecto::Engine->new(domain => Selecto::Domain->parse($trusted), adapter => $adapter);
        my $required_command = Selecto::Write::Operation->new($trusted)->insert({id => 6, name => 'Required clocks'})->compile;
        is($required->execute_write($required_command->{command})->affected_rows, 1, 'generated clocks satisfy required fields');
        $trusted->{writes}{fields}{modified_on}{validators} = [['length', [[min => 1]]]];
        refuses('required_data_rule_pending', sub {
            Selecto::Write::Operation->new($trusted)->insert({id => 7, name => 'Validated clock'})->compile;
        }, 'literal validator on database expression remains pending');
        $dbh->do('DROP TABLE sv_clock_panels');
        $dbh->disconnect;
    };
}
done_testing;
