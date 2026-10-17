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
use Selecto::Query ();

# Lesson 41b: every hop pairs tenant columns by name in a two-column domain
# (source.tenant_field tenant_id, writes.scope.tenant site_id), not only the
# root hop. Nested hops and the domains a retarget rebuilds at its target
# had lost the root's write scope and paired positionally: an accounts hop
# (tenant_id) paired accounts.tenant_id = lines.site_id and a lines hop
# (site_id) paired lines.site_id = notes.tenant_id, so a tenant 7 read
# returned site 7's lines and tenant 5's notes. A hop now pairs only a
# tenant column of the same name on a hop chained to the root; a tenant_id
# relation reached otherwise is bound to the engine tenant (or the root's
# admitted set), and a site_id relation reached otherwise is refused with
# missing_tenant_scope. A retarget target carries each root conjunct only
# onto its same-named column.
#
# And an untenanted retarget hop (retarget to a shared bin) under a required
# predicate such as tenant_id IN (7, 8), with no engine tenant, carries the
# root's admitted set onto later tenant joins, collections and inline
# sources; before, they read every tenant.

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

my $x = 'Selecto::Expression';

sub code_of {
    my ($code) = @_;
    return 'ok' if eval { $code->(); 1 };
    my $error = $@;
    return blessed($error) && $error->isa('Selecto::Error') ? $error->code : "died: $error";
}
sub relation {
    my ($table, %types) = @_;
    return {source_table => $table, primary_key => 'id', fields => [sort keys %types],
        columns => {map { ($_ => {type => $types{$_}}) } keys %types}, associations => {}};
}
sub values_of {
    my ($rows, $index) = @_;
    my %seen = map { defined($_->[$index]) ? ($_->[$index] => 1) : () } @$rows;
    return [sort keys %seen];
}
sub collected {
    my ($rows, $field) = @_;
    return [sort map { my $c = $_->[1]; $c = JSON::PP::decode_json($c) unless ref $c; map { $_->{$field} } @$c } @$rows];
}

sub two_column {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Orders',
        source => {%{relation($t->{orders}, id => 'integer', tenant_id => 'integer', site_id => 'integer', account_id => 'integer')},
            tenant_field => 'tenant_id', associations => {
                account => {queryable => 'account', owner_key => 'account_id', related_key => 'id'},
                lines => {queryable => 'line', owner_key => 'id', related_key => 'order_id', cardinality => 'many'},
            }},
        schemas => {
            account => {%{relation($t->{accounts}, id => 'integer', tenant_id => 'integer', name => 'string')}, tenant_field => 'tenant_id',
                associations => {lines => {queryable => 'line', owner_key => 'id', related_key => 'account_id', cardinality => 'many'}}},
            line => {%{relation($t->{lines}, id => 'integer', order_id => 'integer', account_id => 'integer', site_id => 'integer', code => 'string')},
                tenant_field => 'site_id', associations => {
                    parts => {queryable => 'part', owner_key => 'id', related_key => 'line_id', cardinality => 'many'},
                    notes => {queryable => 'note', owner_key => 'id', related_key => 'line_id', cardinality => 'many'},
                }},
            part => {%{relation($t->{parts}, id => 'integer', line_id => 'integer', site_id => 'integer', code => 'string')}, tenant_field => 'site_id'},
            note => {%{relation($t->{notes}, id => 'integer', line_id => 'integer', tenant_id => 'integer', body => 'string')}, tenant_field => 'tenant_id'},
        },
        joins => {account => {type => 'left', joins => {lines => {type => 'left'}}},
            lines => {type => 'left', joins => {parts => {type => 'left'}, notes => {type => 'left'}}}},
        writes => {operations => {update => {enabled => 1}}, fields => {account_id => {updatable => 1}},
            scope => {tenant => {field => 'site_id', satisfied_by => ['trusted_context']}}},
        ($o{required} ? (required_filters => $o{required}) : ())};
}

