package Selecto::Action::Graph;
use 5.034;
use strict;
use warnings;
use Storable qw(dclone);
use Scalar::Util qw(blessed);
use Selecto::Domain ();
use Selecto::Expression ();
use Selecto::InsertAdmission ();
use Selecto::Error ();
use Selecto::Write ();

sub build {
    my ($class, $engine, $plan, %options) = @_;
    my $base = Selecto::Action::Plan->new(%{$plan->to_hash}, collection_patches => {});
    my $command = $engine->action_command($base, %options);
    Selecto::Error->throw('unsupported_action_collection_patch', 'collection actions require one inserted or updated root')
        unless ($command->operation eq 'insert' || $command->operation eq 'update') && ($command->expected_count // 0) == 1;
    my @nodes = ({id => 'root', command => $command,
        reference_only => $command->operation eq 'update' && !keys %{$command->assignments}});
    my (@sets, @clients, %seen);
    my $relationships = $engine->domain->writes->{relationships} // {};
    for my $patch_id (sort keys %{$plan->collection_patches}) {
        my $patch = $plan->collection_patches->{$patch_id};
        my $target = $patch->{target};
        Selecto::Error->throw('unsupported_action_collection_patch', 'collection action requires a declared relationship target')
            unless ref($target) eq 'ARRAY' && @$target == 2 && $target->[0] eq 'relationship';
        my $name = $target->[1];
        my $edge = $relationships->{$name};
        Selecto::Error->throw('invalid_action_collection_patch', 'relationship must be declared once with an authored child domain')
            unless ref($edge) eq 'HASH' && ref($edge->{domain}) eq 'HASH' && !$seen{$name}++;
        Selecto::Error->throw('invalid_action_collection_patch', 'collection action requires declared owned composition')
            unless ($edge->{ownership} // '') =~ /\A(?:owned|composition)\z/;
        Selecto::Error->throw('invalid_action_collection_patch', 'relationship strategy is unsupported')
            if defined($edge->{strategy}) && $edge->{strategy} !~ /\A(?:ordered|delta|patch|sync)\z/;
        my $child = Selecto::Domain->parse($edge->{domain});
        my $identity = $edge->{identity_fields} // [$child->primary_key];
        my $primary = $patch->{identity} || $child->primary_key;
        Selecto::Error->throw('invalid_action_collection_patch', 'patch identity must be an exact declared stored identity')
            unless ref($identity) eq 'ARRAY' && @$identity && grep { $_ eq $primary } @$identity;
        my $strategy = $patch->{strategy} || 'ordered';
        Selecto::Error->throw('invalid_action_collection_patch', 'patch strategy is unsupported')
            unless $strategy =~ /\A(?:patch|delta|ordered|sync)\z/;
        my (@members, %clients);
        for my $entry (@{$patch->{entries}}) {
            my $op = {add => 'insert', update => 'update', remove => 'delete', reorder => 'update'}->{$entry->{op}};
            Selecto::Error->throw('invalid_action_collection_patch', 'patch operation is unsupported') unless defined $op;
            my $predicate;
            if ($op ne 'insert') {
                Selecto::Error->throw('invalid_action_collection_patch', 'child identity must be complete')
                    if grep { !exists($entry->{$_}) || !defined($entry->{$_}) || ref($entry->{$_}) } @$identity;
                $predicate = Selecto::Expression->all(map { Selecto::Expression->eq($_,
                    Selecto::InsertAdmission::_value($child->fields->{$_}, $entry->{$_}, $_)) } @$identity);
            }
            my %keys = map { ($_ => 1) } @$identity;
            my $assignments = $op eq 'delete' ? {} : {map { ($_ => $entry->{$_}) }
                grep { $_ ne 'op' && $_ ne 'client_id' && ($op eq 'insert' || !$keys{$_}) } keys %$entry};
            if ($entry->{op} eq 'reorder') {
                my $order = $patch->{order_field};
                Selecto::Error->throw('invalid_action_collection_patch', 'reorder requires the declared order value')
                    unless $order && exists($entry->{$order}) && exists($child->fields->{$order});
                $assignments = {$order => $entry->{$order}};
            }
            my $id = 'patch_' . scalar(@nodes);
            my $metadata = {};
            if (exists($entry->{client_id})) {
                my $client = $entry->{client_id};
                Selecto::Error->throw('invalid_action_collection_patch', 'client identities must be nonblank and unique')
                    unless defined($client) && !ref($client) && "$client" =~ /\S/ && !$clients{$client}++;
                if ($op eq 'insert') {
                    $metadata->{returning} = [@$identity];
                    push @clients, {node => $id, client_identity => "$client", fields => [@$identity]};
                }
            }
            push @nodes, {id => $id, command => Selecto::Write::Command->new(operation => $op,
                relation => $child->table, assignments => $assignments,
                (defined($predicate) ? (predicate => $predicate) : ()), metadata => $metadata),
                bindings => [{from => 'root', key => $edge->{parent_key} // $engine->domain->primary_key,
                    field => $edge->{child_key} // $edge->{foreign_key}}]};
            push @members, $id;
        }
        push @sets, {parent => 'root', relationship => $name, nodes => \@members, delete_missing => 1} if $strategy eq 'sync';
    }
    return (Selecto::Write::Graph->new(nodes => \@nodes, owned_sets => \@sets), \@clients);
}
sub preview {
    my ($class, $engine, $graph) = @_;
    my ($prepared, $contexts) = $engine->_prepared_graph($graph);
    $prepared = Selecto::WriteRules->admit_graph($engine, $prepared, $contexts)
        if $prepared->{_requires_rules};
    my (@statements, @bindings, %owners);
    for my $node (@{$prepared->nodes}) {
        my $command = $node->{command};
        for my $binding (@{$node->{bindings}}) {
            my $owner = $owners{$binding->{from}}{$binding->{key}};
            if (defined($owner)) {
                $command = $command->with_scope_predicate(Selecto::QueryEnforcement::combine(
                    $command->scope_predicate, Selecto::Expression->eq($binding->{field}, $owner)));
            } else { push @bindings, {node => $node->{id}, %$binding} }
            $command = $command->with_assignments({%{$command->assignments}, $binding->{field} => $owner})
                if $command->operation eq 'insert';
        }
        my $child = ref($engine)->new(domain => $contexts->{$node->{id}}{domain},
            adapter => $engine->adapter, scope => $engine->scope, limits => $engine->limits);
        $owners{$node->{id}} = Selecto::WriteRules->candidate($child, $command);
        if ($node->{reference_only}) {
            my $query = Selecto::Query->new->select(@{$command->metadata->{returning} // [$child->domain->primary_key]})
                ->where(Selecto::WriteRules::_predicate($command))->limit(2);
            my $statement = $child->compile($query);
            push @statements, {sql => $statement->sql, params => $statement->params, reference_only => 1};
        } else { push @statements, $engine->adapter->preview_write($command) }
    }
    return {statements => \@statements, generated_bindings => \@bindings};
}
sub result {
    my ($class, $result, $clients) = @_;
    my @mapping;
    for my $client (@$clients) {
        my $values = $result->nodes->{$client->{node}}->values;
        Selecto::Error->throw('generated_value_missing', 'actual generated client identity is incomplete')
            if grep { !exists($values->{$_}) || !defined($values->{$_}) || ref($values->{$_}) } @{$client->{fields}};
        push @mapping, {client_identity => $client->{client_identity}, identity => {map { ($_ => $values->{$_}) } @{$client->{fields}}}};
    }
    $result->{metadata}{identity_mapping} = \@mapping;
    return $result;
}
1;
