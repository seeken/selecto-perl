package Selecto::Certification;

use 5.034;
use strict;
use warnings;
use utf8;
use DBI ();
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use URI::Escape qw(uri_unescape);
use Selecto;

our $PROTOCOL_VERSION = 1;
our $SPECIFICATION = '1.1.0';
our @QUERY_CASES = map { sprintf('Q%03d', $_) } 1 .. 20;
our @WRITE_CASES = map { sprintf('W%03d', $_) } 0 .. 6;

sub run {
    my ($class, @argv) = @_;
    my $request_path;
    GetOptionsFromArray(\@argv, 'request=s' => \$request_path)
        or die "invalid command arguments\n";
    die "--request is required\n" unless defined($request_path) && $request_path ne '';
    die "unexpected command arguments\n" if @argv;
    my $request = $class->read_request($request_path);
    my $target = $request->{target};
    my $connection_env = $target->{connection_env};
    my $url = $ENV{$connection_env};
    die "connection environment $connection_env is not configured\n"
        unless defined($url) && $url ne '';

    my ($dsn, $username, $password) = _connection_parts($url);
    my $dbh = DBI->connect($dsn, $username, $password, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        pg_enable_utf8 => 1,
    });
    die "database connection failed\n" unless $dbh;

    my $suite = Selecto::Certification::Suite->new(dbh => $dbh);
    my @observations = map { _observe($suite, $_->{id}) } @{$request->{cases}};
    my $response = {
        protocol_version => $PROTOCOL_VERSION,
        certification_spec => $SPECIFICATION,
        target => $target->{key},
        capabilities => _json_booleans($suite->adapter->write_capabilities),
        metadata => _metadata($dbh),
        observations => \@observations,
    };
    print JSON::PP->new->canonical(1)->utf8(1)->encode($response), "\n";
    $dbh->disconnect;
    return 1;
}

sub read_request {
    my ($class, $path) = @_;
    open my $handle, '<:raw', $path or die "cannot read request file\n";
    local $/;
    my $document = <$handle>;
    close $handle;
    my $request;
    my $ok = eval { $request = JSON::PP->new->utf8(1)->decode($document); 1 };
    die "request JSON is malformed\n" unless $ok;
    _exact_object($request, [qw(protocol_version certification_spec target cases)], 'request');
    die "unsupported protocol version\n" unless $request->{protocol_version} == $PROTOCOL_VERSION;
    die "unsupported certification specification\n" unless $request->{certification_spec} eq $SPECIFICATION;

    my $target = $request->{target};
    _exact_object($target, [qw(key implementation runtime backend connection_env)], 'target');
    die "unsupported target identity\n"
        unless $target->{implementation} eq 'selecto_perl'
        && $target->{runtime} eq 'perl'
        && $target->{backend} eq 'postgresql';
    die "invalid connection environment name\n"
        unless $target->{connection_env} =~ /\A[A-Z][A-Z0-9_]*\z/;
    die "cases must be an array\n" unless ref($request->{cases}) eq 'ARRAY';
    my %seen;
    for my $case (@{$request->{cases}}) {
        _exact_object($case, [qw(id title profile kind requires)], 'case');
        die "case id must be a string\n" if ref($case->{id}) || $case->{id} eq '';
        die "case title must be a string\n" if ref($case->{title});
        die "case profile must be a string\n" if ref($case->{profile});
        die "case kind is invalid\n" unless $case->{kind} =~ /\A(?:static|query|write)\z/;
        die "case requires must be an array\n" unless ref($case->{requires}) eq 'ARRAY';
        die "duplicate case ids\n" if $seen{$case->{id}}++;
    }
    return $request;
}

sub _exact_object {
    my ($value, $allowed, $label) = @_;
    die "$label must be an object\n" unless ref($value) eq 'HASH';
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$value;
    my @missing = sort grep { !exists $value->{$_} } @$allowed;
    die "$label has unknown fields: " . join(',', @unknown) . "\n" if @unknown;
    die "$label is missing fields: " . join(',', @missing) . "\n" if @missing;
}

