use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use lib 't/lib';
use TestSelecto;

sub command {
    my ($expected,$op,$predicate) = @_;
    return Selecto::Write::Command->new(operation=>$op // 'update',relation=>'bounded_items',
        assignments=>($op//'update') eq 'delete' ? {} : {name=>'changed'},
        predicate=>$predicate // Selecto::Expression->gte('id',1),expected_count=>$expected);
}
sub exercise {
    my ($name,$dbh,$trigger_count) = @_;
    my $engine=Selecto::Engine->new(domain=>TestSelecto::writable_domain(
        name=>'Bounded items',table=>'bounded_items',fields=>{id=>'integer',name=>'string'}),
        adapter=>Selecto->adapter($name=>(dbh=>$dbh)));
    for my $op(qw(update delete)) {
        my $ok=eval{$engine->execute_write(command(1,$op));1};
        my $e=$@;
        ok !$ok, "$op refuses excessive match";
        is $e->code,'cardinality_mismatch','typed refusal';
        is $trigger_count->(),0,'refused before any row trigger ran';
        ok !exists($e->to_hash->{details}{actual}),'no match count in public error';
        is(($dbh->selectrow_array('SELECT COUNT(*) FROM bounded_items'))[0],2,'all rows preserved');
    }
    my $result=$engine->execute_write(command(2));
    is $result->affected_rows,2,'exact bounded predicate allowed';
    is $trigger_count->(),2,'only accepted mutation ran triggers';
    $dbh->begin_work;
    $engine->execute_write(command(1,'update',Selecto::Expression->eq('id',1)));
    ok !$dbh->{AutoCommit},'host transaction remains open';
    $dbh->rollback;
}

subtest 'SQLite preflight refuses before triggers' => sub {
    plan skip_all=>'SQLite unavailable' unless eval{require DBI;require DBD::SQLite;1};
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $dbh->do('CREATE TABLE bounded_items(id INTEGER PRIMARY KEY,name TEXT)');
    $dbh->do(q{INSERT INTO bounded_items VALUES(1,'one'),(2,'two')});
    my $count=0;
    $dbh->sqlite_create_function('observe_change',0,sub{++$count});
    for my $op(qw(UPDATE DELETE)) {
        $dbh->do("CREATE TRIGGER observe_$op BEFORE $op ON bounded_items BEGIN SELECT observe_change(); END");
    }
    for my $op(qw(update delete)) {
        for my $expected(1,2) {
            my $engine=Selecto::Engine->new(domain=>TestSelecto::writable_domain(
                name=>'Bounded items',table=>'bounded_items',fields=>{id=>'integer',name=>'string'}),
                adapter=>Selecto->adapter(sqlite=>(dbh=>$dbh)));
            eval {$engine->execute_write(command($expected,$op))};
            is $@->code,'required_data_rule_pending','trigger target needs physical mutation authority';
            is $count,0,'no row trigger runs before authority refusal';
            is $dbh->selectrow_array('SELECT COUNT(*) FROM bounded_items'),2,'trigger target rows remain intact';
        }
    }
    $dbh->do('DROP TRIGGER observe_UPDATE');$dbh->do('DROP TRIGGER observe_DELETE');
    my $before=$dbh->selectrow_array('SELECT total_changes()');
    exercise('sqlite',$dbh,sub{$dbh->selectrow_array('SELECT total_changes()')-$before});
};

subtest 'compound probe retains exact tuples rather than a Cartesian selection' => sub {
    plan skip_all=>'SQLite unavailable' unless eval{require DBI;require DBD::SQLite;1};
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $dbh->do('CREATE TABLE bounded_items(a INTEGER NOT NULL,b INTEGER NOT NULL,name TEXT,PRIMARY KEY(a,b))');
    $dbh->do(q{INSERT INTO bounded_items VALUES(1,1,'picked'),(2,2,'picked'),(1,2,'leave'),(2,1,'leave')});
    my $adapter=Selecto->adapter(sqlite=>(dbh=>$dbh));
    my $cmd=Selecto::Write::Command->new(operation=>'update',relation=>'bounded_items',
        assignments=>{name=>'changed'},predicate=>Selecto::Expression->eq('name','picked'),expected_count=>2,
        metadata=>{__selecto_primary_key=>['a','b'],__selecto_write_limit=>1000});
    $dbh->begin_work;
    my $bounded=$adapter->_bounded_write_command($cmd);
    # Simulate newly matching crossed rows after the probe. They must never
    # join the already selected tuple set, even though both components match.
    $dbh->do(q{UPDATE bounded_items SET name='picked' WHERE name='leave'});
    my $compiled=$adapter->_compile_write($bounded);
    my $sth=$dbh->prepare($compiled->{sql});
    $sth->execute(@{$compiled->{params}});
    is($sth->rows,2,'only complete probed tuples mutate');
    is_deeply($dbh->selectall_arrayref('SELECT a,b,name FROM bounded_items ORDER BY a,b'),
        [[1,1,'changed'],[1,2,'picked'],[2,1,'picked'],[2,2,'changed']], 'crossed component values are excluded');
    $dbh->rollback;
    $dbh->disconnect;
};

subtest 'PostgreSQL preflight refuses before nontransactional trigger effects' => sub {
    my $database=$ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all=>'disposable PostgreSQL unavailable' unless $database && eval{require DBI;require DBD::Pg;1};
    my $dbh=DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0});
    $dbh->do('CREATE TEMP TABLE bounded_items(id INTEGER PRIMARY KEY,name TEXT)');
    $dbh->do(q{INSERT INTO bounded_items VALUES(1,'one'),(2,'two')});
    $dbh->do('CREATE TEMP SEQUENCE bounded_observed');
    $dbh->do(q{CREATE FUNCTION pg_temp.observe_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
        PERFORM nextval('bounded_observed'); IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$});
    $dbh->do('CREATE TRIGGER observe_change BEFORE UPDATE OR DELETE ON bounded_items FOR EACH ROW EXECUTE FUNCTION pg_temp.observe_change()');
    exercise('postgresql',$dbh,sub{
        my($n,$called)=$dbh->selectrow_array('SELECT last_value,is_called FROM bounded_observed');
        return $called?$n:0;
    });
    $dbh->disconnect;
};

