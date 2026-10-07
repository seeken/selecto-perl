use 5.034;
use strict;
use warnings;
use Test::More;
use Selecto::PostgreSQL ();
use Selecto::PostgreSQL::StatementCache ();
use Selecto::Statement ();
use Selecto::Expression ();
use Selecto::Write ();

# A DBD::Pg double. A handle is prepared on the server on its second
# execution (DBD::Pg's pg_switch_prepared default) and deallocated when it is
# destroyed; destroying one inside a failed transaction is recorded, since
# DBD::Pg would roll that transaction back to deallocate.
package CacheDBH {
    sub new { my ($class, %args) = @_; return bless {AutoCommit => 1, ping => 1, prepared => [], events => [], fail => {}, %args}, $class; }
    sub prepare {
        my ($self, $sql) = @_;
        push @{$self->{prepared}}, $sql;
        return undef if $self->{prepare_fails};
        return CacheSTH->new(owner => $self, Statement => $sql);
    }
    # As DBI's: the key is the SQL text and the attributes.
    sub prepare_cached {
        my ($self, $sql, $attributes, $if_active) = @_;
        my $key = join "!\001", $sql, join(',', map { "$_=$attributes->{$_}" } sort keys %{$attributes // {}});
        my $cache = $self->{CachedKids} //= {};
        if (my $sth = $cache->{$key}) {
            $sth->finish if $sth->{Active} && ($if_active // 0) <= 1;
            return $sth;
        }
        my $sth = $self->prepare($sql) or return undef;
        return $cache->{$key} = $sth;
    }
    sub pg_ping { my ($self) = @_; $self->{state} = ''; push @{$self->{events}}, 'PING'; return $self->{ping}; }
    sub state { return $_[0]{state} // ''; }
    sub errstr { return $_[0]{errstr}; }
    sub begin_work { my ($self) = @_; push @{$self->{events}}, 'BEGIN'; $self->{AutoCommit} = 0; return 1; }
    sub commit { my ($self) = @_; push @{$self->{events}}, 'COMMIT'; $self->{AutoCommit} = 1; return 1; }
    sub rollback {
        my ($self) = @_;
        push @{$self->{events}}, 'ROLLBACK';
        @{$self}{qw(AutoCommit failed state)} = (1, 0, '');
        return 1;
    }
    sub do { push @{$_[0]{events}}, $_[1]; return '0E0'; }
    sub fail_next { my ($self, $sql, $state, $message) = @_; push @{$self->{fail}{$sql}}, [$state, $message]; return; }
}

package CacheSTH {
    my $SERIAL = 0;
    sub new { my ($class, %args) = @_; return bless {%args, id => ++$SERIAL, executions => 0, Active => 0, pg_type => []}, $class; }
    sub execute {
        my ($self, @params) = @_;
        my $owner = $self->{owner};
        if (my $failure = shift @{$owner->{fail}{$self->{Statement}} // []}) {
            my ($state, $message) = @$failure;
            @{$self}{qw(state errstr)} = ($state, $message);
            @{$owner}{qw(state errstr)} = ($state, $message);
            $owner->{failed} = 1 unless $owner->{AutoCommit};
            return undef if $owner->{no_raise};
            die "$message\n";
        }
        $self->{params} = [@params];
        $self->{named} = 1 if ++$self->{executions} >= 2;
        push @{$owner->{events}}, "EXEC $self->{id}" . ($self->{named} ? ' named' : '');
        $self->{state} = '';
        return '0E0';
    }
    sub fetchall_arrayref { my ($self) = @_; return [[$self->{Statement}, @{$self->{params}}]]; }
    sub fetchrow_array { my ($self) = @_; return if $self->{fetched}++; return (1); }
    sub rows { return 1; }
    sub finish { $_[0]{Active} = 0; return 1; }
    sub state { return $_[0]{state} // ''; }
    sub err { return $_[0]{state} ? 1 : undef; }
    sub errstr { return $_[0]{errstr}; }
    sub DESTROY {
        my ($self) = @_;
        my $owner = $self->{owner} or return;
        return unless $self->{named};
        push @{$owner->{events}}, ($owner->{failed} ? "DESTROY-IN-FAILED-TRANSACTION $self->{id}" : "DEALLOCATE $self->{id}");
    }
}

package main;

my $statement = sub { Selecto::Statement->new(sql => $_[0], params => [@_[1 .. $#_]], columns => ['sql', 'value']); };
my $adapter = sub { my ($dbh, %options) = @_; return Selecto::PostgreSQL->new(dbh => $dbh, %options); };
my $events = sub { my ($dbh, $pattern) = @_; return [grep { /$pattern/ } @{$dbh->{events}}]; };
my $error_of = sub { my ($code) = @_; return eval { $code->(); 1 } ? undef : $@; };
my ($A, $B, $C) = ('SELECT a WHERE t = $1', 'SELECT b WHERE t = $1', 'SELECT c WHERE t = $1');

subtest 'off by default: a new unnamed handle per call, as before' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh);
    is $pg->statement_cache, 0, 'statement_cache defaults to off';
    $pg->execute_query($statement->($A, $_)) for 1 .. 3;
    is_deeply $dbh->{prepared}, [$A, $A, $A], 'each call prepares';
    is_deeply $events->($dbh, 'named|DEALLOCATE'), [], 'no handle is reused, so none is named on the server';
    ok !$dbh->{CachedKids}, 'nothing is kept on the handle';
    is(Selecto::PostgreSQL::StatementCache->count($dbh), 0, 'count is zero');
};

subtest 'on: hit and miss' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh, statement_cache => 1);
    my @rows = map { $pg->execute_query($statement->($A, $_))->{rows} } 1 .. 3;
    is_deeply \@rows, [[[$A, 1]], [[$A, 2]], [[$A, 3]]], 'each call binds its own value';
    is_deeply $dbh->{prepared}, [$A], 'one prepare for repeated SQL';
    my ($id) = map { $_->{id} } values %{$dbh->{CachedKids}};
    is_deeply $events->($dbh, 'EXEC'), ["EXEC $id", "EXEC $id named", "EXEC $id named"],
        'the first execution is unnamed, later ones reuse the named statement';
    $pg->execute_query($statement->($B, 9));
    is_deeply $dbh->{prepared}, [$A, $B], 'different SQL text is a miss';
    is(Selecto::PostgreSQL::StatementCache->count($dbh), 2, 'two entries');
    my $other = $adapter->($dbh, statement_cache => 1);
    $other->execute_query($statement->($A, 4));
    is_deeply $dbh->{prepared}, [$A, $B], 'the cache belongs to the connection, not the adapter';
    my $fresh = CacheDBH->new;
    $adapter->($fresh, statement_cache => 1)->execute_query($statement->($A, 5));
    is_deeply $fresh->{prepared}, [$A], 'another connection prepares its own';
};

subtest 'bound and least-recently-used eviction' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh, statement_cache => 1, statement_cache_size => 2);
    $pg->execute_query($statement->($_, 1)) for $A, $A, $B, $B, $A;
    my %id = map { $dbh->{CachedKids}{$_}{Statement} => $dbh->{CachedKids}{$_}{id} } keys %{$dbh->{CachedKids}};
    $pg->execute_query($statement->($C, 1));
    is(Selecto::PostgreSQL::StatementCache->count($dbh), 2, 'the bound holds');
    is_deeply [sort map { $_->{Statement} } values %{$dbh->{CachedKids}}], [sort $A, $C], 'the least recently used entry (B) left';
    is_deeply $events->($dbh, 'DEALLOCATE|FAILED'), ["DEALLOCATE $id{$B}"], 'the evicted statement is deallocated';
    $pg->execute_query($statement->($B, 1));
    is_deeply [sort map { $_->{Statement} } values %{$dbh->{CachedKids}}], [sort $B, $C], 'then A, now least recent, leaves';
    is $dbh->{prepared}[-1], $B, 'an evicted statement is prepared again';
    my $error = $error_of->(sub { $adapter->($dbh, statement_cache => 1, statement_cache_size => 0)->execute_query($statement->($A, 1)) });
    is $error->code, 'invalid_adapter', 'a bound must be a positive integer';
};

subtest 'an entry runs only its own SQL text' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh, statement_cache => 1);
    $pg->execute_query($statement->($A, 1));
    $pg->execute_query($statement->($B, 1));
    # Force a collision: A's entry now holds B's handle.
    my ($key_a) = grep { $dbh->{CachedKids}{$_}{Statement} eq $A } keys %{$dbh->{CachedKids}};
    my ($key_b) = grep { $dbh->{CachedKids}{$_}{Statement} eq $B } keys %{$dbh->{CachedKids}};
    $dbh->{CachedKids}{$key_a} = $dbh->{CachedKids}{$key_b};
    my $rows = $pg->execute_query($statement->($A, 7))->{rows};
    is_deeply $rows, [[$A, 7]], 'A runs A, not the handle stored under its entry';
    is $dbh->{prepared}[-1], $A, 'A is prepared again';
    is_deeply $pg->execute_query($statement->($B, 8))->{rows}, [[$B, 8]], 'B still runs B';
    unlike join("\n", keys %{$dbh->{CachedKids}}), qr/\b[78]\b/, 'no parameter value appears in a cache key';
};

for my $state (qw(26000 0A000)) {
    subtest "$state outside a transaction: dropped and prepared once more" => sub {
        my $dbh = CacheDBH->new;
        my $pg = $adapter->($dbh, statement_cache => 1);
        $pg->execute_query($statement->($A, 1)) for 1 .. 2;
        my ($old) = map { $_->{id} } values %{$dbh->{CachedKids}};
        $dbh->fail_next($A, $state, 'statement changed');
        is_deeply $pg->execute_query($statement->($A, 3))->{rows}, [[$A, 3]], 'the call succeeds with the same result';
        is_deeply $dbh->{prepared}, [$A, $A], 'prepared once more';
        is_deeply $events->($dbh, 'PING|DEALLOCATE|FAILED'), ['PING', "DEALLOCATE $old"],
            'the old handle is deallocated after the new statement succeeded';
        is(Selecto::PostgreSQL::StatementCache->count($dbh), 1, 'one entry remains');

        $dbh->fail_next($A, $state, 'statement changed');
        $dbh->fail_next($A, $state, 'statement changed');
        my $error = $error_of->(sub { $pg->execute_query($statement->($A, 4)) });
        is $error->details->{sqlstate}, $state, 'a second failure is reported, not retried again';
    };

    subtest "$state inside a transaction: the original error, nothing deallocated" => sub {
        my $dbh = CacheDBH->new;
        my $pg = $adapter->($dbh, statement_cache => 1);
        $pg->execute_query($statement->($A, 1)) for 1 .. 2;
        $dbh->begin_work;
        $dbh->{ping} = 3;
        $dbh->fail_next($A, $state, 'statement changed');
        my $error = $error_of->(sub { $pg->execute_query($statement->($A, 2)) });
        is $error->code, 'query_error', 'query_error';
        is_deeply $error->details, {cause => 'database_error', sqlstate => $state, category => 'database_error'},
            'with the SQLSTATE of the original failure';
        is_deeply $dbh->{prepared}, [$A], 'not prepared inside the aborted transaction';
        is_deeply $events->($dbh, 'DEALLOCATE|FAILED'), [], 'no handle destroyed inside the failed transaction';
        is(Selecto::PostgreSQL::StatementCache->count($dbh), 0, 'the entry is gone');
        $dbh->rollback;
        $dbh->{ping} = 1;
        is_deeply $pg->execute_query($statement->($A, 5))->{rows}, [[$A, 5]], 'after rollback the next call works';
        is_deeply $dbh->{prepared}, [$A, $A], 'prepared afresh';
        is scalar(@{$events->($dbh, '^DEALLOCATE')}), 1, 'and the retired handle is deallocated at that safe point';
        is_deeply $events->($dbh, 'FAILED'), [], 'never inside the failed transaction';
    };
}

subtest 'other errors keep their mapping and the entry' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh, statement_cache => 1);
    $pg->execute_query($statement->($A, 1));
    $dbh->fail_next($A, '23505', 'duplicate key value violates unique constraint "x" DETAIL: Key (id)=(1) already exists.');
    my $error = $error_of->(sub { $pg->execute_query($statement->($A, 1)) });
    is $error->code, 'database_unique_violation', 'mapped as without the cache';
    $dbh->fail_next($A, '57014', 'canceling statement due to statement timeout');
    $error = $error_of->(sub { $pg->execute_query($statement->($A, 1)) });
    is_deeply $error->details, {cause => 'database_error', sqlstate => '57014', category => 'query_canceled'},
        'SQLSTATE preserved from a cached handle';
    is_deeply $events->($dbh, 'PING'), [], 'no retry for other errors';
    $pg->execute_query($statement->($A, 2));
    is_deeply $dbh->{prepared}, [$A], 'the entry stays cached';
};

