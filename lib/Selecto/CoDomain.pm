package Selecto::CoDomain;

use 5.034;
use strict;
use warnings;
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::QueryLibrary ();

sub definition {
    my ($class, $source_domain, $id) = @_;
    _domain($source_domain, 'source domain');
    my $key = _id($id);
    my $definitions = $source_domain->co_domains;
    Selecto::Error->throw(
        'unknown_co_domain', "unknown co-domain $key", {co_domain => $key},
    ) unless ref($definitions->{$key}) eq 'HASH';
    return dclone($definitions->{$key});
}

sub lookup {
    my ($class, %args) = @_;
    my $source_domain = $args{source_domain};
    my $engine = $args{engine};
    _domain($source_domain, 'source domain');
    Selecto::Error->throw('invalid_co_domain', 'co-domain lookup requires an engine')
        unless blessed($engine) && $engine->isa('Selecto::Engine');
    $engine->assert_tenant_boundary(access => 'read', host_predicate => $args{predicate});
    my $definition = $class->definition($source_domain, $args{co_domain});
    my $target_domain = $engine->domain;
    my $text = $args{query};
    Selecto::Error->throw('invalid_co_domain_lookup', 'lookup query must be a non-empty scalar')
        if !defined($text) || ref($text) || "$text" eq '' || length("$text") > 200
            || "$text" =~ /\0/;
    $text = "$text";
    my $limit = defined($args{limit}) ? $args{limit} : 20;
    Selecto::Error->throw('invalid_co_domain_lookup', 'lookup limit must be between 1 and 100')
        unless defined($limit) && !ref($limit) && "$limit" =~ /\A\d+\z/
            && $limit >= 1 && $limit <= 100;
    my $parameters = $args{parameters} // $definition->{parameters} // {};
    Selecto::Error->throw('invalid_co_domain_lookup', 'lookup parameters must be an object')
        unless ref($parameters) eq 'HASH';

    my $query = $engine->query;
    if (defined $definition->{view}) {
        $query = $engine->apply_view($query, $definition->{view}, $parameters);
    } else {
        $query = $engine->apply_segments(
            $query, $definition->{segments} // [], $parameters,
        ) if @{$definition->{segments} // []};
        $query = $engine->apply_projection($query, $definition->{projection});
        $query = $engine->apply_ordering($query, $definition->{ordering})
            if defined $definition->{ordering};
    }

    _public_field($target_domain, $_)
        for Selecto::Expression->field_references($query->predicate);
    my %selection_index;
    my $selection_index = 0;
    for my $selection (@{$query->selections}) {
        _public_field($target_domain, $_)
            for Selecto::Expression->field_references($selection);
        if ($selection->kind eq 'field') {
            my $field = $selection->arguments->[0];
            $selection_index{$field} //= $selection_index;
        }
        $selection_index++;
    }
    my $result = $definition->{result};
    my @result_fields = (
        $result->{value_field}, $result->{label_field},
        @{$result->{description_fields} // []},
    );
    for my $field (@result_fields) {
        _public_field($target_domain, $field);
        Selecto::Error->throw(
            'invalid_co_domain', 'co-domain result field is absent from its projection',
            {co_domain => _id($args{co_domain}), field => $field},
        ) unless exists $selection_index{$field};
    }

    my $search = $definition->{search};
    _public_field($target_domain, $_) for @{$search->{fields}};
    for my $order (@{$query->orders}) {
        my $field = $order->[0];
        _public_field($target_domain, $_) for blessed($field)
            ? Selecto::Expression->field_references($field) : ($field);
    }
    Selecto::Error->throw(
        'unsupported_feature', 'co-domain lookup requires adapter text search support',
        {co_domain => _id($args{co_domain}), adapter => $engine->adapter->name},
    ) unless $engine->adapter->supports('text_search');
    my $search_text = $search->{mode} eq 'prefix' ? _prefix_query($text) : $text;
    return {results => [], query => $query} unless length $search_text;
    my %search_options = (
        configuration => $search->{configuration}, mode => $search->{mode},
    );
    my $search_expression = Selecto::Expression->text_search(
        $search->{fields}, $search_text, %search_options,
    );
    my @predicates = grep { defined } ($query->predicate, $args{predicate}, $search_expression);
    for my $predicate (@predicates) {
        Selecto::Error->throw(
            'invalid_co_domain_lookup', 'lookup scope predicate must be a Selecto expression',
        ) unless blessed($predicate) && $predicate->isa('Selecto::Expression');
    }
    $query = $query->where(@predicates == 1
        ? $predicates[0] : Selecto::Expression->all(\@predicates));
    if ($search->{rank}) {
        my $orders = $query->orders;
        my $rank = Selecto::Expression->text_rank(
            $search->{fields}, $search_text, %search_options,
        );
        $query = $query->replace_orders([[$rank, 'desc'], @$orders]);
    }
    $query = $query->limit($limit);

    my $raw = $engine->all($query, canonical_values => 1);
    Selecto::Error->throw('invalid_co_domain_result', 'adapter returned an invalid lookup result')
        unless ref($raw) eq 'HASH' && ref($raw->{rows}) eq 'ARRAY';
    my @description_fields = @{$result->{description_fields} // []};
    my @results;
    for my $row (@{$raw->{rows}}) {
        next unless ref($row) eq 'ARRAY';
        my $value = $row->[$selection_index{$result->{value_field}}];
        my $label = $row->[$selection_index{$result->{label_field}}];
        next if !defined($value) || ref($value);
        $label = $value if !defined($label) || ref($label) || "$label" eq '';
        my @description;
        for my $field (@description_fields) {
            my $field_value = $row->[$selection_index{$field}];
            next if !defined($field_value) || ref($field_value) || "$field_value" eq '';
            my $metadata = $target_domain->field_metadata($field);
            my $field_label = ref($metadata) eq 'HASH' ? $metadata->{label} : undef;
            push @description, defined($field_label) && !ref($field_label) && "$field_label" ne ''
                ? "$field_label $field_value" : "$field_value";
        }
        push @results, {
            value => "$value", label => "$label",
            (@description ? (description => join(" \x{b7} ", @description)) : ()),
        };
    }
    return {results => \@results, query => $query};
}

sub _prefix_query {
    my ($value) = @_;
    my @tokens = map { lc $_ } "$value" =~ /([[:alnum:]_]+)/g;
    return join(' & ', map { $_ . ':*' } @tokens);
}

sub _public_field {
    my ($domain, $field) = @_;
    Selecto::Error->throw('invalid_co_domain', 'co-domain lookup uses a non-public field')
        unless $domain->field_is_public($field);
    return $domain->resolve($field);
}

sub _domain {
    my ($value, $label) = @_;
    Selecto::Error->throw('invalid_domain', "$label must be a Selecto::Domain")
        unless blessed($value) && $value->isa('Selecto::Domain');
}

sub _id {
    my ($value) = @_;
    Selecto::Error->throw('invalid_co_domain', 'co-domain id must be a lowercase identifier')
        unless defined($value) && !ref($value) && "$value" =~ /\A[a-z][a-z0-9_]*\z/;
    return "$value";
}

1;

__END__

=head1 NAME

Selecto::CoDomain - governed lookups into another domain

=head1 SYNOPSIS

  # In the source (for example "loads") domain contract:
  co_domains => {
      carriers => {
          domain => 'client',
          view   => 'carrier_lookup',          # or projection/segments/ordering
          search => {fields => [qw(co_name cl_key city)], mode => 'prefix', rank => 1},
          result => {
              value_field        => 'id',
              label_field        => 'co_name',
              description_fields => [qw(cl_key city state)],
          },
      },
  },

  # In the host, with an engine for the target domain built from trusted context:
  my $found = Selecto::CoDomain->lookup(
      source_domain => $loads_domain,
      co_domain     => 'carriers',
      engine        => $tenant_scoped_client_engine,
      query         => $search_text,
      predicate     => $selection_specific_scope,   # optional, can only narrow
      limit         => 20,
  );
  # {results => [{value => '17', label => 'Acme Freight', description => '...'}, ...],
  #  query => $selecto_query}

=head1 DESCRIPTION

A co-domain lets one domain declare a bounded lookup that is owned and
governed by another domain, such as a "choose a carrier" picker on a load
form. The contract names the target domain, the target's query-library view
or projection, the searchable fields and how rows map to options. It never
carries connection details, SQL or a client-selected engine: the host
resolves the target domain and supplies an engine for it.

The target engine's required predicate and tenant are preserved, and the
optional C<predicate> can only restrict the lookup further (for example to
rows eligible for the current action). On a tenant-field domain the lookup
requires a tenant boundary (C<missing_tenant_scope>).

Searching uses full-text search, so the target adapter needs the
C<text_search> capability (PostgreSQL); others fail with
C<unsupported_feature>.

=head1 CLASS METHODS

=head2 definition

  my $definition = Selecto::CoDomain->definition($source_domain, 'carriers');

Returns a copy of one declared co-domain; throws C<unknown_co_domain>.

=head2 lookup

Arguments: C<source_domain>, C<co_domain>, C<engine>, C<query> (1 to 200
characters), optional C<predicate>, C<limit> (1 to 100, default 20) and
C<parameters> for the target's segments. Returns C<results>, a list of
C<< {value, label, description} >> with values and labels as strings, and
the executed C<query>.

C<search> takes C<fields>, C<mode> (C<prefix> turns the text into prefix
terms; other modes pass it to the text search), optional
C<configuration>, and C<rank> to order by relevance. Result fields must be
selected by the view or projection.

=head1 ERRORS

C<unknown_co_domain>, C<invalid_co_domain>, C<invalid_co_domain_lookup>,
C<missing_tenant_scope>, C<unsupported_feature>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::QueryLibrary>, L<Selecto::Engine>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
