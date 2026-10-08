use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Storable qw(dclone);
use DBI ();
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::Domain;
use Selecto::Engine;
use Selecto::Expression;

sub contract {
    return {
        schema_version => 1, name => 'Declared direct tenant joins',
        source => {source_table => 'join_people', primary_key => 'id', tenant_field => 'tenant_id',
            fields => [qw(id tenant_id account_id)],
            columns => {map {($_ => {type => 'integer'})} qw(id tenant_id account_id)},
            associations => {account => {queryable => 'account', owner_key => 'account_id', related_key => 'id', cardinality => 'one'}}},
        schemas => {account => {source_table => 'join_accounts', primary_key => 'id', tenant_field => 'organization_id',
            fields => [qw(id organization_id name region_id)],
            columns => {id => {type => 'integer'}, organization_id => {type => 'integer'}, name => {type => 'string'}, region_id => {type => 'integer'}},
            associations => {region => {queryable => 'region', owner_key => 'region_id', related_key => 'id', cardinality => 'one'}}},
            region => {source_table => 'join_regions', primary_key => 'id', tenant_field => 'company_id',
                fields => [qw(id company_id name)], columns => {id => {type => 'integer'}, company_id => {type => 'integer'}, name => {type => 'string'}}, associations => {}}},
        joins => {account => {type => 'left', joins => {region => {type => 'left'}}}},
    };
}

sub error_code {my ($call) = @_; return 'ok' if eval {$call->(); 1}; return ref($@) && $@->isa('Selecto::Error') ? $@->code : 'untyped';}

subtest 'canonical direct edges infer only complete declared relation tenancy' => sub {
    my $domain = Selecto::Domain->parse(contract(), strict => 1);
    is($domain->associations->{account}->source_scope_key, 'tenant_id', 'root authored tenant field supplies source equality');
    is($domain->associations->{account}->target_scope_key, 'organization_id', 'target authored tenant field can have a different name');
    my $nested = $domain->resolve_association('account.region')->{association};
    is($nested->source_scope_key, 'organization_id', 'nested direct edge uses its immediate source relation');
    is($nested->target_scope_key, 'company_id', 'nested direct edge uses its immediate target relation');
    for my $missing (qw(source target)) {
        my $raw = contract();
        delete $raw->{source}{tenant_field} if $missing eq 'source';
        delete $raw->{schemas}{account}{tenant_field} if $missing eq 'target';
        my $plain = Selecto::Domain->parse($raw, strict => 1)->associations->{account};
        ok(!defined($plain->source_scope_key) && !defined($plain->target_scope_key), "no inference without declared $missing tenancy");
    }
    my $explicit = contract();
    @{$explicit->{source}{associations}{account}}{qw(source_scope_key target_scope_key)} = ('account_id', 'id');
    my $edge = Selecto::Domain->parse($explicit, strict => 1)->associations->{account};
    is_deeply([$edge->source_scope_key, $edge->target_scope_key], ['account_id', 'id'], 'complete author pair takes precedence without added equality');
    for my $key (qw(source_scope_key target_scope_key)) {
        my $partial = contract();
        $partial->{source}{associations}{account}{$key} = $key eq 'source_scope_key' ? 'tenant_id' : 'organization_id';
        is(error_code(sub {Selecto::Domain->parse($partial, strict => 1)}), 'invalid_domain', "$key alone is refused and never completed by inference");
    }
    for my $bad (undef, JSON::PP::false, 'missing') {
        my $raw = contract();
        @{$raw->{source}{associations}{account}}{qw(source_scope_key target_scope_key)} = ($bad, 'organization_id');
        is(error_code(sub {Selecto::Domain->parse($raw, strict => 1)}), 'invalid_domain', 'malformed explicit pairs retain typed native refusal');
    }
    for my $key (qw(source_scope_key target_scope_key)) {
        my $partial = contract();
        $partial->{schemas}{account}{associations}{region}{$key} = $key eq 'source_scope_key' ? 'organization_id' : 'company_id';
        is(error_code(sub {Selecto::Domain->parse($partial, strict => 1)->resolve_association('account.region')}),
            'invalid_domain', "nested $key alone is refused by native association admission");
    }
    for my $bad (JSON::PP::false, 'missing') {
        my $raw = contract();
        $raw->{schemas}{account}{tenant_field} = $bad;
        is(error_code(sub {Selecto::Domain->parse($raw, strict => 1)}), 'invalid_domain',
            'inferred tenant metadata must identify an actual target relation field');
    }
    my $roundtrip = Selecto::Domain->parse($domain->as_contract, strict => 1);
    is_deeply([$roundtrip->associations->{account}->source_scope_key,
        $roundtrip->resolve_association('account.region')->{association}->target_scope_key],
        ['tenant_id','company_id'], 'portable canonical roundtrip retains declared relation guard semantics');
};

