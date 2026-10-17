use 5.034;
use strict;
use warnings;
use Test::More;
use DBI ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto;
use Selecto::CoDomain ();
use Selecto::Engine ();

# Lesson 37: a choice source or co-domain lookup returns the value, label and
# description fields its declaration names. A declaration that would expose
# a redacted field is refused when the engine is built (invalid_domain,
# details code choice_source_redacted_field or co_domain_redacted_field), and
# a co-domain lookup refuses a non-public field of its target at lookup time.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my @backends = (['sqlite', sub {
    return DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}]);
my $url = $ENV{SELECTO_PERL_TEST_POSTGRES_URL};
my ($user, $host, $port, $db) = defined($url) ? $url =~ m{\Apostgres(?:ql)?://([^:@/]+)\@([^:/]+):(\d+)/([^?]+)} : ();
push @backends, ['postgresql', sub {
    return DBI->connect("dbi:Pg:dbname=$db;host=$host;port=$port", $user, '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}] if $db && eval { require DBD::Pg; 1 };

sub error_of {
    my ($code) = @_;
    return undef if eval { $code->(); 1 };
    return $@;
}

sub contract {
    my (%o) = @_;
    return {
        schema_version => 1, name => 'Tickets',
        source => {source_table => 'tickets', primary_key => 'id', fields => [qw(id title owner_id)],
            columns => {id => {type => 'integer'}, title => {type => 'string'},
                owner_id => {type => 'integer', choice_source => 'owners',
                    ($o{reference} ? (reference => {choice_source => 'owners', %{$o{reference}}}) : ())}},
            associations => {owner => {queryable => 'owners', owner_key => 'owner_id', related_key => 'id'}}},
        schemas => {owners => {source_table => 'users', primary_key => 'id', fields => [qw(id name ssn)],
            columns => {id => {type => 'integer'}, name => {type => 'string'}, ssn => {type => 'string'}},
            associations => {}, redact_fields => ['ssn']}},
        joins => {owner => {type => 'left'}},
        choice_sources => {owners => {domain => 'users', value_field => 'id', label_field => 'name', %{$o{source} // {}}}},
        ($o{co_domains} ? (co_domains => $o{co_domains}) : ()),
    };
}

for my $backend (@backends) {
    my ($name, $connect) = @$backend;
    subtest "lookups never expose redacted fields on $name" => sub {
        my $adapter = Selecto->adapter($name => (dbh => $connect->()));
        my $build = sub { Selecto::Engine->new(domain => Selecto::Domain->parse(contract(@_)), adapter => $adapter) };
        is(error_of(sub { $build->() }), undef, 'a lookup over public fields is accepted');
        for my $case (
            ['label_field of the choice domain', source => {label_field => 'ssn'}],
            ['description_source', source => {description_source => 'owners.ssn'}],
            ['caption_source', source => {caption_source => 'owners.ssn'}],
            ['a field reference caption', reference => {caption_source => 'owners.ssn'}],
            ['a self-targeted co-domain label', co_domains => {self => {domain => 'Tickets', projection => 'all',
                search => {fields => ['title']}, result => {value_field => 'id', label_field => 'secret'}}}],
            # A search over a redacted column is a match oracle even when
            # every returned field is public.
            ['a self-targeted co-domain search field', co_domains => {self => {domain => 'Tickets', projection => 'all',
                search => {fields => ['secret']}, result => {value_field => 'id', label_field => 'title'}}}],
        ) {
            my ($label, %o) = @$case;
            my $raw = contract(%o);
            if ($o{co_domains}) {
                push @{$raw->{source}{fields}}, 'secret';
                $raw->{source}{columns}{secret} = {type => 'string'};
                $raw->{redact_fields} = ['secret'];
            }
            my $error = error_of(sub { Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => $adapter) });
            is($error && blessed($error) && $error->code, 'invalid_domain', "$label: refused at engine build");
            like($error && blessed($error) && $error->details->{code}, qr/\A(?:choice_source|co_domain)_redacted_field\z/,
                "$label: a clear details code");
        }

        # A co-domain into another domain is checked against that domain
        # when it is looked up.
        my $source = Selecto::Domain->parse(contract(co_domains => {owners => {domain => 'Users', projection => 'all',
            search => {fields => ['name']}, result => {value_field => 'id', label_field => 'ssn'}}}));
        my $users = Selecto::Engine->new(adapter => $adapter, domain => Selecto::Domain->parse({
            schema_version => 1, name => 'Users',
            source => {source_table => 'users', primary_key => 'id', fields => [qw(id name ssn)],
                columns => {id => {type => 'integer'}, name => {type => 'string'}, ssn => {type => 'string'}},
                associations => {}, redact_fields => ['ssn']},
            schemas => {}, joins => {},
            query_library => {projections => {all => {fields => [qw(id name ssn)]}}},
        }));
        my $error = error_of(sub { Selecto::CoDomain->lookup(source_domain => $source, co_domain => 'owners',
            engine => $users, query => 'a') });
        ok($error && blessed($error) && $error->code =~ /\Ainvalid_co_domain|invalid_domain|invalid_query/,
            'a co-domain lookup returning a redacted target field is refused (' . ($error && blessed($error) ? $error->code : 'none') . ')');

        my $searching = Selecto::Domain->parse(contract(co_domains => {owners => {domain => 'Users', projection => 'all',
            search => {fields => ['ssn']}, result => {value_field => 'id', label_field => 'name'}}}));
        $error = error_of(sub { Selecto::CoDomain->lookup(source_domain => $searching, co_domain => 'owners',
            engine => $users, query => 'a') });
        ok($error && blessed($error) && $error->code =~ /\Ainvalid_co_domain|invalid_domain|invalid_query/,
            'a co-domain lookup searching a redacted target field is refused (' . ($error && blessed($error) ? $error->code : 'none') . ')');
    };
}

done_testing;
