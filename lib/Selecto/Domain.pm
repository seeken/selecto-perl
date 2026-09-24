package Selecto::Domain;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::DataRules ();

my %TOP_LEVEL = map { $_ => 1 } qw(
    schema_version domain_version domain_fingerprint name source schemas joins associations
    default_selected required_selected required_order_by
    filters functions query_members published_views detail_actions capabilities
    source_relationships choice_sources writes actions imports editors extensions columns custom_columns
    jsonb_schemas subfilters window_functions pagination retarget redact_fields components
    query_library co_domains domain_dependencies operations experiences rules
);
my %SIMPLE_SOURCE = map { $_ => 1 } qw(table fields);
my %RELATION = map { $_ => 1 } qw(
    source_table values primary_key fields columns associations tenant_field redact_fields
);
my %ASSOCIATION = map { $_ => 1 } qw(
    queryable owner_key related_key cardinality through source_scope_key target_scope_key where
    join_strategy
);
my %JOIN = map { $_ => 1 } qw(
    type name display_field dimension_key display_fallback joins
);
my %THROUGH = map { $_ => 1 } qw(
    table owner_key related_key source_scope_key through_scope_key target_scope_key
    where target_key_cast
);
my %COMPONENTS = map { $_ => 1 } qw(query_params filter_choices filter_picker_hidden_paths picker_visible_id_paths);
my %DETAIL_ACTION = map { $_ => 1 } qw(
    name description type required_fields payload capability
);
my %DETAIL_ACTION_PAYLOAD = map { $_ => 1 } qw(
    url_template target title size allow referrer_policy sandbox navigation_enabled editor target_field
);
my %EDITOR = map { $_ => 1 } qw(label description fields actions collections submit_label);
my %EDITOR_FIELD = map { $_ => 1 } qw(
    field label control required nullable readonly rows placeholder help section options
);
my %EDITOR_COLLECTION = map { $_ => 1 } qw(
    id label fields order_by limit empty_label
);
my %EDITOR_COLLECTION_FIELD = map { $_ => 1 } qw(field label);

sub new {
    my ($class, %args) = @_;
    my $fields = _normalize_fields($args{fields}, 'fields');
    my %associations;
    my $input = $args{associations} // {};
    _object($input, 'associations');
    for my $name (keys %$input) {
        my $association_name = _identifier($name, 'association');
        $associations{$association_name} =
            blessed($input->{$name}) && $input->{$name}->isa('Selecto::Domain::Association')
            ? $input->{$name}
            : Selecto::Domain::Association->new(
                name => $association_name,
                value => $input->{$name},
            );
    }
    my $self = bless {
        name         => _required_string($args{name}, 'name'),
        table        => _identifier($args{table}, 'table'),
        fields       => $fields,
        associations => \%associations,
        components   => _normalize_components($args{components}),
        query_library => _normalize_query_library($args{query_library}),
        co_domains   => _normalize_co_domains($args{co_domains}),
        domain_dependencies => _normalize_domain_dependencies($args{domain_dependencies}),
        operations   => _normalize_consumer_registry($args{operations}, 'operations'),
        experiences  => _normalize_consumer_registry($args{experiences}, 'experiences'),
        detail_actions => {},
        rules        => undef,
        primary_key  => undef,
        required_predicate => $args{required_predicate},
        tenant_field => $args{tenant_field},
    }, $class;
    $self->{primary_key} = _identifier(
        $args{primary_key} // (exists($fields->{id}) ? 'id' : (sort keys %$fields)[0]),
        'primary key',
    );
    Selecto::Error->throw('invalid_domain', 'primary key must be a root field')
        unless exists $fields->{$self->{primary_key}};
    if (defined($self->{tenant_field})) {
        $self->{tenant_field} = _identifier($self->{tenant_field}, 'tenant field');
        Selecto::Error->throw('invalid_domain', 'tenant field must be a root field')
            unless exists $fields->{$self->{tenant_field}};
    }
    for my $association (values %associations) {
        if (defined $association->source_scope_key) {
            Selecto::Error->throw(
                'invalid_domain',
                'association source scope key must be a root field',
                {association => $association->name},
            ) unless exists $fields->{$association->source_scope_key};
            Selecto::Error->throw(
                'invalid_domain',
                'association target scope key must be queryable',
                {association => $association->name},
            ) unless exists $association->fields->{$association->target_scope_key};
        }
        if (my $through = $association->through) {
            if (defined $through->{source_scope_key}) {
                Selecto::Error->throw(
                    'invalid_domain',
                    'through association source scope key must be a root field',
                    {association => $association->name},
                ) unless exists $fields->{$through->{source_scope_key}};
                Selecto::Error->throw(
                    'invalid_domain',
                    'through association target scope key must be queryable',
                    {association => $association->name},
                ) unless exists $association->fields->{$through->{target_scope_key}};
            }
        }
        next unless $association->join_mode eq 'star_dimension';
        Selecto::Error->throw(
            'invalid_domain',
            'star dimension key must be a root field',
            { association => $association->name, dimension_key => $association->dimension_key },
        ) unless exists $fields->{$association->dimension_key};
        Selecto::Error->throw(
            'invalid_domain',
            'star dimension key must match the association owner key',
            { association => $association->name },
        ) unless $association->dimension_key eq $association->owner_key;
    }
    if (defined($args{detail_actions})) {
        $self->{detail_actions} = _validate_detail_actions(
            $self, $args{detail_actions},
        );
    }
    $self->{rules} = Selecto::DataRules->parse($args{rules}) if defined $args{rules};
    $self->_refresh_fingerprint;
    return $self;
}

sub _refresh_fingerprint {
    my ($self) = @_;
    my $fingerprint_value = {
        name => $self->{name},
        table => $self->{table},
        fields => $self->{fields},
        associations => {
            map { $_ => $self->{associations}{$_}->fingerprint_value }
                sort keys %{$self->{associations}}
        },
        primary_key => $self->{primary_key},
        required_predicate => _expression_value($self->{required_predicate}),
        tenant_field => $self->{tenant_field},
    };
    $fingerprint_value->{components} = $self->{components} if keys %{$self->{components}};
    $fingerprint_value->{query_library} = $self->{query_library}
        if keys %{$self->{query_library}};
    $fingerprint_value->{co_domains} = $self->{co_domains}
        if keys %{$self->{co_domains}};
    $fingerprint_value->{domain_dependencies} = $self->{domain_dependencies}
        if @{$self->{domain_dependencies}};
    $fingerprint_value->{operations} = $self->{operations}
        if keys %{$self->{operations}};
    $fingerprint_value->{experiences} = $self->{experiences}
        if keys %{$self->{experiences}};
    $fingerprint_value->{detail_actions} = $self->{detail_actions}
        if keys %{$self->{detail_actions}};
    my $json = JSON::PP->new->canonical(1)->encode($fingerprint_value);
    $self->{fingerprint} = 'sha256:' . sha256_hex(encode_utf8($json));
    return $self;
}

sub with_required_predicate {
    my ($self, $predicate) = @_;
    my $copy = bless {%$self}, ref($self);
    $copy->{required_predicate} = $predicate;
    return $copy->_refresh_fingerprint;
}

sub parse {
    my ($class, $document, %options) = @_;
    my $strict = exists($options{strict}) ? $options{strict} : 1;
    my $raw;
    if (ref($document)) {
        $raw = $document;
    } else {
        my $ok = eval { $raw = JSON::PP->new->allow_nonref(0)->decode($document); 1 };
        Selecto::Error->throw('invalid_domain', 'domain JSON is malformed', { parser => 'JSON::PP' })
            unless $ok;
    }
    _object($raw, 'domain');
    _reject_unknown($raw, \%TOP_LEVEL, 'domain') if $strict;
    _required_key($raw, 'source', 'domain');
    _object($raw->{source}, 'source');

    if (exists $raw->{source}{source_table}) {
        return $class->_parse_canonical($raw, $raw->{source}, $strict);
    }

    _reject_unknown($raw->{source}, \%SIMPLE_SOURCE, 'source') if $strict;
    _required_key($raw, 'name', 'domain');
    _required_key($raw->{source}, 'table', 'source');
    _required_key($raw->{source}, 'fields', 'source');
    return $class->new(
        name => $raw->{name},
        table => $raw->{source}{table},
        fields => $raw->{source}{fields},
        associations => $raw->{associations} // {},
        components => $raw->{components},
        query_library => $raw->{query_library},
        co_domains => $raw->{co_domains},
        domain_dependencies => $raw->{domain_dependencies},
        operations => $raw->{operations},
        experiences => $raw->{experiences},
        detail_actions => $raw->{detail_actions},
        rules => $raw->{rules},
    );
}

sub _parse_canonical {
    my ($class, $raw, $source, $strict) = @_;
    $raw = dclone($raw);
    $source = $raw->{source};
    _reject_unknown($source, \%RELATION, 'source') if $strict;
    Selecto::Error->throw(
        'invalid_domain', 'root source must use source_table rather than values',
    ) if exists $source->{values};
    my $schemas = $raw->{schemas} // {};
    my $joins = $raw->{joins} // {};
    _object($schemas, 'schemas');
    _object($joins, 'joins');
    my $associations = _canonical_associations(
        $source, $schemas, $joins, $strict, '',
    );
    _apply_values_foreign_key_metadata(
        $source, $associations, $raw->{writes},
    );
    _validate_computed_columns($source, $associations);
    _validate_action_eligibility($raw, $source);

    _required_key($raw, 'name', 'domain');
    _required_key($source, 'source_table', 'source');
    my $domain = $class->new(
        name => $raw->{name},
        table => $source->{source_table},
        fields => _canonical_fields($source),
        associations => $associations,
        primary_key => $source->{primary_key} // 'id',
        tenant_field => $source->{tenant_field},
        components => $raw->{components},
        query_library => $raw->{query_library},
        co_domains => $raw->{co_domains},
        domain_dependencies => $raw->{domain_dependencies},
        operations => $raw->{operations},
        experiences => $raw->{experiences},
        rules => $raw->{rules},
    );
    $domain->{contract} = dclone($raw);
    $domain->{canonical_schemas} = dclone($schemas);
    $domain->{canonical_joins} = dclone($joins);
    _validate_conditional_filter_choices($domain);
    _validate_picker_visible_id_paths($domain);
    $domain->{editors} = _validate_editors($domain, $raw->{editors});
    $domain->{contract}{editors} = dclone($domain->{editors})
        if keys %{$domain->{editors}};
    $domain->{detail_actions} = _validate_detail_actions(
        $domain, $raw->{detail_actions},
    );
    my $fingerprint_document = dclone($raw);
    delete $fingerprint_document->{domain_fingerprint};
    $domain->{fingerprint} = 'sha256:' . sha256_hex(
        encode_utf8(JSON::PP->new->canonical(1)->encode($fingerprint_document))
    );
    return $domain;
}