subtest 'unproven broad-write dialects refuse, bounded key writes remain supported' => sub {
    for my $name(qw(mysql mariadb mssql duckdb)) {
        my $adapter=Selecto->adapter($name=>(dbh=>TestSelecto::DBH->new));
        my $cmd=command(1)->with_metadata({__selecto_primary_key=>'id',__selecto_write_limit=>1000});
        eval{$adapter->_bounded_write_command($cmd)};
        is $@->code,'write_capability_missing',"$name broad predicate refused";
        my $key=command(1,'update',Selecto::Expression->eq('id',1))->with_metadata($cmd->metadata);
        is $adapter->_bounded_write_command($key),$key,"$name unique-key write needs no preflight";
    }
};
subtest 'PostgreSQL fixes the selected keys and restores timeout after refusal' => sub {
    my $database=$ENV{SELECTO_API_TEST_DATABASE};
    plan skip_all=>'disposable PostgreSQL unavailable' unless $database && eval{require DBI;require DBD::Pg;1};
    {
        package Local::BoundedPostgreSQL;
        use Mojo::Base 'Selecto::PostgreSQL';
        has 'after_probe';
        sub _bounded_write_command {
            my ($self,$command)=@_;
            my $bounded=$self->SUPER::_bounded_write_command($command);
            if (my $after=$self->after_probe) { $self->after_probe(undef); $after->() }
            return $bounded;
        }
    }
    my $dbh=DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0});
    my $peer=DBI->connect("dbi:Pg:dbname=$database;host=/tmp",undef,undef,{RaiseError=>1,PrintError=>0});
    my $table='bounded_concurrent_' . $$;
    $dbh->do("CREATE TABLE $table(id INTEGER PRIMARY KEY,name TEXT)");
    $dbh->do("INSERT INTO $table VALUES(1,'one'),(2,'two')");
    my $adapter=Local::BoundedPostgreSQL->new(dbh=>$dbh);
    my $engine=Selecto::Engine->new(domain=>TestSelecto::writable_domain(
        name=>'Concurrent bounded',table=>$table,fields=>{id=>'integer',name=>'string'}),adapter=>$adapter);
    $peer->do(q{SET lock_timeout='20ms'});
    $adapter->after_probe(sub {
        $peer->do("INSERT INTO $table VALUES(3,'new match')");
        my $ok=eval{$peer->do("UPDATE $table SET name='raced' WHERE id=1");1};
        ok !$ok,'selected rows stay locked until mutation';
    });
    my $cmd=Selecto::Write::Command->new(operation=>'update',relation=>$table,
        assignments=>{name=>'accepted'},predicate=>Selecto::Expression->gte('id',1),expected_count=>2);
    is $engine->execute_write($cmd)->affected_rows,2,'only verified keys are updated';
    is_deeply $dbh->selectall_arrayref("SELECT id,name FROM $table ORDER BY id"),
        [[1,'accepted'],[2,'accepted'],[3,'new match']], 'concurrent newly matching row is excluded';
    # A peer holds a selected row, forcing preflight to hit the stricter host
    # statement deadline. The adapter must restore a reusable connection.
    $peer->begin_work;
    $peer->do("UPDATE $table SET name='held' WHERE id=1");
    $dbh->do(q{SET statement_timeout='20ms'});
    my $ok=eval{$engine->execute_write($cmd);1};
    ok !$ok,'locked preflight is interrupted';
    $peer->rollback;
    is(($dbh->selectrow_array(q{SHOW statement_timeout}))[0],'20ms','host timeout survives rollback');
    ok !$dbh->{private_selecto_query_budget_poisoned},'recovered handle is not poisoned';
    my $guard=$adapter->begin_query_budget(timeout_ms=>100);
    $guard->close;
    $dbh->do("DROP TABLE $table");
    $peer->disconnect;$dbh->disconnect;
};
done_testing;