sub shared_hop {
    my ($t, %o) = @_;
    return {schema_version => 1, name => 'Customers',
        source => {%{relation($t->{customers}, id => 'integer', tenant_id => 'integer', bin_id => 'integer')},
            tenant_field => 'tenant_id', associations => {bin => {queryable => 'bin', owner_key => 'bin_id', related_key => 'id'}}},
        schemas => {
            bin => {%{relation($t->{bins}, id => 'integer', label => 'string')},
                associations => {notes => {queryable => 'note', owner_key => 'id', related_key => 'bin_id', cardinality => 'many'}}},
            note => {%{relation($t->{bin_notes}, id => 'integer', bin_id => 'integer', tenant_id => 'integer', body => 'string')},
                tenant_field => 'tenant_id'},
        },
        joins => {bin => {type => 'left', joins => {notes => {type => 'left'}}}},
        ($o{required} ? (required_filters => $o{required}) : ())};
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "every retarget hop pairs by name on $name" => sub {
        my $dbh = $connect->();
        my $adapter = Selecto->adapter($name => (dbh => $dbh));
        my $suffix = $$ . '_' . int(rand(1_000_000));
        my %t = map { ($_ => "selecto_l41b_${_}_$suffix") } qw(orders accounts lines parts notes customers bins bin_notes);
        $dbh->do("CREATE TABLE $t{orders} (id integer primary key, tenant_id integer, site_id integer, account_id integer)");
        $dbh->do("CREATE TABLE $t{accounts} (id integer primary key, tenant_id integer, name text)");
        $dbh->do("CREATE TABLE $t{lines} (id integer primary key, order_id integer, account_id integer, site_id integer, code text)");
        $dbh->do("CREATE TABLE $t{parts} (id integer primary key, line_id integer, site_id integer, code text)");
        $dbh->do("CREATE TABLE $t{notes} (id integer primary key, line_id integer, tenant_id integer, body text)");
        # Tenant 7's order 1 is at site 5. Line 2 and part 2 are at site 7
        # (tenant 8's); note 3 belongs to tenant 5, the site's number.
        $dbh->do("INSERT INTO $t{orders} VALUES (1, 7, 5, 1), (2, 8, 7, 2)");
        $dbh->do("INSERT INTO $t{accounts} VALUES (1, 7, 'account 7'), (2, 8, 'account 8')");
        $dbh->do("INSERT INTO $t{lines} VALUES (1, 1, 1, 5, 'site 5 line'), (2, 1, 1, 7, 'site 7 line')");
        $dbh->do("INSERT INTO $t{parts} VALUES (1, 1, 5, 'site 5 part'), (2, 1, 7, 'site 7 part')");
        $dbh->do("INSERT INTO $t{notes} VALUES (1, 1, 7, 'tenant 7 note'), (2, 1, 8, 'tenant 8 note'), (3, 1, 5, 'tenant 5 note')");

        for my $case (
            ['engine tenant 7', tenant => 7],
            ['engine tenant 7, required tenant_id IN (7, 8)', tenant => 7, required => [['tenant_id', ['in', [7, 8]]]]],
        ) {
            my ($label, %o) = @$case;
            my $e = Selecto::Engine->new(domain => Selecto::Domain->parse(two_column(\%t, %o)), adapter => $adapter,
                scope => {tenant => $o{tenant}});
            # A refusal reads as its error code, so every check runs.
            my $read = sub {
                my ($q, $i) = @_;
                my $values;
                my $code = code_of(sub { $values = values_of($e->all($q)->{rows}, $i // 0) });
                return $code eq 'ok' ? $values : [$code];
            };
            my $collect = sub {
                my ($q) = @_;
                my $values;
                my $code = code_of(sub { $values = collected($e->all($q)->{rows}, 'body') });
                return $code eq 'ok' ? $values : [$code];
            };
            # Chained by name: root -> lines (site_id) -> parts (site_id).
            is_deeply($read->($e->query->select('lines.parts.code')), ['site 5 part'], "$label: a site_id hop under a site_id hop pairs by name");
            is_deeply($read->($e->query->retarget('lines.parts')->select('code')), ['site 5 part'], "$label: retarget lines.parts");
            is_deeply($read->($e->query->retarget('lines')->select('id', 'parts.code'), 1), ['site 5 part'],
                "$label: retarget lines, then parts.code");
            # A tenant_id relation under a site_id hop is bound to the engine
            # tenant, never paired lines.site_id = notes.tenant_id.
            is_deeply($read->($e->query->select('lines.notes.body')), ['tenant 7 note'], "$label: a tenant_id hop under a site_id hop");
            is_deeply($read->($e->query->retarget('lines.notes')->select('body')), ['tenant 7 note'], "$label: retarget lines.notes");
            is_deeply($read->($e->query->retarget('lines')->select('id', 'notes.body'), 1), ['tenant 7 note'],
                "$label: retarget lines, then notes.body");
            is_deeply($collect->($e->query->retarget('lines')->select('id', $x->related_collection('notes', ['body'])->as('n'))),
                ['tenant 7 note'], "$label: retarget lines, then a notes collection");
            # A site_id relation under a tenant_id hop has no by-name chain.
            for my $refused (
                ['account.lines.code', sub { $e->all($e->query->select('account.lines.code')) }],
                ['retarget account, then a lines collection', sub {
                    $e->all($e->query->retarget('account')->select('id', $x->related_collection('lines', ['code'])->as('l'))) }],
                ['retarget account.lines', sub { $e->all($e->query->retarget('account.lines')->select('code')) }],
                ['retarget account, then lines.code', sub { $e->all($e->query->retarget('account')->select('id', 'lines.code')) }],
                ['filter on account.lines.code', sub { $e->all($e->query->select('id')->where($x->eq('account.lines.code', 'site 7 line'))) }],
            ) {
                is(code_of($refused->[1]), 'missing_tenant_scope', "$label: $refused->[0] is refused");
            }
            is_deeply($read->($e->query->retarget('account')->select('name')), ['account 7'],
                "$label: a tenant_id target carries only the tenant_id bound");
        }
        my $site = Selecto::Engine->new(domain => Selecto::Domain->parse(two_column(\%t, required => [['site_id', 5]])),
            adapter => $adapter, scope => {tenant => 7});
        is_deeply(values_of($site->all($site->query->retarget('account')->select('name'))->{rows}, 0), ['account 7'],
            'a site_id conjunct is never carried onto a tenant_id target');
        is_deeply(values_of($site->all($site->query->retarget('lines')->select('code'))->{rows}, 0), ['site 5 line'],
            'a site_id target carries the site_id conjunct by name');

        # An untenanted retarget hop under a required predicate, no engine tenant.
        $dbh->do("CREATE TABLE $t{customers} (id integer primary key, tenant_id integer, bin_id integer)");
        $dbh->do("CREATE TABLE $t{bins} (id integer primary key, label text)");
        $dbh->do("CREATE TABLE $t{bin_notes} (id integer primary key, bin_id integer, tenant_id integer, body text)");
        $dbh->do("INSERT INTO $t{customers} VALUES (1, 7, 1), (2, 8, 1), (3, 9, 1)");
        $dbh->do("INSERT INTO $t{bins} VALUES (1, 'shared bin')");
        $dbh->do("INSERT INTO $t{bin_notes} VALUES (1, 1, 7, 'note 7'), (2, 1, 8, 'note 8'), (3, 1, 9, 'note 9')");
        my $notes = Selecto::Domain->parse({schema_version => 1, name => 'Notes',
            source => {%{relation($t{bin_notes}, id => 'integer', bin_id => 'integer', tenant_id => 'integer', body => 'string')},
                tenant_field => 'tenant_id'}, schemas => {}, joins => {}});
        for my $case (
            ['required tenant_id IN (7, 8)', [['tenant_id', ['in', [7, 8]]]], ['note 7', 'note 8']],
            ['required tenant_id = 7', [['tenant_id', 7]], ['note 7']],
        ) {
            my ($label, $required, $allowed) = @$case;
            my $e = Selecto::Engine->new(domain => Selecto::Domain->parse(shared_hop(\%t, required => $required)), adapter => $adapter);
            my $bin = sub { $e->query->retarget('bin') };
            is_deeply(values_of($e->all($bin->()->select('id', 'notes.body'))->{rows}, 1), $allowed, "$label: retarget bin, then notes.body");
            is_deeply($e->all($bin->()->select('id')->where($x->eq('notes.body', 'note 9')))->{rows}, [],
                "$label: retarget bin, then a filter on notes.body");
            is_deeply(collected($e->all($bin->()->select('id', $x->related_collection('notes', ['body'])->as('n')))->{rows}, 'body'),
                $allowed, "$label: retarget bin, then a notes collection");
            is_deeply(values_of($e->all($bin->()->subquery_join('sq', $notes, Selecto::Query->new->select('bin_id', 'body'),
                on => [{left => 'id', right => 'bin_id'}])->select('id', 'sq.body'))->{rows}, 1), $allowed,
                "$label: retarget bin, then an inline source over notes");
            is_deeply(values_of($e->all($e->query->retarget('bin.notes')->select('body'))->{rows}, 0), $allowed,
                "$label: retarget bin.notes");
        }

        $dbh->do("DROP TABLE $t{$_}") for sort keys %t;
    };
}

done_testing;
