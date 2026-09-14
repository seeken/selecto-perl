package Selecto::Importer;

use 5.034;
use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Text::CSV ();
use Selecto::Domain ();
use Selecto::Error ();

has 'domain';
has max_columns => 200;
has max_rows => 50_000;
has max_sample_rows => 25;

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    Selecto::Error->throw('invalid_importer', 'importer requires a Selecto domain')
        unless blessed($self->domain) && $self->domain->isa('Selecto::Domain');
    for my $name (qw(max_columns max_rows max_sample_rows)) {
        my $value = $self->$name;
        Selecto::Error->throw('invalid_importer', "$name must be a positive integer")
            unless defined($value) && !ref($value) && "$value" =~ /\A[1-9][0-9]*\z/;
        $self->$name(0 + $value);
    }
    $self->_contract;
    return $self;
}

sub contract ($self) { return _clone($self->_contract); }

sub inspect_csv ($self, $content, %options) {
    Selecto::Error->throw('invalid_import_file', 'CSV content must be a scalar')
        if !defined($content) || ref($content);
    my $delimiter = $options{delimiter} // ',';
    Selecto::Error->throw('invalid_import_file', 'CSV delimiter must be one character')
        if ref($delimiter) || length($delimiter) != 1;
    my $header = exists($options{header}) ? $options{header} : 1;
    Selecto::Error->throw('invalid_import_file', 'CSV header setting must be boolean')
        if ref($header);

    my $csv = Text::CSV->new({
        binary => 1,
        auto_diag => 0,
        sep_char => $delimiter,
        allow_whitespace => 0,
    }) or Selecto::Error->throw('invalid_import_file', 'CSV parser could not be initialized');
    open my $fh, '<:encoding(UTF-8)', \$content
        or Selecto::Error->throw('invalid_import_file', 'CSV content cannot be read');

    my @records;
    my $record_number = 0;
    while (my $row = $csv->getline($fh)) {
        $record_number++;
        Selecto::Error->throw('import_column_limit_exceeded', 'Import file has too many columns', {
            maximum => $self->max_columns,
            columns => scalar(@$row),
        }) if @$row > $self->max_columns;
        push @records, {values => [@$row], physical_line => $csv->record_number};
        Selecto::Error->throw('import_row_limit_exceeded', 'Import file has too many rows', {
            maximum => $self->max_rows,
        }) if @records > $self->max_rows + ($header ? 1 : 0);
    }
    if (!$csv->eof) {
        my ($code, $message, $position, $record, $field) = $csv->error_diag;
        Selecto::Error->throw('import_parser_error', 'CSV parsing failed', {
            parser => 'Text::CSV', code => "$code", message => "$message",
            physical_line => $record,
            defined($field) ? (field => $field) : (),
        });
    }
    Selecto::Error->throw('import_file_empty', 'Import file has no rows') unless @records;

    my $header_record = $header ? shift @records : undef;
    my @headers = $header
        ? map { defined($_) ? "$_" : '' } @{$header_record->{values}}
        : map { 'Column ' . ($_ + 1) } 0 .. $#{$records[0]{values}};
    my %occurrences;
    my @columns = map {
        my $label = $headers[$_] // '';
        $occurrences{lc $label}++;
        {
            id => 'c' . ($_ + 1), ordinal => $_ + 1, header => $label,
            occurrence => $occurrences{lc $label},
            label => length($label) ? $label . ($occurrences{lc $label} > 1 ? ' #' . $occurrences{lc $label} : '') : 'Column ' . ($_ + 1),
        }
    } 0 .. $#headers;
    my @rows;
    for my $index (0 .. $#records) {
        my $record = $records[$index];
        my %values;
        for my $column (@columns) {
            $values{$column->{id}} = $record->{values}[ $column->{ordinal} - 1 ];
        }
        push @rows, {
            row_number => $index + 1,
            physical_line => $record->{physical_line},
            values => \%values,
        };
    }
    return {
        format => 'csv', delimiter => $delimiter, header => $header ? JSON::PP::true : JSON::PP::false,
        sha256 => 'sha256:' . sha256_hex($content), columns => \@columns,
        rows => \@rows,
        sample_rows => [@rows[0 .. ($#rows < $self->max_sample_rows - 1 ? $#rows : $self->max_sample_rows - 1)]],
        row_count => scalar(@rows),
    };
}

sub normalize_configuration ($self, $configuration, %options) {
    _object($configuration, 'import configuration');
    _reject_unknown($configuration, [qw(
        config_version domain_fingerprint upload_id profile parser rows mappings match idempotency errors parameters
    )], 'import configuration');
    my $contract = $self->_contract;
    my $fingerprint = $self->domain->fingerprint;
    Selecto::Error->throw('import_domain_changed', 'Import configuration does not match the current domain', {
        expected => $fingerprint, received => $configuration->{domain_fingerprint},
    }) if defined($configuration->{domain_fingerprint}) && $configuration->{domain_fingerprint} ne $fingerprint;
    Selecto::Error->throw('invalid_import_configuration', 'config_version must be 1')
        unless ($configuration->{config_version} // 1) == 1;
    my $columns = $options{columns} // [];
    Selecto::Error->throw('invalid_import_configuration', 'columns must be an array')
        unless ref($columns) eq 'ARRAY';
    my %columns = map { $_->{id} => $_ } grep { ref($_) eq 'HASH' && defined($_->{id}) } @$columns;

    my $mappings = $configuration->{mappings} // [];
    Selecto::Error->throw('invalid_import_configuration', 'mappings must be an array')
        unless ref($mappings) eq 'ARRAY';
    my %fields = %{$contract->{fields}};
    my %mapped;
    my @normalized;
    for my $mapping (@$mappings) {
        _object($mapping, 'import mapping');
        _reject_unknown($mapping, [qw(target source transforms blank_policy)], 'import mapping');
        my $target = _string($mapping->{target}, 'import mapping target');
        Selecto::Error->throw('import_field_not_enabled', "Field $target is not enabled for importing", {field => $target})
            unless exists $fields{$target};
        Selecto::Error->throw('invalid_import_configuration', "Field $target is mapped more than once", {field => $target})
            if $mapped{$target}++;
        _object($mapping->{source}, "import mapping $target source");
        _reject_unknown($mapping->{source}, [qw(kind column_id value name)], "import mapping $target source");
        my $kind = _string($mapping->{source}{kind}, "import mapping $target source kind");
        my %allowed_sources = map { $_ => 1 } @{$fields{$target}{sources} // []};
        Selecto::Error->throw('import_source_not_allowed', "Source $kind is not allowed for $target", {
            field => $target, source => $kind,
        }) unless $allowed_sources{$kind};
        my %source = (kind => $kind);
        if ($kind eq 'column') {
            my $column_id = _string($mapping->{source}{column_id}, "import mapping $target column_id");
            Selecto::Error->throw('import_column_missing', "Column $column_id is not present in this upload", {
                field => $target, column_id => $column_id,
            }) unless exists $columns{$column_id};
            $source{column_id} = $column_id;
        } elsif ($kind eq 'static') {
            Selecto::Error->throw('invalid_import_configuration', "Static source for $target requires value")
                unless exists $mapping->{source}{value};
            $source{value} = _clone($mapping->{source}{value});
        } elsif ($kind eq 'parameter') {
            $source{name} = _string($mapping->{source}{name}, "import mapping $target parameter name");
        } elsif ($kind eq 'trusted') {
            $source{name} = $fields{$target}{trusted_provider};
            Selecto::Error->throw('invalid_import_contract', "Trusted source $target has no provider")
                unless defined($source{name}) && length($source{name});
        } else {
            Selecto::Error->throw('invalid_import_configuration', "Unknown import source $kind", {field => $target});
        }
        my $transforms = $mapping->{transforms} // [];
        Selecto::Error->throw('invalid_import_configuration', "Transforms for $target must be an array")
            unless ref($transforms) eq 'ARRAY';
        my %allowed_transforms = map { $_ => 1 } @{$fields{$target}{transforms} // []};
        for my $transform (@$transforms) {
            Selecto::Error->throw('import_transform_not_allowed', "Transform $transform is not allowed for $target", {
                field => $target, transform => $transform,
            }) unless defined($transform) && !ref($transform) && $allowed_transforms{$transform};
        }
        my $blank_policy = $mapping->{blank_policy} // $fields{$target}{blank_policy} // 'omit';
        Selecto::Error->throw('invalid_import_configuration', "Invalid blank policy for $target", {field => $target})
            unless $blank_policy =~ /\A(?:omit|empty|null|error)\z/;
        push @normalized, {
            target => $target, source => \%source, transforms => [@$transforms], blank_policy => $blank_policy,
        };
    }
    my $match = $configuration->{match} // {};
    _object($match, 'import match');
    _reject_unknown($match, [qw(key_set on_match on_missing)], 'import match');
    my $key_set_id = _string($match->{key_set}, 'import key_set');
    my ($key_set) = grep { $_->{id} eq $key_set_id } @{$contract->{key_sets}};
    Selecto::Error->throw('import_key_set_not_found', "Key set $key_set_id is not published", {key_set => $key_set_id})
        unless $key_set;
    my $on_match = $match->{on_match} // $key_set->{default_on_match};
    my $on_missing = $match->{on_missing} // $key_set->{default_on_missing};
    _choice($on_match, $key_set->{allowed_on_match}, 'on_match');
    _choice($on_missing, $key_set->{allowed_on_missing}, 'on_missing');
    my $rows = $configuration->{rows} // {};
    _object($rows, 'import rows');
    _reject_unknown($rows, [qw(start end)], 'import rows');
    my $start = exists($rows->{start}) ? _positive_integer($rows->{start}, 'import rows start') : 1;
    my $end = exists($rows->{end}) ? _positive_integer($rows->{end}, 'import rows end') : undef;
    Selecto::Error->throw('invalid_import_configuration', 'import row end must not precede start')
        if defined($end) && $end < $start;
    return {
        config_version => 1,
        domain_fingerprint => $fingerprint,
        (defined($configuration->{upload_id}) ? (upload_id => _string($configuration->{upload_id}, 'upload_id')) : ()),
        mappings => \@normalized,
        match => {key_set => $key_set_id, on_match => $on_match, on_missing => $on_missing},
        rows => {start => $start, defined($end) ? (end => $end) : ()},
        parameters => _clone($configuration->{parameters} // {}),
        idempotency => _normalize_idempotency($configuration->{idempotency}, $contract),
        errors => _normalize_errors($configuration->{errors}),
    };
}

sub preview_rows ($self, $inspection, $configuration, %options) {
    _object($inspection, 'import inspection');
    my $normalized = $self->normalize_configuration($configuration, columns => $inspection->{columns} // []);
    my $resolver = $options{key_resolver};
    Selecto::Error->throw('invalid_import_host', 'preview requires a key_resolver callback')
        unless ref($resolver) eq 'CODE';
    my $trusted = $options{trusted_values} // {};
    _object($trusted, 'trusted values');
    my $contract = $self->_contract;
    my ($key_set) = grep { $_->{id} eq $normalized->{match}{key_set} } @{$contract->{key_sets}};
    my @rows;
    for my $row (@{$inspection->{rows} // []}) {
        next if $row->{row_number} < $normalized->{rows}{start};
        last if defined($normalized->{rows}{end}) && $row->{row_number} > $normalized->{rows}{end};
        my $preview = $self->_preview_row($row, $normalized, $key_set, $trusted, $resolver);
        push @rows, $preview;
    }
    return {configuration => $normalized, rows => \@rows, returned => scalar(@rows)};
}

sub _preview_row ($self, $row, $configuration, $key_set, $trusted, $resolver) {
    my %assignments;
    my %match_values;
    my $fields = $self->_contract->{fields};
    my @errors;
    for my $mapping (@{$configuration->{mappings}}) {
        my $field = $fields->{$mapping->{target}};
        my $values = $field->{match_only} ? \%match_values : \%assignments;
        my ($present, $value) = _resolve_value($mapping, $row->{values}, $configuration->{parameters}, $trusted);
        if ($present) {
            my $ok = eval { $value = _apply_transforms($value, $mapping->{transforms}); 1 };
            if (!$ok) {
                my $error = $@;
                push @errors, _error_hash($error, $mapping->{target});
                next;
            }
        }
        if (!$present || _blank($value)) {
            my $policy = $mapping->{blank_policy};
            if ($policy eq 'omit') { next }
            if ($policy eq 'empty') { $values->{$mapping->{target}} = ''; next }
            if ($policy eq 'null') { $values->{$mapping->{target}} = undef; next }
            push @errors, {code => 'import_required_value_missing', field => $mapping->{target}, message => 'A value is required'};
            next;
        }
        $values->{$mapping->{target}} = $value;
    }
    my %key_values = map {
        $_ => exists($assignments{$_}) ? $assignments{$_} : $match_values{$_}
    } @{$key_set->{fields}};
    for my $field (@{$key_set->{fields}}) {
        push @errors, {code => 'import_key_incomplete', field => $field, message => 'A key value is required'}
            if !exists($key_values{$field}) || _blank($key_values{$field});
    }
    my $match_result = {matches => []};
    if (!@errors) {
        my $ok = eval { $match_result = $resolver->(\%key_values, $key_set, $row); 1 };
        if (!$ok) { push @errors, _error_hash($@, undef); }
        elsif (ref($match_result) ne 'HASH' || ref($match_result->{matches}) ne 'ARRAY') {
            push @errors, {code => 'invalid_import_host', message => 'key resolver returned an invalid result'};
        }
    }
    my $decision = 'error';
    my $target;
    if (!@errors) {
        my $matches = $match_result->{matches};
        if (@$matches > 1) {
            push @errors, {code => 'import_key_ambiguous', message => 'Key matches more than one record', details => {count => scalar(@$matches)}};
        } elsif (@$matches == 1) {
            $target = $matches->[0];
            $decision = $configuration->{match}{on_match};
        } else {
            $decision = $configuration->{match}{on_missing};
        }
    }
    # Requiredness belongs to governed inserts. An update may intentionally
    # contain only its key plus one changed field, so do this only after the
    # match decision is known.
    if (!@errors && $decision eq 'insert') {
        my $writes = $self->domain->writes;
        for my $field (sort keys %{$writes->{fields} // {}}) {
            my $spec = $writes->{fields}{$field};
            next unless ref($spec) eq 'HASH' && $spec->{required};
            next if exists $assignments{$field} && !_blank($assignments{$field});
            push @errors, {code => 'import_required_value_missing', field => $field, message => 'Required for insert'};
        }
    }
    $decision = 'error' if @errors;
    my $write;
    if ($decision eq 'insert' || $decision eq 'update') {
        $write = {
            operation => $decision,
            assignments => \%assignments,
            expected_count => 1,
            returning => [$self->domain->primary_key],
        };
        if ($decision eq 'update') {
            my $id = ref($target) eq 'HASH' ? $target->{$self->domain->primary_key} : undef;
            if (!defined $id) {
                push @errors, {code => 'invalid_import_host', message => 'Matched record has no primary key'};
                $decision = 'error';
                undef $write;
            } else {
                $write->{filters} = [{field => $self->domain->primary_key, op => 'eq', value => $id}];
            }
        }
    }
    return {
        row_number => $row->{row_number}, physical_line => $row->{physical_line},
        source => _clone($row->{values}), assignments => \%assignments,
        match_values => \%match_values,
        key => \%key_values, decision => $decision,
        defined($target) ? (target => _clone($target)) : (),
        errors => \@errors,
        defined($write) ? (write => $write) : (),
    };
}

sub _contract ($self) {
    return $self->{_contract} if $self->{_contract};
    my $extension = $self->domain->contract->{extensions}{importer};
    Selecto::Error->throw('import_not_enabled', 'This domain does not publish an importer contract')
        unless ref($extension) eq 'HASH' && $extension->{enabled};
    _reject_unknown($extension, [qw(contract_version enabled field_policy fields key_sets idempotency)], 'importer extension');
    Selecto::Error->throw('invalid_import_contract', 'importer contract_version must be 1')
        unless ($extension->{contract_version} // 1) == 1;
    Selecto::Error->throw('invalid_import_contract', 'importer field_policy must be declared_only')
        unless ($extension->{field_policy} // 'declared_only') eq 'declared_only';
    _object($extension->{fields}, 'importer fields');
    my $domain_fields = $self->domain->fields;
    my %fields;
    for my $name (keys %{$extension->{fields}}) {
        Selecto::Error->throw('invalid_import_contract', 'import fields must be root governed fields', {field => $name})
            if $name =~ /\./ || !exists($domain_fields->{$name});
        my $spec = $extension->{fields}{$name};
        _object($spec, "importer field $name");
        _reject_unknown($spec, [qw(sources header_aliases transforms blank_policy trusted_provider match_only)], "importer field $name");
        my $match_only = $spec->{match_only} ? 1 : 0;
        Selecto::Error->throw('invalid_import_contract', "Importer field $name match_only must be boolean")
            if exists($spec->{match_only}) && (ref($spec->{match_only}) || $spec->{match_only} !~ /\A(?:0|1)\z/);
        my $write = $self->domain->writes->{fields}{$name};
        Selecto::Error->throw('invalid_import_contract', "Import field $name is not governed-write enabled", {field => $name})
            unless $match_only || (ref($write) eq 'HASH' && ($write->{insertable} || $write->{updatable}));
        my $sources = $spec->{sources} // [];
        Selecto::Error->throw('invalid_import_contract', "Importer field $name sources must be an array") unless ref($sources) eq 'ARRAY' && @$sources;
        my %seen;
        for my $source (@$sources) {
            Selecto::Error->throw('invalid_import_contract', "Importer field $name has invalid source", {field => $name, source => $source})
                unless defined($source) && !ref($source) && $source =~ /\A(?:column|static|parameter|trusted)\z/ && !$seen{$source}++;
        }
        if (grep { $_ eq 'trusted' } @$sources) {
            Selecto::Error->throw('invalid_import_contract', "Trusted importer field $name needs trusted_provider")
                unless defined($spec->{trusted_provider}) && !ref($spec->{trusted_provider}) && length($spec->{trusted_provider});
        }
        my $transforms = $spec->{transforms} // [];
        Selecto::Error->throw('invalid_import_contract', "Importer field $name transforms must be an array") unless ref($transforms) eq 'ARRAY';
        for my $transform (@$transforms) {
            Selecto::Error->throw('invalid_import_contract', "Importer field $name has invalid transform")
                unless defined($transform) && !ref($transform) && $transform =~ /\A(?:trim|uppercase|lowercase|normalize_whitespace|empty_to_null)\z/;
        }
        my $blank_policy = $spec->{blank_policy} // 'omit';
        Selecto::Error->throw('invalid_import_contract', "Importer field $name has invalid blank_policy")
            unless $blank_policy =~ /\A(?:omit|empty|null|error)\z/;
        $fields{$name} = {
            sources => [@$sources], header_aliases => [@{$spec->{header_aliases} // []}],
            transforms => [@$transforms], blank_policy => $blank_policy,
            ($match_only ? (match_only => JSON::PP::true) : ()),
            (defined($spec->{trusted_provider}) ? (trusted_provider => $spec->{trusted_provider}) : ()),
        };
    }
    my $key_sets = $extension->{key_sets} // [];
    Selecto::Error->throw('invalid_import_contract', 'importer key_sets must be a non-empty array')
        unless ref($key_sets) eq 'ARRAY' && @$key_sets;
    my %key_ids;
    my @normalized_keys;
    for my $key (@$key_sets) {
        _object($key, 'importer key set');
        _reject_unknown($key, [qw(id label fields cardinality allowed_on_match allowed_on_missing default_on_match default_on_missing)], 'importer key set');
        my $id = _string($key->{id}, 'importer key set id');
        Selecto::Error->throw('invalid_import_contract', "Duplicate importer key set $id") if $key_ids{$id}++;
        my $key_fields = $key->{fields};
        Selecto::Error->throw('invalid_import_contract', "Importer key set $id fields must be a non-empty array")
            unless ref($key_fields) eq 'ARRAY' && @$key_fields;
        for my $field (@$key_fields) {
            Selecto::Error->throw('invalid_import_contract', "Importer key set $id uses non-importable field $field")
                unless exists $fields{$field};
        }
        my $cardinality = $key->{cardinality} // 'zero_or_one';
        Selecto::Error->throw('invalid_import_contract', "Importer key set $id must have zero_or_one cardinality")
            unless $cardinality eq 'zero_or_one';
        my $on_match = $key->{allowed_on_match} // [qw(update skip error)];
        my $on_missing = $key->{allowed_on_missing} // [qw(insert skip error)];
        _allowed_decisions($on_match, "Importer key set $id allowed_on_match");
        _allowed_decisions($on_missing, "Importer key set $id allowed_on_missing");
        my $default_match = $key->{default_on_match} // $on_match->[0];
        my $default_missing = $key->{default_on_missing} // $on_missing->[0];
        _choice($default_match, $on_match, "Importer key set $id default_on_match");
        _choice($default_missing, $on_missing, "Importer key set $id default_on_missing");
        push @normalized_keys, {
            id => $id, label => $key->{label} // $id, fields => [@$key_fields], cardinality => $cardinality,
            allowed_on_match => [@$on_match], allowed_on_missing => [@$on_missing],
            default_on_match => $default_match, default_on_missing => $default_missing,
        };
    }
    $self->{_contract} = {
        contract_version => 1, enabled => JSON::PP::true, field_policy => 'declared_only',
        fields => \%fields, key_sets => \@normalized_keys,
        idempotency => _clone($extension->{idempotency} // {supported => JSON::PP::false}),
    };
    return $self->{_contract};
}

sub _resolve_value ($mapping, $values, $parameters, $trusted) {
    my $source = $mapping->{source};
    return (1, $values->{$source->{column_id}}) if $source->{kind} eq 'column';
    return (1, _clone($source->{value})) if $source->{kind} eq 'static';
    return (exists($parameters->{$source->{name}}), $parameters->{$source->{name}}) if $source->{kind} eq 'parameter';
    return (exists($trusted->{$source->{name}}), $trusted->{$source->{name}}) if $source->{kind} eq 'trusted';
    return (0, undef);
}

sub _apply_transforms ($value, $transforms) {
    for my $transform (@$transforms) {
        next unless defined $value;
        $value =~ s/\A\s+|\s+\z//g if $transform eq 'trim';
        $value = uc $value if $transform eq 'uppercase';
        $value = lc $value if $transform eq 'lowercase';
        $value =~ s/\s+/ /g if $transform eq 'normalize_whitespace';
        $value = undef if $transform eq 'empty_to_null' && _blank($value);
    }
    return $value;
}

sub _normalize_idempotency ($value, $contract) {
    $value //= {};
    _object($value, 'import idempotency');
    _reject_unknown($value, [qw(mode on_duplicate)], 'import idempotency');
    my $supported = $contract->{idempotency}{supported} ? 1 : 0;
    my $mode = $value->{mode} // 'none';
    Selecto::Error->throw('invalid_import_configuration', 'idempotency mode must be none or source_row')
        unless $mode =~ /\A(?:none|source_row)\z/;
    Selecto::Error->throw('import_idempotency_not_supported', 'This importer does not support source-row idempotency')
        if $mode eq 'source_row' && !$supported;
    my $on_duplicate = $value->{on_duplicate} // 'skip';
    Selecto::Error->throw('invalid_import_configuration', 'idempotency on_duplicate must be skip or error')
        unless $on_duplicate =~ /\A(?:skip|error)\z/;
    return {mode => $mode, on_duplicate => $on_duplicate};
}

sub _normalize_errors ($value) {
    $value //= {};
    _object($value, 'import errors');
    _reject_unknown($value, ['mode'], 'import errors');
    my $mode = $value->{mode} // 'continue';
    Selecto::Error->throw('invalid_import_configuration', 'error mode must be continue or fail_fast')
        unless $mode =~ /\A(?:continue|fail_fast)\z/;
    return {mode => $mode};
}

sub _allowed_decisions ($values, $label) {
    Selecto::Error->throw('invalid_import_contract', "$label must be a non-empty array")
        unless ref($values) eq 'ARRAY' && @$values;
    my %seen;
    for my $value (@$values) {
        Selecto::Error->throw('invalid_import_contract', "$label has invalid value")
            unless defined($value) && !ref($value) && $value =~ /\A(?:insert|update|skip|error)\z/ && !$seen{$value}++;
    }
}

sub _choice ($value, $choices, $label) {
    Selecto::Error->throw('invalid_import_configuration', "$label is not allowed", {value => $value})
        unless defined($value) && !ref($value) && grep { $_ eq $value } @$choices;
    return $value;
}

sub _blank ($value) { return !defined($value) || (!ref($value) && $value =~ /\A\s*\z/); }
sub _positive_integer ($value, $label) {
    Selecto::Error->throw('invalid_import_configuration', "$label must be a positive integer")
        unless defined($value) && !ref($value) && "$value" =~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}
sub _string ($value, $label) {
    Selecto::Error->throw('invalid_import_configuration', "$label must be a non-empty string")
        unless defined($value) && !ref($value) && length($value);
    return "$value";
}
sub _object ($value, $label) { Selecto::Error->throw('invalid_import_configuration', "$label must be an object") unless ref($value) eq 'HASH'; }
sub _reject_unknown ($value, $allowed, $label) {
    my %allowed = map { $_ => 1 } @$allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$value;
    Selecto::Error->throw('invalid_import_configuration', "$label has unknown properties", {properties => \@unknown}) if @unknown;
}
sub _clone ($value) { return JSON::PP->new->allow_nonref(1)->decode(JSON::PP->new->canonical(1)->encode($value)); }
sub _error_hash ($error, $field) {
    return {code => $error->code, message => $error->message, defined($field) ? (field => $field) : (), details => $error->details}
        if blessed($error) && $error->isa('Selecto::Error');
    return {code => 'import_transform_failed', message => 'Import value processing failed', defined($field) ? (field => $field) : ()};
}

1;