subtest 'legacy explicit scope and through contracts retain their existing policy' => sub {
    my %root = (name => 'Legacy direct', table => 'parents', tenant_field => 'tenant_id', fields => {id => 'integer', tenant_id => 'integer'});
    my %edge = (table => 'children', fields => {id => 'integer', tenant_key => 'integer'}, owner_key => 'id', related_key => 'id');
    my $unscoped = Selecto::Domain->new(%root, associations => {child => \%edge})->associations->{child};
    ok(!defined($unscoped->source_scope_key), 'legacy path does not invent unavailable target tenant metadata');
    my $scoped = Selecto::Domain->new(%root, associations => {child => {%edge, source_scope_key => 'tenant_id', target_scope_key => 'tenant_key'}})->associations->{child};
    is_deeply([$scoped->source_scope_key, $scoped->target_scope_key], ['tenant_id', 'tenant_key'], 'legacy complete explicit pair remains');
    for my $key (qw(source_scope_key target_scope_key)) {
        is(error_code(sub {Selecto::Domain->new(%root, associations => {child => {%edge, $key => $key eq 'source_scope_key' ? 'tenant_id' : 'tenant_key'}})}), 'invalid_domain', 'legacy partial pair remains refused');
    }
    my $raw = contract();
    $raw->{source}{associations}{account}{through} = {table => 'bridges', owner_key => 'person_id', related_key => 'account_id'};
    my $through = Selecto::Domain->parse($raw, strict => 1)->associations->{account};
    ok(!defined($through->source_scope_key) && !defined($through->target_scope_key), 'through tenancy cannot be inferred from two endpoints');
};