sub _apply_values_foreign_key_metadata {
    my ($source, $associations, $writes) = @_;
    my %owner_association;
    for my $name (sort keys %$associations) {
        my $association = $associations->{$name};
        my $values = $association->values;
        next unless defined($values)
            && $association->cardinality eq 'one'
            && !defined($association->through);
        my $owner_key = $association->owner_key;
        next unless ref($source->{columns}{$owner_key}) eq 'HASH';
        Selecto::Error->throw(
            'invalid_domain',
            'a root field cannot reference multiple inline-values associations',
            {
                field => $owner_key,
                associations => [$owner_association{$owner_key}, $name],
            },
        ) if exists $owner_association{$owner_key};
        $owner_association{$owner_key} = $name;

        my $value_field = $association->related_key;
        my $label_field = $association->join_mode eq 'star_dimension'
            ? $association->display_field : $value_field;
        my @options;
        for my $row (@$values) {
            my $value = $row->{$value_field};
            Selecto::Error->throw(
                'invalid_domain',
                'inline-values foreign key values cannot be null',
                {association => $name, field => $value_field},
            ) unless defined $value;
            my $label = $row->{$label_field};
            $label = $value unless defined($label) && !ref($label);
            push @options, {value => $value, label => "$label"};
        }
        next unless @options;
        my $foreign_key = {
            kind => 'values',
            association => $name,
            value_field => $value_field,
            label_field => $label_field,
        };
        $source->{columns}{$owner_key}{foreign_key} = dclone($foreign_key);
        $source->{columns}{$owner_key}{options} = \@options;
        my $write_field = ref($writes) eq 'HASH'
            && ref($writes->{fields}) eq 'HASH'
                ? $writes->{fields}{$owner_key} : undef;
        $write_field->{foreign_key} = dclone($foreign_key)
            if ref($write_field) eq 'HASH' && $write_field->{insertable};
    }
}

