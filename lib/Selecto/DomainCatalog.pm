package Selecto::DomainCatalog;

use Mojo::Base -base, -signatures;
use Cpanel::JSON::XS ();
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Domain ();
use Selecto::Domain::QueryContract ();
use Selecto::CanonicalJSON ();
use Selecto::Engine ();
use Selecto::Adapter::Registry ();
use Selecto::DomainCatalog::Diff ();
use Selecto::Error ();

sub new ($class, %args) {
    Selecto::Error->throw('invalid_catalog', 'catalog requires a source list')
        unless ref($args{sources}) eq 'ARRAY';
    for my $name (qw(scope_policies pins)) {
        Selecto::Error->throw('invalid_catalog', "$name must be a map")
            if exists($args{$name}) && ref($args{$name}) ne 'HASH';
    }
    Selecto::Error->throw('invalid_catalog', 'checks must be callbacks')
        if exists($args{checks}) && (ref($args{checks}) ne 'ARRAY'
            || grep { ref($_) ne 'CODE' } @{$args{checks}});
    Selecto::Error->throw('invalid_catalog', 'allowed_sources must be an exact table-name list')
        if exists($args{allowed_sources}) && (ref($args{allowed_sources}) ne 'ARRAY'
            || grep { !defined($_) || ref($_) } @{$args{allowed_sources}});
    my $self = $class->SUPER::new(%args, parsed => {}, documents => {}, pinned => {},
        policy_domains => {}, scope_policies => $args{scope_policies} // {},
        pins => $args{pins} // {}, checks => $args{checks} // [],
        registry => $args{registry} // Selecto::Adapter::Registry->default);
    $self->_refresh;
    for my $id (sort keys %{$self->{pins}}) {
        my $pin = $self->{pins}{$id};
        Selecto::Error->throw('invalid_catalog_pin', 'pin requires an expected fingerprint')
            unless ref($pin) eq 'HASH' && defined($pin->{fingerprint}) && !ref($pin->{fingerprint});
        my $record = $self->{records}{$id};
        next unless $record;
        my $pinned;
        if (exists $pin->{document}) {
            $pinned = {%$record, value => $pin->{document}, failed => 0, missing_id => 0};
        } elsif (exists($pin->{revision}) && $record->{source}{kind} eq 'store') {
            $pinned = {%{$record->{provider}->revision($record->{source}{ref}{key}, $pin->{revision})},
                id => $id, provider => $record->{provider}};
        } else {
            my $info = $self->_inspect($record);
            $pinned = $record if ($info->{entry}{fingerprint} // '') eq $pin->{fingerprint};
        }
        if ($pinned) {
            my $info = $self->_inspect($pinned);
            $self->{pinned}{$id} = $pinned
                if ($info->{entry}{fingerprint} // '') eq $pin->{fingerprint};
        }
    }
    return $self;
}

sub _refresh ($self) {
    my %records;
    for my $source (@{$self->{sources}}) {
        Selecto::Error->throw('invalid_catalog_source', 'source must implement records')
            unless blessed($source) && $source->can('records');
        for my $record (@{$source->records}) {
            my $id = $record->{id};
            Selecto::Error->throw('invalid_catalog_source', 'domain id must be a nonblank string')
                unless defined($id) && !ref($id) && $id =~ /\S/;
            if (my $previous = $records{$id}) {
                my @origins = map {
                    my $ref = $_->{ref};
                    $_->{kind} . ':' . ($ref->{path} // $ref->{label} // $ref->{key});
                } ($previous->{source}, $record->{source});
                Selecto::Error->throw('duplicate_domain', "duplicate catalog id: $id ($origins[0], $origins[1])",
                    {sources => [dclone($previous->{source}), dclone($record->{source})]});
            }
            $records{$id} = {%$record, provider => $source};
        }
    }
    $self->{records} = \%records;
}

sub _record ($self, $id) {
    return $self->{records}{$id} // Selecto::Error->throw('domain_not_found', 'catalog domain was not found');
}

sub _metadata ($document) {
    return {} unless ref($document) eq 'HASH' && ref($document->{extensions}) eq 'HASH'
        && ref($document->{extensions}{catalog}) eq 'HASH';
    return $document->{extensions}{catalog};
}

sub _inspect ($self, $record) {
    my $value = $record->{value};
    my $original = blessed($value) && $value->isa('Selecto::Domain') ? $value : undef;
    my ($document, $domain, $error);
    my $ok = eval {
        Selecto::Error->throw('catalog_source_failed', 'contract source could not be read') if $record->{failed};
        my $raw = $original ? (eval { $original->as_document } // $original->contract_json)
            : ref($value) ? $value : Cpanel::JSON::XS->new->decode($value);
        $document = $record->{source}{kind} eq 'code' ? dclone($raw)
            : Selecto::Domain::QueryContract->copy_declaration($raw);
        Selecto::Error->throw('invalid_domain', 'contract must be an object') unless ref($document) eq 'HASH';
        my $json = Cpanel::JSON::XS->new->canonical->encode($document);
        my $key = sha256_hex(encode_utf8($json)) . ($original ? $original->fingerprint : '');
        my $cached = $self->{parsed}{$key};
        if (!$cached) {
            my $parsed = eval { Selecto::Domain->parse($document, strict => 1) };
            my $failure = $@;
            $cached = $self->{parsed}{$key} = {domain => $original // $parsed, error => $failure};
        }
        $domain = $cached->{domain};
        die $cached->{error} if $cached->{error};
        1;
    };
    $error = $@ unless $ok;
    my $metadata = _metadata($document);
    $error = Selecto::Error->new(code => 'catalog_id_missing', message => 'document requires extensions.catalog.id')
        if $record->{missing_id} && !$error;
    my $entry = {id => $record->{id}, name => ref($document) eq 'HASH' ? $document->{name} : undef,
        version => ref($document) eq 'HASH' ? $document->{domain_version} : undef,
        fingerprint => $ok && $domain ? $domain->fingerprint : undef,
        adapter => $record->{adapter} // $metadata->{adapter} // $self->{adapter},
        source => dclone($record->{source})};
    $self->{documents}{$entry->{fingerprint}} = dclone($document) if defined $entry->{fingerprint};
    return {entry => $entry, document => $document, domain => $domain, error => $error};
}

sub list ($self) {
    $self->_refresh;
    return [map {
        my $info = $self->_inspect($self->{records}{$_});
        my $entry = $info->{entry};
        $entry->{validation_status} = $info->{error} ? 'refused' : 'ok';
        $entry->{status} = $self->_changed($_, $info) ? 'changed' : $entry->{validation_status};
        $entry->{diff} = $self->_pin_diff($_, $info) if $entry->{status} eq 'changed';
        $entry;
    } sort keys %{$self->{records}}];
}

sub _changed ($self, $id, $info) {
    return exists($self->{pins}{$id})
        && ($info->{entry}{fingerprint} // '') ne $self->{pins}{$id}{fingerprint};
}

sub _pin_diff ($self, $id, $info) {
    my $pin = $self->{pinned}{$id};
    return undef unless $pin && ref($info->{document}) eq 'HASH';
    return Selecto::DomainCatalog::Diff->compare($self->_inspect($pin)->{document}, $info->{document});
}

sub _finding ($stage, $status, $code, $path = '$') {
    return {stage => $stage, status => $status, code => $code,
        message => $status eq 'ok' ? 'Check passed' : $status eq 'skipped' ? 'Dependency was refused' : 'Check failed',
        path => $path};
}

sub _error_finding ($stage, $error, $fallback = '$') {
    my $code = blessed($error) && $error->isa('Selecto::Error') ? $error->code : 'catalog_check_failed';
    my $details = blessed($error) && $error->isa('Selecto::Error') ? $error->details : {};
    my $path = $details->{path} // (ref($details->{errors}) eq 'ARRAY' && @{$details->{errors}}
        ? $details->{errors}[0]{path} : undef);
    $path = '$' . join('', map { /^\d+$/ ? "[$_]" : ".$_" } @$path) if ref($path) eq 'ARRAY';
    return _finding($stage, 'refused', $code, defined($path) && !ref($path) ? $path : $fallback);
}

# Only host code can supply row obligations. Walk all declarations, including
# nested write domains, so an unused schema cannot conceal a future escape.
sub _scope_declarations ($document, $prefix = '$') {
    my @paths;
    push @paths, "$prefix.$_" for grep { exists $document->{$_} }
        qw(required_predicate required_filters tenant tenant_required require_tenant);
    my @relations = (['source', $document->{source}]);
    push @relations, map { ["schemas.$_", $document->{schemas}{$_}] }
        sort keys %{ref($document->{schemas}) eq 'HASH' ? $document->{schemas} : {}};
    for my $relation (@relations) {
        my ($path, $value) = @$relation;
        next unless ref($value) eq 'HASH';
        push @paths, "$prefix.$path.tenant_field" if exists $value->{tenant_field};
    }
    my $writes = ref($document->{writes}) eq 'HASH' ? $document->{writes} : {};
    push @paths, "$prefix.writes.scope" if exists $writes->{scope};
    my $relationships = ref($writes->{relationships}) eq 'HASH' ? $writes->{relationships} : {};
    for my $name (sort keys %$relationships) {
        my $relationship = $relationships->{$name};
        next unless ref($relationship) eq 'HASH' && ref($relationship->{domain}) eq 'HASH';
        push @paths, @{_scope_declarations($relationship->{domain},
            "$prefix.writes.relationships.$name.domain")};
    }
    return \@paths;
}

sub _source_findings ($self, $document, $prefix = '$') {
    my %allowed = map { $_ => 1 } @{$self->{allowed_sources} // []};
    my @findings;
    my $check = sub ($table, $path) {
        push @findings, _finding('allowed_sources', 'refused', 'source_not_allowed', $path)
            unless defined($table) && !ref($table) && $allowed{$table};
    };
    my @relations = (['source', $document->{source}]);
    push @relations, map { ["schemas.$_", $document->{schemas}{$_}] }
        sort keys %{ref($document->{schemas}) eq 'HASH' ? $document->{schemas} : {}};
    for my $relation (@relations) {
        my ($path, $value) = @$relation;
        next unless ref($value) eq 'HASH';
        $check->($value->{$_}, "$prefix.$path.$_")
            for grep { exists $value->{$_} } qw(source_table table);
        if (ref($value->{fts5_index}) eq 'HASH') {
            $check->($value->{fts5_index}{table}, "$prefix.$path.fts5_index.table");
        }
        my $associations = ref($value->{associations}) eq 'HASH' ? $value->{associations} : {};
        for my $name (sort keys %$associations) {
            my $association = $associations->{$name};
            next unless ref($association) eq 'HASH' && ref($association->{through}) eq 'HASH';
            $check->($association->{through}{table}, "$prefix.$path.associations.$name.through.table");
        }
    }
    my $walk_joins;
    $walk_joins = sub ($joins, $path) {
        return unless ref($joins) eq 'HASH';
        for my $name (sort keys %$joins) {
            my $join = $joins->{$name};
            next unless ref($join) eq 'HASH';
            $check->($join->{source}, "$path.$name.source") if exists $join->{source};
            $walk_joins->($join->{joins}, "$path.$name.joins");
        }
    };
    $walk_joins->($document->{joins}, "$prefix.joins");
    my $writes = ref($document->{writes}) eq 'HASH' ? $document->{writes} : {};
    my $relationships = ref($writes->{relationships}) eq 'HASH' ? $writes->{relationships} : {};
    for my $name (sort keys %$relationships) {
        my $relationship = $relationships->{$name};
        next unless ref($relationship) eq 'HASH' && ref($relationship->{domain}) eq 'HASH';
        push @findings, @{$self->_source_findings($relationship->{domain},
            "$prefix.writes.relationships.$name.domain")};
    }
    return \@findings;
}

sub _checks ($self, $record, $info) {
    my @checks;
    my $domain = $info->{domain};
    push @checks, $info->{error} ? _error_finding('strict_parse', $info->{error})
        : _finding('strict_parse', 'ok', 'strict_parse_ok');
    my $portable = $record->{source}{kind} ne 'code';
    my $scope_failed = 0;
    if ($portable && ref($info->{document}) eq 'HASH') {
        my $paths = _scope_declarations($info->{document});
        push @checks, map { _finding('scope_policy', 'refused', 'document_scope_forbidden', $_) } @$paths;
        $scope_failed = @$paths ? 1 : 0;
        my $policy = _metadata($info->{document})->{scope_policy};
        if (!defined($policy) || ref($policy) || ref($self->{scope_policies}{$policy}) ne 'CODE') {
            push @checks, _finding('scope_policy', 'refused', 'unknown_scope_policy', '$.extensions.catalog.scope_policy');
            $scope_failed = 1;
        } elsif ($domain && !$info->{error} && !$scope_failed) {
            my $cache_key = $info->{entry}{id} . ':' . $domain->fingerprint;
            my $ok = eval {
                $domain = $self->{policy_domains}{$cache_key} //= do {
                    my $obligation = $self->{scope_policies}{$policy}->($domain, dclone($info->{entry}));
                    Selecto::Error->throw('invalid_scope_policy', 'policy must return a required predicate')
                        unless ref($obligation) eq 'HASH'
                            && !grep { $_ ne 'required_predicate' && $_ ne 'tenant_field' } keys %$obligation;
                    my $predicate = $obligation->{required_predicate};
                    Selecto::Error->throw('invalid_scope_policy', 'policy must return a required predicate')
                        unless blessed($predicate) && $predicate->isa('Selecto::Expression');
                    my $scoped = defined($obligation->{tenant_field})
                        ? $domain->with_tenant_field($obligation->{tenant_field}) : $domain;
                    $scoped->with_required_predicate($predicate);
                };
                1;
            };
            if (!$ok) {
                push @checks, _error_finding('scope_policy', $@, '$.extensions.catalog.scope_policy');
                $scope_failed = 1;
            }
        }
        push @checks, $info->{error}
            ? _finding('scope_policy', 'skipped', 'dependency_refused', '$.extensions.catalog.scope_policy')
            : _finding('scope_policy', 'ok', 'scope_policy_ok') unless $scope_failed;
        my $sources = $self->_source_findings($info->{document});
        push @checks, @$sources ? @$sources : _finding('allowed_sources', 'ok', 'allowed_sources_ok');
    } else {
        push @checks, map { _finding($_, $portable ? 'skipped' : 'ok', $portable ? 'dependency_refused' : 'trusted_code') }
            qw(scope_policy allowed_sources);
    }
    my $library_ok = eval {
        require Selecto::QueryLibrary::Contract;
        if (ref($info->{document}) eq 'HASH') {
            my $validation = Selecto::QueryLibrary::Contract->validate_declaration($info->{document});
            Selecto::Error->throw('invalid_query_library', 'query-library declaration failed', $validation)
                unless $validation->{valid};
        } else {
            Selecto::Error->throw('catalog_source_failed', 'contract source could not be read');
        }
        $domain->validate_query_library if $domain && !$info->{error};
        1;
    };
    push @checks, $library_ok ? _finding('query_library', 'ok', 'query_library_ok', '$.query_library')
        : _error_finding('query_library', $@, '$.query_library');
    if ($info->{error}) {
        push @checks, _finding('engine_admission', 'skipped', 'dependency_refused');
    } else {
        my $admitted = eval {
            my $adapter = $self->{registry}->build($info->{entry}{adapter},
                dbh => Selecto::DomainCatalog::_NoDatabase->new);
            Selecto::Engine->admit_domain(domain => $domain, adapter => $adapter);
            1;
        };
        push @checks, $admitted ? _finding('engine_admission', 'ok', 'engine_admission_ok')
            : _error_finding('engine_admission', $@);
    }
    for my $callback (@{$self->{checks}}) {
        if ($info->{error}) {
            push @checks, _finding('host', 'skipped', 'dependency_refused');
            next;
        }
        my $findings = eval { $callback->($domain, dclone($info->{entry})) };
        my $error = $@;
        if ($error || ref($findings) ne 'ARRAY' || grep {
            ref($_) ne 'HASH' || ($_->{status} // '') !~ /\A(?:ok|warning|refused)\z/
                || !defined($_->{code}) || ref($_->{code}) || !defined($_->{path}) || ref($_->{path})
                || !defined($_->{message}) || ref($_->{message})
                || $_->{path} !~ /\A\$/
        } @{$findings // []}) {
            push @checks, _finding('host', 'refused', 'host_check_failed');
        } else {
            push @checks, map { my $finding = $_;
                +{stage => 'host', map { $_ => $finding->{$_} } qw(status code message path)}
            } @$findings;
        }
    }
    return (\@checks, $domain);
}

sub _report ($self, $id, $record, %options) {
    my $info = $self->_inspect($record);
    my ($checks, $domain) = $self->_checks($record, $info);
    my $validation = grep($_->{status} eq 'refused', @$checks) ? 'refused'
        : grep($_->{status} eq 'warning', @$checks) ? 'warning' : 'ok';
    my $report = {id => $id, entry => $info->{entry}, status => $validation,
        validation_status => $validation, checks => $checks};
    if ($self->_changed($id, $info)) {
        if (!$self->{pinned}{$id}) {
            push @{$report->{checks}}, _finding('pin', 'warning', 'catalog_pin_unavailable');
            $report->{validation_status} = 'warning' if $validation eq 'ok';
        }
        $report->{status} = 'changed';
        $report->{diff} = $self->_pin_diff($id, $info);
    }
    if (exists $options{against}) {
        my $before = $options{against};
        $before = $self->{documents}{$before} unless ref($before);
        Selecto::Error->throw('catalog_baseline_missing', 'earlier fingerprint is not retained')
            unless ref($before) eq 'HASH';
        $report->{diff} = Selecto::DomainCatalog::Diff->compare($before, $info->{document})
            if ref($info->{document}) eq 'HASH';
    }
    return ($report, $domain, $info);
}

sub report ($self, $id, %options) {
    $self->_refresh;
    my ($report) = $self->_report($id, $self->_record($id), %options);
    return $report;
}

sub report_all ($self, %options) {
    $self->_refresh;
    return [map { my ($report) = $self->_report($_, $self->{records}{$_}, %options); $report }
        sort keys %{$self->{records}}];
}

sub _served ($self, $id) {
    $self->_refresh;
    my $current = $self->_record($id);
    my $record = $current;
    if (exists $self->{pins}{$id}) {
        $record = $self->{pinned}{$id}
            // Selecto::Error->throw('catalog_pin_unavailable', 'matching pinned document is unavailable');
    }
    my ($report, $domain, $info) = $self->_report($id, $record);
    Selecto::Error->throw('catalog_domain_refused', 'catalog domain failed validation',
        {checks => $report->{checks}}) if $report->{validation_status} eq 'refused';
    return ($domain, $info);
}

sub get ($self, $id) { my ($domain) = $self->_served($id); return $domain }
sub document ($self, $id) {
    my (undef, $info) = $self->_served($id);
    my $document = eval { $info->{domain}->as_document } // $info->{domain}->contract_json;
    return Selecto::CanonicalJSON->encode($document);
}

package Selecto::DomainCatalog::_NoDatabase;

sub new { return bless {}, shift }
sub AUTOLOAD { Selecto::Error->throw('catalog_database_forbidden', 'static admission cannot access a database') }
sub DESTROY { }

1;

=head1 NAME

Selecto::DomainCatalog - metadata catalog and static validation for domains

=head1 DESCRIPTION

See C<docs/domain-catalog.md> for constructor options, source interfaces,
scope policy callbacks, revision guarantees, pins, report/diff JSON examples,
and serving semantics. The catalog is HTTP-neutral and decides no privileges.

=head1 METHODS

C<new(sources =E<gt> [...], adapter =E<gt> 'sqlite', scope_policies =E<gt> {...},
allowed_sources =E<gt> [...], pins =E<gt> {...}, checks =E<gt> [...],
registry =E<gt> $optional_adapter_registry)> checks duplicate IDs immediately.
C<list> returns sorted metadata and rereads file/store sources without building
engines. Code factories run once. C<get($id)> returns a strictly parsed,
validated domain cached by identity; portable domains gain host scope.
C<document($id)> returns canonical contract JSON for the served version.
C<report($id, against =E<gt> $earlier_contract_or_retained_fingerprint)> and
C<report_all> run static validation, never queries. Reports contain metadata
and paths, never driver errors or before/after data values. Host check
findings are trusted public messages: hosts must not include secrets or data.

=cut
