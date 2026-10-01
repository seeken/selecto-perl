package Selecto::Retarget;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();

# Retarget moves a query's row grain from the domain root to the relation at
# an association path. The query's earlier predicate becomes the context: an
# ordinary query on the original domain that selects the target's primary key
# through the full path, so every hop keeps its declared join semantics and
# the root's required (host and tenant) predicate always applies. The rest of
# the query compiles on a domain rooted at the target relation.
#
#   retarget => {
#       targets => {'attendees.orders' => {label => 'Orders', default_selected => ['id']}},
#       default_target => 'attendees.orders',
#   }
#
# Without `targets`, any association path may be a target.

my %CONFIG_KEYS = map { $_ => 1 } qw(targets default_target);
my %TARGET_KEYS = map { $_ => 1 } qw(label default_selected);

# Validates a domain's retarget section against the parsed domain.
sub validate_config {
    my ($class, $domain, $config, %options) = @_;
    return unless defined $config;
    my $strict = exists($options{strict}) ? $options{strict} : 1;
    _fail('retarget must be an object') unless ref($config) eq 'HASH';
    if ($strict) {
        my @unknown = sort grep { !$CONFIG_KEYS{$_} } keys %$config;
        _fail('retarget contains unsupported keys', {keys => \@unknown}) if @unknown;
    }
    my $targets = $config->{targets};
    if (defined $targets) {
        _fail('retarget targets must be an object') unless ref($targets) eq 'HASH';
        for my $path (sort keys %$targets) {
            my $spec = $targets->{$path};
            _fail("retarget target $path must be an object") unless ref($spec) eq 'HASH';
            if ($strict) {
                my @unknown = sort grep { !$TARGET_KEYS{$_} } keys %$spec;
                _fail("retarget target $path contains unsupported keys", {keys => \@unknown})
                    if @unknown;
            }
            _fail("retarget target $path label must be a string")
                if exists($spec->{label}) && (!defined($spec->{label}) || ref($spec->{label}));
            _target_relation($domain, $path, "retarget target $path", 'invalid_domain');
            if (exists $spec->{default_selected}) {
                my $selected = $spec->{default_selected};
                _fail("retarget target $path default_selected must be a non-empty array of fields")
                    unless ref($selected) eq 'ARRAY' && @$selected
                        && !grep { !defined($_) || ref($_) } @$selected;
                $domain->resolve("$path.$_") for @$selected;
            }
        }
    }
    if (exists $config->{default_target}) {
        my $path = $config->{default_target};
        _fail('retarget default_target must be an association path')
            unless defined($path) && !ref($path);
        _target_relation($domain, $path, 'retarget default_target', 'invalid_domain');
        _fail('retarget default_target must be one of the declared targets', {path => "$path"})
            if ref($targets) eq 'HASH' && !exists $targets->{$path};
    }
    return 1;
}

# The resolved target for a query's retarget path, after the domain's
# governance and the target requirements are checked.
sub target {
    my ($class, $domain, $path) = @_;
    my $config = $domain->retarget_config;
    if (ref($config) eq 'HASH' && ref($config->{targets}) eq 'HASH') {
        Selecto::Error->throw(
            'retarget_not_allowed', "retarget to $path is not allowed by the domain",
            {path => "$path"},
        ) unless exists $config->{targets}{$path};
    }
    return _target_relation($domain, $path, "retarget to $path", 'invalid_query');
}

# A domain rooted at the target relation, for compiling. Its required
# predicate carries the root's tenant conditions onto the target's
# tenant_field, failing closed when a scoped root's condition cannot be
# carried.
sub target_domain {
    my ($class, $domain, $target) = @_;
    my $relation_domain = $class->relation_domain($domain, $target);
    my $relation = _contract_relation($domain, $target);
    return $relation_domain unless $relation;
    require Selecto::QueryMember;
    return Selecto::QueryMember::_scoped_member_domain(
        $domain, $relation_domain, $relation, "retarget to $target->{path}",
    );
}