sub _canonical_associations {
    my ($relation, $schemas, $joins, $strict, $prefix) = @_;
    my $source_associations = $relation->{associations} // {};
    _object($source_associations, $prefix eq '' ? 'source associations' : "schema $prefix associations");
    my %associations;
    for my $name (keys %$source_associations) {
        my $association = $source_associations->{$name};
        my $path = $prefix eq '' ? "$name" : "$prefix.$name";
        _object($association, "association $path");
        _reject_unknown($association, \%ASSOCIATION, "association $path") if $strict;
        _required_key($association, 'queryable', "association $path");
        my $queryable = $association->{queryable};
        Selecto::Error->throw('invalid_domain', "missing schema $queryable")
            unless exists $schemas->{$queryable};
        my $target = $schemas->{$queryable};
        _object($target, "schema $queryable");
        _reject_unknown($target, \%RELATION, "schema $queryable") if $strict;
        my $join = _canonical_join($joins, $path, $name);
        _object($join, "join $path");
        _reject_unknown($join, \%JOIN, "join $path") if $strict;
        for my $key (qw(owner_key related_key)) {
            _required_key($association, $key, "association $path");
        }
        my $has_table = exists $target->{source_table};
        my $has_values = exists $target->{values};
        Selecto::Error->throw(
            'invalid_domain', "schema $queryable must declare exactly one of source_table or values",
        ) unless $has_table != $has_values;
        my $target_fields = _canonical_fields($target);
        my $values = $has_values
            ? _canonical_relation_values($target, "schema $queryable")
            : undef;
        my $join_mode = lc(_required_string($join->{type} // 'left', 'join type'));
        Selecto::Error->throw('invalid_domain', "unsupported join type $join_mode")
            unless $join_mode eq 'left' || $join_mode eq 'inner'
                || $join_mode eq 'star_dimension';
        my $target_primary_key = $target->{primary_key} // 'id';
        my $display_fallback;
        if (exists $join->{display_fallback}) {
            Selecto::Error->throw(
                'invalid_domain',
                'display fallback is available only for star dimensions',
                {association => $path},
            ) unless $join_mode eq 'star_dimension';
            $display_fallback = lc(_required_string(
                $join->{display_fallback}, 'star dimension display fallback'
            ));
            Selecto::Error->throw(
                'invalid_domain',
                'star dimension display fallback must be dimension_key',
                {association => $path},
            ) unless $display_fallback eq 'dimension_key';
            my $display_field = $join->{display_field} // 'name';
            my $owner_column = ref($relation->{columns}) eq 'HASH'
                ? $relation->{columns}{$association->{owner_key}} : undef;
            my $display_column = ref($target->{columns}) eq 'HASH'
                ? $target->{columns}{$display_field} : undef;
            my $owner_type = ref($owner_column) eq 'HASH'
                ? $owner_column->{type} : undef;
            my $display_type = ref($display_column) eq 'HASH'
                ? $display_column->{type} : undef;
            Selecto::Error->throw(
                'invalid_domain',
                'star dimension display fallback requires matching display and key types',
                {association => $path},
            ) unless defined($owner_type) && defined($display_type)
                && $owner_type eq $display_type;
        }
        my $cardinality = $association->{cardinality};
        $cardinality = $association->{related_key} eq $target_primary_key ? 'one' : 'many'
            unless defined $cardinality;
        $associations{$name} = Selecto::Domain::Association->new(
            name => $name,
            value => {
                table => $target->{source_table} // "__selecto_values_$queryable",
                fields => $target_fields,
                (defined($values) ? (
                    values => $values,
                    value_fields => [@{$target->{fields}}],
                ) : ()),
                owner_key => $association->{owner_key},
                related_key => $association->{related_key},
                target_primary_key => $target_primary_key,
                cardinality => $cardinality,
                join_type => $join_mode eq 'star_dimension' ? 'left' : $join_mode,
                join_mode => $join_mode,
                queryable => "$queryable",
                (exists($association->{source_scope_key}) ? (
                    source_scope_key => $association->{source_scope_key},
                    target_scope_key => $association->{target_scope_key},
                ) : ()),
                (exists($association->{through}) ? (through => $association->{through}) : ()),
                (exists($association->{where}) ? (where => $association->{where}) : ()),
                (exists($association->{join_strategy}) ? (
                    join_strategy => $association->{join_strategy},
                ) : ()),
                ($join_mode eq 'star_dimension' ? (
                    display_field => $join->{display_field} // 'name',
                    dimension_key => $join->{dimension_key} // $association->{owner_key},
                    display_name => $join->{name} // $name,
                    (defined($display_fallback)
                        ? (display_fallback => $display_fallback) : ()),
                ) : ()),
            },
        );
    }
    return \%associations;
}

sub _canonical_join {
    my ($joins, $path, $name) = @_;
    return $joins->{$path} if ref($joins->{$path}) eq 'HASH';
    return $joins->{$name} if $path eq $name && ref($joins->{$name}) eq 'HASH';

    my $current = $joins;
    my @segments = split /\./, $path;
    for my $index (0 .. $#segments) {
        my $segment = $segments[$index];
        return {} unless ref($current) eq 'HASH'
            && ref($current->{$segment}) eq 'HASH';
        my $join = $current->{$segment};
        return $join if $index == $#segments;
        $current = $join->{joins};
    }
    return {};
}

sub _canonical_relation_values {
    my ($relation, $label) = @_;
    my $rows = $relation->{values};
    Selecto::Error->throw('invalid_domain', "$label values must be a non-empty array")
        unless ref($rows) eq 'ARRAY' && @$rows;
    my %expected = map { $_ => 1 } @{$relation->{fields}};
    my @normalized;
    for my $index (0 .. $#$rows) {
        my $row = $rows->[$index];
        _object($row, "$label values row $index");
        my @unknown = sort grep { !$expected{$_} } keys %$row;
        Selecto::Error->throw(
            'invalid_domain', "$label values row has unknown fields",
            {row => $index, fields => \@unknown},
        ) if @unknown;
        my @missing = grep { !exists $row->{$_} } @{$relation->{fields}};
        Selecto::Error->throw(
            'invalid_domain', "$label values row is missing fields",
            {row => $index, fields => \@missing},
        ) if @missing;
        my %copy;
        for my $field (@{$relation->{fields}}) {
            my $value = $row->{$field};
            Selecto::Error->throw(
                'invalid_domain', "$label values must contain only scalar literals",
                {row => $index, field => $field},
            ) if ref($value) && !JSON::PP::is_bool($value);
            $copy{$field} = JSON::PP::is_bool($value) ? ($value ? 1 : 0) : $value;
        }
        push @normalized, \%copy;
    }
    return \@normalized;
}

sub _canonical_fields {
    my ($relation) = @_;
    _required_key($relation, 'fields', 'relation');
    _required_key($relation, 'columns', 'relation');
    Selecto::Error->throw('invalid_domain', 'relation fields must be an array')
        unless ref($relation->{fields}) eq 'ARRAY' && @{$relation->{fields}};
    _object($relation->{columns}, 'relation columns');
    my %result;
    for my $field (@{$relation->{fields}}) {
        Selecto::Error->throw('invalid_domain', 'relation field names must be strings') if ref($field);
        Selecto::Error->throw('invalid_domain', "missing column $field")
            unless exists $relation->{columns}{$field};
        my $column = $relation->{columns}{$field};
        _object($column, "column $field");
        _required_key($column, 'type', "column $field");
        require Selecto::Analytics::UnitRegistry;
        $column = Selecto::Analytics::UnitRegistry->normalize_column_metadata(
            $column, "column $field",
        );
        if (exists $column->{text_case}) {
            my $text_case = lc(_required_string(
                $column->{text_case}, "column $field text_case",
            ));
            Selecto::Error->throw(
                'invalid_domain',
                'column text_case must be uppercase or lowercase',
                {field => $field},
            ) unless $text_case eq 'uppercase' || $text_case eq 'lowercase';
            Selecto::Error->throw(
                'invalid_domain',
                'column text_case is available only for string fields',
                {field => $field},
            ) unless ($column->{type} // '') eq 'string';
            $column->{text_case} = $text_case;
        }
        $relation->{columns}{$field} = $column;
        $result{$field} = $column->{type};
    }
    return \%result;
}

sub _validate_computed_columns {
    my ($source, $associations) = @_;
    my %predicate_dependencies;
    for my $field (@{$source->{fields} // []}) {
        my $column = $source->{columns}{$field};
        next unless ref($column) eq 'HASH' && exists $column->{computed};
        my $computed = $column->{computed};
        _object($computed, "computed column $field");
        my $kind = _required_string($computed->{kind}, "computed column $field kind");
        my %allowed = map { $_ => 1 } $kind eq 'predicate'
            ? qw(kind expression) : qw(kind association);
        _reject_unknown($computed, \%allowed, "computed column $field");
        Selecto::Error->throw('invalid_domain', "unsupported computed column kind $kind")
            unless $kind eq 'association_exists' || $kind eq 'predicate';
        if ($kind eq 'predicate') {
            Selecto::Error->throw(
                'invalid_domain', 'predicate computed columns must be boolean', {field => $field},
            ) unless ($column->{type} // '') eq 'boolean';
            Selecto::Error->throw(
                'invalid_domain', 'predicate computed columns require an expression', {field => $field},
            ) unless exists $computed->{expression};
            require Selecto::Expression;
            my $expression;
            my $ok = eval {
                $expression = Selecto::Expression->from_filter_ast($computed->{expression});
                1;
            };
            Selecto::Error->throw(
                'invalid_domain', 'computed predicate expression is invalid', {field => $field},
            ) unless $ok;
            my @dependencies = _computed_predicate_fields($expression);
            for my $dependency (@dependencies) {
                Selecto::Error->throw(
                    'invalid_domain', 'computed predicates may reference only root domain fields',
                    {field => $field, dependency => $dependency},
                ) if $dependency =~ /\./;
                Selecto::Error->throw(
                    'invalid_domain', 'computed predicate references an unknown field',
                    {field => $field, dependency => $dependency},
                ) unless exists $source->{columns}{$dependency};
            }
            $predicate_dependencies{$field} = \@dependencies;
            next;
        }
        my $association = _identifier(
            $computed->{association}, "computed column $field association"
        );
        Selecto::Error->throw(
            'invalid_domain', 'computed column association is not governed',
            {field => $field, association => $association},
        ) unless exists $associations->{$association};
        Selecto::Error->throw(
            'invalid_domain', 'association-exists computed columns require a direct association',
            {field => $field, association => $association},
        ) if $associations->{$association}->through;
    }
    _validate_computed_predicate_cycles(\%predicate_dependencies, $source);
}

sub _validate_action_eligibility {
    my ($contract, $source) = @_;
    my $actions = $contract->{actions} // {};
    _object($actions, 'actions');
    for my $action_id (sort keys %$actions) {
        my $action = $actions->{$action_id};
        _object($action, "action $action_id");
        if (exists $action->{inputs}) {
            my $inputs = $action->{inputs};
            _object($inputs, "action $action_id inputs");
            for my $input_id (sort keys %$inputs) {
                _identifier($input_id, "action $action_id input");
                my $input = $inputs->{$input_id};
                _object($input, "action $action_id input $input_id");
                if (exists $input->{type}) {
                    _nonblank_string($input->{type}, "action $action_id input $input_id type");
                }
                if (exists $input->{required}) {
                    my $required = $input->{required};
                    my $boolean = JSON::PP::is_bool($required)
                        || (!ref($required) && "$required" =~ /\A(?:0|1)\z/);
                    Selecto::Error->throw(
                        'invalid_domain', "action $action_id input $input_id required must be boolean",
                    ) unless $boolean;
                }
            }
        }
        next unless exists $action->{selection};
        my $selection = $action->{selection};
        _object($selection, "action $action_id selection");
        my $mode = $selection->{mode} // 'rows';
        Selecto::Error->throw(
            'invalid_domain', "action $action_id selection mode must be rows or groups",
        ) if ref($mode) || "$mode" !~ /\A(?:rows|groups)\z/;
        for my $key (qw(min_rows max_rows)) {
            next unless exists $selection->{$key};
            my $value = $selection->{$key};
            Selecto::Error->throw(
                'invalid_domain', "action $action_id selection $key must be an integer from 1 to 1000",
            ) if ref($value) || "$value" !~ /\A\d+\z/
                || $value < 1 || $value > 1000;
        }
        Selecto::Error->throw(
            'invalid_domain', "action $action_id selection max_rows must be at least min_rows",
        ) if exists($selection->{min_rows}) && exists($selection->{max_rows})
            && $selection->{max_rows} < $selection->{min_rows};
        my $presentation = $selection->{presentation} // 'toolbar';
        Selecto::Error->throw(
            'invalid_domain',
            "action $action_id selection presentation must be toolbar, row_dialog, or row_inline",
        ) if ref($presentation)
            || "$presentation" !~ /\A(?:toolbar|row_dialog|row_inline)\z/;
        if ($presentation ne 'toolbar') {
            Selecto::Error->throw(
                'invalid_domain',
                "action $action_id $presentation presentation requires rows mode and max_rows 1",
            ) unless $mode eq 'rows'
                && exists($selection->{max_rows}) && $selection->{max_rows} == 1;
        }
        next unless exists $selection->{eligibility_field};
        my $field = _identifier(
            $selection->{eligibility_field}, "action $action_id eligibility field",
        );
        my $column = $source->{columns}{$field};
        Selecto::Error->throw(
            'invalid_domain', 'eligibility_field must name a boolean root field',
            {action => $action_id, field => $field},
        ) unless ref($column) eq 'HASH' && ($column->{type} // '') eq 'boolean';
    }
}

sub _computed_predicate_fields {
    my ($expression) = @_;
    return () unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $arguments = $expression->arguments;
    return ("$arguments->[0]") if $expression->kind eq 'field';
    my @fields;
    for my $argument (@$arguments) {
        if (blessed($argument) && $argument->isa('Selecto::Expression')) {
            push @fields, _computed_predicate_fields($argument);
        } elsif (ref($argument) eq 'ARRAY') {
            push @fields, map { _computed_predicate_fields($_) } @$argument;
        }
    }
    my %seen;
    return grep { !$seen{$_}++ } @fields;
}

sub _validate_computed_predicate_cycles {
    my ($dependencies, $source) = @_;
    my (%visiting, %visited);
    my $visit;
    $visit = sub {
        my ($field) = @_;
        Selecto::Error->throw(
            'invalid_domain', 'computed predicate dependency cycle detected', {field => $field},
        ) if $visiting{$field};
        return if $visited{$field}++;
        local $visiting{$field} = 1;
        for my $dependency (@{$dependencies->{$field} // []}) {
            next unless exists $dependencies->{$dependency};
            $visit->($dependency);
        }
    };
    $visit->($_) for sort keys %$dependencies;
}

sub _expression_value {
    my ($expression) = @_;
    return undef unless defined $expression;
    return $expression unless blessed($expression) && $expression->isa('Selecto::Expression');
    return {
        kind => $expression->kind,
        arguments => [map {
            ref($_) eq 'ARRAY'
                ? [map { _expression_value($_) } @$_]
                : _expression_value($_)
        } @{$expression->arguments}],
    };
}

sub resolve {
    my ($self, $path) = @_;
    my @segments = split /\./, "$path", -1;
    if (@segments == 1) {
        my $field = $segments[0];
        Selecto::Error->throw('unknown_field', "unknown field $path")
            unless exists $self->{fields}{$field};
        return {
            association => undef, associations => [], association_path => undef,
            field => $field, type => $self->{fields}{$field},
        };
    }
    my $field = pop @segments;
    my $resolved = $self->resolve_association(join('.', @segments));
    my $association = $resolved->{association};
    my $fields = $association->fields;
    Selecto::Error->throw('unknown_field', "unknown field $path")
        unless exists $fields->{$field};
    return {
        association => $association,
        associations => $resolved->{associations},
        association_path => join('.', @segments),
        field => $field,
        type => $fields->{$field},
    };
}

sub resolve_association {
    my ($self, $path) = @_;
    my @segments = split /\./, defined($path) ? "$path" : '', -1;
    Selecto::Error->throw('invalid_field', 'association path must not be empty')
        unless @segments && !grep { $_ eq '' } @segments;
    my $associations = $self->{associations};
    my @resolved;
    my $prefix = '';
    for my $name (@segments) {
        my $full_path = $prefix eq '' ? $name : "$prefix.$name";
        my $association = $associations->{$name};
        Selecto::Error->throw('unknown_association', "unknown association $full_path")
            unless $association;
        push @resolved, $association;
        $prefix = $full_path;
        my $queryable = $association->queryable;
        if (defined($queryable) && ref($self->{canonical_schemas}) eq 'HASH') {
            my $relation = $self->{canonical_schemas}{$queryable};
            Selecto::Error->throw('invalid_domain', "missing schema $queryable") unless $relation;
            $associations = _canonical_associations(
                $relation,
                $self->{canonical_schemas},
                $self->{canonical_joins} // {},
                1,
                $prefix,
            );
        } else {
            $associations = $association->associations;
        }
    }
    return {
        association => $resolved[-1],
        associations => \@resolved,
        association_path => $prefix,
    };
}

sub compose {
    my ($invocant, @args) = @_;
    my ($base, @overlays) = ref($invocant) ? ($invocant, @args) : @args;
    require Selecto::Domain::Overlay;
    return Selecto::Domain::Overlay->compose($base, @overlays);
}

sub as_contract {
    my ($self) = @_;
    return dclone($self->{contract}) if defined $self->{contract};
    Selecto::Error->throw(
        'invalid_domain_overlay',
        'runtime predicate domains cannot be converted to portable overlay contracts',
    ) if defined $self->{required_predicate};

    my %columns = map {
        $_ => {type => $self->{fields}{$_}}
    } sort keys %{$self->{fields}};
    my (%schemas, %joins);
    my $source_associations = _portable_associations(
        $self->{associations}, [], \%schemas, \%joins,
    );

    my $contract = {
        schema_version => 1,
        name => $self->{name},
        source => {
            source_table => $self->{table},
            primary_key => $self->{primary_key},
            fields => [sort keys %{$self->{fields}}],
            columns => \%columns,
            associations => $source_associations,
            (defined($self->{tenant_field}) ? (tenant_field => $self->{tenant_field}) : ()),
        },
        schemas => \%schemas,
        joins => \%joins,
    };
    $contract->{components} = dclone($self->{components}) if keys %{$self->{components}};
    $contract->{query_library} = dclone($self->{query_library})
        if keys %{$self->{query_library}};
    $contract->{co_domains} = dclone($self->{co_domains})
        if keys %{$self->{co_domains}};
    $contract->{domain_dependencies} = dclone($self->{domain_dependencies})
        if @{$self->{domain_dependencies}};
    $contract->{operations} = dclone($self->{operations})
        if keys %{$self->{operations}};
    $contract->{experiences} = dclone($self->{experiences})
        if keys %{$self->{experiences}};
    return $contract;
}

sub _portable_associations {
    my ($associations, $parent_path, $schemas, $joins) = @_;
    my %references;
    for my $name (sort keys %$associations) {
        my $association = $associations->{$name};
        my @path = (@$parent_path, $name);
        my $path = join('.', @path);
        my $schema_name = _portable_schema_name(@path);
        my $fields = $association->fields;
        my $target_primary_key = $association->target_primary_key
            // (exists($fields->{id}) ? 'id' : (sort keys %$fields)[0]);
        my %target_columns = map {
            $_ => {type => $fields->{$_}}
        } sort keys %$fields;
        $schemas->{$schema_name} = {
            (defined($association->values)
                ? (values => $association->values)
                : (source_table => $association->table)),
            primary_key => $target_primary_key,
            fields => [sort keys %$fields],
            columns => \%target_columns,
            associations => _portable_associations(
                $association->associations, \@path, $schemas, $joins,
            ),
        };
        $references{$name} = {
            queryable => $schema_name,
            owner_key => $association->owner_key,
            related_key => $association->related_key,
            cardinality => $association->cardinality,
            (defined($association->join_strategy) ? (
                join_strategy => $association->join_strategy,
            ) : ()),
            (defined($association->source_scope_key) ? (
                source_scope_key => $association->source_scope_key,
                target_scope_key => $association->target_scope_key,
            ) : ()),
            (defined($association->through) ? (through => $association->through) : ()),
            (keys(%{$association->where}) ? (where => $association->where) : ()),
        };
        $joins->{$path} = {
            type => $association->join_mode,
            ($association->join_mode eq 'star_dimension' ? (
                name => $association->display_name,
                display_field => $association->display_field,
                dimension_key => $association->dimension_key,
                (defined($association->display_fallback) ? (
                    display_fallback => $association->display_fallback,
                ) : ()),
            ) : ()),
        };
    }
    return \%references;
}

sub _portable_schema_name {
    return 'q' . join('', map { '_' . length($_) . '_' . $_ } @_);
}

sub field_metadata {
    my ($self, $path) = @_;
    my $contract = $self->{contract};
    return {} unless ref($contract) eq 'HASH';
    my @segments = split /\./, "$path", -1;
    my $column;
    if (@segments == 1) {
        $column = $contract->{source}{columns}{$segments[0]}
            if ref($contract->{source}) eq 'HASH'
            && ref($contract->{source}{columns}) eq 'HASH';
    }
    elsif (@segments == 2) {
        my ($association, $field) = @segments;
        my $association_spec = $contract->{source}{associations}{$association}
            if ref($contract->{source}) eq 'HASH'
            && ref($contract->{source}{associations}) eq 'HASH';
        my $queryable = ref($association_spec) eq 'HASH'
            ? $association_spec->{queryable} : undef;
        $column = $contract->{schemas}{$queryable}{columns}{$field}
            if defined($queryable)
            && ref($contract->{schemas}) eq 'HASH'
            && ref($contract->{schemas}{$queryable}) eq 'HASH'
            && ref($contract->{schemas}{$queryable}{columns}) eq 'HASH';
    }
    return ref($column) eq 'HASH' ? dclone($column) : {};
}

sub values_foreign_keys {
    my ($self) = @_;
    my %foreign_keys;
    for my $name (sort keys %{$self->{associations}}) {
        my $association = $self->{associations}{$name};
        my $values = $association->values;
        next unless defined($values)
            && $association->cardinality eq 'one'
            && !defined($association->through);
        my $field = $association->owner_key;
        $foreign_keys{$field} = {
            association => $name,
            display_name => $association->join_mode eq 'star_dimension'
                ? $association->display_name : $name,
            value_field => $association->related_key,
            values => [
                map { $_->{$association->related_key} } @$values
            ],
        };
    }
    return dclone(\%foreign_keys);
}

sub normalize_field_value {
    my ($self, $path, $value) = @_;
    return $value unless defined($value) && !ref($value);
    my $text_case = $self->field_metadata($path)->{text_case};
    return uc("$value") if defined($text_case) && $text_case eq 'uppercase';
    return lc("$value") if defined($text_case) && $text_case eq 'lowercase';
    return $value;
}

sub normalize_write_assignments {
    my ($self, $assignments) = @_;
    return {} unless ref($assignments) eq 'HASH';
    return {
        map { $_ => $self->normalize_field_value($_, $assignments->{$_}) }
            keys %$assignments
    };
}

sub field_unit {
    my ($self, $path) = @_;
    require Selecto::Analytics::UnitRegistry;
    return Selecto::Analytics::UnitRegistry->column_unit(
        $self->field_metadata($path),
    );
}

sub field_behavior {
    my ($self, $path) = @_;
    require Selecto::Analytics::UnitRegistry;
    return Selecto::Analytics::UnitRegistry->column_behavior(
        $self->field_metadata($path),
    );
}

sub field_is_public {
    my ($self, $path) = @_;
    my $metadata = $self->field_metadata($path);
    return $metadata->{internal} ? 0 : 1;
}

sub _normalize_fields {
    my ($value, $label) = @_;
    _object($value, $label);
    Selecto::Error->throw('invalid_domain', "$label must not be empty") unless keys %$value;
    my %fields;
    for my $name (keys %$value) {
        $fields{_identifier($name, 'field')} = _required_string($value->{$name}, "$label type");
    }
    return \%fields;
}

sub _normalize_components {
    my ($value) = @_;
    return {} unless defined $value;
    _object($value, 'components');
    _reject_unknown($value, \%COMPONENTS, 'components');
    my %components;
    if (exists $value->{query_params}) {
        my $query_params = $value->{query_params};
        my $boolean = JSON::PP::is_bool($query_params)
            || (!ref($query_params) && "$query_params" =~ /\A(?:0|1)\z/);
        Selecto::Error->throw('invalid_domain', 'components query_params must be a boolean')
            unless $boolean;
        $components{query_params} = $query_params ? 1 : 0;
    }
    if (exists $value->{filter_choices}) {
        my $filters = $value->{filter_choices};
        _object($filters, 'components filter_choices');
        my %normalized;
        for my $path (sort keys %$filters) {
            Selecto::Error->throw('invalid_domain', 'filter choice field path is invalid')
                unless $path =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
            my $spec = $filters->{$path};
            _object($spec, "filter choices for $path");
            _reject_unknown($spec, {label => 1, choices => 1, conditional => 1,
                picker_hidden => 1}, "filter choices for $path");
            my $label = _nonblank_string($spec->{label}, "filter choices for $path label");
            my $choices = $spec->{choices};
            Selecto::Error->throw('invalid_domain', "filter choices for $path need 1-500 items")
                unless ref($choices) eq 'ARRAY' && @$choices >= 1 && @$choices <= 500;
            my (%seen, @items);
            for my $choice (@$choices) {
                _object($choice, "filter choice for $path");
                _reject_unknown($choice, {value => 1, label => 1}, "filter choice for $path");
                my $item_value = _nonblank_string($choice->{value}, "filter choice value for $path");
                Selecto::Error->throw('invalid_domain', "filter choice value for $path cannot contain a comma")
                    if $item_value =~ /,/;
                Selecto::Error->throw('invalid_domain', "duplicate filter choice value for $path")
                    if $seen{$item_value}++;
                push @items, {
                    value => $item_value,
                    label => _nonblank_string($choice->{label}, "filter choice label for $path"),
                };
            }
            my %normalized_spec = (label => $label, choices => \@items);
            if (exists $spec->{conditional}) {
                my $conditional = $spec->{conditional};
                _object($conditional, "conditional filter choices for $path");
                _reject_unknown($conditional, {map { $_ => 1 }
                    qw(when_field present_field absent_field)},
                    "conditional filter choices for $path");
                for my $key (qw(when_field present_field absent_field)) {
                    my $field = _nonblank_string($conditional->{$key},
                        "conditional filter choices for $path $key");
                    Selecto::Error->throw('invalid_domain',
                        "conditional filter choices for $path $key is not a field path")
                        unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
                }
                $normalized_spec{conditional} = {%$conditional};
            }
            if (exists $spec->{picker_hidden}) {
                my $hidden = $spec->{picker_hidden};
                Selecto::Error->throw('invalid_domain',
                    "filter choices for $path picker_hidden must be a boolean")
                    unless JSON::PP::is_bool($hidden)
                        || (!ref($hidden) && "$hidden" =~ /\A(?:0|1)\z/);
                $normalized_spec{picker_hidden} = $hidden ? 1 : 0;
            }
            $normalized{$path} = \%normalized_spec;
        }
        $components{filter_choices} = \%normalized;
    }
    if (exists $value->{filter_picker_hidden_paths}) {
        my $paths = $value->{filter_picker_hidden_paths};
        Selecto::Error->throw('invalid_domain',
            'components filter_picker_hidden_paths must be an array')
            unless ref($paths) eq 'ARRAY';
        my @paths;
        for my $path (@$paths) {
            Selecto::Error->throw('invalid_domain',
                'filter picker hidden path must be a field path or dotted prefix')
                unless defined($path) && !ref($path)
                    && $path =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.?\z/;
            push @paths, "$path";
        }
        $components{filter_picker_hidden_paths} = \@paths;
    }
    if (exists $value->{picker_visible_id_paths}) {
        my $paths = $value->{picker_visible_id_paths};
        Selecto::Error->throw('invalid_domain',
            'components picker_visible_id_paths must be an array')
            unless ref($paths) eq 'ARRAY';
        my @paths;
        for my $path (@$paths) {
            Selecto::Error->throw('invalid_domain',
                'picker visible ID path must be a field path')
                unless defined($path) && !ref($path)
                    && $path =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
            push @paths, "$path";
        }
        $components{picker_visible_id_paths} = \@paths;
    }
    return \%components;
}

sub _validate_conditional_filter_choices {
    my ($domain) = @_;
    my $choices = $domain->components->{filter_choices} // {};
    for my $path (sort keys %$choices) {
        my $conditional = $choices->{$path}{conditional};
        next unless ref($conditional) eq 'HASH';
        Selecto::Error->throw('invalid_domain',
            "conditional filter $path conflicts with a domain field")
            if eval { $domain->resolve($path) };
        my %resolved;
        for my $key (qw(when_field present_field absent_field)) {
            my $field = $conditional->{$key};
            my $entry = eval { $domain->resolve($field) };
            Selecto::Error->throw('invalid_domain',
                "conditional filter $path references unavailable $key $field")
                unless $entry;
            Selecto::Error->throw('invalid_domain',
                "conditional filter $path cannot use a to-many $key")
                if grep { $_->cardinality eq 'many' }
                    @{$entry->{associations} // []};
            $resolved{$key} = $entry;
        }
        Selecto::Error->throw('invalid_domain',
            "conditional filter $path must compare the same field type")
            unless $resolved{present_field}{type} eq $resolved{absent_field}{type};
    }
}

sub _validate_picker_visible_id_paths {
    my ($domain) = @_;
    for my $path (@{$domain->components->{picker_visible_id_paths} // []}) {
        Selecto::Error->throw('invalid_domain',
            "picker visible ID path $path is not a domain field")
            unless eval { $domain->resolve($path) };
    }
}

sub _normalize_query_library {
    my ($value) = @_;
    return {} unless defined $value;
    _object($value, 'query_library');
    my %known = map { $_ => 1 } qw(segments projections orderings views segment_picker_groups);
    _reject_unknown($value, \%known, 'query_library');
    my %library;
    for my $registry (qw(segments projections orderings views)) {
        my $definitions = $value->{$registry} // {};
        _object($definitions, "query_library $registry");
        $library{$registry} = dclone($definitions);
    }
    if (exists $value->{segment_picker_groups}) {
        my $groups = $value->{segment_picker_groups};
        _object($groups, 'query_library segment_picker_groups');
        my %used_segment;
        for my $id (sort keys %$groups) {
            Selecto::Error->throw('invalid_domain', 'segment picker group ID must use letters, digits, or underscores')
                unless $id =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
            my $group = $groups->{$id};
            _object($group, "segment picker group $id");
            _reject_unknown($group, {map { $_ => 1 } qw(label description off_label choices)}, "segment picker group $id");
            _nonblank_string($group->{label}, "segment picker group $id label");
            Selecto::Error->throw('invalid_domain', "segment picker group $id description must be a string")
                if exists($group->{description}) && (!defined($group->{description}) || ref($group->{description}));
            _nonblank_string($group->{off_label}, "segment picker group $id off_label")
                if exists $group->{off_label};
            my $choices = $group->{choices};
            Selecto::Error->throw('invalid_domain', "segment picker group $id needs at least two choices")
                unless ref($choices) eq 'ARRAY' && @$choices >= 2;
            for my $choice (@$choices) {
                _object($choice, "segment picker group $id choice");
                _reject_unknown($choice, {segment => 1, label => 1}, "segment picker group $id choice");
                my $segment = _nonblank_string($choice->{segment}, "segment picker group $id choice segment");
                _nonblank_string($choice->{label}, "segment picker group $id choice label");
                Selecto::Error->throw('invalid_domain', "segment picker group $id references unknown segment $segment")
                    unless ref($library{segments}{$segment}) eq 'HASH';
                Selecto::Error->throw('invalid_domain', "segment $segment belongs to more than one picker group")
                    if $used_segment{$segment}++;
            }
        }
        $library{segment_picker_groups} = dclone($groups);
    }
    return \%library;
}

sub _normalize_co_domains {
    my ($value) = @_;
    return {} unless defined $value;
    _object($value, 'co_domains');
    my %co_domains;
    my %known = map { $_ => 1 } qw(
        domain view segments projection ordering parameters search result
    );
    my %search_known = map { $_ => 1 } qw(fields configuration mode rank);
    my %result_known = map { $_ => 1 } qw(value_field label_field description_fields);
    for my $raw_id (sort keys %$value) {
        my $id = _identifier($raw_id, 'co-domain');
        my $definition = $value->{$raw_id};
        _object($definition, "co-domain $id");
        _reject_unknown($definition, \%known, "co-domain $id");
        my %normalized = (
            domain => _identifier($definition->{domain}, "co-domain $id domain"),
        );
        for my $key (qw(view projection ordering)) {
            next unless exists $definition->{$key};
            $normalized{$key} = _identifier(
                $definition->{$key}, "co-domain $id $key",
            );
        }
        if (exists $definition->{segments}) {
            Selecto::Error->throw(
                'invalid_domain', "co-domain $id segments must be an array",
            ) unless ref($definition->{segments}) eq 'ARRAY';
            $normalized{segments} = [map {
                _identifier($_, "co-domain $id segment")
            } @{$definition->{segments}}];
        }
        Selecto::Error->throw(
            'invalid_domain', "co-domain $id requires exactly one of view or projection",
        ) unless (defined($normalized{view}) ? 1 : 0)
            + (defined($normalized{projection}) ? 1 : 0) == 1;
        Selecto::Error->throw(
            'invalid_domain', "co-domain $id view cannot be combined with segments or ordering",
        ) if defined($normalized{view})
            && (exists($normalized{segments}) || defined($normalized{ordering}));
        if (exists $definition->{parameters}) {
            _object($definition->{parameters}, "co-domain $id parameters");
            $normalized{parameters} = dclone($definition->{parameters});
        }

        my $search = $definition->{search};
        _object($search, "co-domain $id search");
        _reject_unknown($search, \%search_known, "co-domain $id search");
        Selecto::Error->throw(
            'invalid_domain', "co-domain $id search fields must be a non-empty array",
        ) unless ref($search->{fields}) eq 'ARRAY' && @{$search->{fields}};
        my %normalized_search = (
            fields => [map {
                my $field = _required_string($_, "co-domain $id search field");
                Selecto::Error->throw('invalid_domain', "co-domain $id search field is invalid")
                    unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
                $field;
            } @{$search->{fields}}],
            configuration => lc(_nonblank_string(
                $search->{configuration} // 'simple',
                "co-domain $id search configuration",
            )),
            mode => lc(_required_string(
                $search->{mode} // 'plain', "co-domain $id search mode",
            )),
        );
        Selecto::Error->throw('invalid_domain', "co-domain $id search mode is not available")
            unless $normalized_search{mode} =~ /\A(?:plain|phrase|websearch|prefix)\z/;
        if (exists $search->{rank}) {
            my $rank = $search->{rank};
            my $boolean = JSON::PP::is_bool($rank)
                || (!ref($rank) && "$rank" =~ /\A(?:0|1)\z/);
            Selecto::Error->throw(
                'invalid_domain', "co-domain $id search rank must be a boolean",
            ) unless $boolean;
            $normalized_search{rank} = $rank ? 1 : 0;
        }
        $normalized{search} = \%normalized_search;

        my $result = $definition->{result};
        _object($result, "co-domain $id result");
        _reject_unknown($result, \%result_known, "co-domain $id result");
        my %normalized_result;
        for my $key (qw(value_field label_field)) {
            my $field = _required_string($result->{$key}, "co-domain $id result $key");
            Selecto::Error->throw('invalid_domain', "co-domain $id result $key is invalid")
                unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
            $normalized_result{$key} = $field;
        }
        my $description_fields = $result->{description_fields} // [];
        Selecto::Error->throw(
            'invalid_domain', "co-domain $id result description_fields must be an array",
        ) unless ref($description_fields) eq 'ARRAY';
        $normalized_result{description_fields} = [map {
            my $field = _required_string($_, "co-domain $id description field");
            Selecto::Error->throw('invalid_domain', "co-domain $id description field is invalid")
                unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
            $field;
        } @$description_fields];
        $normalized{result} = \%normalized_result;
        $co_domains{$id} = \%normalized;
    }
    return \%co_domains;
}

sub _normalize_domain_dependencies {
    my ($value) = @_;
    return [] unless defined $value;
    Selecto::Error->throw('invalid_domain', 'domain_dependencies must be an array')
        unless ref($value) eq 'ARRAY';
    my %known = map { $_ => 1 } qw(
        provider contract accepts expected_fingerprint uses satisfies
    );
    my %uses_known = map { $_ => 1 } qw(fields filters query_members);
    my @dependencies;
    for my $index (0 .. $#$value) {
        my $dependency = $value->[$index];
        _object($dependency, "domain dependency $index");
        _reject_unknown($dependency, \%known, "domain dependency $index");
        _nonblank_string($dependency->{provider}, "domain dependency $index provider");
        _nonblank_string($dependency->{contract}, "domain dependency $index contract");
        for my $key (qw(accepts expected_fingerprint)) {
            _nonblank_string($dependency->{$key}, "domain dependency $index $key")
                if exists $dependency->{$key};
        }
        if (exists $dependency->{uses}) {
            _object($dependency->{uses}, "domain dependency $index uses");
            _reject_unknown($dependency->{uses}, \%uses_known, "domain dependency $index uses");
            _identifier_list(
                $dependency->{uses}{$_}, "domain dependency $index uses $_",
            ) for keys %{$dependency->{uses}};
        }
        _identifier_list($dependency->{satisfies}, "domain dependency $index satisfies")
            if exists $dependency->{satisfies};
        push @dependencies, dclone($dependency);
    }
    return \@dependencies;
}

sub _normalize_consumer_registry {
    my ($value, $section) = @_;
    return {} unless defined $value;
    _object($value, $section);
    my %registry;
    for my $id (keys %$value) {
        _nonblank_string($id, "$section id");
        _object($value->{$id}, "$section entry $id");
        $registry{$id} = dclone($value->{$id});
    }
    return \%registry;
}

sub _identifier_list {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_domain', "$label must be an array")
        unless ref($value) eq 'ARRAY';
    _nonblank_string($_, "$label entry") for @$value;
}

sub _validate_detail_actions {
    my ($domain, $value) = @_;
    return {} unless defined $value;
    _object($value, 'detail_actions');
    my %actions;
    for my $raw_id (sort keys %$value) {
        my $id = _identifier($raw_id, 'detail action');
        my $action = $value->{$raw_id};
        _object($action, "detail action $id");
        _reject_unknown($action, \%DETAIL_ACTION, "detail action $id");
        my $name = _required_string($action->{name}, "detail action $id name");
        my $type = lc _required_string($action->{type}, "detail action $id type");
        Selecto::Error->throw(
            'invalid_domain', "unsupported detail action type $type",
            {action => $id},
        ) unless $type eq 'external_link' || $type eq 'iframe_modal'
            || $type eq 'record_editor';
        my $description;
        if (defined($action->{description})) {
            $description = _required_string(
                $action->{description}, "detail action $id description",
            );
        }
        my $capability;
        if (defined($action->{capability})) {
            $capability = _required_string(
                $action->{capability}, "detail action $id capability",
            );
        }
        my $required_fields = $action->{required_fields} // [];
        Selecto::Error->throw(
            'invalid_domain', "detail action $id required_fields must be an array",
        ) unless ref($required_fields) eq 'ARRAY';
        my (@fields, %seen_field);
        for my $raw_field (@$required_fields) {
            Selecto::Error->throw(
                'invalid_domain', "detail action $id required field must be a field path",
            ) if !defined($raw_field) || ref($raw_field)
                || "$raw_field" !~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
            my $field = "$raw_field";
            next if $seen_field{$field}++;
            my $resolved = eval { $domain->resolve($field) };
            Selecto::Error->throw(
                'invalid_domain', "detail action $id required field is not queryable",
                {action => $id, field => $field},
            ) unless $resolved;
            Selecto::Error->throw(
                'invalid_domain', "detail action $id required field cannot denormalize rows",
                {action => $id, field => $field},
            ) if grep { $_->cardinality eq 'many' } @{$resolved->{associations} // []};
            push @fields, $field;
        }
        my $payload = $action->{payload};
        _object($payload, "detail action $id payload");
        _reject_unknown($payload, \%DETAIL_ACTION_PAYLOAD, "detail action $id payload");
        if ($type eq 'record_editor') {
            my @unsupported = grep { exists $payload->{$_} } qw(
                url_template target allow referrer_policy sandbox
            );
            Selecto::Error->throw(
                'invalid_domain', "detail action $id record editor payload contains unsupported settings",
                {action => $id, settings => \@unsupported},
            ) if @unsupported;
            my $editor = _identifier(
                $payload->{editor}, "detail action $id payload editor",
            );
            Selecto::Error->throw(
                'invalid_domain', "detail action $id references an unknown editor",
                {action => $id, editor => $editor},
            ) unless exists($domain->{editors}{$editor});
            my $target_field = _identifier(
                $payload->{target_field} // $domain->primary_key,
                "detail action $id payload target_field",
            );
            Selecto::Error->throw(
                'invalid_domain', "detail action $id target_field is not a required field",
                {action => $id, field => $target_field},
            ) unless grep { $_ eq $target_field } @fields;
            my $title = defined($payload->{title})
                ? _required_string($payload->{title}, "detail action $id payload title")
                : $name;
            my %required = map { $_ => 1 } @fields;
            my @title_placeholders = $title =~ /\{\{\s*([^}]+?)\s*\}\}/g;
            for my $placeholder (@title_placeholders) {
                Selecto::Error->throw(
                    'invalid_domain', "detail action $id title placeholder is not a required field",
                    {action => $id, field => $placeholder},
                ) unless $required{$placeholder};
            }
            my $title_without_placeholders = $title;
            $title_without_placeholders =~ s/\{\{\s*[^}]+?\s*\}\}//g;
            Selecto::Error->throw(
                'invalid_domain', "detail action $id title has malformed placeholders",
                {action => $id},
            ) if $title_without_placeholders =~ /[{}]/;
            my $size = defined($payload->{size})
                ? lc _required_string($payload->{size}, "detail action $id payload size")
                : 'lg';
            Selecto::Error->throw(
                'invalid_domain', "detail action $id editor size is not available",
                {action => $id, size => $size},
            ) unless $size =~ /\A(?:sm|md|lg|xl|full|third|fullscreen)\z/;
            my $navigation_enabled = exists($payload->{navigation_enabled})
                ? $payload->{navigation_enabled} : 1;
            my $boolean = JSON::PP::is_bool($navigation_enabled)
                || (!ref($navigation_enabled) && "$navigation_enabled" =~ /\A(?:0|1)\z/);
            Selecto::Error->throw(
                'invalid_domain', "detail action $id navigation_enabled must be a boolean",
                {action => $id},
            ) unless $boolean;
            $actions{$id} = {
                name => $name,
                type => $type,
                required_fields => \@fields,
                payload => {
                    editor => $editor,
                    target_field => $target_field,
                    title => $title,
                    size => $size,
                    navigation_enabled => $navigation_enabled ? 1 : 0,
                },
                (defined($description) ? (description => $description) : ()),
                (defined($capability) ? (capability => $capability) : ()),
            };
            next;
        }
        my $url_template = _required_string(
            $payload->{url_template}, "detail action $id payload url_template",
        );
        my $url_safety = $url_template;
        $url_safety =~ s/\{\{ *[A-Za-z_][A-Za-z0-9_.]* *\}\}/field/g;
        Selecto::Error->throw(
            'invalid_domain', "detail action $id URL template is not safe",
            {action => $id},
        ) if $url_safety =~ /[\x00-\x20\x7f\\]/
            || $url_template =~ m{\A//}
            || $url_template =~ /\A(?:javascript|data|vbscript):/i
            || $url_template =~ /\A(?!https?:)[A-Za-z][A-Za-z0-9+.-]*:/i;
        my %required = map { $_ => 1 } @fields;
        my @placeholders = $url_template =~ /\{\{\s*([^}]+?)\s*\}\}/g;
        Selecto::Error->throw(
            'invalid_domain', "detail action $id URL template requires placeholders",
            {action => $id},
        ) unless @placeholders;
        for my $placeholder (@placeholders) {
            Selecto::Error->throw(
                'invalid_domain', "detail action $id URL placeholder is not a required field",
                {action => $id, field => $placeholder},
            ) unless $required{$placeholder};
        }
        my $without_placeholders = $url_template;
        $without_placeholders =~ s/\{\{\s*[^}]+?\s*\}\}//g;
        Selecto::Error->throw(
            'invalid_domain', "detail action $id URL template has malformed placeholders",
            {action => $id},
        ) if $without_placeholders =~ /[{}]/;
        my %normalized_payload = (url_template => $url_template);
        if ($type eq 'external_link') {
            for my $key (qw(title size allow referrer_policy sandbox navigation_enabled)) {
                Selecto::Error->throw(
                    'invalid_domain', "detail action $id payload $key is only available for iframe_modal",
                    {action => $id},
                ) if exists $payload->{$key};
            }
            my $target = defined($payload->{target})
                ? _required_string($payload->{target}, "detail action $id payload target")
                : '_self';
            Selecto::Error->throw(
                'invalid_domain', "detail action $id target is not available",
                {action => $id, target => $target},
            ) unless $target =~ /\A_(?:self|blank|parent|top)\z/;
            $normalized_payload{target} = $target;
        } else {
            Selecto::Error->throw(
                'invalid_domain', "detail action $id payload target is only available for external_link",
                {action => $id},
            ) if exists $payload->{target};
            my $title = defined($payload->{title})
                ? _required_string($payload->{title}, "detail action $id payload title")
                : $name;
            my @title_placeholders = $title =~ /\{\{\s*([^}]+?)\s*\}\}/g;
            for my $placeholder (@title_placeholders) {
                Selecto::Error->throw(
                    'invalid_domain', "detail action $id title placeholder is not a required field",
                    {action => $id, field => $placeholder},
                ) unless $required{$placeholder};
            }
            my $title_without_placeholders = $title;
            $title_without_placeholders =~ s/\{\{\s*[^}]+?\s*\}\}//g;
            Selecto::Error->throw(
                'invalid_domain', "detail action $id title has malformed placeholders",
                {action => $id},
            ) if $title_without_placeholders =~ /[{}]/;
            my $size = defined($payload->{size})
                ? lc _required_string($payload->{size}, "detail action $id payload size")
                : 'xl';
            Selecto::Error->throw(
                'invalid_domain', "detail action $id iframe size is not available",
                {action => $id, size => $size},
            ) unless $size =~ /\A(?:sm|md|lg|xl|full|third|fullscreen)\z/;
            my $referrer_policy = defined($payload->{referrer_policy})
                ? lc _required_string(
                    $payload->{referrer_policy},
                    "detail action $id payload referrer_policy",
                )
                : 'strict-origin-when-cross-origin';
            Selecto::Error->throw(
                'invalid_domain', "detail action $id iframe referrer policy is not available",
                {action => $id, referrer_policy => $referrer_policy},
            ) unless $referrer_policy =~ /\A(?:no-referrer|no-referrer-when-downgrade|origin|origin-when-cross-origin|same-origin|strict-origin|strict-origin-when-cross-origin|unsafe-url)\z/;
            my $navigation_enabled = exists($payload->{navigation_enabled})
                ? $payload->{navigation_enabled} : 1;
            my $boolean = JSON::PP::is_bool($navigation_enabled)
                || (!ref($navigation_enabled) && "$navigation_enabled" =~ /\A(?:0|1)\z/);
            Selecto::Error->throw(
                'invalid_domain', "detail action $id navigation_enabled must be a boolean",
                {action => $id},
            ) unless $boolean;
            $normalized_payload{title} = $title;
            $normalized_payload{size} = $size;
            $normalized_payload{referrer_policy} = $referrer_policy;
            $normalized_payload{navigation_enabled} = $navigation_enabled ? 1 : 0;
            for my $key (qw(allow sandbox)) {
                next unless exists $payload->{$key};
                my $setting = _required_string(
                    $payload->{$key}, "detail action $id payload $key",
                );
                Selecto::Error->throw(
                    'invalid_domain', "detail action $id iframe $key contains unsafe characters",
                    {action => $id},
                ) if $setting =~ /[\x00-\x1f\x7f<>"'`]/;
                $normalized_payload{$key} = $setting;
            }
        }
        $actions{$id} = {
            name => $name,
            type => $type,
            required_fields => \@fields,
            payload => \%normalized_payload,
            (defined($description) ? (description => $description) : ()),
            (defined($capability) ? (capability => $capability) : ()),
        };
    }
    return \%actions;
}

sub _validate_editors {
    my ($domain, $value) = @_;
    return {} unless defined $value;
    _object($value, 'editors');
    my $contract = $domain->{contract} // {};
    my $writes = $contract->{writes} // {};
    my $update = ref($writes->{operations}) eq 'HASH'
        ? $writes->{operations}{update} : undef;
    my $write_fields = ref($writes->{fields}) eq 'HASH' ? $writes->{fields} : {};
    my $actions = ref($contract->{actions}) eq 'HASH' ? $contract->{actions} : {};
    my %editors;
    for my $raw_id (sort keys %$value) {
        my $id = _identifier($raw_id, 'editor');
        my $editor = $value->{$raw_id};
        _object($editor, "editor $id");
        _reject_unknown($editor, \%EDITOR, "editor $id");
        Selecto::Error->throw(
            'invalid_domain', "editor $id requires an enabled update write operation",
            {editor => $id},
        ) unless ref($update) eq 'HASH' && $update->{enabled};
        my $label = _required_string($editor->{label} // $id, "editor $id label");
        my $fields = $editor->{fields};
        Selecto::Error->throw(
            'invalid_domain', "editor $id fields must be a non-empty array",
        ) unless ref($fields) eq 'ARRAY' && @$fields;
        my (@normalized_fields, %seen);
        for my $index (0 .. $#$fields) {
            my $entry = $fields->[$index];
            $entry = {field => $entry} if defined($entry) && !ref($entry);
            _object($entry, "editor $id field $index");
            _reject_unknown($entry, \%EDITOR_FIELD, "editor $id field $index");
            my $field = _required_string($entry->{field}, "editor $id field");
            Selecto::Error->throw(
                'invalid_domain', "editor $id field path is invalid",
                {editor => $id, field => $field},
            ) unless $field =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
            Selecto::Error->throw(
                'invalid_domain', "editor $id field is duplicated",
                {editor => $id, field => $field},
            ) if $seen{$field}++;
            my $resolved = $domain->resolve($field);
            Selecto::Error->throw(
                'invalid_domain', "editor $id field is not public",
                {editor => $id, field => $field},
            ) unless $domain->field_is_public($field);
            my %normalized = (field => $field);
            for my $key (qw(label placeholder help section)) {
                $normalized{$key} = _required_string(
                    $entry->{$key}, "editor $id field $field $key",
                ) if exists $entry->{$key};
            }
            my $control = exists($entry->{control})
                ? lc _required_string($entry->{control}, "editor $id field $field control")
                : '';
            Selecto::Error->throw(
                'invalid_domain', "editor $id field $field control is not available",
            ) if length($control)
                && $control !~ /\A(?:text|textarea|number|date|datetime-local|checkbox|select)\z/;
            $normalized{control} = $control if length $control;
            for my $key (qw(required nullable readonly)) {
                next unless exists $entry->{$key};
                my $setting = $entry->{$key};
                my $boolean = JSON::PP::is_bool($setting)
                    || (!ref($setting) && "$setting" =~ /\A(?:0|1)\z/);
                Selecto::Error->throw(
                    'invalid_domain', "editor $id field $field $key must be a boolean",
                ) unless $boolean;
                $normalized{$key} = $setting ? 1 : 0;
            }
            Selecto::Error->throw(
                'invalid_domain', "editor $id field is not updatable",
                {editor => $id, field => $field},
            ) unless $normalized{readonly}
                || !$resolved->{association}
                    && ref($write_fields->{$field}) eq 'HASH'
                    && $write_fields->{$field}{updatable};
            Selecto::Error->throw(
                'invalid_domain', "editor $id readonly field cannot be required",
                {editor => $id, field => $field},
            ) if $normalized{readonly} && $normalized{required};
            if (exists $entry->{rows}) {
                my $rows = $entry->{rows};
                Selecto::Error->throw(
                    'invalid_domain', "editor $id field $field rows must be from 2 to 20",
                ) if ref($rows) || "$rows" !~ /\A\d+\z/ || $rows < 2 || $rows > 20;
                $normalized{rows} = 0 + $rows;
            }
            if (exists $entry->{options}) {
                my $options = $entry->{options};
                Selecto::Error->throw(
                    'invalid_domain', "editor $id field $field options must be a non-empty array",
                ) unless ref($options) eq 'ARRAY' && @$options;
                my @options;
                for my $option (@$options) {
                    _object($option, "editor $id field $field option");
                    _reject_unknown($option, {value => 1, label => 1}, "editor $id field $field option");
                    Selecto::Error->throw(
                        'invalid_domain', "editor $id field $field option value must be scalar",
                    ) if !exists($option->{value}) || ref($option->{value});
                    push @options, {
                        value => $option->{value},
                        label => _required_string(
                            $option->{label}, "editor $id field $field option label",
                        ),
                    };
                }
                $normalized{options} = \@options;
                $normalized{control} //= 'select';
            }
            push @normalized_fields, \%normalized;
        }
        my $editor_actions = $editor->{actions} // [];
        Selecto::Error->throw(
            'invalid_domain', "editor $id actions must be an array",
        ) unless ref($editor_actions) eq 'ARRAY';
        my (@normalized_actions, %seen_action);
        for my $raw_action (@$editor_actions) {
            my $action = _identifier($raw_action, "editor $id action");
            next if $seen_action{$action}++;
            Selecto::Error->throw(
                'invalid_domain', "editor $id action is not published",
                {editor => $id, action => $action},
            ) unless ref($actions->{$action}) eq 'HASH';
            my $selection = $actions->{$action}{selection} // {};
            Selecto::Error->throw(
                'invalid_domain', "editor $id action must accept a row target",
                {editor => $id, action => $action},
            ) if ref($selection) eq 'HASH' && ($selection->{mode} // 'rows') eq 'groups';
            push @normalized_actions, $action;
        }
        my $editor_collections = $editor->{collections} // [];
        Selecto::Error->throw(
            'invalid_domain', "editor $id collections must be an array",
        ) unless ref($editor_collections) eq 'ARRAY';
        my (@normalized_collections, %seen_collection);
        for my $index (0 .. $#$editor_collections) {
            my $collection = $editor_collections->[$index];
            _object($collection, "editor $id collection $index");
            _reject_unknown($collection, \%EDITOR_COLLECTION, "editor $id collection $index");
            my $collection_id = _identifier(
                $collection->{id}, "editor $id collection",
            );
            Selecto::Error->throw(
                'invalid_domain', "editor $id collection is duplicated",
                {editor => $id, collection => $collection_id},
            ) if $seen_collection{$collection_id}++;
            my $collection_fields = $collection->{fields};
            Selecto::Error->throw(
                'invalid_domain', "editor $id collection $collection_id fields must be a non-empty array",
            ) unless ref($collection_fields) eq 'ARRAY' && @$collection_fields;
            my (@fields, $association_name);
            for my $field_index (0 .. $#$collection_fields) {
                my $field_spec = $collection_fields->[$field_index];
                $field_spec = {field => $field_spec}
                    if defined($field_spec) && !ref($field_spec);
                _object($field_spec, "editor $id collection $collection_id field $field_index");
                _reject_unknown(
                    $field_spec, \%EDITOR_COLLECTION_FIELD,
                    "editor $id collection $collection_id field $field_index",
                );
                my $path = _required_string(
                    $field_spec->{field}, "editor $id collection $collection_id field",
                );
                my $resolved = $domain->resolve($path);
                Selecto::Error->throw(
                    'invalid_domain', "editor $id collection field is not public",
                    {editor => $id, collection => $collection_id, field => $path},
                ) unless $domain->field_is_public($path);
                my $associations = $resolved->{associations};
                Selecto::Error->throw(
                    'invalid_domain', "editor $id collection field must belong to a to-many association",
                    {editor => $id, collection => $collection_id, field => $path},
                ) unless ref($associations) eq 'ARRAY' && @$associations
                    && $associations->[0]->cardinality eq 'many';
                my ($root_association) = split /\./, $path, 2;
                $association_name //= $root_association;
                Selecto::Error->throw(
                    'invalid_domain', "editor $id collection fields must share one association",
                    {editor => $id, collection => $collection_id, field => $path},
                ) unless $association_name eq $root_association;
                push @fields, {
                    field => $path,
                    (exists($field_spec->{label}) ? (
                        label => _required_string(
                            $field_spec->{label},
                            "editor $id collection $collection_id field label",
                        ),
                    ) : ()),
                };
            }
            my @orders;
            for my $order (@{$collection->{order_by} // []}) {
                if (ref($order) eq 'HASH') {
                    _reject_unknown(
                        $order, {field => 1, direction => 1},
                        "editor $id collection $collection_id order",
                    );
                    $order = [$order->{field}, $order->{direction}];
                }
                Selecto::Error->throw(
                    'invalid_domain', "editor $id collection $collection_id order_by entries must be arrays",
                ) unless ref($order) eq 'ARRAY' && @$order >= 1 && @$order <= 2;
                my $field = _required_string(
                    $order->[0], "editor $id collection $collection_id order field",
                );
                $domain->resolve($field);
                my ($root_association) = split /\./, $field, 2;
                Selecto::Error->throw(
                    'invalid_domain', "editor $id collection order must use its association",
                ) unless $root_association eq $association_name;
                my $direction = lc($order->[1] // 'asc');
                Selecto::Error->throw(
                    'invalid_domain', "editor $id collection order direction must be asc or desc",
                ) unless $direction eq 'asc' || $direction eq 'desc';
                push @orders, {field => $field, direction => $direction};
            }
            my $limit = $collection->{limit} // 50;
            Selecto::Error->throw(
                'invalid_domain', "editor $id collection $collection_id limit must be from 1 to 100",
            ) if ref($limit) || "$limit" !~ /\A\d+\z/ || $limit < 1 || $limit > 100;
            push @normalized_collections, {
                id => $collection_id,
                label => _required_string(
                    $collection->{label} // $collection_id,
                    "editor $id collection $collection_id label",
                ),
                fields => \@fields,
                order_by => \@orders,
                limit => 0 + $limit,
                (exists($collection->{empty_label}) ? (
                    empty_label => _required_string(
                        $collection->{empty_label},
                        "editor $id collection $collection_id empty_label",
                    ),
                ) : ()),
            };
        }
        $editors{$id} = {
            label => $label,
            fields => \@normalized_fields,
            actions => \@normalized_actions,
            collections => \@normalized_collections,
            (exists($editor->{description}) ? (
                description => _required_string($editor->{description}, "editor $id description"),
            ) : ()),
            (exists($editor->{submit_label}) ? (
                submit_label => _required_string($editor->{submit_label}, "editor $id submit_label"),
            ) : ()),
        };
    }
    return \%editors;
}

sub _constant_predicates {
    my ($value, $label) = @_;
    _object($value, $label);
    my %predicates;
    for my $field (keys %$value) {
        my $name = _identifier($field, "$label field");
        my $literal = $value->{$field};
        Selecto::Error->throw('invalid_domain', "$label values must be scalar literals")
            if ref($literal) && !JSON::PP::is_bool($literal);
        $predicates{$name} = $literal;
    }
    return \%predicates;
}

sub _reject_unknown {
    my ($value, $allowed, $location) = @_;
    my @unknown = sort grep { !$allowed->{$_} } keys %$value;
    Selecto::Error->throw('unknown_domain_key', "unknown keys in $location", { keys => \@unknown }) if @unknown;
}

sub _object {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_domain', "$label must be an object") unless ref($value) eq 'HASH';
}

sub _required_key {
    my ($value, $key, $location) = @_;
    Selecto::Error->throw('invalid_domain', "missing required $location key: $key")
        unless exists $value->{$key};
}

sub _required_string {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_domain', "$label must be a non-empty string")
        if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

sub _nonblank_string {
    my ($value, $label) = @_;
    my $text = _required_string($value, $label);
    Selecto::Error->throw('invalid_domain', "$label must be a non-empty string")
        if $text !~ /\S/;
    return $text;
}

sub _identifier {
    my ($value, $label) = @_;
    my $string = _required_string($value, $label);
    Selecto::Error->throw('invalid_identifier', "invalid $label")
        unless $string =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
    return $string;
}

sub name         { return $_[0]->{name}; }
sub table        { return $_[0]->{table}; }
sub fields       { return { %{$_[0]->{fields}} }; }
sub associations { return { %{$_[0]->{associations}} }; }
sub fingerprint  { return $_[0]->{fingerprint}; }
sub primary_key  { return $_[0]->{primary_key}; }
sub required_predicate { return $_[0]->{required_predicate}; }
sub tenant_field { return $_[0]->{tenant_field}; }
sub contract     { return defined($_[0]->{contract}) ? dclone($_[0]->{contract}) : undef; }
sub rules        { return $_[0]->{rules}; }
sub writes       { my $contract = $_[0]->contract // {}; return dclone($contract->{writes} // {}); }
sub actions      { my $contract = $_[0]->contract // {}; return dclone($contract->{actions} // {}); }
sub imports      { my $contract = $_[0]->contract // {}; return dclone($contract->{imports} // {}); }
sub editors      { return dclone($_[0]->{editors} // {}); }
sub detail_actions { return dclone($_[0]->{detail_actions} // {}); }
sub capabilities { my $contract = $_[0]->contract // {}; return dclone($contract->{capabilities} // {}); }
sub components   { return dclone($_[0]->{components} // {}); }
sub query_library { return dclone($_[0]->{query_library} // {}); }
sub co_domains   { return dclone($_[0]->{co_domains} // {}); }
sub domain_dependencies { return dclone($_[0]->{domain_dependencies} // []); }
sub operations   { return dclone($_[0]->{operations} // {}); }
sub experiences  { return dclone($_[0]->{experiences} // {}); }

package Selecto::Domain::Association;

use 5.034;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $value = $args{value};
    $value = { %$value } if ref($value) eq 'HASH';
    Selecto::Error->throw('invalid_domain', "association $args{name} must be an object")
        unless ref($value) eq 'HASH';
    for my $key (qw(table fields owner_key related_key)) {
        Selecto::Domain::_required_key($value, $key, "association $args{name}");
    }
    my $join_mode = lc(Selecto::Domain::_required_string(
        $value->{join_mode} // $value->{join_type} // 'left', 'join type'
    ));
    Selecto::Error->throw('invalid_domain', "unsupported join type $join_mode")
        unless $join_mode eq 'left' || $join_mode eq 'inner'
            || $join_mode eq 'star_dimension';
    my $join_type = $join_mode eq 'star_dimension' ? 'left'
        : lc(Selecto::Domain::_required_string($value->{join_type} // $join_mode, 'join type'));
    Selecto::Error->throw('invalid_domain', "unsupported join type $join_type")
        unless $join_type eq 'left' || $join_type eq 'inner';
    my $fields = Selecto::Domain::_normalize_fields($value->{fields}, 'association fields');
    my %associations;
    my $nested = $value->{associations} // {};
    Selecto::Domain::_object($nested, "association $args{name} associations");
    for my $name (keys %$nested) {
        my $association_name = Selecto::Domain::_identifier($name, 'association');
        $associations{$association_name} = __PACKAGE__->new(
            name => $association_name,
            value => $nested->{$name},
        );
    }
    my $where = exists($value->{where})
        ? Selecto::Domain::_constant_predicates(
            $value->{where}, "association $args{name} where"
        ) : {};
    for my $field (keys %$where) {
        Selecto::Error->throw(
            'invalid_domain', 'association where field is not queryable',
            {association => $args{name}, field => $field},
        ) unless exists $fields->{$field};
    }
    my $cardinality = lc(Selecto::Domain::_required_string(
        $value->{cardinality} // 'one', 'association cardinality'
    ));
    Selecto::Error->throw('invalid_domain', "unsupported association cardinality $cardinality")
        unless $cardinality eq 'one' || $cardinality eq 'many';
    my $join_strategy;
    if (exists $value->{join_strategy}) {
        $join_strategy = lc(Selecto::Domain::_required_string(
            $value->{join_strategy}, 'association join strategy'
        ));
        Selecto::Error->throw('invalid_domain', 'unsupported association join strategy')
            unless $join_strategy eq 'lateral_lookup';
        Selecto::Error->throw(
            'invalid_domain', 'lateral lookup requires a direct table association'
        ) if exists($value->{through}) || defined($value->{values});
    }
    my $target_primary_key;
    if (defined $value->{target_primary_key}) {
        $target_primary_key = Selecto::Domain::_identifier(
            $value->{target_primary_key}, 'association target primary key'
        );
        Selecto::Error->throw('invalid_domain', 'association target primary key is not queryable')
            unless exists $fields->{$target_primary_key};
    }
    my $display_field;
    my $dimension_key;
    my $display_name;
    my $display_fallback;
    if ($join_mode eq 'star_dimension') {
        $display_field = Selecto::Domain::_identifier(
            $value->{display_field} // 'name', 'star dimension display field'
        );
        Selecto::Error->throw('invalid_domain', 'star dimension display field is not queryable', {
            association => $args{name}, display_field => $display_field,
        }) unless exists $fields->{$display_field};
        $dimension_key = Selecto::Domain::_identifier(
            $value->{dimension_key} // $value->{owner_key}, 'star dimension key'
        );
        $display_name = Selecto::Domain::_required_string(
            $value->{display_name} // $args{name}, 'star dimension name'
        );
        if (defined $value->{display_fallback}) {
            $display_fallback = lc(Selecto::Domain::_required_string(
                $value->{display_fallback}, 'star dimension display fallback'
            ));
            Selecto::Error->throw(
                'invalid_domain',
                'star dimension display fallback must be dimension_key',
            ) unless $display_fallback eq 'dimension_key';
        }
    }
    my ($source_scope_key, $target_scope_key);
    my $direct_scope_count = grep { exists $value->{$_} }
        qw(source_scope_key target_scope_key);
    Selecto::Error->throw(
        'invalid_domain',
        'association scope requires source and target keys',
    ) if $direct_scope_count && $direct_scope_count != 2;
    if ($direct_scope_count) {
        $source_scope_key = Selecto::Domain::_identifier(
            $value->{source_scope_key}, 'association source scope key'
        );
        $target_scope_key = Selecto::Domain::_identifier(
            $value->{target_scope_key}, 'association target scope key'
        );
    }
    my $through;
    if (exists $value->{through}) {
        $through = $value->{through};
        Selecto::Error->throw('invalid_domain', 'association through must be an object')
            unless ref($through) eq 'HASH';
        Selecto::Domain::_reject_unknown(
            $through, \%THROUGH, "association $args{name} through"
        );
        for my $key (qw(table owner_key related_key)) {
            Selecto::Domain::_required_key($through, $key, "association $args{name} through");
        }
        $through = {
            table => Selecto::Domain::_identifier($through->{table}, 'through table'),
            owner_key => Selecto::Domain::_identifier($through->{owner_key}, 'through owner key'),
            related_key => Selecto::Domain::_identifier($through->{related_key}, 'through related key'),
            (exists($through->{where}) ? (
                where => Selecto::Domain::_constant_predicates(
                    $through->{where}, "association $args{name} through where"
                ),
            ) : ()),
        };
        if (exists $value->{through}{target_key_cast}) {
            my $cast = Selecto::Domain::_required_string(
                $value->{through}{target_key_cast}, 'through target key cast'
            );
            Selecto::Error->throw('invalid_domain', 'through target key cast must be string')
                unless $cast eq 'string';
            $through->{target_key_cast} = $cast;
        }
        my @scope_keys = qw(source_scope_key through_scope_key target_scope_key);
        my $scope_count = grep { exists $value->{through}{$_} } @scope_keys;
        Selecto::Error->throw(
            'invalid_domain',
            'through association scope requires source, through, and target keys',
        ) if $scope_count && $scope_count != @scope_keys;
        if ($scope_count) {
            $through->{$_} = Selecto::Domain::_identifier(
                $value->{through}{$_}, "through $_"
            ) for @scope_keys;
        }
        Selecto::Error->throw(
            'invalid_domain',
            'through associations declare scope inside the through contract',
        ) if $direct_scope_count;
    }
    return bless {
        name => Selecto::Domain::_identifier($args{name}, 'association'),
        table => Selecto::Domain::_identifier($value->{table}, 'association table'),
        fields => $fields,
        (defined($value->{values}) ? (
            values => [map { {%$_} } @{$value->{values}}],
            value_fields => [@{$value->{value_fields}}],
        ) : ()),
        associations => \%associations,
        (defined($value->{queryable}) ? (queryable => "$value->{queryable}") : ()),
        owner_key => Selecto::Domain::_identifier($value->{owner_key}, 'owner key'),
        related_key => Selecto::Domain::_identifier($value->{related_key}, 'related key'),
        cardinality => $cardinality,
        target_primary_key => $target_primary_key,
        join_type => $join_type,
        join_mode => $join_mode,
        (defined($join_strategy) ? (join_strategy => $join_strategy) : ()),
        (defined($source_scope_key) ? (
            source_scope_key => $source_scope_key,
            target_scope_key => $target_scope_key,
        ) : ()),
        (defined($through) ? (through => $through) : ()),
        (keys(%$where) ? (where => $where) : ()),
        ($join_mode eq 'star_dimension' ? (
            display_field => $display_field,
            dimension_key => $dimension_key,
            display_name => $display_name,
            (defined($display_fallback)
                ? (display_fallback => $display_fallback) : ()),
        ) : ()),
    }, $class;
}

sub fingerprint_value {
    my ($self) = @_;
    return {
        table => $self->{table},
        fields => { %{$self->{fields}} },
        (defined($self->{values}) ? (
            values => [map { {%$_} } @{$self->{values}}],
            value_fields => [@{$self->{value_fields}}],
        ) : ()),
        (defined($self->{queryable}) ? (queryable => $self->{queryable}) : ()),
        (keys(%{$self->{associations} // {}}) ? (
            associations => {
                map { $_ => $self->{associations}{$_}->fingerprint_value }
                    sort keys %{$self->{associations}}
            },
        ) : ()),
        owner_key => $self->{owner_key},
        related_key => $self->{related_key},
        join_type => $self->{join_type},
        (defined($self->{join_strategy}) ? (
            join_strategy => $self->{join_strategy},
        ) : ()),
        ($self->{cardinality} eq 'many' ? (cardinality => 'many') : ()),
        (defined($self->{target_primary_key}) && $self->{cardinality} eq 'many'
            ? (target_primary_key => $self->{target_primary_key}) : ()),
        (defined($self->{through}) ? (through => {%{$self->{through}}}) : ()),
        (defined($self->{where}) ? (where => {%{$self->{where}}}) : ()),
        (defined($self->{source_scope_key}) ? (
            source_scope_key => $self->{source_scope_key},
            target_scope_key => $self->{target_scope_key},
        ) : ()),
        ($self->{join_mode} eq 'star_dimension' ? (
            join_mode => $self->{join_mode},
            display_field => $self->{display_field},
            dimension_key => $self->{dimension_key},
            display_name => $self->{display_name},
            (defined($self->{display_fallback})
                ? (display_fallback => $self->{display_fallback}) : ()),
        ) : ()),
    };
}

sub name        { return $_[0]->{name}; }
sub table       { return $_[0]->{table}; }
sub fields      { return { %{$_[0]->{fields}} }; }
sub values      { return defined($_[0]->{values}) ? [map { {%$_} } @{$_[0]->{values}}] : undef; }
sub value_fields { return defined($_[0]->{value_fields}) ? [@{$_[0]->{value_fields}}] : undef; }
sub associations { return { %{$_[0]->{associations} // {}} }; }
sub queryable   { return $_[0]->{queryable}; }
sub owner_key   { return $_[0]->{owner_key}; }
sub related_key { return $_[0]->{related_key}; }
sub join_type   { return $_[0]->{join_type}; }
sub join_strategy { return $_[0]->{join_strategy}; }
sub cardinality { return $_[0]->{cardinality}; }
sub target_primary_key { return $_[0]->{target_primary_key}; }
sub join_mode   { return $_[0]->{join_mode}; }
sub display_field { return $_[0]->{display_field}; }
sub dimension_key { return $_[0]->{dimension_key}; }
sub display_name { return $_[0]->{display_name}; }
sub display_fallback { return $_[0]->{display_fallback}; }
sub through { return defined($_[0]->{through}) ? {%{$_[0]->{through}}} : undef; }
sub where { return defined($_[0]->{where}) ? {%{$_[0]->{where}}} : {}; }
sub source_scope_key { return $_[0]->{source_scope_key}; }
sub target_scope_key { return $_[0]->{target_scope_key}; }

1;
