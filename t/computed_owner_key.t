use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Storable qw(dclone);
use lib 't/lib';
use TestSelecto;
use TestPostgreSQL;
use TestComputedOwnerKey qw(contract setup);
use Selecto;
use Selecto::Domain::WriteContract ();

{
    package ComputedKeyDBH;
    our @ISA = ('TestSelecto::DBH');
    sub selectrow_array {
        my ($self, $sql) = @_;
        return ($sql =~ /SET STATEMENT/ ? '11.4.5-MariaDB' : '8.4.5') if $sql =~ /SELECT VERSION\(\)/;
        return $self->SUPER::selectrow_array($sql);
    }
}
my $domain = Selecto::Domain->parse(contract(), strict => 1);
sub caught { return eval { $_[0]->(); 1 } ? undef : $@ }

subtest 'legacy association SQL and fingerprint captured at eded9da' => sub {
    open my $fh, '<', 't/fixtures/computed_owner_key_legacy.json' or die $!;
    my $before = JSON::PP->new->decode(do { local $/; <$fh> });
    my $legacy = TestSelecto::orders_domain();
    is $legacy->fingerprint, $before->{fingerprint}, 'existing fixture fingerprint is byte-identical';
    for my $name (@{Selecto->available_adapters}) {
        my $engine = Selecto::Engine->new(domain => $legacy,
            adapter => Selecto->adapter($name, dbh => ComputedKeyDBH->new));
        my $s = $engine->compile($engine->query->select(qw(id person.name))
            ->where(Selecto::Expression->eq('person.name', 'Ada'))->order_by('id'));
        is $s->sql, $before->{$name}{sql}, "$name existing SQL is byte-identical";
        is_deeply $s->params, $before->{$name}{params}, "$name existing parameters unchanged";
    }
};