# The target relation as an unscoped domain: its fields, associations, and
# metadata, for catalogs and field resolution. Never compile against it; the
# context and target scope come from target_domain.
sub relation_domain {
    my ($class, $domain, $target) = @_;
    my $path = $target->{path};
    my $association = $target->{association};
    require Selecto::Domain;
    if (my $relation = _contract_relation($domain, $target)) {
        my $contract = $domain->contract;
        my %document = (
            schema_version => 1,
            name => $domain->name,
            source => dclone($relation),
            schemas => dclone($contract->{schemas}),
            joins => _rerooted_joins($contract->{joins} // {}, $path),
        );
        my @redacted = map { substr($_, length($path) + 1) }
            grep { defined($_) && !ref($_) && index($_, "$path.") == 0 }
            @{ref($contract->{redact_fields}) eq 'ARRAY' ? $contract->{redact_fields} : []};
        $document{redact_fields} = \@redacted if @redacted;
        return Selecto::Domain->parse(\%document);
    }
    # Directly constructed domains carry their relationships as nested
    # associations and declare no tenant field on related relations, so the
    # context (which always carries the root scope) bounds the target.
    return Selecto::Domain->new(
        name => $domain->name,
        table => $association->table,
        fields => $association->fields,
        associations => $association->associations,
        primary_key => $target->{primary_key},
    );
}

sub _contract_relation {
    my ($domain, $target) = @_;
    my $contract = $domain->contract;
    my $queryable = $target->{association}->queryable;
    return undef unless ref($contract) eq 'HASH' && ref($contract->{schemas}) eq 'HASH'
        && defined($queryable);
    my $relation = $contract->{schemas}{$queryable};
    return ref($relation) eq 'HASH' ? $relation : undef;
}

sub _target_relation {
    my ($domain, $path, $label, $code) = @_;
    Selecto::Error->throw($code, "$label requires an association path")
        unless defined($path) && !ref($path)
            && "$path" =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/;
    my $resolved = $domain->resolve_association($path);
    my $association = $resolved->{association};
    Selecto::Error->throw(
        'unsupported_feature', "$label: retarget targets must be table-backed relations",
        {path => "$path"},
    ) if defined $association->values;
    my $fields = $association->fields;
    my $primary_key = $association->target_primary_key
        // (exists($fields->{id}) ? 'id' : undef);
    Selecto::Error->throw(
        $code, "$label: the target relation must expose its primary key", {path => "$path"},
    ) unless defined($primary_key) && exists($fields->{$primary_key});
    return {path => "$path", association => $association, primary_key => $primary_key};
}

# The joins tree below $path, re-rooted at the target. Flat dotted keys win
# over nested entries, as they do when the original domain resolves a join.
sub _rerooted_joins {
    my ($joins, $path) = @_;
    my %rerooted;
    my $node = {joins => $joins};
    for my $segment (split /\./, $path) {
        $node = ref($node->{joins}) eq 'HASH' ? $node->{joins}{$segment} : undef;
        last unless ref($node) eq 'HASH';
    }
    %rerooted = %{dclone($node->{joins})}
        if ref($node) eq 'HASH' && ref($node->{joins}) eq 'HASH';
    for my $key (grep { index($_, "$path.") == 0 } keys %$joins) {
        my $child = substr($key, length($path) + 1);
        my $flat = dclone($joins->{$key});
        $flat->{joins} //= $rerooted{$child}{joins}
            if ref($flat) eq 'HASH' && ref($rerooted{$child}) eq 'HASH'
                && defined $rerooted{$child}{joins};
        $rerooted{$child} = $flat;
    }
    return \%rerooted;
}

sub _fail {
    my ($message, $details) = @_;
    Selecto::Error->throw('invalid_domain', $message, $details // {});
}

1;
