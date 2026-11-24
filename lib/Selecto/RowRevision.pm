package Selecto::RowRevision;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Math::BigFloat ();
use Cpanel::JSON::XS ();
use Selecto::CanonicalJSON ();
use Selecto::Error ();
use Selecto::Expression ();
use Selecto::QueryEnforcement ();

sub fields { my ($class, $spec) = @_; return $spec->{columns} // [$spec->{column}] }
sub token {
    my ($class, $spec, $values, $types) = @_;
    return $values->[0] unless exists $spec->{columns};
    my @canonical;
    for my $i (0 .. $#$values) {
        my $value = $values->[$i];
        my $type = lc($types->[$i] // 'string');
        if (defined $value) {
            $value = "$value";
            $value = Math::BigFloat->new($value)->bstr if $type =~ /\A(?:integer|int|bigint|smallint|decimal|numeric|float|double|real|epoch_datetime)\z/;
            $value = Cpanel::JSON::XS->new->allow_nonref->decode($value) if $type =~ /\Ajsonb?\z/;
        }
        push @canonical, [$class->fields($spec)->[$i], $type, $value];
    }
    return 'sha256:' . sha256_hex(Selecto::CanonicalJSON->encode_utf8(\@canonical));
}

# Rebuild executable metadata from the governing domain. Caller metadata
# cannot choose revision columns, bypass required tokens or supply a target.
sub govern {
    my ($class, $command, $writes, $primary) = @_;
    my $meta = $command->metadata;
    delete @{$meta}{qw(__selecto_row_revision __selecto_revision_target)};
    my $spec = $writes->{row_revision};
    my $has = exists $meta->{row_revision};
    Selecto::Error->throw('invalid_row_revision', 'row revisions require a declaration and an update or delete')
        if $has && (!$spec || $command->operation !~ /\A(?:update|delete)\z/);
    if ($spec && $command->operation =~ /\A(?:update|delete)\z/) {
        Selecto::Error->throw('row_revision_required', 'this domain requires a row revision') if $spec->{required} && !$has;
        if ($has) {
            my $token = $meta->{row_revision};
            Selecto::Error->throw('invalid_row_revision', 'a row revision must be a scalar token')
                if ref($token) || exists($spec->{columns}) && (!defined($token) || $token !~ /\Asha256:[0-9a-f]{64}\z/);
            require Selecto::OperationBudget;
            Selecto::OperationBudget->new(code => 'invalid_row_revision')->check_tree({row_revision => $token});
            require Selecto::SQL;
            my @keys = ref($primary) eq 'ARRAY' ? @$primary : ($primary);
            my $predicate = Selecto::QueryEnforcement::combine($command->predicate, $command->scope_predicate,
                defined($command->query_enforcement) ? $command->query_enforcement->predicate : undef);
            Selecto::Error->throw('row_revision_requires_identity', 'a row revision requires one concrete primary-key target')
                if !@keys || grep { !defined($_) || (Selecto::SQL::_write_identity_bound($predicate, $_) // 0) != 1 } @keys;
            $meta->{__selecto_row_revision} = {%$spec};
        }
    }
    return $command->with_metadata($meta);
}

# Append exact storage text in the same SELECT as the requested row. Hidden
# inputs are removed before transport; no second lookup can race this read.
sub prepare_read {
    my ($class, $engine, $query) = @_;
    my $spec = $engine->domain->writes_shared->{row_revision};
    return ($query, undef) unless $spec;
    return ($query, undef) if @{$query->groups} || $query->grouping_mode ne 'plain' || $query->retarget_spec
        || grep { @{$query->{$_} // []} } qw(set_operations values_sources subqueries function_laterals);
    my @scan = @{$query->selections};
    while (@scan) {
        my $e = pop @scan;
        next unless ref($e) eq 'Selecto::Expression';
        return ($query, undef) if $e->kind =~ /\A(?:row_revision_value|count|count_field|count_distinct|sum|sum_zero|avg|min|max|true_count|false_count|true_percentage|ratio_of_sums|dimension_display|aggregate|window)\z/;
        push @scan, map { ref($_) eq 'ARRAY' ? @$_ : $_ } @{$e->arguments};
    }
    my $statement = $engine->compile($query); # admit the caller's complete query first
    my @fields = @{$class->fields($spec)};
    my %used = map { $_ => 1 } @{$statement->columns};
    my $sequence = 0;
    my @extra = map {
        my $alias;
        do { $alias = '__selecto_row_revision_' . ++$sequence } while $used{$alias};
        $used{$alias} = 1;
        Selecto::Expression->new('row_revision_value', $_)->as($alias);
    } @fields;
    return ($query->_copy(selections => [@{$query->selections}, @extra]),
        {spec => $spec, count => scalar(@fields), types => [map { $engine->domain->resolve($_)->{type} } @fields]});
}
sub finish_read {
    my ($class, $result, $plan) = @_;
    return $result unless $plan;
    splice @{$result->{columns}}, -$plan->{count};
    $result->{row_revisions} = [map {
        my @values = splice @$_, -$plan->{count};
        $class->token($plan->{spec}, \@values, $plan->{types});
    } @{$result->{rows}}];
    return $result;
}

1;
