package Selecto::Domain::ContractVerification;

use 5.034;
use strict;
use warnings;
use JSON::PP ();
use Cpanel::JSON::XS ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();

# This is metadata verification, independent of query execution. A portable
# contract can declare callbacks that this runtime does not execute. Only the
# published interface is retained in a snapshot; no query or callback is run.
sub snapshot {
    my ($class, $provider) = @_;
    my $contract = _contract($provider);
    my $identity = _identity($contract);
    my $views = _object($contract->{published_views} // {}, 'published_views');
    my $filters = _object($contract->{filters} // {}, 'filters');
    for my $id (sort keys %$filters) {
        _string($id, 'filter id');
        my $filter = _object($filters->{$id}, "filters.$id");
        _string($filter->{$_}, "filters.$id.$_") for grep { exists $filter->{$_} } qw(field type);
    }
    my $members = _object($contract->{query_members} // {}, 'query_members');
    my %groups = map { $_ => 1 } qw(ctes values subqueries laterals unnests);
    my %member_ids;
    for my $group (sort keys %$members) {
        _fail("unknown query member group $group") unless $groups{$group};
        my $entries = _object($members->{$group}, "query_members.$group");
        for my $id (sort keys %$entries) {
            _string($id, 'query member id');
            _object($entries->{$id}, "query_members.$group.$id");
            $member_ids{"$group.$id"} = 1;
        }
    }
    my %root_fields;
    my $source = _object($contract->{source} // {}, 'source');
    if (exists $source->{fields}) {
        $root_fields{$_} = 1 for @{_names($source->{fields}, 'source.fields')};
    }
    $root_fields{$_} = 1 for keys %{_object($source->{columns} // {}, 'source.columns')};
    my @surfaces;
    for my $id (sort keys %$views) {
        _string($id, 'published view id');
        my $spec = _object($views->{$id}, "published_views.$id");
        my $columns = _object($spec->{columns} // {}, "published_views.$id.columns");
        my %shape;
        for my $field (sort keys %$columns) {
            _string($field, 'published result field');
            my $column = _object($columns->{$field}, "published_views.$id.columns.$field");
            $shape{$field} = _string($column->{type}, "published_views.$id.columns.$field.type");
        }
        my $fields = exists($spec->{fields})
            ? _names($spec->{fields}, "published_views.$id.fields") : [sort keys %shape];
        _fail("published view $id field $_ has no result column") for grep { !exists $shape{$_} } @$fields;
        my $surface_filters = _names($spec->{filters} // [], "published_views.$id.filters");
        _fail("published view $id filter $_ is not declared") for grep { !exists $filters->{$_} } @$surface_filters;
        my $surface_members = _names($spec->{query_members} // [], "published_views.$id.query_members");
        _fail("published view $id query member $_ is not declared") for grep { !$member_ids{$_} } @$surface_members;
        my $required = _names($spec->{required_filters} // [], "published_views.$id.required_filters");
        _fail("published view $id required filter $_ is not declared")
            for grep { !$root_fields{$_} && !exists $filters->{$_} } @$required;
        my $surface = {
            id => $id, kind => 'query_surface', source => 'published_view',
            fields => $fields, result_shape => \%shape,
            filters => $surface_filters, query_members => $surface_members,
            required_filters => $required,
            stable => exists($spec->{stable}) ? _boolean($spec->{stable}, "$id.stable") : JSON::PP::true,
        };
        for my $key (qw(version compatibility fingerprint capability)) {
            $surface->{$key} = _string($spec->{$key}, "$id.$key") if exists $spec->{$key};
        }
        $surface->{version} //= $identity->{domain_version} if exists $identity->{domain_version};
        push @surfaces, $surface;
    }
    return {
        format => 'selecto.domain_contract_snapshot', format_version => 1,
        generated_at => 'stable', provider => $identity, surfaces => \@surfaces,
    };
}

sub verify {
    my ($class, $provider, $consumer) = @_;
    my $snapshot = $class->snapshot($provider);
    my $contract = _contract($consumer);
    my $identity = _identity($contract);
    my $dependencies = $contract->{domain_dependencies} // [];
    _fail('domain_dependencies must be an array') unless ref($dependencies) eq 'ARRAY';
    my %surfaces = map { $_->{id} => $_ } @{$snapshot->{surfaces}};
    my (@selected, @errors);
    for my $dependency (@$dependencies) {
        _dependency($dependency);
        next unless $dependency->{provider} eq $snapshot->{provider}{name};
        push @selected, dclone($dependency);
        my $id = $dependency->{contract};
        my $surface = $surfaces{$id};
        unless ($surface) {
            push @errors, _diagnostic('missing_provider_contract', $id);
            next;
        }
        if (exists($dependency->{accepts}) && !_accepts($surface->{version}, $dependency->{accepts})) {
            push @errors, _diagnostic('incompatible_contract_version', $id, accepts => $dependency->{accepts},
                (defined($surface->{version}) ? (version => $surface->{version}) : ()));
        }
        if (exists $dependency->{expected_fingerprint}) {
            my $actual = $surface->{fingerprint} // $snapshot->{provider}{domain_fingerprint};
            push @errors, _diagnostic('provider_fingerprint_changed', $id)
                unless defined($actual) && $actual eq $dependency->{expected_fingerprint};
        }
        my $uses = $dependency->{uses} // {};
        for my $section (qw(fields filters query_members)) {
            my %available = map { $_ => 1 } @{$surface->{$section}};
            my $code = $section eq 'fields' ? 'missing_field'
                : $section eq 'filters' ? 'missing_filter' : 'missing_query_member';
            push @errors, _diagnostic($code, $id, section => $section, value => $_)
                for grep { !$available{$_} } @{_names($uses->{$section} // [], "uses.$section")};
        }
        my %satisfied = map { $_ => 1 } @{_names($dependency->{satisfies} // [], 'satisfies')};
        push @errors, _diagnostic('unsatisfied_required_filter', $id, filter => $_)
            for grep { !$satisfied{$_} } @{$surface->{required_filters}};
    }
    return {
        provider => dclone($snapshot->{provider}), consumer => $identity,
        dependencies => \@selected, errors => \@errors, warnings => [],
        compatible => @errors ? JSON::PP::false : JSON::PP::true,
    };
}

sub diff_snapshots {
    my ($class, $before, $after) = @_;
    my $left = _snapshot_index($before);
    my $right = _snapshot_index($after);
    my @changes;
    for my $id (sort keys %$left) {
        unless (exists $right->{$id}) {
            push @changes, _change('surface_removed', $id, 1);
            next;
        }
        my ($old, $new) = ($left->{$id}, $right->{$id});
        for my $section (qw(fields filters query_members)) {
            my %old_ids = map { $_ => 1 } @{$old->{$section}};
            my %new_ids = map { $_ => 1 } @{$new->{$section}};
            push @changes, _change("${section}_removed", $id, 1, value => $_)
                for grep { !$new_ids{$_} } sort keys %old_ids;
            push @changes, _change("${section}_added", $id, 0, value => $_)
                for grep { !$old_ids{$_} } sort keys %new_ids;
        }
        for my $field (sort keys %{$old->{result_shape}}) {
            push @changes, _change('result_type_changed', $id, 1, field => $field)
                unless exists($new->{result_shape}{$field})
                    && $new->{result_shape}{$field} eq $old->{result_shape}{$field};
        }
        my %old_required = map { $_ => 1 } @{$old->{required_filters}};
        push @changes, _change('required_filter_added', $id, 1, filter => $_)
            for grep { !$old_required{$_} } @{$new->{required_filters}};
        push @changes, _change('surface_metadata_changed', $id, 0)
            unless _same($old, $new);
    }
    push @changes, _change('surface_added', $_, 0) for grep { !exists $left->{$_} } sort keys %$right;
    push @changes, _change('provider_metadata_changed', undef, 0)
        unless _same($before->{provider}, $after->{provider});
    return {
        changed => @changes ? JSON::PP::true : JSON::PP::false,
        breaking => (grep { $_->{breaking} } @changes) ? JSON::PP::true : JSON::PP::false,
        changes => \@changes,
    };
}

sub _snapshot_index {
    my ($snapshot) = @_;
    _object($snapshot, 'snapshot');
    _fail('unsupported contract snapshot format')
        unless defined($snapshot->{format}) && !ref($snapshot->{format})
            && $snapshot->{format} eq 'selecto.domain_contract_snapshot'
            && defined($snapshot->{format_version}) && !ref($snapshot->{format_version})
            && "$snapshot->{format_version}" eq '1';
    _identity(_object($snapshot->{provider}, 'snapshot.provider'));
    _fail('snapshot.surfaces must be an array') unless ref($snapshot->{surfaces}) eq 'ARRAY';
    my %surfaces;
    for my $surface (@{$snapshot->{surfaces}}) {
        _object($surface, 'snapshot surface');
        my $id = _string($surface->{id}, 'snapshot surface id');
        _fail("duplicate snapshot surface $id") if exists $surfaces{$id};
        my %normalized = %$surface;
        $normalized{$_} = _string($surface->{$_}, "snapshot.$id.$_")
            for grep { exists $surface->{$_} } qw(kind source version compatibility fingerprint capability);
        $normalized{stable} = _boolean($surface->{stable}, "snapshot.$id.stable") if exists $surface->{stable};
        $normalized{$_} = _names($surface->{$_}, "snapshot.$id.$_")
            for qw(fields filters query_members required_filters);
        my $shape = _object($surface->{result_shape}, "snapshot.$id.result_shape");
        $normalized{result_shape} = {map { $_ => _string($shape->{$_}, "snapshot.$id.result_shape.$_") } sort keys %$shape};
        _fail("snapshot $id field $_ has no result column")
            for grep { !exists $shape->{$_} } @{$normalized{fields}};
        $surfaces{$id} = \%normalized;
    }
    return \%surfaces;
}

sub _contract {
    my ($value) = @_;
    if (blessed($value) && $value->isa('Selecto::Domain')) {
        my $contract = $value->contract;
        return $contract if defined $contract;
        my $fields = $value->fields;
        return {name => $value->name, source => {columns => $fields},
            domain_dependencies => $value->domain_dependencies};
    }
    return _object($value, 'domain contract');
}

sub _identity {
    my ($contract) = @_;
    my %identity = (name => _string($contract->{name}, 'domain name'));
    $identity{$_} = _string($contract->{$_}, "domain $_")
        for grep { exists $contract->{$_} } qw(schema_version domain_version domain_fingerprint);
    return \%identity;
}

sub _dependency {
    my ($dependency) = @_;
    _object($dependency, 'domain dependency');
    my %known = map { $_ => 1 } qw(provider contract accepts expected_fingerprint uses satisfies);
    _fail('domain dependency has unknown fields') if grep { !$known{$_} } keys %$dependency;
    _string($dependency->{$_}, "dependency $_") for qw(provider contract);
    _string($dependency->{$_}, "dependency $_") for grep { exists $dependency->{$_} } qw(accepts expected_fingerprint);
    my $uses = _object($dependency->{uses} // {}, 'dependency uses');
    my %sections = map { $_ => 1 } qw(fields filters query_members);
    _fail('dependency uses has unknown fields') if grep { !$sections{$_} } keys %$uses;
    _names($uses->{$_}, "dependency uses $_") for keys %$uses;
    _names($dependency->{satisfies}, 'dependency satisfies') if exists $dependency->{satisfies};
}

# Deliberately bounded numeric version grammar. Invalid versions or requirements
# fail closed. Two-component ~> advances the major, three-component the minor.
sub _accepts {
    my ($version, $requirement) = @_;
    return 0 unless defined($version) && !ref($version);
    my @actual = _version($version);
    return 0 unless @actual;
    my @clauses = split /\s+and\s+/, $requirement, -1;
    for my $clause (@clauses) {
        return 0 unless $clause =~ /\A\s*(~>|>=|<=|>|<|==|=)?\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*\z/;
        my ($operator, $text) = ($1 // '=', $2);
        my @wanted = _version($text);
        return 0 unless @wanted;
        my $order = _compare(\@actual, \@wanted);
        if ($operator eq '~>') {
            my @upper = @wanted;
            if ($text =~ /\A[0-9]+\.[0-9]+\z/) { @upper = ($wanted[0] + 1, 0, 0); }
            else { @upper = ($wanted[0], $wanted[1] + 1, 0); }
            return 0 unless $order >= 0 && _compare(\@actual, \@upper) < 0;
        } else {
            return 0 unless $operator eq '>=' ? $order >= 0 : $operator eq '<=' ? $order <= 0
                : $operator eq '>' ? $order > 0 : $operator eq '<' ? $order < 0 : $order == 0;
        }
    }
    return 1;
}

sub _version {
    my ($value) = @_;
    return () unless $value =~ /\A([0-9]+)\.([0-9]+)(?:\.([0-9]+))?\z/;
    my @parts = ($1, $2, $3 // 0);
    return () if grep { length($_) > 9 || $_ > 999_999_999 } @parts;
    return map { 0 + $_ } @parts;
}
sub _compare { for my $i (0 .. 2) { my $order = $_[0][$i] <=> $_[1][$i]; return $order if $order; } return 0; }
sub _same {
    my ($left, $right) = @_;
    my $same;
    my $ok = eval { $same = Cpanel::JSON::XS->new->allow_nonref(1)->canonical->encode($left) eq Cpanel::JSON::XS->new->allow_nonref(1)->canonical->encode($right); 1 };
    _fail('snapshot metadata must be JSON-compatible') unless $ok;
    return $same;
}
sub _object { _fail("$_[1] must be an object") unless ref($_[0]) eq 'HASH'; return $_[0]; }
sub _string { _fail("$_[1] must be a nonblank string") unless defined($_[0]) && !ref($_[0]) && $_[0] =~ /\S/; return "$_[0]"; }
sub _names {
    my ($value, $label) = @_;
    _fail("$label must be an array") unless ref($value) eq 'ARRAY';
    my %ids = map { _string($_, "$label entry") => 1 } @$value;
    return [sort keys %ids];
}
sub _boolean {
    my ($value, $label) = @_;
    return $value ? JSON::PP::true : JSON::PP::false if JSON::PP::is_bool($value);
    _fail("$label must be boolean") unless defined($value) && !ref($value) && "$value" =~ /\A[01]\z/;
    return $value ? JSON::PP::true : JSON::PP::false;
}
sub _diagnostic { my ($code, $contract, %extra) = @_; return {code => $code, contract => $contract, %extra}; }
sub _change { my ($code, $surface, $breaking, %extra) = @_; return {code => $code, (defined($surface) ? (surface => $surface) : ()), breaking => $breaking ? JSON::PP::true : JSON::PP::false, %extra}; }
sub _fail { Selecto::Error->throw('invalid_domain', $_[0]); }

1;

=head1 NAME

Selecto::Domain::ContractVerification - portable published contract metadata

=head1 SYNOPSIS

  my $snapshot = Selecto::Domain::ContractVerification->snapshot($provider);
  my $report = Selecto::Domain::ContractVerification->verify($provider, $consumer);
  my $diff = Selecto::Domain::ContractVerification->diff_snapshots($before, $after);

=head1 DESCRIPTION

Accepts contract hashes or parsed Selecto::Domain objects. Snapshots contain
only the declared published interface and use stable ordering. Metadata checks
do not execute queries, callbacks, materialized views, or database refreshes.
Malformed metadata throws C<invalid_domain>. Compatibility reports contain
C<compatible>, C<dependencies>, C<errors>, and C<warnings>. Dependencies for
other named providers are validated but are outside this provider's report.

Numeric versions accept two or three components, comparisons, C<~E<gt>>, and
C<and> conjunctions. Invalid or unsupported version expressions are incompatible.
Removal, result type changes, and added required filters are breaking changes;
new fields and surfaces are additive. Other metadata changes are reported for
review and do not by themselves establish a breaking interface change.

=cut