subtest 'all adapter SQL shapes' => sub {
    for my $name (@{Selecto->available_adapters}) {
        my $engine = Selecto::Engine->new(domain => $domain,
            adapter => Selecto->adapter($name, dbh => ComputedKeyDBH->new));
        my $s = $engine->compile($engine->query->select('inventory_location.co_name')
            ->where(Selecto::Expression->eq('inventory_location_id', 2)));
        (my $sql = $s->sql) =~ tr/`/"/;
        like $sql, qr/ON (?:CAST\()?\(CASE WHEN .*THEN "s0"\."dest_id" WHEN .*THEN "s0"\."orig_id" END\)(?: AS INTEGER\))? = "j_inventory_location"\."id"/,
            "$name joins on the computed key";
        like $sql, qr/WHERE (?:CAST\()?\(CASE WHEN .* END\)(?: AS INTEGER\))? = (?:CAST\()?(?:\?|\$\d+)/, "$name filters the same expression";
        is_deeply $s->params, [qw(I D I G D C I D I G D C), 2], "$name branch constants and filter stay bound in SQL order";
        unlike $sql, qr/"s0"\."inventory_location_id"/, "$name never reads a synthetic physical column";
    }
    my $changed = contract();
    $changed->{source}{columns}{inventory_location_id}{computed}{expression}[1][0][2][2] = 'R';
    isnt(Selecto::Domain->parse($changed)->fingerprint, $domain->fingerprint, 'CASE conditions change the fingerprint');
};

subtest 'reject invalid computed owner keys' => sub {
    for my $case (
        ['literal result', sub { $_[0]{source}{columns}{inventory_location_id}{computed}{expression}[1][1] = ['literal', 2] }],
        ['unknown field', sub { $_[0]{source}{columns}{inventory_location_id}{computed}{expression}[1][1] = ['field', 'no_such'] }],
        ['joined dependency', sub { $_[0]{source}{columns}{inventory_location_id}{computed}{expression}[1][0] = ['eq', 'inventory_location.city', 'Arc'] }],
        ['computed dependency cycle', sub { $_[0]{source}{columns}{orig_id}{computed} = {kind => 'expression', expression => ['field', 'inventory_location_id']} }],
        ['redacted dependency', sub { $_[0]{source}{columns}{status}{redacted} = 1 }],
        ['wrong type', sub { $_[0]{source}{columns}{inventory_location_id}{type} = 'string' }],
        ['raw SQL', sub { $_[0]{source}{columns}{inventory_location_id}{computed}{expression} = ['unsafe_sql', 'dest_id'] }],
    ) {
        my $raw = contract(); $case->[1]->($raw);
        my $error = caught(sub { Selecto::Domain->parse($raw, strict => 1) });
        ok $error && $error->code eq 'invalid_domain', "$case->[0] refuses at domain boundary";
    }
};

subtest 'governed writes refuse computed keys and relationships' => sub {
    my $raw = contract();
    $raw->{writes} = {operations => {update => {enabled => JSON::PP::true}}, fields => {status => {updatable => JSON::PP::true}}};
    ok(Selecto::Domain::WriteContract->validate($raw)->{valid}, 'ordinary root writes remain valid');
    for my $inline (0, 1) {
        my $bad = dclone($raw);
        my $spec = {writable => JSON::PP::true, cardinality => 'one', ownership => 'owned',
            parent_key => 'orig_id', child_key => 'id'}; # overriding parent key cannot bypass read-only
        if ($inline) { $bad->{source}{associations}{inventory_location}{write} = $spec }
        else { $bad->{writes}{relationships}{inventory_location} = $spec }
        my $v = Selecto::Domain::WriteContract->validate($bad);
        ok !$v->{valid} && grep($_->{code} eq 'computed_owner_key_read_only', @{$v->{errors}}),
            ($inline ? 'inline' : 'canonical') . ' relationship writes explicitly refuse';
        ok caught(sub { Selecto::Domain::WriteContract->compile($bad) }), 'compiled contract also refuses';
    }
    my $bad = dclone($raw);
    $bad->{writes}{fields}{inventory_location_id} = {updatable => JSON::PP::true};
    ok(!Selecto::Domain::WriteContract->validate($bad)->{valid}, 'direct write contract rejects computed field');
    ok caught(sub { Selecto::Domain->parse($bad) }), 'domain rejects computed field write policy';
};

for my $name (qw(sqlite postgresql)) {
    subtest "$name live" => sub {
        plan skip_all => 'PostgreSQL test URL not set' if $name eq 'postgresql' && !TestPostgreSQL->configured;
        my $dbh = $name eq 'sqlite'
            ? DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0})
            : TestPostgreSQL->connect;
        setup($dbh);
        my $engine = Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter($name, dbh => $dbh));
        my $rows = sub { $engine->all($_[0])->{rows} };
        is_deeply $rows->($engine->query->select(qw(id inventory_location_id inventory_location.co_name inventory_location.city inventory_location.state))->order_by('id')),
            [[1,2,'Beta','Bay','UT'], [2,1,'Alpha','Arc','CO'], [3,2,'Beta','Bay','UT'],
             (map { [$_,undef,undef,undef,undef] } 4..10), [11,3,'Alpha','Cove','AZ']],
            'conditional destination/origin, exclusions and SQL NULL semantics';
        my $grouped = $rows->($engine->query->select('inventory_location_id',
            Selecto::Expression->min('inventory_location.co_name')->as('label'), Selecto::Expression->count->as('n'))
            ->group_by('inventory_location_id')->order_by('inventory_location_id'));
        is_deeply [sort { ($a->[0] // 0) <=> ($b->[0] // 0) } @$grouped],
            [[undef,undef,7], [1,'Alpha',1], [2,'Beta',2], [3,'Alpha',1]], 'stable key groups, duplicate labels and missing NULL group';
        is_deeply $rows->($engine->query->select('id')->where(Selecto::Expression->eq('inventory_location_id', '2'))->order_by('id')),
            [[1],[3]], 'dimension key filter/drilldown uses CASE, not origin';
        is_deeply $rows->($engine->query->select('id')->where(Selecto::Expression->is_null('inventory_location_id'))->order_by('id')),
            [map { [$_] } 4..10], 'missing key drilldown';
        is_deeply $rows->($engine->query->select('id')->where(Selecto::Expression->eq('inventory_location.city', 'Cove'))),
            [[11]], 'association fields filter normally';
        # Association-exists and related_rows use correlated owner-key compilation too.
        my $exists = contract();
        push @{$exists->{source}{fields}}, 'has_location';
        $exists->{source}{columns}{has_location} = {type => 'boolean', computed => {kind => 'association_exists', association => 'inventory_location'}};
        my $ed = Selecto::Domain->parse($exists);
        my $ee = Selecto::Engine->new(domain => $ed, adapter => Selecto->adapter($name, dbh => $dbh));
        is_deeply $ee->all($ee->query->select('id')->where(Selecto::Expression->eq('has_location', 1))->order_by('id'))->{rows},
            [[1],[2],[3],[11]], 'correlated existence uses computed owner key';
        my $collections = $rows->($engine->query->select('id',
            Selecto::Expression->related_rows('inventory_location', [qw(id co_name)], order_by => [['id','asc']], limit => 2)->as('location'))
            ->where(Selecto::Expression->in('id', [1,4]))->order_by('id'));
        my $decode = sub { ref($_[0]) ? $_[0] : JSON::PP->new->decode($_[0]) };
        is_deeply $decode->($collections->[0][1]), [{id => 2, co_name => 'Beta'}], 'bounded related rows use computed key';
        is_deeply $decode->($collections->[1][1]), [], 'missing key has no related rows';

        # Alias the owner relation itself, then join the computed dimension
        # underneath it. CASE conditions/results must use that parent alias.
        my $nested = {schema_version => 1, name => 'Nested synthetic loads',
            source => {source_table => 'ck_load', primary_key => 'id', fields => ['id'], columns => {id => {type => 'integer'}},
                associations => {load => {queryable => 'loads', owner_key => 'id', related_key => 'id'}}},
            schemas => {loads => contract()->{source}, client_party => contract()->{schemas}{client_party}},
            joins => {load => {type => 'left', alias => 'joined_load'},
                'load.inventory_location' => contract()->{joins}{inventory_location}}};
        my $ne = Selecto::Engine->new(domain => Selecto::Domain->parse($nested, strict => 1), adapter => Selecto->adapter($name, dbh => $dbh));
        is_deeply $ne->all($ne->query->select('id', 'load.inventory_location.co_name')
            ->where(Selecto::Expression->eq('load.inventory_location_id', '2'))->order_by('id'))->{rows},
            [[1,'Beta'],[3,'Beta']], 'nested dimension conditions and results use owner alias with text ID';

        my $nr = $ne->all($ne->query->select(Selecto::Expression->related_rows('load', [
            'id', {key => 'location', expression => Selecto::Expression->related_rows('load.inventory_location', ['id'],
                order_by => [['id','asc']], limit => 2)}], order_by => [['id','asc']], limit => 2)->as('nested'))
            ->where(Selecto::Expression->eq('id',1)))->{rows};
        is_deeply $decode->($nr->[0][0]), [{id => 1, location => [{id => 2}]}],
            'bounded nested collection projects physical CASE dependencies and correlates the parent alias';

        # A tenant collision in the target cannot become a matching dimension.
        $dbh->do('ALTER TABLE ck_load ADD COLUMN tenant_id integer');
        $dbh->do('ALTER TABLE ck_client_profile ADD COLUMN tenant_id integer');
        $dbh->do('UPDATE ck_load SET tenant_id = 7');
        $dbh->do('UPDATE ck_client_profile SET tenant_id = 7');
        $dbh->do("INSERT INTO ck_client_profile VALUES (99,'Foreign','Secret','ZZ',8)");
        $dbh->do("INSERT INTO ck_load VALUES (12,'D','I',1,99,7)");
        my $tenant = contract();
        for my $relation ($tenant->{source}, $tenant->{schemas}{client_party}) {
            push @{$relation->{fields}}, 'tenant_id';
            $relation->{columns}{tenant_id} = {type => 'integer'};
            $relation->{tenant_field} = 'tenant_id';
        }
        my $te = Selecto::Engine->new(domain => Selecto::Domain->parse($tenant),
            adapter => Selecto->adapter($name, dbh => $dbh), tenant => 7);
        is_deeply $te->all($te->query->select('id','inventory_location.co_name')->where(Selecto::Expression->eq('id',12)))->{rows},
            [[12,undef]], 'computed key retains inferred tenant pairing';
        $dbh->do('CREATE TEMPORARY TABLE ck_bridge (client_id integer, target_id integer, info varchar(1))');
        $dbh->do("INSERT INTO ck_bridge VALUES (1,1,'Y'), (2,2,'Y'), (3,3,'N')");
        my $through = contract();
        $through->{source}{associations}{inventory_location}{through} = {
            table => 'ck_bridge', owner_key => 'client_id', related_key => 'target_id', where => {info => 'Y'}};
        $through->{source}{associations}{inventory_location}{where} = {co_name => 'Beta'};
        my $be = Selecto::Engine->new(domain => Selecto::Domain->parse($through), adapter => Selecto->adapter($name, dbh => $dbh));
        is_deeply $be->all($be->query->select('id')->where(Selecto::Expression->eq('inventory_location.co_name','Beta'))->order_by('id'))->{rows},
            [[1],[3]], 'through joins bind target policy, computed owner and bridge policy in SQL order';
        my $br = $be->all($be->query->select(Selecto::Expression->related_rows('inventory_location', ['id'],
            order_by => [['id','asc']], limit => 2)->as('location'))->where(Selecto::Expression->eq('id',1)))->{rows};
        is_deeply $decode->($br->[0][0]), [{id => 2}], 'through correlated rows retain computed key and policy';

        for my $join_type (qw(right full)) {
            next unless $engine->adapter->supports("${join_type}_join");
            my $preserved = contract();
            $preserved->{joins}{inventory_location} = {type => $join_type};
            $preserved->{source}{associations}{inventory_location}{where} = {co_name => 'Beta'};
            my $pe = Selecto::Engine->new(domain => Selecto::Domain->parse($preserved), adapter => Selecto->adapter($name, dbh => $dbh));
            is_deeply $pe->all($pe->query->select('id')->where(Selecto::Expression->not_null('inventory_location.co_name'))->order_by('id'))->{rows},
                [[1],[3]], "$join_type joins bind target restriction before computed ON key";
        }
        my $wd = contract();
        $wd->{writes} = {operations => {update => {enabled => JSON::PP::true}}, fields => {status => {updatable => JSON::PP::true}}};
        my $we = Selecto::Engine->new(domain => Selecto::Domain->parse($wd), adapter => Selecto->adapter($name, dbh => $dbh));
        my $before_write = $dbh->selectall_arrayref('SELECT * FROM ck_load ORDER BY id');
        my $error = caught(sub { $we->execute_write($we->write_command(operation => 'update',
            assignments => {inventory_location_id => 1}, filter => ['eq','id',1])) });
        isa_ok $error, 'Selecto::Error', 'native engine refuses synthetic owner key';
        is $error->code, 'write_field_not_writable', 'native write refusal identifies non-writable field';
        my $portable_error = caught(sub { $we->write->update->assignments(inventory_location_id => 1)
            ->filter(['id',1])->execute });
        isa_ok $portable_error, 'Selecto::Error', 'portable native builder refuses synthetic owner key';
        is $portable_error->code, 'write_field_not_writable', 'portable refusal names missing write grant';
        is_deeply $dbh->selectall_arrayref('SELECT * FROM ck_load ORDER BY id'), $before_write, 'write refusals preserve storage';
        $dbh->disconnect;
    };
}
done_testing;
