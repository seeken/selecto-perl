package Selecto::WriteRules;
use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);
use Storable qw(dclone);
use JSON::PP ();
use Math::BigInt ();
use Math::BigFloat ();
use Selecto::InsertAdmission ();
use Selecto::Error ();
use Selecto::Query ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();
our $HYDRATION;
my $STORED_FAILURES;

sub _with_stored_failure_deferral {
    my ($class, $work) = @_;
    return $work->() if $STORED_FAILURES;
    my $failures = [];
    $STORED_FAILURES = $failures;
    my $scope = bless {restore => sub { $STORED_FAILURES = undef }}, 'Selecto::WriteRules::_FailureScope';
    my $want = wantarray;
    my (@result, $result);
    if ($want) { @result = $work->() } else { $result = $work->() }
    die $failures->[0] if @$failures;
    return $want ? @result : $result;
}


sub has_rules {
    my ($class, $domain, $operation) = @_;
    my $rules = $domain->rules;
    return 0 unless $rules;
    return scalar(grep { @{$rules->applicable_paths($_, $operation)} } qw(input candidate transaction evidence));
}
sub _pending { Selecto::Error->throw('required_data_rule_pending', $_[0] // 'required rule lacks a complete governed candidate') }
sub _fields {
    my ($domain) = @_;
    return [sort grep { ref($domain->_field_metadata_view($_)->{computed}) ne 'HASH' } keys %{$domain->fields}];
}
sub _predicate {
    my ($command) = @_;
    return Selecto::QueryEnforcement::combine($command->predicate, $command->scope_predicate,
        $command->query_enforcement ? $command->query_enforcement->predicate : undef);
}
sub rows {
    my ($class, $engine, $predicate, $maximum, %options) = @_;
    $maximum = 1000 - $HYDRATION->{loaded}
        if $HYDRATION && $maximum > 1000 - $HYDRATION->{loaded};
    my $fields = _fields($engine->domain);
    my $query = Selecto::Query->new->select(@$fields)->limit($maximum + 1);
    $query = $query->where($predicate) if defined $predicate;
    my $result = $engine->all($query);
    _pending('candidate provider did not establish a complete bounded snapshot')
        if exists($result->{complete}) && !$result->{complete};
    _pending('stored candidate exceeds its row bound') if @{$result->{rows}} > $maximum;
    $HYDRATION->{loaded} += @{$result->{rows}} if $HYDRATION;
    return [map { my $row = $_; my $values = +{map { ($fields->[$_] => $row->[$_]) } 0 .. $#$fields};
        $options{raw} ? $values : _typed_subject($engine, $values) } @{$result->{rows}}];
}
sub _check_storage {
    my ($engine, $command, $bound_fields) = @_;
    return unless $engine->adapter->name eq 'sqlite';
    my %fields = map { ($_ => 1) } keys %{$command->assignments}, @{$bound_fields // []};
    if (my $rules = $engine->domain->rules) {
        for my $stage (qw(input candidate transaction evidence)) {
            $fields{$_->[0]} = 1 for @{$rules->applicable_paths($stage, $command->operation)};
        }
    }
    _pending('SQLite rule candidates require supported physical scalar types')
        if grep { exists($engine->domain->fields->{$_})
            && lc($engine->domain->fields->{$_}) !~ /\A(?:integer|decimal|string|boolean)\z/ } keys %fields;
    my %types = map { ($_ => lc($engine->domain->fields->{$_})) }
        grep { exists($engine->domain->fields->{$_}) } keys %fields;
    my $ok = eval {
        $engine->adapter->rule_candidate_storage($command) if $engine->adapter->can('rule_candidate_storage');
        $engine->adapter->insert_admission_storage($command, \%types, for_rules => 1);
        1;
    };
    _pending('SQLite cannot establish trigger-free ordinary storage for required rules') unless $ok;
}
sub candidate {
    my ($class, $engine, $command) = @_;
    my $values = {};
    if ($command->operation eq 'update' || $command->operation eq 'delete') {
        _pending('protected scalar candidates require exactly one row') unless ($command->expected_count // 0) == 1;
        my $rows = $class->rows($engine, _predicate($command), 1, raw => 1);
        Selecto::Error->throw('cardinality_mismatch', 'candidate must resolve exactly one governed row') unless @$rows == 1;
        $values = $rows->[0];
    } elsif ($command->operation eq 'upsert') {
        _pending('protected upsert candidates require a provider-selected stored branch');
    }
    for my $field (keys %{$command->assignments}) {
        my $value = $command->assignments->{$field};
        if (blessed($value) && $value->isa('Selecto::Write::Expression')) {
            if ($value->kind eq 'literal') { $value = $value->arguments->[0] }
            else { delete $values->{$field}; next }
        }
        $values->{$field} = $value;
    }
    return $values;
}
sub _at {
    my ($subject, $path) = @_;
    for my $field (@$path) { return 0 unless ref($subject) eq 'HASH' && exists($subject->{$field}); $subject = $subject->{$field} }
    return !(blessed($subject) && !JSON::PP::is_bool($subject));
}
sub evaluate {
    my ($class, $rules, $stage, $operation, $subject, %options) = @_;
    my $paths = $rules->applicable_paths($stage, $operation, $options{action});
    return $subject unless @$paths;
    my $consumed = $rules->consumed_paths($stage, $operation, $options{action});
    my $unknown;
    if ($stage eq 'input' || $stage eq 'action_input') {
        $unknown = grep { _unknown_input($subject, $_) } @$consumed;
        $subject = _clean_input($subject);
    } else {
        $unknown = grep { !_known_path($options{domain}, $subject, $_) } @$consumed;
    }
    my $method = $options{test_only} ? '_recheck' : 'evaluate';
    my $result = $rules->$method(stage => $stage, operation => $operation, subject => $subject,
        ($stage eq 'transaction' ? (authoritative_stage => 'transaction') : ()),
        (defined($options{action}) ? (action => $options{action}) : ()));
    Selecto::Error->throw('evaluation_limit', 'rule evaluation exceeds its finite resource budget')
        if ($result->{code} // '') eq 'evaluation_limit';
    _pending('consumed input or prospective candidate is unknown') if $unknown;
    if ($result->{state} ne 'passed') {
        _pending() if $result->{state} eq 'pending' || $result->{state} eq 'error';
        my $error = Selecto::Error->new(code => 'data_rule_failed', message => 'required domain data rule failed',
            details => {rule_code => $result->{code}, path => $result->{path}});
        if ($STORED_FAILURES && $stage ne 'input' && $stage ne 'action_input') { push @$STORED_FAILURES, $error }
        else { die $error }
    }
    return $result->{normalized};
}
sub literal_input {
    my ($class, $command) = @_;
    Selecto::Error->throw('invalid_write', 'rule input requires a write command')
        unless blessed($command) && $command->isa('Selecto::Write::Command');
    my $values = $command->assignments;
    for my $field (keys %$values) {
        my $value = $values->{$field};
        $values->{$field} = $value->arguments->[0]
            if blessed($value) && $value->isa('Selecto::Write::Expression') && $value->kind eq 'literal';
    }
    return $values;
}
sub _unknown_input {
    my ($value, $path) = @_;
    return blessed($value) && !JSON::PP::is_bool($value) unless @$path;
    return 1 if blessed($value) && !JSON::PP::is_bool($value);
    my ($head, @tail) = @$path;
    if (ref($head) eq 'HASH') {
        return _unknown_value($value) if $head->{complete};
        return 0 unless ref($value) eq 'ARRAY';
        return scalar(grep { _unknown_input($_, \@tail) } @$value);
    }
    return 0 unless ref($value) eq 'HASH' && exists $value->{$head};
    return _unknown_input($value->{$head}, \@tail);
}
sub _unknown_value {
    my ($value, $active, $depth) = @_;
    $active //= {}; $depth //= 0;
    return 1 if $depth > 64 || blessed($value) && !JSON::PP::is_bool($value);
    return 0 unless ref($value) eq 'ARRAY' || ref($value) eq 'HASH';
    my $id = refaddr($value);
    return 1 if $active->{$id};
    local $active->{$id} = 1;
    return scalar(grep { _unknown_value($_, $active, $depth + 1) }
        ref($value) eq 'ARRAY' ? @$value : values %$value);
}
sub _clean_input {
    my $value = shift;
    return undef if blessed($value) && !JSON::PP::is_bool($value);
    return [map { _clean_input($_) } @$value] if ref($value) eq 'ARRAY';
    return {map { ($_ => _clean_input($value->{$_})) }
        grep { !blessed($value->{$_}) || JSON::PP::is_bool($value->{$_}) } keys %$value} if ref($value) eq 'HASH';
    return $value;
}
sub _known_path {
    my ($domain, $value, $path) = @_;
    return !(blessed($value) && !JSON::PP::is_bool($value)) unless @$path;
    my ($head, @tail) = @$path;
    if (ref($head) eq 'HASH') {
        if ($head->{each}) {
            return 1 unless ref($value) eq 'ARRAY';
            return !grep { !_known_path($domain, $_, \@tail) } @$value;
        }
        return _complete_rows($domain, $value);
    }
    return 0 unless ref($value) eq 'HASH' && exists $value->{$head};
    my $edges = $domain ? $domain->writes->{relationships} // {} : {};
    my $edge = ref($edges->{$head}) eq 'HASH' ? $edges->{$head} : {};
    my $child = $edge->{domain};
    $domain = ref($child) eq 'HASH' ? _relationship_domain($child) : undef;
    return _known_path($domain, $value->{$head}, \@tail);
}
sub _relationship_domain {
    require Selecto::Engine;
    return Selecto::Engine::_native_relationship_domain($_[0]);
}
sub _complete_rows {
    my ($domain, $value) = @_;
    return 0 if blessed($value) && !JSON::PP::is_bool($value);
    return 1 unless $domain && ref($value) eq 'ARRAY';
    for my $row (@$value) {
        next unless ref($row) eq 'HASH';
        return 0 if grep { !exists($row->{$_}) || blessed($row->{$_}) && !JSON::PP::is_bool($row->{$_}) } keys %{$domain->fields};
        for my $name (keys %{$domain->writes->{relationships} // {}}) {
            my $edge = $domain->writes->{relationships}{$name};
            next unless ($edge->{ownership} // '') =~ /\A(?:owned|composition)\z/;
            return 0 unless exists($row->{$name}) && ref($edge->{domain}) eq 'HASH'
                && _complete_rows(_relationship_domain($edge->{domain}), $row->{$name});
        }
    }
    return 1;
}
sub _typed_subject {
    my ($engine, $subject) = @_;
    my %values = %$subject;
    for my $field (keys %values) {
        my $value = $values{$field};
        if (blessed($value) && $value->isa('Selecto::Write::Expression')) {
            if ($value->kind eq 'literal') { $value = $value->arguments->[0] }
            else { delete $values{$field}; next }
        }
        $values{$field} = $value;
        next unless defined($value) && exists($engine->domain->fields->{$field});
        my $type = lc($engine->domain->fields->{$field} // '');
        if ($type eq 'integer') {
            _pending('integer candidate requires a bounded exact stored scalar')
                unless !ref($value) && "$value" =~ /\A[+-]?[0-9]+\z/
                    && length("$value") <= $engine->limits->get('max_rule_numeric_digits') + 1;
            my $canonical = Math::BigInt->new("$value")->bstr;
            Selecto::InsertAdmission::_value('integer', $canonical, $field);
            $value = 0 + $canonical;
        } elsif ($type eq 'decimal') {
            _pending('decimal candidate requires a bounded exact scalar')
                unless !ref($value) && "$value" =~ /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE]([+-]?[0-9]+))?\z/
                    && length("$value") <= $engine->limits->get('max_rule_numeric_digits') + 2
                    && (!defined($1) || abs($1) <= $engine->limits->get('max_rule_numeric_digits'));
            $value = Math::BigFloat->new("$value")->bstr;
            if ($engine->adapter->name eq 'sqlite') {
                my ($stored) = $engine->adapter->dbh->selectrow_array('SELECT CAST(? AS NUMERIC)', undef, $value);
                _pending('SQLite decimal candidate is non-finite') if !defined($stored) || "$stored" =~ /inf|nan/i;
                # Retain the actual native scalar kind. Turning a projected
                # numeric value back into text would make type.is coerce.
                $value = $stored;
            }
        } elsif ($type eq 'boolean') {
            _pending('boolean candidate requires a canonical stored scalar')
                unless JSON::PP::is_bool($value) || (!ref($value) && "$value" =~ /\A[01]\z/);
            $value = $value ? JSON::PP::true : JSON::PP::false;
        } elsif (($type eq 'string' || $type eq 'text') && !ref($value)) { $value = "$value" }
        $values{$field} = $value;
    }
    return \%values;
}
sub _normalize {
    my ($class, $engine, $command, $values, $submitted) = @_;
    my $rules = $engine->domain->rules;
    return ($command, _typed_subject($engine, $values)) unless $rules;
    my $before = dclone($values);
    my $original_input = $submitted // $class->literal_input($command);
    my $input = $class->evaluate($rules, 'input', $command->operation, $original_input);
    # INPUT runs before native conversion. Materialize its actual mutations
    # independently of candidate availability (a NULL rowid alias is unknown).
    my $input_assignments = $command->assignments;
    # Unchanged raw inputs must never replace an already projected storage value.
    for my $field (keys %$input) {
        next if blessed($input->{$field}) && !JSON::PP::is_bool($input->{$field});
        if (!exists($original_input->{$field}) || _changed($input->{$field}, $original_input->{$field})) {
            $values->{$field} = $input->{$field};
            $input_assignments->{$field} = $input->{$field};
        }
    }
    $command = $command->with_assignments($input_assignments);
    $values = _typed_subject($engine, $values);
    $values = $engine->adapter->rule_project_subject($command, $values)
        if $engine->adapter->can('rule_project_subject');
    $values = $class->evaluate($rules, $_, $command->operation, $values, domain => $engine->domain) for qw(candidate transaction evidence);
    $values = _typed_subject($engine, $values);
    $values = $engine->adapter->rule_project_subject($command, $values)
        if $engine->adapter->can('rule_project_subject');
    $values = $class->evaluate($rules, 'candidate', $command->operation, $values,
        domain => $engine->domain, test_only => 1);
    my $assignments = $command->assignments;
    for my $field (keys %$values) {
        next unless exists($engine->domain->fields->{$field});
        my $changed = !exists($before->{$field}) || _changed($values->{$field}, $before->{$field});
        $assignments->{$field} = $values->{$field} if exists($assignments->{$field}) || $changed;
    }
    my $normalized = $command->with_assignments($assignments);
    _check_storage($engine, $normalized) unless $normalized->operation eq 'update' && !keys %$assignments;
    return ($normalized, $values);
}
sub _changed { JSON::PP->new->canonical->encode([$_[0]]) ne JSON::PP->new->canonical->encode([$_[1]]) }
sub govern {
    my ($class, @args) = @_;
    return $class->_with_stored_failure_deferral(sub { $class->_govern(@args) });
}
sub _govern {
    my ($class, $engine, $command, %options) = @_;
    return $command unless $class->has_rules($engine->domain, $command->operation);
    local $HYDRATION = $HYDRATION // {loaded => 0};
    _check_storage($engine, $command);
    my $relationships = $engine->domain->writes->{relationships} // {};
    if (grep { my $stage = $_; grep { exists($relationships->{$_->[0]}) }
        @{$engine->domain->rules->applicable_paths($stage, $command->operation)} } qw(candidate transaction evidence)) {
        my ($graph, $contexts) = $engine->_prepared_graph(Selecto::Write::Graph->new(nodes => [{id => 'root', command => $command}]));
        $contexts->{root}{rule_input} = $options{input} if defined $options{input};
        return $class->admit_graph($engine, $graph, $contexts)->nodes->[0]{command};
    }
    my $values = $class->candidate($engine, $command);
    my ($normalized) = $class->_normalize($engine, $command, $values, $options{input});
    return $engine->governed_write($normalized);
}
sub _key {
    my ($domain, $fields, $values) = @_;
    _pending('collection identity is incomplete') if grep { !exists($values->{$_}) || !defined($values->{$_}) || ref($values->{$_}) } @$fields;
    return JSON::PP->new->canonical->encode([map {
        my $value = $values->{$_};
        if (($domain->fields->{$_} // '') eq 'integer') {
            _pending('collection identity must retain exact integers') unless "$value" =~ /\A[+-]?[0-9]+\z/;
            +{integer => Math::BigInt->new("$value")->bstr};
        } else { +{string => "$value"} }
    } @$fields]);
}
sub admit_graph {
    my ($class, @args) = @_;
    return $class->_with_stored_failure_deferral(sub { $class->_admit_graph(@args) });
}
sub _admit_graph {
    my ($class, $root, $graph, $contexts) = @_;
    local $HYDRATION = $HYDRATION // {loaded => 0};
    my @nodes = @{$graph->nodes};
    my %nodes = map { ($_->{id} => $_) } @nodes;
    my %engines = map { ($_ => ref($root)->new(domain => $contexts->{$_}{domain},
        adapter => $root->adapter, scope => $root->scope, write_context => $root->write_context,
        limits => $root->limits)) } keys %$contexts;
    my (%children, %edges, %sets, %values);
    for my $node (@nodes[1 .. $#nodes]) {
        _pending('protected graph candidates require one ownership binding') unless @{$node->{bindings}} == 1;
        my $binding = $node->{bindings}[0];
        my $relationships = $contexts->{$binding->{from}}{relationships};
        my @names = grep {
            my $edge = $relationships->{$_};
            ref($edge) eq 'HASH' && ($edge->{parent_key} // $contexts->{$binding->{from}}{primary_key}) eq $binding->{key}
                && ($edge->{child_key} // $edge->{foreign_key} // '') eq $binding->{field}
                && ref($edge->{domain}) eq 'HASH'
                && ($edge->{domain}{source}{source_table} // $edge->{domain}{table} // '') eq $node->{command}->relation
        } keys %{$relationships // {}};
        _pending('candidate edge must resolve one declared relationship') unless @names == 1;
        $edges{$node->{id}} = $relationships->{$names[0]};
        push @{$children{$binding->{from}}{$names[0]}}, $node->{id};
    }
    $sets{$_->{parent}}{$_->{relationship}} = $_ for @{$graph->owned_sets};
    my $walk;
    $walk = sub {
        my ($id, $owner) = @_;
        my $node = $nodes{$id};
        my $command = $node->{command};
        if (@{$node->{bindings}}) {
            my $binding = $node->{bindings}[0];
            if (defined($owner)) {
                $command = $command->with_scope_predicate(Selecto::QueryEnforcement::combine(
                    $command->scope_predicate, Selecto::Expression->eq($binding->{field}, $owner)));
                $command = $command->with_assignments({%{$command->assignments}, $binding->{field} => $owner})
                    if $command->operation eq 'insert';
            } elsif ($command->operation ne 'insert') { _pending('stored child requires a stored parent key') }
        }
        my $engine = $engines{$id};
        _check_storage($engine, $command, [map { $_->{field} } @{$node->{bindings}}]) unless $node->{reference_only};
        my $candidate = $class->candidate($engine, $command);
        my $relationships = $contexts->{$id}{relationships} // {};
        my %names = map { ($_ => 1) } keys %{$children{$id} // {}}, keys %{$sets{$id} // {}};
        if (my $rules = $engine->domain->rules) {
            for my $stage (qw(candidate transaction evidence)) {
                $names{$_->[0]} = 1 for grep { exists($relationships->{$_->[0]}) }
                    @{$rules->applicable_paths($stage, $command->operation)};
            }
        }
        for my $name (sort keys %names) {
            my $edge = $relationships->{$name};
            _pending('collection rules require an authored child domain') unless ref($edge->{domain}) eq 'HASH';
            my $domain = _relationship_domain($edge->{domain});
            my $child_engine = ref($root)->new(domain => $domain, adapter => $root->adapter,
                scope => $root->scope, write_context => $root->write_context, limits => $root->limits);
            my $parent_key = $edge->{parent_key} // $engine->domain->primary_key;
            my $child_key = $edge->{child_key} // $edge->{foreign_key};
            _pending('stored collection ownership key cannot be reassigned')
                if $command->operation ne 'insert' && exists($command->assignments->{$parent_key});
            $root->adapter->ownership_storage($engine->domain->table, $parent_key,
                $domain->table, $child_key) if $root->adapter->can('ownership_storage');
            my $owner_value = $candidate->{$parent_key};
            my $final = [];
            if ($command->operation ne 'insert') {
                _pending('stored collection requires its exact parent key') unless defined $owner_value;
                my $maximum = $edge->{max_rows} // 1000;
                _pending('candidate collection limit must be bounded') unless !ref($maximum) && "$maximum" =~ /\A[1-9][0-9]*\z/ && $maximum <= 1000;
                my $predicate = Selecto::Expression->eq($child_key, $owner_value);
                if (my $scope = $domain->write_tenant_scope) {
                    my $tenants = $root->_trusted_write_tenants($root->domain->required_predicate);
                    _pending('stored child candidate requires trusted tenant scope') unless $tenants && @$tenants;
                    $predicate = Selecto::Expression->all($predicate,
                        @$tenants == 1 ? Selecto::Expression->eq($scope->{field}, $tenants->[0])
                            : Selecto::Expression->in($scope->{field}, $tenants));
                }
                $final = $class->rows($child_engine, $predicate, $maximum);
            }
            my $identity = $edge->{identity_fields} // [$domain->primary_key];
            _pending('collection identity must be ordered stored fields') unless ref($identity) eq 'ARRAY' && @$identity
                && !grep { !exists($domain->fields->{$_}) || ref($domain->_field_metadata_view($_)->{computed}) eq 'HASH' } @$identity;
            my (@kept, %touched);
            for my $child_id (@{$children{$id}{$name} // []}) {
                my $child_values = $walk->($child_id, $owner_value);
                my $child_command = $nodes{$child_id}{command};
                if ($child_command->operation eq 'insert') { push @$final, $child_values; push @kept, $child_values; next }
                my $key = _key($domain, $identity, $child_values);
                Selecto::Error->throw('invalid_write_graph', 'collection delta addresses an identity more than once') if $touched{$key}++;
                my @positions = grep {
                    my $row = $final->[$_];
                    !(grep { !exists($row->{$_}) || !defined($row->{$_}) } @$identity)
                        && _key($domain, $identity, $row) eq $key
                } 0 .. $#$final;
                Selecto::Error->throw('cardinality_mismatch', 'child candidate is not in its governed owner collection') unless @positions == 1;
                if ($child_command->operation eq 'delete') { splice @$final, $positions[0], 1 }
                else { $final->[$positions[0]] = $child_values; push @kept, $child_values }
            }
            if ($sets{$id}{$name}) {
                my %keep = map { (_key($domain, $identity, $_) => 1) } grep {
                    my $row = $_; !grep { !exists($row->{$_}) || !defined($row->{$_}) } @$identity
                } @kept;
                for my $omitted (@$final) {
                    next if grep { !exists($omitted->{$_}) || !defined($omitted->{$_}) } @$identity;
                    next if $keep{_key($domain, $identity, $omitted)};
                    my $deletion = $child_engine->governed_write(Selecto::Write::Command->new(operation => 'delete',
                        relation => $domain->table, predicate => Selecto::Expression->all(map { Selecto::Expression->eq($_, $omitted->{$_}) } @$identity)));
                    $class->govern($child_engine, $deletion);
                }
                $final = \@kept;
            }
            _pending('final candidate collection exceeds its bound') if @$final > 1000;
            $candidate->{$name} = $final;
        }
        my ($normalized, $result) = $class->_normalize($engine, $command, $candidate, $contexts->{$id}{rule_input});
        for my $name (keys %names) {
            my $key = $relationships->{$name}{parent_key} // $engine->domain->primary_key;
            _pending('normalizers cannot change collection ownership keys')
                if exists($candidate->{$key}) && exists($result->{$key}) && _changed($candidate->{$key}, $result->{$key});
        }
        my $assignments = $normalized->assignments;
        for my $binding (@{$node->{bindings}}) {
            _pending('normalizers cannot change generated ownership bindings')
                if defined($owner) && exists($assignments->{$binding->{field}})
                    && (!defined($assignments->{$binding->{field}}) || "$assignments->{$binding->{field}}" ne "$owner");
            delete $assignments->{$binding->{field}};
        }
        $node->{command} = $normalized->with_assignments($assignments);
        return $result;
    };
    $walk->($nodes[0]{id}, undef);
    # Re-run domain governance after every normalizer, including trusted tenant checks.
    for my $node (@nodes) {
        my $metadata=$node->{command}->metadata;
        my $returning=$graph->public_returning($node->{id});
        if (defined $returning) { $metadata->{returning}=$returning }
        else { delete $metadata->{returning} }
        $node->{command}=$node->{command}->with_metadata($metadata);
    }
    my ($prepared) = $root->_prepared_graph(Selecto::Write::Graph->new(nodes => \@nodes, owned_sets => $graph->owned_sets));
    return $prepared;
}
{
    package Selecto::WriteRules::_FailureScope;
    sub DESTROY { $_[0]{restore}->() }
}
1;
