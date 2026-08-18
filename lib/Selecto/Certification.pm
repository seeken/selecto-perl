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
our $SPECIFICATION = '2.2.0';
our @QUERY_CASES = map { sprintf('Q%03d', $_) } 1 .. 25;
our @WRITE_CASES = map { sprintf('W%03d', $_) } 0 .. 6;
our @DOMAIN_CASES = map { sprintf('D%03d', $_) } 1 .. 8;
our @ACTION_VARIANT_CASES = map { sprintf('D%03d', $_) } 38 .. 40;
our @CANONICAL_API_CASES = map { sprintf('D%03d', $_) } 64 .. 71;

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

    my $backend = $target->{backend};
    my ($dsn, $username, $password) = _connection_parts($url, $backend);
    my %attributes = (
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    );
    $attributes{pg_enable_utf8} = 1 if $backend eq 'postgresql';
    $attributes{sqlite_unicode} = 1 if $backend eq 'sqlite';
    $attributes{mariadb_client_found_rows} = 1 if $backend eq 'mysql' || $backend eq 'mariadb';
    my $dbh = DBI->connect($dsn, $username, $password, \%attributes);
    die "database connection failed\n" unless $dbh;

    my $suite = Selecto::Certification::Suite->new(
        dbh => $dbh,
        adapter_name => $backend,
        type_samples => $backend eq 'sqlite'
            ? [qw(integer decimal datetime)]
            : $backend eq 'mysql' || $backend eq 'mariadb'
                ? [qw(int decimal datetime)]
                : [qw(int4 numeric timestamptz)],
    );
    my @observations = map { _observe($suite, $_->{id}) } @{$request->{cases}};
    my %capabilities = %{$suite->adapter->write_capabilities};
    if ($backend eq 'postgresql') {
        @capabilities{qw(domain_actions action_variants canonical_domain_api)} = (1, 1, 1);
    }
    my $response = {
        protocol_version => $PROTOCOL_VERSION,
        certification_spec => $SPECIFICATION,
        target => $target->{key},
        capabilities => _json_booleans(\%capabilities),
        metadata => _metadata($dbh, $backend),
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
    my $backend = $target->{backend};
    die "unsupported target identity\n"
        unless $target->{implementation} eq 'selecto_perl'
        && $target->{runtime} eq 'perl'
        && ($backend eq 'postgresql' || $backend eq 'sqlite' || $backend eq 'mysql' || $backend eq 'mariadb')
        && $target->{key} eq "perl_$backend";
    die "invalid connection environment name\n"
        unless $target->{connection_env} =~ /\A[A-Z][A-Z0-9_]*\z/;
    die "cases must be an array\n" unless ref($request->{cases}) eq 'ARRAY';
    my %seen;
    for my $case (@{$request->{cases}}) {
        _exact_object($case, [qw(id title profile kind requires)], 'case');
        die "case id must be a string\n" if ref($case->{id}) || $case->{id} eq '';
        die "case title must be a string\n" if ref($case->{title});
        die "case profile must be a string\n" if ref($case->{profile});
        die "case kind is invalid\n" unless $case->{kind} =~ /\A(?:static|bounded|domain|query|write)\z/;
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
    my ($value, $backend) = @_;
    $backend //= 'postgresql';
    if ($backend eq 'sqlite') {
        return ($value, undef, undef) if $value =~ /\Adbi:SQLite:/i;
        return ('dbi:SQLite:dbname=:memory:', undef, undef) if $value eq ':memory:';
        die "SQLite connection path is required\n" if $value eq '';
        return ('dbi:SQLite:dbname=' . $value, undef, undef);
    }
    if ($backend eq 'mysql' || $backend eq 'mariadb') {
        return ($value, undef, undef) if $value =~ /\Adbi:MariaDB:/i;
        my ($userinfo, $host, $port, $database) = _parse_mysql_family_url($value);
        my ($username, $password) = split /:/, ($userinfo // ''), 2;
        $username = length($username // '') ? uri_unescape($username) : undef;
        $password = defined($password) ? uri_unescape($password) : undef;
        $database = uri_unescape($database);
        die "MySQL-family connection URL must name a database\n"
            unless $database =~ /\A[A-Za-z0-9_$-]+\z/;
        my @parts = ('database=' . $database, 'host=' . $host);
        push @parts, 'port=' . int($port) if defined($port);
        return ('dbi:MariaDB:' . join(';', @parts), $username, $password);
    }
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

sub _parse_mysql_family_url {
    my ($value) = @_;
    die "unsupported MySQL-family connection URL\n"
        unless $value =~ m{\A(?:mysql|mariadb)://(?:([^/?#@]*)@)?(\[[^\]]+\]|[^/:?#]+)(?::(\d+))?/([^?#]*)\z}i;
    my ($userinfo, $host, $port, $database) = ($1, $2, $3, $4);
    $host =~ s/\A\[|\]\z//g;
    die "invalid MySQL-family host\n" if $host =~ /[;\s]/;
    return ($userinfo, $host, $port, $database);
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
    my ($dbh, $backend) = @_;
    my ($backend_version) = $backend eq 'sqlite'
        ? $dbh->selectrow_array('SELECT sqlite_version()')
        : $backend eq 'mysql' || $backend eq 'mariadb'
            ? $dbh->selectrow_array('SELECT VERSION()')
            : $dbh->selectrow_array(q{SELECT current_setting('server_version')});
    my ($driver_module, $driver_version) = $backend eq 'sqlite'
        ? ('DBD::SQLite', eval { $DBD::SQLite::VERSION } // 'unknown')
        : $backend eq 'mysql' || $backend eq 'mariadb'
            ? ('DBD::MariaDB', eval { $DBD::MariaDB::VERSION } // 'unknown')
            : ('DBD::Pg', eval { $DBD::Pg::VERSION } // 'unknown');
    return {
        protocol_version => $PROTOCOL_VERSION,
        runtime => { name => 'perl', version => "$^V", platform => $^O },
        implementation => { module => 'Selecto', version => $Selecto::VERSION },
        engine => { name => 'selecto-perl', version => $Selecto::VERSION, source => 'native-perl', mode => 'native' },
        driver => { module => $driver_module, version => "$driver_version" },
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
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto;

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        dbh => $args{dbh},
        adapter_name => $args{adapter_name} // 'postgresql',
        type_samples => $args{type_samples} // [qw(int4 numeric timestamptz)],
    }, $class;
    $self->{adapter} = Selecto->adapter($self->{adapter_name} => (dbh => $self->{dbh}));
    $self->_setup_fixtures;
    $self->{people_engine} = Selecto::Engine->new(domain => $self->_people_domain, adapter => $self->{adapter});
    $self->{orders_engine} = Selecto::Engine->new(domain => $self->_orders_domain, adapter => $self->{adapter});
    $self->{action_domain} = Selecto::Domain->parse($self->_action_contract, strict => 1);
    $self->{action_variant_domain} = Selecto::Domain->parse($self->_action_variant_contract, strict => 1);
    $self->{action_execution_case_domain} = Selecto::Domain->parse($self->_action_execution_case_contract, strict => 1);
    $self->{canonical_api} = Selecto::API->new(
        domain => Selecto::Domain->parse($self->_canonical_api_contract, strict => 1),
        base_path => '/api/v1/certification',
    );
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
        return [{ map { $_ => $self->{adapter}->normalize_type($_) } @{$self->{type_samples}} }, {}];
    }
    return [$self->_capability_contract, {}] if $case_id eq 'A009';
    return [{ missing => [] }, {}] if $case_id eq 'A010';
    return $self->_run_query($case_id) if grep { $_ eq $case_id } @Selecto::Certification::QUERY_CASES;
    return $self->_write_capability_contract if $case_id eq 'W000';
    return $self->_run_write($case_id) if grep { $_ eq $case_id } @Selecto::Certification::WRITE_CASES;
    return $self->_run_domain_action($case_id) if grep { $_ eq $case_id } @Selecto::Certification::DOMAIN_CASES;
    return $self->_run_action_variant($case_id)
        if grep { $_ eq $case_id } @Selecto::Certification::ACTION_VARIANT_CASES;
    return $self->_run_canonical_api($case_id)
        if grep { $_ eq $case_id } @Selecto::Certification::CANONICAL_API_CASES;
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
    elsif ($case_id eq 'Q021') {
        $engine = $self->{orders_engine};
        $query = $engine->query
            ->select($x->field('id')->as('order_id'), $x->field('person.name')->as('person_name'), $x->field('total'))
            ->where($x->all($x->eq('state', 'open'), $x->all($x->eq('person.active', 1), $x->gte('total', '12.5'))))
            ->order_by('total')->order_by('id');
    }
    elsif ($case_id eq 'Q022') {
        $engine = $self->{orders_engine};
        $query = $engine->query
            ->select($x->field('person.name')->as('person_name'), $x->field('state'), $x->count->as('order_count'), $x->sum('total')->as('total_amount'))
            ->where($x->all($x->not_null('person.id'), $x->gte('total', '7.5')))
            ->group_by('person.name', 'state')->order_by('person.name')->order_by('state');
    }
    elsif ($case_id eq 'Q023') {
        $engine = $self->{orders_engine};
        $query = $engine->query
            ->select($x->field('person.active')->as('active'), $x->field('state'), $x->count->as('order_count'), $x->sum('total')->as('total_amount'))
            ->where($x->not_null('person.id'))
            ->group_by('person.active', 'state')->order_by('person.active')->order_by('state')
            ->limit(2)->offset(1);
    }
    elsif ($case_id eq 'Q024') {
        $engine = $self->{orders_engine};
        $query = $engine->query
            ->select($x->min('total')->as('minimum_total'), $x->max('total')->as('maximum_total'), $x->sum('total')->as('total_amount'), $x->count->as('order_count'))
            ->where($x->all($x->in('state', 'open', 'closed'), $x->eq('person.active', 1)));
    }
    elsif ($case_id eq 'Q025') {
        $engine = $self->{orders_engine};
        $query = $engine->query
            ->select($x->field('id')->as('order_id'), $x->field('person.name')->as('person_name'), $x->field('state'), $x->field('total'))
            ->where($x->all($x->not_null('person.id'), $x->gt('total', '7')))
            ->order_by('person.name')->order_by('total')->order_by('id')->limit(3)->offset(1);
    }

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

sub _run_domain_action {
    my ($self, $case_id) = @_;
    if ($case_id eq 'D001') {
        my $plan = $self->_archive_plan;
        return [{
            action => $plan->action, type => $plan->type, operation => $plan->operation,
            scope => $plan->scope, capability => $plan->capability, target => $plan->target,
            filters => $plan->filters, changes => $plan->changes,
            expected_cardinality => $plan->expected_cardinality,
        }, { api => 'Selecto::Action->plan' }];
    }
    if ($case_id eq 'D002') {
        my $plan = $self->_archive_plan;
        my $preconditions = $plan->preconditions;
        Selecto::Error->throw('unexpected_action_preconditions', 'expected one transition precondition')
            unless @$preconditions == 1;
        return [$preconditions->[0], { api => 'Selecto::Action->plan' }];
    }
    if ($case_id eq 'D003') {
        my @attempts = (
            ['unknown_action', { action => 'does_not_exist', target => 7 }],
            ['missing_target', { action => 'archive' }],
        );
        return [[map {
            +{ attempt => $_->[0], code => $self->_action_plan_error($self->{action_domain}, $_->[1]) }
        } @attempts], { fail_closed => JSON::PP::true }];
    }
    if ($case_id eq 'D004') {
        my $plan = Selecto::Action->plan($self->_bulk_action_domain, {
            action => 'bulk_archive', target => { ids => [2, 3] },
        });
        return [{
            action => $plan->action, operation => $plan->operation, scope => $plan->scope,
            target => $plan->target, filters => $plan->filters, changes => $plan->changes,
            expected_cardinality => $plan->expected_cardinality,
        }, { api => 'Selecto::Action->plan' }];
    }
    if ($case_id eq 'D005') {
        my $domain = $self->_bulk_action_domain;
        my @attempts = (
            ['empty', { action => 'bulk_archive', target => { ids => [] } }],
            ['duplicate', { action => 'bulk_archive', target => { ids => [2, 2] } }],
        );
        return [[map {
            +{ attempt => $_->[0], code => $self->_action_plan_error($domain, $_->[1]) }
        } @attempts], { fail_closed => JSON::PP::true }];
    }
    if ($case_id eq 'D006') {
        my $plan = $self->_archive_plan;
        my @results = map {
            my $phase = $_;
            my $error = $self->_action_authorization_error($plan, $phase);
            +{
                capability => $error->{capability}, code => $error->{code}, phase => $error->{phase},
                status => $error->{status},
            }
        } qw(preview execute);
        return [\@results, { fail_closed => JSON::PP::true }];
    }
    if ($case_id eq 'D007') {
        my $plan = $self->_archive_plan;
        my @results;
        for my $phase (qw(preview execute)) {
            for my $decision (qw(disabled hidden)) {
                my $error = $self->_action_authorization_error(
                    $plan,
                    $phase,
                    resolver => sub { return $decision },
                );
                push @results, {
                    phase => $phase, decision => $decision, status => 'denied',
                    capability => $error->{capability},
                };
            }
        }
        return [\@results, { fail_closed => JSON::PP::true }];
    }
    if ($case_id eq 'D008') {
        my $plan = $self->_archive_plan;
        my @results = map {
            my $phase = $_;
            my $decision = Selecto::Action->authorize(
                $plan,
                $phase,
                resolver => sub { return 'enabled' },
            );
            my $request = Selecto::Action->capability_request($plan, $phase);
            +{
                decision => { status => $decision->{status}, capability => $decision->{capability} },
                request => { map { $_ => $request->{$_} } qw(phase capability action operation scope target filters) },
            }
        } qw(preview execute);
        return [\@results, { api => 'Selecto::Action->authorize' }];
    }
    Selecto::Error->throw('unsupported_case', "unsupported domain action case $case_id");
}

sub _archive_plan {
    my ($self) = @_;
    return Selecto::Action->plan($self->{action_domain}, { action => 'archive', target => 7 });
}

sub _run_action_variant {
    my ($self, $case_id) = @_;
    if ($case_id eq 'D038') {
        my $plan = Selecto::Action->plan($self->{action_variant_domain}, {
            action => 'check_in_camper',
            target => { id => 42 },
            inputs => { documents_complete => 'true' },
        });
        return [{
            variant => $plan->variant,
            inputs => $plan->inputs,
            changes => $plan->changes,
        }, { api => 'Selecto::Action->plan', source => 'public_action_planner' }];
    }
    if ($case_id eq 'D039') {
        my $plan = Selecto::Action->plan($self->{action_variant_domain}, {
            action => 'check_in_camper',
            target => { id => 42 },
            inputs => {
                documents_complete => JSON::PP::false,
                follow_up_note => 'Guardian will bring the waiver.',
                missing_documents => [
                    {
                        op => 'add', client_id => 'tmp-waiver', position => 1,
                        document_type => 'waiver', note => 'Needs signature',
                    },
                    { op => 'reorder', id => 17, position => 2 },
                ],
            },
        });
        my $patch = $plan->collection_patches->{missing_documents};
        return [{
            variant => $plan->variant,
            target => $patch->{target},
            strategy => $patch->{strategy},
            identity => $patch->{identity},
            order_field => $patch->{order_field},
            operations => [map { $_->{op} } @{$patch->{entries}}],
        }, { api => 'Selecto::Action->plan', source => 'public_action_planner' }];
    }
    if ($case_id eq 'D040') {
        my %plans = map {
            my $label = $_;
            my $urgent = $label eq 'urgent' ? JSON::PP::true : JSON::PP::false;
            my $plan = Selecto::Action->plan($self->{action_execution_case_domain}, {
                action => 'archive', target => 7,
                inputs => { reason => 'certification', urgent => $urgent },
            });
            ($label => $plan->changes);
        } qw(urgent ordinary);
        return [\%plans, { api => 'Selecto::Action->plan', source => 'public_action_planner' }];
    }
    Selecto::Error->throw('unsupported_case', "unsupported action variant case $case_id");
}

sub _run_canonical_api {
    my ($self, $case_id) = @_;
    if ($case_id eq 'D064') {
        return [$self->{canonical_api}->manifest, { api => 'Selecto::API->manifest' }];
    }
    if ($case_id eq 'D065') {
        my $document = $self->{canonical_api}->openapi_document;
        my @operations = sort {
            join("\0", @$a) cmp join("\0", @$b)
        } map {
            my $path = $_;
            map {
                [$path, $_, $document->{paths}{$path}{$_}{operationId}]
            } keys %{$document->{paths}{$path}}
        } keys %{$document->{paths}};
        my $selecto = $document->{'x-selecto'};
        return [{
            info => $document->{info},
            json_schema_dialect => $document->{jsonSchemaDialect},
            openapi => $document->{openapi},
            operations => \@operations,
            selecto => {
                canonical_json => $selecto->{canonicalJson},
                domain_fingerprint => $selecto->{domainFingerprint},
                domain_schema_version => $selecto->{domainSchemaVersion},
                domain_version => $selecto->{domainVersion},
            },
        }, { api => 'Selecto::API->openapi_document' }];
    }
    if ($case_id eq 'D066') {
        return $self->_canonical_api_response({
            method => 'GET', path => '/api/v1/certification/domain',
        });
    }
    if ($case_id eq 'D067') {
        return $self->_canonical_api_response({
            method => 'GET', path => '/api/v1/certification/openapi.json',
        });
    }
    if ($case_id eq 'D068') {
        return $self->_canonical_api_response(
            {
                method => 'POST', path => '/api/v1/certification/query',
                body => { select => ['id', 'label'] },
            },
            {
                query => sub {
                    return ['ok', {
                        columns => ['id', 'label'],
                        rows => [[7, 'Renée 東京'], [8, "line\nbreak"]],
                    }];
                },
            },
        );
    }
    if ($case_id eq 'D069') {
        return $self->_canonical_api_response({
            method => 'DELETE', path => '/api/v1/certification/domain',
        });
    }
    if ($case_id eq 'D070') {
        return $self->_canonical_api_response(
            {
                method => 'POST', path => '/api/v1/certification/write',
                body => { operation => 'update' },
            },
            {
                write => sub {
                    my ($body) = @_;
                    return ['ok', {
                        affected_rows => 1,
                        operation => $body->{operation},
                    }];
                },
            },
        );
    }
    if ($case_id eq 'D071') {
        return $self->_canonical_api_response(
            {
                method => 'POST', path => '/api/v1/certification/actions/archive',
                body => { target => 7 },
            },
            {
                action => sub {
                    my ($body, $params) = @_;
                    return ['ok', {
                        accepted => JSON::PP::true,
                        action => $params->{action},
                        target => $body->{target},
                    }];
                },
            },
        );
    }
    Selecto::Error->throw('unsupported_case', "unsupported canonical API case $case_id");
}

sub _canonical_api_response {
    my ($self, $request, $handlers) = @_;
    my $response = $self->{canonical_api}->request($request, $handlers // {});
    my $body = $response->{body};
    return [{
        status => $response->{status},
        headers => $response->{headers},
        body_hex => unpack('H*', $body),
        body_sha256 => sha256_hex($body),
    }, {
        api => 'Selecto::API->request',
        body_bytes => length($body),
    }];
}

sub _action_plan_error {
    my ($self, $domain, $intent) = @_;
    my $ok = eval { Selecto::Action->plan($domain, $intent); 1 };
    Selecto::Error->throw('expected_error', 'expected action planning to fail') if $ok;
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    return $error->code;
}

sub _action_authorization_error {
    my ($self, $plan, $phase, %options) = @_;
    my $ok = eval { Selecto::Action->authorize($plan, $phase, %options); 1 };
    Selecto::Error->throw('expected_error', 'expected action authorization to fail') if $ok;
    my $error = $@;
    die $error unless blessed($error) && $error->isa('Selecto::Error');
    return { code => $error->code, %{$error->details // {}} };
}

sub _bulk_action_domain {
    my ($self) = @_;
    my $contract = $self->{action_domain}->contract;
    $contract->{writes}{operations}{update}{bulk} = JSON::PP::true;
    $contract->{capabilities}{'work_items.bulk_archive'} = {
        operations => ['action', 'update'], action => 'bulk_archive',
    };
    $contract->{actions}{bulk_archive} = {
        type => 'bulk_action', scope => 'bulk', capability => 'work_items.bulk_archive',
        execution => { kind => 'updato', operation => 'update', set => { state => 'archived' } },
    };
    return Selecto::Domain->parse($contract, strict => 1);
}

sub _action_contract {
    return {
        schema_version => 1,
        name => 'Certification Actions',
        source => {
            source_table => 'selecto_cert_actions', primary_key => 'id',
            fields => [qw(id state tenant_id)],
            columns => {
                id => { type => 'integer' }, state => { type => 'string' },
                tenant_id => { type => 'integer' },
            },
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => { update => { enabled => JSON::PP::true, require_filter => JSON::PP::true } },
            fields => { state => { updatable => JSON::PP::true } },
            transitions => { state => { done => ['archived'], archived => [] } },
        },
        actions => {
            archive => {
                type => 'transition', scope => 'row', capability => 'work_items.archive',
                transition => { field => 'state', from => 'done', to => 'archived' },
                execution => { kind => 'updato', operation => 'update', set => { state => 'archived' } },
            },
        },
        capabilities => {
            'work_items.archive' => { operations => ['action', 'update'], action => 'archive' },
        },
    };
}

sub _canonical_api_contract {
    return {
        schema_version => 1,
        domain_version => '2.1.0',
        domain_fingerprint => 'sha256:certification-api-v1',
        name => 'Certification API',
        source => {
            source_table => 'selecto_cert_api',
            primary_key => 'id',
            fields => ['id', 'label'],
            columns => {
                id => { type => 'integer' },
                label => { type => 'string' },
            },
            associations => {},
        },
        schemas => {},
        joins => {},
        writes => { operations => { update => { enabled => JSON::PP::true } } },
        actions => { archive => { type => 'row_action', scope => 'row' } },
    };
}

sub _action_variant_contract {
    return {
        schema_version => 1,
        name => 'Certification Action Variants',
        source => {
            source_table => 'selecto_cert_action_variants', primary_key => 'id',
            fields => [qw(
                id status documents_complete checked_in_at medical_form_received follow_up_note
            )],
            columns => {
                id => { type => 'integer' }, status => { type => 'string' },
                documents_complete => { type => 'boolean' }, checked_in_at => { type => 'utc_datetime' },
                medical_form_received => { type => 'boolean' }, follow_up_note => { type => 'string' },
            },
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => { update => { enabled => JSON::PP::true, require_filter => JSON::PP::true } },
            fields => {
                status => { updatable => JSON::PP::true },
                checked_in_at => { updatable => JSON::PP::true },
                medical_form_received => { updatable => JSON::PP::true },
                follow_up_note => { updatable => JSON::PP::true },
            },
            transitions => { status => { registered => ['checked_in'], checked_in => [] } },
            relationships => {
                registration_missing_documents => {
                    writable => JSON::PP::true, cardinality => 'many',
                    allowed_ops => [qw(insert update delete)], ownership => 'owned',
                    foreign_key => 'camp_registration_id',
                },
            },
        },
        actions => {
            check_in_camper => {
                type => 'transition', scope => 'row',
                transition => { field => 'status', from => 'registered', to => 'checked_in' },
                inputs => {
                    checked_in_at => {
                        type => 'utc_datetime', required => JSON::PP::false,
                        default => ['system', 'now'],
                    },
                    documents_complete => {
                        type => 'boolean', required => JSON::PP::true,
                        discriminator => JSON::PP::true,
                    },
                    follow_up_note => { type => 'string', required => JSON::PP::false },
                },
                variants => [
                    {
                        id => 'standard_check_in',
                        when => { documents_complete => JSON::PP::true },
                        execution => {
                            kind => 'updato', operation => 'update',
                            set => {
                                status => 'checked_in',
                                checked_in_at => ['input', 'checked_in_at'],
                            },
                        },
                    },
                    {
                        id => 'missing_documents',
                        when => { documents_complete => JSON::PP::false },
                        inputs => {
                            missing_documents => {
                                type => 'collection', representation => 'patch', min_items => 1,
                            },
                            follow_up_note => { type => 'string', required => JSON::PP::true },
                        },
                        execution => {
                            kind => 'updato', operation => 'update',
                            set => {
                                status => 'checked_in', medical_form_received => JSON::PP::false,
                                follow_up_note => ['input', 'follow_up_note'],
                            },
                            collection_patches => {
                                missing_documents => {
                                    from_input => 'missing_documents',
                                    target => ['relationship', 'registration_missing_documents'],
                                    strategy => 'patch', identity => 'id', order_field => 'position',
                                },
                            },
                        },
                    },
                ],
            },
        },
        capabilities => {},
    };
}

sub _action_execution_case_contract {
    return {
        schema_version => 1,
        name => 'Certification Action Execution Cases',
        source => {
            source_table => 'selecto_cert_action_cases', primary_key => 'id',
            fields => [qw(id state priority)],
            columns => {
                id => { type => 'integer' }, state => { type => 'string' },
                priority => { type => 'integer' },
            },
            associations => {},
        },
        schemas => {}, joins => {},
        writes => {
            operations => { update => { enabled => JSON::PP::true, require_filter => JSON::PP::true } },
            fields => {
                state => { updatable => JSON::PP::true },
                priority => { updatable => JSON::PP::true },
            },
            transitions => { state => { done => ['archived'], archived => [] } },
        },
        actions => {
            archive => {
                type => 'transition', scope => 'row',
                transition => { field => 'state', from => 'done', to => 'archived' },
                inputs => {
                    reason => { type => 'string', required => JSON::PP::true },
                    urgent => { type => 'boolean', required => JSON::PP::true },
                },
                execution => {
                    kind => 'updato', operation => 'update',
                    cases => [
                        {
                            id => 'urgent', when => { urgent => JSON::PP::true },
                            set => { state => 'archived', priority => 99 },
                        },
                        {
                            id => 'ordinary', when => { urgent => JSON::PP::false },
                            set => { state => 'archived' },
                        },
                    ],
                },
            },
        },
        capabilities => {},
    };
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
