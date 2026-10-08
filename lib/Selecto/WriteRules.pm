package Selecto::WriteRules;
use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use JSON::PP ();
use Math::BigInt ();
use Math::BigFloat ();
use Selecto::InsertAdmission ();
use Selecto::Error ();
use Selecto::Query ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();

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
    my ($class, $engine, $predicate, $maximum) = @_;
    my $fields = _fields($engine->domain);
    my $query = Selecto::Query->new->select(@$fields)->limit($maximum + 1);
    $query = $query->where($predicate) if defined $predicate;
    my $result = $engine->all($query);
    _pending('candidate provider did not establish a complete bounded snapshot')
        if exists($result->{complete}) && !$result->{complete};
    _pending('stored candidate exceeds its row bound') if @{$result->{rows}} > $maximum;
    return [map { my $row = $_; _typed_subject($engine,
        +{map { ($fields->[$_] => $row->[$_]) } 0 .. $#$fields}) } @{$result->{rows}}];
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
    my %types = map { ($_ => lc($engine->domain->fields->{$_})) }
        grep { exists($engine->domain->fields->{$_}) && lc($engine->domain->fields->{$_}) =~ /\A(?:integer|decimal|string|boolean)\z/ } keys %fields;
    my $ok = eval { $engine->adapter->insert_admission_storage($command, \%types); 1 };
    _pending('SQLite cannot establish trigger-free ordinary storage for required rules') unless $ok;
}
sub candidate {
    my ($class, $engine, $command) = @_;
    my $values = {};
    if ($command->operation eq 'update' || $command->operation eq 'delete') {
        _pending('protected scalar candidates require exactly one row') unless ($command->expected_count // 0) == 1;
        my $rows = $class->rows($engine, _predicate($command), 1);
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
    _pending('external evidence is not an authoritative stored candidate') if $stage eq 'evidence';
    _pending() if grep { !_at($subject, $_) } @$paths;
    my $result = $rules->evaluate(stage => $stage, operation => $operation, subject => $subject,
        ($stage eq 'transaction' ? (authoritative_stage => 'transaction') : ()),
        (defined($options{action}) ? (action => $options{action}) : ()));
    if ($result->{state} ne 'passed') {
        _pending() if $result->{state} eq 'pending' || $result->{state} eq 'error';
        Selecto::Error->throw('data_rule_failed', 'required domain data rule failed',
            {rule_code => $result->{code}, path => $result->{path}});
    }
    return $result->{normalized};
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
                $value = Math::BigFloat->new("$stored")->bstr;
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
    my ($class, $engine, $command, $values) = @_;
    my $rules = $engine->domain->rules;
    return ($command, $values) unless $rules;
    $values = _typed_subject($engine, $values);
    my $before = dclone($values);
    my $input = _typed_subject($engine, $command->assignments);
    $input = $class->evaluate($rules, 'input', $command->operation, $input);
    $values = {%$values, %$input};
    $values = $class->evaluate($rules, $_, $command->operation, $values) for qw(candidate transaction evidence);
    my $assignments = $command->assignments;
    for my $field (keys %$values) {
        next unless exists($engine->domain->fields->{$field});
        my $changed = !exists($before->{$field}) || JSON::PP->new->canonical->encode([$values->{$field}]) ne JSON::PP->new->canonical->encode([$before->{$field}]);
        $assignments->{$field} = $values->{$field} if exists($assignments->{$field}) || $changed;
    }
    return ($command->with_assignments($assignments), $values);
}
sub govern {
    my ($class, $engine, $command) = @_;
    return $command unless $class->has_rules($engine->domain, $command->operation);
    _check_storage($engine, $command);
    my $relationships = $engine->domain->writes->{relationships} // {};
    if (grep { my $stage = $_; grep { exists($relationships->{$_->[0]}) }
        @{$engine->domain->rules->applicable_paths($stage, $command->operation)} } qw(candidate transaction evidence)) {
        my ($graph, $contexts) = $engine->_prepared_graph(Selecto::Write::Graph->new(nodes => [{id => 'root', command => $command}]));
        return $class->admit_graph($engine, $graph, $contexts)->nodes->[0]{command};
    }
    my $values = $class->candidate($engine, $command);
    my ($normalized) = $class->_normalize($engine, $command, $values);
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
    my ($class, $root, $graph, $contexts) = @_;
    my @nodes = @{$graph->nodes};
    my %nodes = map { ($_->{id} => $_) } @nodes;
    my %engines = map { ($_ => ref($root)->new(domain => $contexts->{$_}{domain},
        adapter => $root->adapter, scope => $root->scope, limits => $root->limits)) } keys %$contexts;
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
            my $domain = Selecto::Domain->parse($edge->{domain});
            my $child_engine = ref($root)->new(domain => $domain, adapter => $root->adapter,
                scope => $root->scope, limits => $root->limits);
            my $parent_key = $edge->{parent_key} // $engine->domain->primary_key;
            my $child_key = $edge->{child_key} // $edge->{foreign_key};
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
        my ($normalized, $result) = $class->_normalize($engine, $command, $candidate);
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
    my ($prepared) = $root->_prepared_graph(Selecto::Write::Graph->new(nodes => \@nodes, owned_sets => $graph->owned_sets));
    return $prepared;
}
1;