subtest 'a failed first execution is not cached' => sub {
    my $dbh = CacheDBH->new(no_raise => 1);
    my $pg = $adapter->($dbh, statement_cache => 1);
    $dbh->fail_next($A, '42P01', 'relation "a" does not exist');
    my $error = $error_of->(sub { $pg->execute_query($statement->($A, 1)) });
    is_deeply $error->details, {cause => 'database_error', sqlstate => '42P01', category => 'database_error'},
        'an undefined execute result is a failure with its SQLSTATE';
    is(Selecto::PostgreSQL::StatementCache->count($dbh), 0, 'nothing cached');
};

subtest 'writes reuse handles inside their own transactions' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh, statement_cache => 1);
    my $command = sub {
        Selecto::Write::Command->new(operation => 'update', relation => 'items', assignments => {name => $_[0]},
            predicate => Selecto::Expression->eq('id', 7), expected_count => 1);
    };
    is $pg->execute_write_unsafe($command->("n$_"))->affected_rows, 1, "write $_" for 1 .. 3;
    is scalar(@{$dbh->{prepared}}), 1, 'one prepare for three writes';
    is_deeply $events->($dbh, 'BEGIN|COMMIT|ROLLBACK'), [('BEGIN', 'COMMIT') x 3], 'each write commits on its own';
    my ($sql) = @{$dbh->{prepared}};
    $dbh->fail_next($sql, '23503', 'violates foreign key constraint');
    my $error = $error_of->(sub { $pg->execute_write_unsafe($command->('x')) });
    is $error->code, 'database_foreign_key_violation', 'write error mapping unchanged';
    is $dbh->{events}[-1], 'ROLLBACK', 'rolled back';
    is_deeply $events->($dbh, 'FAILED'), [], 'nothing destroyed in the failed transaction';
    $pg->execute_write_unsafe($command->('y'));
    is scalar(@{$dbh->{prepared}}), 1, 'the entry survives the rollback';
};

subtest 'forget drops entries without deallocating' => sub {
    my $dbh = CacheDBH->new;
    my $pg = $adapter->($dbh, statement_cache => 1);
    $pg->execute_query($statement->($A, 1));
    $dbh->{CachedKids}{'SELECT host!' . "\001"} = 'host entry';
    Selecto::PostgreSQL::StatementCache->forget($dbh);
    is(Selecto::PostgreSQL::StatementCache->count($dbh), 0, 'entries gone');
    is $dbh->{CachedKids}{'SELECT host!' . "\001"}, 'host entry', "the host's prepare_cached entries are untouched";
};

done_testing;
