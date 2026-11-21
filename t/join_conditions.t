use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use JSON::PP ();
use Storable qw(dclone);
use lib 't/lib';
use TestSelecto;
use Selecto;
use Selecto::MySQL ();

# Association conditions: each compares an owner field with a target field
# after the key equality. They only narrow a join: an effective-dated price
# matches the order date inside its half-open validity, an open bound also
# matches a NULL end, and the tenant pairing still decides scope.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @EFFECTIVE = (
    {left => 'ordered_on', op => 'gte', right => 'valid_from'},
    {left => 'ordered_on', op => 'lt', right => 'valid_to', open => JSON::PP::true},
);

sub domain {
    my (%options) = @_;
    my $association = {queryable => 'prices', owner_key => 'product_id', related_key => 'product_id',
        conditions => $options{conditions} // dclone(\@EFFECTIVE), %{$options{association} // {}}};
    return {schema_version => 1, name => 'Orders',
        source => {source_table => 'jc_orders', primary_key => 'id', fields => [qw(id product_id ordered_on grade tenant_id)],
            tenant_field => 'tenant_id',
            columns => {id => {type => 'integer'}, product_id => {type => 'integer'}, ordered_on => {type => 'date'},
                grade => {type => 'string'}, tenant_id => {type => 'integer'}},
            associations => {price => $association}},
        schemas => {prices => {source_table => 'jc_prices', primary_key => 'id',
            fields => [qw(id product_id valid_from valid_to amount grade tenant_id)],
            tenant_field => 'tenant_id',
            columns => {id => {type => 'integer'}, product_id => {type => 'integer'}, valid_from => {type => 'date'},
                valid_to => {type => 'date'}, amount => {type => 'integer'}, grade => {type => 'string'},
                tenant_id => {type => 'integer'}}}},
        joins => {price => {type => $options{type} // 'left'}}};
}
sub caught { my ($run) = @_; return eval { $run->(); 1 } ? undef : $@ }

my @backends = (['sqlite', sub { DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0}) }]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    my $dbh = DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '', {RaiseError => 1, PrintError => 0});
    $dbh->do('SET client_min_messages TO warning');
    return $dbh;
}] if $db && eval { require DBD::Pg; 1 };

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "$name rows" => sub {
        my $dbh = $connect->();
        $dbh->do($_) for 'DROP TABLE IF EXISTS jc_orders', 'DROP TABLE IF EXISTS jc_prices',
            'CREATE TABLE jc_orders (id INTEGER PRIMARY KEY, product_id INTEGER, ordered_on DATE, grade TEXT, tenant_id INTEGER)',
            'CREATE TABLE jc_prices (id INTEGER PRIMARY KEY, product_id INTEGER, valid_from DATE, valid_to DATE,'
                . ' amount INTEGER, grade TEXT, tenant_id INTEGER)',
            q{INSERT INTO jc_orders VALUES (1, 10, '2025-12-15', 'a', 7), (2, 10, '2026-01-15', 'a', 7),}
                . q{ (3, 10, '2026-02-01', 'b', 7), (4, 10, '2026-05-01', 'a', 7), (5, 20, '2026-02-15', 'a', 7),}
                . q{ (6, 10, '2026-01-20', 'a', 8)},
            q{INSERT INTO jc_prices VALUES (1, 10, '2026-01-01', '2026-02-01', 100, 'a', 7),}
                . q{ (2, 10, '2026-02-01', NULL, 120, 'a', 7), (3, 20, '2026-03-01', NULL, 50, 'a', 7),}
                . q{ (4, 10, '2026-01-01', NULL, 999, 'a', 8)};
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $rows = sub {
            my ($engine, @fields) = @_;
            @fields = ('id', 'price.amount') unless @fields;
            return [sort { ($a->[0] // -1) <=> ($b->[0] // -1) || ($a->[1] // -1) <=> ($b->[1] // -1) }
                map { [map { defined($_) ? 0 + $_ : undef } @$_] }
                @{$engine->all($engine->query->select(@fields))->{rows}}];
        };
        my $engine = sub {
            my ($tenant, %options) = @_;
            my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(domain(%options)), adapter => $adapter);
            return defined($tenant) ? $engine->with_tenant($tenant) : $engine;
        };
        is_deeply($rows->($engine->(7)), [[1, undef], [2, 100], [3, 120], [4, 120], [5, undef]],
            'effective-dated price: before the first price is NULL, the boundary is half-open, the open row is current');
        is_deeply($rows->($engine->(7, type => 'inner')), [[2, 100], [3, 120], [4, 120]], 'inner drops unmatched orders');
        my $closed = dclone(\@EFFECTIVE);
        delete $closed->[1]{open};
        is_deeply($rows->($engine->(7, conditions => $closed)), [[1, undef], [2, 100], [3, undef], [4, undef], [5, undef]],
            'without open a NULL end never matches');
        my %untenanted = (
            left => [[1, undef], [2, 100], [3, 120], [4, 120], [5, undef], [6, 999]],
            inner => [[2, 100], [3, 120], [4, 120], [6, 999]],
            right => [[undef, 50], [2, 100], [3, 120], [4, 120], [6, 999]],
            full => [[undef, 50], [1, undef], [2, 100], [3, 120], [4, 120], [5, undef], [6, 999]],
        );
        for my $type (qw(left inner right full)) {
            is_deeply($rows->($engine->(undef, type => $type)), $untenanted{$type},
                "$type join without a tenant: rows of two tenants never pair");
        }
        my $where = $engine->(undef, type => 'right', association => {where => {grade => 'a'}});
        is_deeply($rows->($where), [[undef, 50], [2, 100], [3, 120], [4, 120], [6, 999]],
            'a right join keeps the where in its derived table and the conditions in ON');
        my $graded = $engine->(7, conditions => [@{dclone(\@EFFECTIVE)}, {left => 'grade', op => 'eq', right => 'grade'}]);
        is_deeply($rows->($graded), [[1, undef], [2, 100], [3, undef], [4, 120], [5, undef]], 'string eq narrows');
        my $other = $engine->(7, conditions => [@{dclone(\@EFFECTIVE)}, {left => 'grade', op => 'NE', right => 'grade'}]);
        is_deeply($rows->($other), [[1, undef], [2, undef], [3, 120], [4, undef], [5, undef]], 'string ne narrows');
        my $collection = $engine->(7);
        my $collected = $collection->all($collection->query->select('id',
            Selecto::Expression->related_collection('price', ['amount'])->as('prices'))->order_by('id'))->{rows};
        my %amounts = map {
            my $value = ref($_->[1]) ? $_->[1] : JSON::PP::decode_json($_->[1] // '[]');
            (0 + $_->[0] => [map { 0 + $_->{amount} } @$value]);
        } @$collected;
        is_deeply(\%amounts, {1 => [], 2 => [100], 3 => [120], 4 => [120], 5 => []}, 'related collections apply the conditions');
        my $flagged = domain();
        push @{$flagged->{source}{fields}}, 'priced';
        $flagged->{source}{columns}{priced} = {type => 'boolean', computed => {kind => 'association_exists', association => 'price'}};
        my $exists = Selecto::Engine->new(domain => Selecto::Domain->parse($flagged), adapter => $adapter)->with_tenant(7);
        is_deeply([map { [0 + $_->[0], $_->[1] ? 1 : 0] } @{$exists->all($exists->query->select('id', 'priced')->order_by('id'))->{rows}}],
            [[1, 0], [2, 1], [3, 1], [4, 1], [5, 0]], 'association_exists applies the conditions');
        if ($name eq 'postgresql') {
            my $lateral = $engine->(7, association => {join_strategy => 'lateral_lookup'});
            is_deeply($rows->($lateral), [[1, undef], [2, 100], [3, 120], [4, 120], [5, undef]],
                'a lateral lookup applies the conditions in its WHERE');
            like($lateral->compile($lateral->query->select('id', 'price.amount'))->{sql},
                qr/LATERAL \(SELECT \* FROM "jc_prices" AS "__selecto_lookup_\w+" WHERE [^)]*"ordered_on" >= /,
                'inside the lateral WHERE');
        }
        $dbh->do($_) for 'DROP TABLE jc_orders', 'DROP TABLE jc_prices';
    };
}

subtest 'SQL follows the key equality' => sub {
    my $engine = Selecto::Engine->new(domain => Selecto::Domain->parse(domain()),
        adapter => Selecto->adapter(sqlite => (dbh => DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1}))));
    my $sql = $engine->compile($engine->query->select('id', 'price.amount'))->{sql};
    my $on = 'ON "s0"."product_id" = "j_price"."product_id" AND "s0"."ordered_on" >= "j_price"."valid_from"'
        . ' AND ("j_price"."valid_to" IS NULL OR "s0"."ordered_on" < "j_price"."valid_to")'
        . ' AND "s0"."tenant_id" = "j_price"."tenant_id"';
    ok(index($sql, $on) >= 0, 'conditions follow the key equality, the open bound as an IS NULL alternative')
        or diag $sql;
    my $text = Selecto::Engine->new(adapter => Selecto::MySQL->new(dbh => TestSelecto::DBH->new),
        domain => Selecto::Domain->parse(domain(conditions => [{left => 'grade', op => 'ne', right => 'grade'}])));
    like($text->compile($text->query->select('id', 'price.amount'))->{sql},
        qr/NOT \(\(`s0`\.`grade` = `j_price`\.`grade` AND CAST\(CONVERT\(`s0`\.`grade` USING utf8mb4\) AS BINARY\)/,
        'MySQL text ne compares bytes');
};

subtest 'domain refusals' => sub {
    my %cases = (
        'unknown left' => [{left => 'missing', op => 'eq', right => 'grade'}],
        'lt on strings' => [{left => 'grade', op => 'lt', right => 'grade'}],
        'op like' => [{left => 'grade', op => 'like', right => 'grade'}],
        'empty' => [],
        'nine entries' => [map { {left => 'grade', op => 'eq', right => 'grade'} } 1 .. 9],
        'open with eq' => [{left => 'grade', op => 'eq', right => 'grade', open => JSON::PP::true}],
        'mixed types' => [{left => 'ordered_on', op => 'eq', right => 'amount'}],
        'unknown key' => [{left => 'grade', op => 'eq', right => 'grade', mode => 'x'}],
        'not an array' => {left => 'grade', op => 'eq', right => 'grade'},
        'open not boolean' => [{left => 'ordered_on', op => 'lt', right => 'valid_to', open => 'yes'}],
    );
    for my $case (sort keys %cases) {
        my $error = caught(sub { Selecto::Domain->parse(domain(conditions => $cases{$case})) });
        is($error && $error->code, 'invalid_domain', "$case refuses");
    }
    my $computed = domain(conditions => [{left => 'grade', op => 'eq', right => 'label'}]);
    push @{$computed->{schemas}{prices}{fields}}, 'label';
    $computed->{schemas}{prices}{columns}{label} = {type => 'string',
        computed => {kind => 'expression', expression => ['field', 'grade']}};
    my $error = caught(sub { Selecto::Domain->parse($computed) });
    like($error && $error->message, qr/computed/, 'a computed right refuses');
    my $redacted = domain(conditions => [{left => 'grade', op => 'eq', right => 'grade'}]);
    $redacted->{schemas}{prices}{redact_fields} = ['grade'];
    $error = caught(sub { Selecto::Domain->parse($redacted) });
    like($error && $error->message, qr/redacted/, 'a redacted right refuses');
    my $top = domain(conditions => [{left => 'grade', op => 'eq', right => 'grade'}]);
    $top->{redact_fields} = ['grade'];
    $error = caught(sub { Selecto::Domain->parse($top) });
    like($error && $error->message, qr/redacted/, 'a redacted owner field refuses');
    my $through = domain(association => {through => {table => 'jc_links', owner_key => 'order_id', related_key => 'price_id'}});
    $error = caught(sub { Selecto::Domain->parse($through) });
    like($error && $error->message, qr/through/, 'conditions with through refuse');
};

subtest 'fingerprint, contract and export' => sub {
    my $plain = domain();
    delete $plain->{source}{associations}{price}{conditions};
    my $before = Selecto::Domain->parse($plain);
    my $with = Selecto::Domain->parse(domain());
    ok(!exists($before->associations->{price}->fingerprint_value->{conditions}), 'absent conditions leave the fingerprint value unchanged');
    isnt($before->fingerprint, $with->fingerprint, 'conditions change the fingerprint');
    is_deeply($with->associations->{price}->conditions,
        [{left => 'ordered_on', op => 'gte', right => 'valid_from'}, {left => 'ordered_on', op => 'lt', right => 'valid_to', open => 1}],
        'conditions are normalized');
    my $upper = domain(conditions => [{left => 'ordered_on', op => 'GTE', right => 'valid_from'},
        {left => 'ordered_on', op => 'lt', right => 'valid_to', open => 1}]);
    is_deeply(Selecto::Domain->parse($upper)->associations->{price}->fingerprint_value,
        $with->associations->{price}->fingerprint_value, 'operators are lowercased, open 1 is true');
    ok((grep { $_ eq 'conditions' } @{Selecto::Domain->contract_keys->{association}}), 'association table lists conditions');
    is_deeply($with->as_contract->{source}{associations}{price}{conditions}, domain()->{source}{associations}{price}{conditions},
        'as_contract keeps the authored conditions');
};

done_testing;
