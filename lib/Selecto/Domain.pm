package Selecto::Domain;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();

my %TOP_LEVEL = map { $_ => 1 } qw(
    schema_version domain_version domain_fingerprint name source schemas joins associations
    default_selected required_selected required_order_by
    filters functions query_members published_views detail_actions capabilities
    source_relationships choice_sources writes actions extensions columns custom_columns
    jsonb_schemas subfilters window_functions pagination retarget redact_fields components
    query_library
);
my %SIMPLE_SOURCE = map { $_ => 1 } qw(table fields);
my %RELATION = map { $_ => 1 } qw(source_table primary_key fields columns associations tenant_field);
my %ASSOCIATION = map { $_ => 1 } qw(queryable owner_key related_key cardinality);
my %JOIN = map { $_ => 1 } qw(type);
my %COMPONENTS = map { $_ => 1 } qw(query_params);

sub new {
    my ($class, %args) = @_;
    my $fields = _normalize_fields($args{fields}, 'fields');
    my %associations;
    my $input = $args{associations} // {};
    _object($input, 'associations');
    for my $name (keys %$input) {
        my $association_name = _identifier($name, 'association');
        $associations{$association_name} = Selecto::Domain::Association->new(
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
    my $fingerprint_value = {
        name => $self->{name},
        table => $self->{table},
        fields => $self->{fields},
        associations => {
            map { $_ => $self->{associations}{$_}->fingerprint_value } sort keys %associations
        },
        primary_key => $self->{primary_key},
        required_predicate => _expression_value($self->{required_predicate}),
        tenant_field => $self->{tenant_field},
    };
    $fingerprint_value->{components} = $self->{components} if keys %{$self->{components}};
    $fingerprint_value->{query_library} = $self->{query_library}
        if keys %{$self->{query_library}};
    my $json = JSON::PP->new->canonical(1)->encode($fingerprint_value);
    $self->{fingerprint} = 'sha256:' . sha256_hex($json);
    return $self;
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
    );
}

sub _parse_canonical {
    my ($class, $raw, $source, $strict) = @_;
    _reject_unknown($source, \%RELATION, 'source') if $strict;
    my $schemas = $raw->{schemas} // {};
    my $joins = $raw->{joins} // {};
    _object($schemas, 'schemas');
    _object($joins, 'joins');
    my $source_associations = $source->{associations} // {};
    _object($source_associations, 'source associations');
    my %associations;

    for my $name (keys %$source_associations) {
        my $association = $source_associations->{$name};
        _object($association, "association $name");
        _reject_unknown($association, \%ASSOCIATION, "association $name") if $strict;
        _required_key($association, 'queryable', "association $name");
        my $queryable = $association->{queryable};
        Selecto::Error->throw('invalid_domain', "missing schema $queryable")
            unless exists $schemas->{$queryable};
        my $target = $schemas->{$queryable};
        _object($target, "schema $queryable");
        _reject_unknown($target, \%RELATION, "schema $queryable") if $strict;
        my $join = $joins->{$name} // {};
        _object($join, "join $name");
        _reject_unknown($join, \%JOIN, "join $name") if $strict;
        for my $key (qw(owner_key related_key)) {
            _required_key($association, $key, "association $name");
        }
        _required_key($target, 'source_table', "schema $queryable");
        $associations{$name} = {
            table => $target->{source_table},
            fields => _canonical_fields($target),
            owner_key => $association->{owner_key},
            related_key => $association->{related_key},
            join_type => $join->{type} // 'left',
        };
    }

    _required_key($raw, 'name', 'domain');
    _required_key($source, 'source_table', 'source');
    my $domain = $class->new(
        name => $raw->{name},
        table => $source->{source_table},
        fields => _canonical_fields($source),
        associations => \%associations,
        primary_key => $source->{primary_key} // 'id',
        tenant_field => $source->{tenant_field},
        components => $raw->{components},
        query_library => $raw->{query_library},
    );
    $domain->{contract} = dclone($raw);
    return $domain;
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
        $result{$field} = $column->{type};
    }
    return \%result;
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
        return { association => undef, field => $field, type => $self->{fields}{$field} };
    }
    if (@segments == 2) {
        my ($association_name, $field) = @segments;
        Selecto::Error->throw('unknown_association', "unknown association $association_name")
            unless exists $self->{associations}{$association_name};
        my $association = $self->{associations}{$association_name};
        Selecto::Error->throw('unknown_field', "unknown field $path")
            unless exists $association->{fields}{$field};
        return { association => $association, field => $field, type => $association->{fields}{$field} };
    }
    Selecto::Error->throw('invalid_field', 'field paths may contain at most one association');
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
    return \%components;
}

sub _normalize_query_library {
    my ($value) = @_;
    return {} unless defined $value;
    _object($value, 'query_library');
    my %known = map { $_ => 1 } qw(segments projections orderings views);
    _reject_unknown($value, \%known, 'query_library');
    my %library;
    for my $registry (qw(segments projections orderings views)) {
        my $definitions = $value->{$registry} // {};
        _object($definitions, "query_library $registry");
        $library{$registry} = dclone($definitions);
    }
    return \%library;
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
sub writes       { my $contract = $_[0]->contract // {}; return dclone($contract->{writes} // {}); }
sub actions      { my $contract = $_[0]->contract // {}; return dclone($contract->{actions} // {}); }
sub capabilities { my $contract = $_[0]->contract // {}; return dclone($contract->{capabilities} // {}); }
sub components   { return dclone($_[0]->{components} // {}); }
sub query_library { return dclone($_[0]->{query_library} // {}); }

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
    my $join_type = lc(Selecto::Domain::_required_string($value->{join_type} // 'left', 'join type'));
    Selecto::Error->throw('invalid_domain', "unsupported join type $join_type")
        unless $join_type eq 'left' || $join_type eq 'inner';
    return bless {
        name => Selecto::Domain::_identifier($args{name}, 'association'),
        table => Selecto::Domain::_identifier($value->{table}, 'association table'),
        fields => Selecto::Domain::_normalize_fields($value->{fields}, 'association fields'),
        owner_key => Selecto::Domain::_identifier($value->{owner_key}, 'owner key'),
        related_key => Selecto::Domain::_identifier($value->{related_key}, 'related key'),
        join_type => $join_type,
    }, $class;
}

sub fingerprint_value {
    my ($self) = @_;
    return {
        table => $self->{table},
        fields => { %{$self->{fields}} },
        owner_key => $self->{owner_key},
        related_key => $self->{related_key},
        join_type => $self->{join_type},
    };
}

sub name        { return $_[0]->{name}; }
sub table       { return $_[0]->{table}; }
sub fields      { return { %{$_[0]->{fields}} }; }
sub owner_key   { return $_[0]->{owner_key}; }
sub related_key { return $_[0]->{related_key}; }
sub join_type   { return $_[0]->{join_type}; }

1;