sub check_live_reads {
    my ($dbh, $backend) = @_;
    my $initial;
    $dbh->do('CREATE TEMP TABLE join_people(id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, account_id INTEGER)');
    $dbh->do('CREATE TEMP TABLE join_accounts(id INTEGER, organization_id INTEGER, name TEXT, region_id INTEGER, UNIQUE(organization_id,id))');
    $dbh->do('CREATE TEMP TABLE join_regions(id INTEGER, company_id INTEGER, name TEXT, UNIQUE(company_id,id))');
    $dbh->do(q{INSERT INTO join_people VALUES(1,7,101),(2,7,201),(3,7,102),(4,7,NULL),(5,7,999),(8,8,201)});
    $dbh->do(q{INSERT INTO join_accounts VALUES(101,7,'Own beta',301),(102,7,'Own alpha',302),(101,8,'Foreign collision',301),(201,8,'Foreign only',303)});
    $dbh->do(q{INSERT INTO join_regions VALUES(301,7,'Own region'),(301,8,'Foreign region collision'),(302,8,'Foreign region only'),(303,8,'Foreign region')});
    my $snapshot = sub {return [map {$dbh->selectall_arrayref('SELECT * FROM '.$_.' ORDER BY 1,2')} qw(join_people join_accounts join_regions)];};
    $initial = $snapshot->();
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(contract(), strict => 1), adapter => Selecto->adapter($backend => (dbh => $dbh)), scope => {tenant => 7});
    my $rows = $engine->all($engine->query->select('id', 'account.name', 'account.region.name')->order_by('id'))->{rows};
    is_deeply($rows, [[1,'Own beta','Own region'],[2,undef,undef],[3,'Own alpha',undef],[4,undef,undef],[5,undef,undef]], 'both actual direct edges prevent foreign matches without duplicate/drop root rows');
    is_deeply($engine->all($engine->query->select('id')->where(Selecto::Expression->eq('account.name','Foreign only')))->{rows}, [], 'foreign joined values cannot drive root membership');
    is_deeply($engine->all($engine->query->select('id')->where(Selecto::Expression->eq('account.region.name','Foreign region only')))->{rows}, [], 'foreign nested joined values cannot drive root membership');
    my $many = contract();
    $many->{source}{associations}{account}{cardinality} = 'many';
    my $collection = Selecto::Engine->new(domain => Selecto::Domain->parse($many, strict => 1), adapter => $engine->adapter, scope => {tenant => 7});
    is_deeply($collection->all($collection->query->select('id', Selecto::Expression->related_count('account','id')->as('n'))->order_by('id'))->{rows}, [[1,1],[2,0],[3,1],[4,0],[5,0]], 'actual correlated counts use inferred equality');
    my $computed = contract();
    push @{$computed->{source}{fields}}, 'account_exists';
    $computed->{source}{columns}{account_exists} = {type => 'boolean', computed => {kind => 'association_exists', association => 'account'}};
    my $exists = Selecto::Engine->new(domain => Selecto::Domain->parse($computed, strict => 1), adapter => $engine->adapter, scope => {tenant => 7});
    is_deeply([map {[$_->[0], $_->[1] ? 1 : 0]} @{$exists->all($exists->query->select('id','account_exists')->order_by('id'))->{rows}}], [[1,1],[2,0],[3,1],[4,0],[5,0]], 'actual computed EXISTS cannot see foreign-only targets');
    $many->{schemas}{account}{associations}{region}{cardinality} = 'many';
    my $nested_collection = Selecto::Engine->new(domain => Selecto::Domain->parse($many, strict => 1), adapter => $engine->adapter, scope => {tenant => 7});
    my $nested_rows = $nested_collection->all($nested_collection->query->select('id',
        Selecto::Expression->related_collection('account', ['name', {
            key => 'regions', expression => Selecto::Expression->related_collection('account.region', ['name']),
        }])->as('accounts'))->order_by('id'))->{rows};
    is_deeply([map {[$_->[0], JSON::PP->new->decode($_->[1])]} @$nested_rows],
        [[1,[{name => 'Own beta', regions => [{name => 'Own region'}]}]], [2,[]],
            [3,[{name => 'Own alpha', regions => []}]], [4,[]], [5,[]]],
        'actual nested correlated JSON collections scope both immediate relation edges');
    if ($backend eq 'postgresql') {
        my $lateral_raw = contract();
        $lateral_raw->{source}{associations}{account}{join_strategy} = 'lateral_lookup';
        $lateral_raw->{schemas}{account}{associations}{region}{join_strategy} = 'lateral_lookup';
        my $lateral = Selecto::Engine->new(domain => Selecto::Domain->parse($lateral_raw, strict => 1), adapter => $engine->adapter, scope => {tenant => 7});
        is_deeply($lateral->all($lateral->query->select('id','account.name','account.region.name')->order_by('id'))->{rows},
            [[1,'Own beta','Own region'],[2,undef,undef],[3,'Own alpha',undef],[4,undef,undef],[5,undef,undef]],
            'actual PostgreSQL lateral lookups keep inferred tenant equality inside each lookup');
    }
    is_deeply($snapshot->(), $initial, 'all actual joined/correlated reads preserve every tenant row');
}

subtest 'actual SQLite joined and correlated reads preserve root rows and hide foreign collisions' => sub {
    require DBD::SQLite;
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    check_live_reads($dbh, 'sqlite');
    $dbh->disconnect;
};

subtest 'actual PostgreSQL joined, correlated and lateral reads' => sub {
    my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
    plan skip_all => 'SELECTO_PERL_TEST_POSTGRES_URL is not configured' unless defined($url) && $url ne '';
    require DBD::Pg;
    require Selecto::Certification;
    my ($dsn, $username, $password) = Selecto::Certification::_connection_parts($url);
    my $dbh = DBI->connect($dsn, $username, $password, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    check_live_reads($dbh, 'postgresql');
    $dbh->disconnect;
};

subtest 'six native dialect compilers retain inferred joins and bound parameters' => sub {
    for my $backend (qw(postgresql sqlite duckdb mysql mariadb mssql)) {
        my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(contract(), strict => 1),
            adapter => Selecto->adapter($backend => (dbh => TestSelecto::DBH->new)), scope => {tenant => 7});
        my $statement = $engine->compile($engine->query->select(Selecto::Expression->literal(99)->as('literal'),
            'account.name','account.region.name')->where(Selecto::Expression->eq('id', 1)));
        my $sql = $statement->sql;
        $sql =~ s/[\"`\[\]]//g;
        like($sql, qr/s0\.tenant_id = j_account\.organization_id/, "$backend direct join has column equality");
        like($sql, qr/j_account\.organization_id = j_account__region\.company_id/, "$backend nested join uses immediate parent tenancy");
        is_deeply($statement->params, [99,7,1], "$backend inferred keys add no binds or reorder native binds");
    }
};

done_testing;