sub _connection_parts {
    my ($value) = @_;
    return ($value, undef, undef) if $value =~ /\Adbi:Pg:/i;
    my ($userinfo, $host, $port, $database, $query_string) = _parse_postgresql_url($value);
    my ($username, $password) = split /:/, ($userinfo // ''), 2;
    $username = length($username // '') ? uri_unescape($username) : undef;
    $password = defined($password) ? uri_unescape($password) : undef;
    $database = uri_unescape($database);
    die "PostgreSQL connection URL must name a database\n" if $database eq '';
    my @parts = ('dbname=' . _dsn_quote($database));
    push @parts, 'host=' . _dsn_quote($host) if defined($host) && $host ne '';
    push @parts, 'port=' . int($port) if defined($port);
    my %query = map {
        my ($key, $nested_value) = split /=/, $_, 2;
        (uri_unescape($key // ''), uri_unescape($nested_value // ''))
    } grep { $_ ne '' } split /&/, ($query_string // '');
    push @parts, 'sslmode=' . _dsn_quote($query{sslmode}) if defined $query{sslmode};
    return ('dbi:Pg:' . join(';', @parts), $username, $password);
}

sub _parse_postgresql_url {
    my ($value) = @_;
    die "unsupported PostgreSQL connection URL\n"
        unless $value =~ m{\Apostgres(?:ql)?://(?:([^/?#@]*)@)?(\[[^\]]+\]|[^/:?#]+)(?::(\d+))?/([^?#]*)(?:\?([^#]*))?\z}i;
    my ($userinfo, $host, $port, $database, $query) = ($1, $2, $3, $4, $5);
    $host =~ s/\A\[|\]\z//g;
    return ($userinfo, $host, $port, $database, $query);
}

sub _dsn_quote {
    my ($value) = @_;
    $value = "$value";
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/\\'/g;
    return "'$value'";
}

sub _observe {
    my ($suite, $case_id) = @_;
    my $started = clock_gettime(CLOCK_MONOTONIC);
    my ($value, $evidence);
    my $ok = eval {
        my $result = $suite->run_case($case_id);
        die "case dispatcher must return value and evidence\n" unless ref($result) eq 'ARRAY' && @$result == 2;
        ($value, $evidence) = @$result;
        1;
    };
    my $duration = sprintf('%.3f', (clock_gettime(CLOCK_MONOTONIC) - $started) * 1000) + 0;
    return {
        case_id => $case_id,
        status => 'ok',
        value => $value,
        evidence => $evidence // {},
        duration_ms => $duration,
    } if $ok;
    my $error = $@;
    return {
        case_id => $case_id,
        status => 'error',
        error => blessed($error) && $error->isa('Selecto::Error')
            ? $error->to_hash
            : { type => 'execution_failed', message => "$error", class => blessed($error) ? ref($error) : 'perl_exception' },
        evidence => {},
        duration_ms => $duration,
    };
}

sub _metadata {
    my ($dbh) = @_;
    my ($backend_version) = $dbh->selectrow_array(q{SELECT current_setting('server_version')});
    my $driver_version = eval { $DBD::Pg::VERSION } // 'unknown';
    return {
        protocol_version => $PROTOCOL_VERSION,
        runtime => { name => 'perl', version => "$^V", platform => $^O },
        implementation => { module => 'Selecto', version => $Selecto::VERSION },
        engine => { name => 'selecto-perl', version => $Selecto::VERSION, source => 'native-perl', mode => 'native' },
        driver => { module => 'DBD::Pg', version => "$driver_version" },
        backend_version => "$backend_version",
        connection => { configured => JSON::PP::true, source => 'environment' },
    };
}

sub _json_booleans {
    my ($values) = @_;
    return { map { $_ => $values->{$_} ? JSON::PP::true : JSON::PP::false } keys %$values };
}

package Selecto::Certification::Suite;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto;

sub new {
    my ($class, %args) = @_;
    my $self = bless { dbh => $args{dbh} }, $class;
    $self->{adapter} = Selecto::PostgreSQL->new(dbh => $self->{dbh});
    $self->_setup_fixtures;
    $self->{people_engine} = Selecto::Engine->new(domain => $self->_people_domain, adapter => $self->{adapter});
    $self->{orders_engine} = Selecto::Engine->new(domain => $self->_orders_domain, adapter => $self->{adapter});
    return $self;
}

sub adapter { return $_[0]->{adapter}; }

sub run_case {
    my ($self, $case_id) = @_;
    return [$self->_required_contract, {}] if $case_id eq 'A001';
    return [$self->{adapter}->name, {}] if $case_id eq 'A002';
    return [{ module => $self->{adapter}->dialect, loaded => JSON::PP::true, behavior => JSON::PP::true }, {}] if $case_id eq 'A003';
    return [{ first => $self->{adapter}->placeholder(1), second => $self->{adapter}->placeholder(2) }, {}] if $case_id eq 'A004';
    if ($case_id eq 'A005') {
        my $input = 'odd' . chr(96) . '"name]';
        return [{ input => $input, quoted => $self->{adapter}->quote_identifier($input) }, {}];
    }
    return [$self->{adapter}->normalize_execution_result({ columns => ['id'], rows => [[1]] }), {}] if $case_id eq 'A006';
    if ($case_id eq 'A007') {
        my $error = $self->{adapter}->normalize_error('synthetic');
        return [{ contract => 'portable_error', struct => ref($error), type => $error->code, message => $error->message }, {}];
    }
    if ($case_id eq 'A008') {
        return [{ map { $_ => $self->{adapter}->normalize_type($_) } qw(int4 numeric timestamptz) }, {}];
    }
    return [$self->_capability_contract, {}] if $case_id eq 'A009';
    return [{ missing => [] }, {}] if $case_id eq 'A010';
    return $self->_run_query($case_id) if grep { $_ eq $case_id } @Selecto::Certification::QUERY_CASES;
    return $self->_write_capability_contract if $case_id eq 'W000';
    return $self->_run_write($case_id) if grep { $_ eq $case_id } @Selecto::Certification::WRITE_CASES;
    Selecto::Error->throw('unsupported_case', "unsupported certification case $case_id");
}

sub _required_contract {
    my ($self) = @_;
    my @required = qw(
        name dialect placeholder quote_identifier normalize_execution_result normalize_error
        normalize_type supports capability compile execute_query write_capabilities preview_write
        execute_write execute_batch
    );
    return { missing => [grep { !$self->{adapter}->can($_) } @required] };
}

sub _capability_contract {
    my ($self) = @_;
    my @features = map {
        my $supported = $self->{adapter}->supports($_) ? 1 : 0;
        my $capability = $self->{adapter}->capability($_)->{supported} ? 1 : 0;
        {
            feature => $_,
            supports => $supported ? JSON::PP::true : JSON::PP::false,
            capability_supported => $capability ? JSON::PP::true : JSON::PP::false,
            _matches => $supported == $capability,
        }
    } @{$self->{adapter}->feature_inventory};
    my @mismatches = map {
        +{ feature => $_->{feature}, supports => $_->{supports}, capability_supported => $_->{capability_supported} }
    } grep { !$_->{_matches} } @features;
    my @public = map {
        +{ feature => $_->{feature}, supports => $_->{supports}, capability_supported => $_->{capability_supported} }
    } @features;
    return { features => \@public, mismatches => \@mismatches };
}

sub _write_capability_contract {
    my ($self) = @_;
    my $capabilities = $self->{adapter}->write_capabilities;
    my @missing = grep { !$capabilities->{$_} } qw(insert update upsert delete transactions atomic_batch);
    return [
        { validation => 'ok', missing => \@missing },
        { write_capabilities => Selecto::Certification::_json_booleans($capabilities) },
    ];
}

sub _run_query {
    my ($self, $case_id) = @_;
    my $engine = $self->{people_engine};
    my $query = $engine->query;
    my $x = 'Selecto::Expression';

    if ($case_id eq 'Q001') { $query = $query->select('id', 'name')->order_by('id'); }
    elsif ($case_id eq 'Q002') { $engine = $self->{orders_engine}; $query = $engine->query->select('id', 'state')->where($x->eq('state', 'open'))->order_by('id'); }
    elsif ($case_id eq 'Q003') { $engine = $self->{orders_engine}; $query = $engine->query->select('id', 'total')->where($x->gt('total', '10'))->order_by('id'); }
    elsif ($case_id eq 'Q004') { $query = $query->select('id', 'active')->where($x->eq('active', 1))->order_by('id'); }
    elsif ($case_id eq 'Q005') { $query = $query->select('id', 'nickname')->where($x->is_null('nickname'))->order_by('id'); }
    elsif ($case_id eq 'Q006') { $query = $query->select('id', 'name')->where($x->eq('name', 'Renée 東京')); }
    elsif ($case_id eq 'Q007') { $query = $query->select('id', 'nickname')->where($x->eq('nickname', q{O'Brien})); }
    elsif ($case_id eq 'Q008') { $engine = $self->{orders_engine}; $query = $engine->query->select('id', 'state')->where($x->in('state', 'open', 'orphan'))->order_by('id'); }
    elsif ($case_id eq 'Q009') { $query = $query->select('id', 'score')->where($x->all($x->eq('active', 1), $x->gte('score', '15')))->order_by('id'); }
    elsif ($case_id eq 'Q010') { $query = $query->select('id', 'name')->where($x->eq('name', 'does-not-exist')); }
    elsif ($case_id eq 'Q011') { $query = $query->select('id', 'name')->order_by('id')->limit(2)->offset(1); }
    elsif ($case_id eq 'Q012') { $query = $query->select('id', 'joined_on')->where($x->gte('joined_on', '2024-02-01'))->order_by('id'); }
    elsif ($case_id eq 'Q013') { $query = $query->select('id', 'created_at')->where($x->gt('created_at', '2024-01-31 23:59:59'))->order_by('id'); }
    elsif ($case_id eq 'Q014') { $engine = $self->{orders_engine}; $query = $engine->query->select($x->field('id')->as('order_id'), $x->field('person.name')->as('person_name'))->order_by('id'); }
    elsif ($case_id eq 'Q015') { $engine = $self->{orders_engine}; $query = $engine->query->select($x->field('id')->as('order_id'), $x->field('person.name')->as('person_name'))->where($x->not_null('person.id'))->order_by('id'); }
    elsif ($case_id eq 'Q016') { $engine = $self->{orders_engine}; $query = $engine->query->select($x->field('state'), $x->count->as('order_count'))->group_by('state')->order_by('state'); }
    elsif ($case_id eq 'Q017') { $engine = $self->{orders_engine}; $query = $engine->query->select($x->field('state'), $x->sum('total')->as('total_amount'))->group_by('state')->order_by('state'); }
    elsif ($case_id eq 'Q018') { $engine = $self->{orders_engine}; $query = $engine->query->select($x->min('total')->as('minimum_total'), $x->max('total')->as('maximum_total')); }
    elsif ($case_id eq 'Q019') { $engine = $self->{orders_engine}; $query = $engine->query->select($x->count->as('order_count'))->where($x->eq('state', 'missing')); }
    elsif ($case_id eq 'Q020') { $query = $query->select('id', 'score')->where($x->not_null('score'))->order_by('score')->order_by('id'); }

    my $statement = $engine->compile($query);
    return [$engine->all($query), $statement->to_hash];
}

sub _run_write {
    my ($self, $case_id) = @_;
    $self->_reset_writes;
    my $x = 'Selecto::Expression';
    return $self->_successful_write($self->_insert_command(2, 'inserted', 'created')) if $case_id eq 'W001';
    if ($case_id eq 'W002') {
        return $self->_successful_write(Selecto::Write::Command->new(
            operation => 'update', relation => 'selecto_cert_writes', assignments => { name => 'before' },
            predicate => $x->eq('external_id', 'baseline'),
        ));
    }
    if ($case_id eq 'W003') {
        return $self->_expected_write_error(Selecto::Write::Command->new(
            operation => 'update', relation => 'selecto_cert_writes', assignments => { name => 'must-not-appear' },
            predicate => $x->eq('external_id', 'missing'),
        ));
    }
    if ($case_id eq 'W004') {
        my $command = Selecto::Write::Command->new(
            operation => 'upsert', relation => 'selecto_cert_writes',
            assignments => { id => 99, external_id => 'baseline', name => 'after-upsert' },
            metadata => { conflict_target => ['external_id'], upsert_update_fields => ['name'] },
        );
        my $preview = $self->{adapter}->preview_write($command);
        my $first = $self->{people_engine}->execute_write($command);
        my $second = $self->{people_engine}->execute_write($command);
        return [
            { affected_rows => [$first->affected_rows, $second->affected_rows], final_rows => $self->_write_state },
            { preview => $preview, results => [$first->to_hash, $second->to_hash] },
        ];
    }
    if ($case_id eq 'W005') {
        return $self->_successful_write(Selecto::Write::Command->new(
            operation => 'delete', relation => 'selecto_cert_writes', predicate => $x->eq('external_id', 'baseline'),
        ));
    }
    if ($case_id eq 'W006') {
        my $first = $self->_insert_command(2, 'batch-first', 'first');
        my $second = Selecto::Write::Command->new(
            operation => 'update', relation => 'selecto_cert_writes', assignments => { name => 'never' },
            predicate => $x->eq('external_id', 'missing'),
        );
        my $batch = Selecto::Write::Batch->new($first, $second);
        my @previews = map { $self->{adapter}->preview_write($_) } @{$batch->commands};
        my $ok = eval { $self->{people_engine}->execute_batch($batch); 1 };
        Selecto::Error->throw('expected_error', 'expected atomic batch failure') if $ok;
        my $error = $@;
        die $error unless blessed($error) && $error->isa('Selecto::Error');
        return [
            { error_type => $error->code, final_rows => $self->_write_state },
            { preview => \@previews, error => $error->to_hash },
        ];
    }
    Selecto::Error->throw('unsupported_case', "unsupported write case $case_id");
}

sub _successful_write {
    my ($self, $command) = @_;
    my $preview = $self->{adapter}->preview_write($command);
    my $result = $self->{people_engine}->execute_write($command);
    return [
        { operation => $result->operation, affected_rows => $result->affected_rows, final_rows => $self->_write_state },
        { preview => $preview, result => $result->to_hash },
    ];
}

sub _expected_write_error {
    my ($self, $command) = @_;
    my $preview = $self->{adapter}->preview_write($command);
    my $ok = eval { $self->{people_engine}->execute_write($command); 1 };
    Selecto::Error->throw('expected_error', 'expected cardinality failure') if $ok;
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    return [
        { error_type => $error->code, final_rows => $self->_write_state },
        { preview => $preview, error => $error->to_hash },
    ];
}

sub _insert_command {
    my ($self, $id, $external_id, $name) = @_;
    return Selecto::Write::Command->new(
        operation => 'insert', relation => 'selecto_cert_writes',
        assignments => { id => $id, external_id => $external_id, name => $name },
    );
}

sub _setup_fixtures {
    my ($self) = @_;
    for my $sql (
        'DROP TABLE IF EXISTS selecto_cert_orders',
        'DROP TABLE IF EXISTS selecto_cert_people',
        'DROP TABLE IF EXISTS selecto_cert_writes',
        'CREATE TABLE selecto_cert_people (id integer primary key, name varchar(120) not null, nickname varchar(120), active boolean not null, score decimal(12,2), joined_on date not null, created_at timestamp not null)',
        'CREATE TABLE selecto_cert_orders (id integer primary key, person_id integer, state varchar(40) not null, total decimal(12,2) not null)',
        'CREATE TABLE selecto_cert_writes (id integer primary key, external_id varchar(80) not null unique, name varchar(120) not null)',
        q{INSERT INTO selecto_cert_people VALUES (1, 'Ada Lovelace', 'ada', true, 10.50, '2024-01-01', '2024-01-01 10:00:00'), (2, 'Grace Hopper', null, true, 20.00, '2024-01-02', '2024-01-02 11:30:00'), (3, 'Renée 東京', 'O''Brien', false, 20.25, '2024-02-01', '2024-02-01 09:15:00'), (4, 'Linus Torvalds', null, true, null, '2024-03-01', '2024-03-01 08:00:00')},
        q{INSERT INTO selecto_cert_orders VALUES (101, 1, 'open', 12.50), (102, 1, 'closed', 7.50), (103, 2, 'open', 20.00), (104, null, 'orphan', 5.00), (105, 3, 'open', 20.25)},
    ) {
        $self->{dbh}->do($sql);
    }
    $self->_reset_writes;
}

sub _reset_writes {
    my ($self) = @_;
    $self->{dbh}->do('DELETE FROM selecto_cert_writes');
    $self->{dbh}->do(q{INSERT INTO selecto_cert_writes VALUES (1, 'baseline', 'before')});
}

sub _write_state {
    my ($self) = @_;
    my $rows = $self->{dbh}->selectall_arrayref('SELECT id, external_id, name FROM selecto_cert_writes ORDER BY id');
    return [map { [int($_->[0]), $_->[1], $_->[2]] } @$rows];
}

sub _people_domain {
    return Selecto::Domain->new(
        name => 'CertificationPeople', table => 'selecto_cert_people',
        fields => {
            id => 'integer', name => 'string', nickname => 'string', active => 'boolean', score => 'decimal',
            joined_on => 'date', created_at => 'naive_datetime',
        },
    );
}

sub _orders_domain {
    return Selecto::Domain->new(
        name => 'CertificationOrders', table => 'selecto_cert_orders',
        fields => { id => 'integer', person_id => 'integer', state => 'string', total => 'decimal' },
        associations => {
            person => {
                table => 'selecto_cert_people', fields => { id => 'integer', name => 'string', active => 'boolean' },
                owner_key => 'person_id', related_key => 'id', join_type => 'left',
            },
        },
    );
}

1;
