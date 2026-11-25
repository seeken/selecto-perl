package Selecto::DomainCatalog::Diff;

use 5.034;
use strict;
use warnings;
use Cpanel::JSON::XS ();

sub compare {
    my ($class, $before, $after) = @_;
    my ($old, $new) = map { _surfaces($_) } ($before, $after);
    my %diff;
    for my $section (sort keys %$old) {
        my $changes = $diff{$section} = {added => [], removed => [], changed => []};
        my %names = map { $_ => 1 } (keys %{$old->{$section}}, keys %{$new->{$section}});
        for my $name (sort keys %names) {
            my ($left, $right) = ($old->{$section}{$name}, $new->{$section}{$name});
            my $entry = {name => $name, path => ($right // $left)->{path}};
            if (!$left) { push @{$changes->{added}}, $entry }
            elsif (!$right) { push @{$changes->{removed}}, $entry }
            else {
                my $paths = _changed_paths($left->{value}, $right->{value}, $entry->{path});
                push @{$changes->{changed}}, {%$entry, changes => $paths} if @$paths;
            }
        }
    }
    return \%diff;
}

sub _surfaces {
    my ($document) = @_;
    my %result = map { $_ => {} } qw(fields associations joins actions writes segments authorization);
    my @relations = (['source', $document->{source}]);
    push @relations, map { ['schemas.' . $_, $document->{schemas}{$_}] }
        sort keys %{_map($document->{schemas})};
    for my $relation (@relations) {
        my ($prefix, $value) = @$relation;
        for my $section (qw(columns associations)) {
            for my $name (sort keys %{_map(_map($value)->{$section})}) {
                my $id = $prefix eq 'source' ? $name : "$prefix.$name";
                $result{$section eq 'columns' ? 'fields' : 'associations'}{$id} = {
                    path => "\$.$prefix.$section.$name", value => $value->{$section}{$name}};
            }
        }
    }
    $result{actions}{$_} = {path => "\$.actions.$_", value => $document->{actions}{$_}}
        for sort keys %{_map($document->{actions})};
    my $walk_joins;
    $walk_joins = sub {
        my ($joins, $prefix, $path) = @_;
        for my $name (sort keys %{_map($joins)}) {
            my $id = length($prefix) ? "$prefix.$name" : $name;
            my $join = $joins->{$name};
            my $value = ref($join) eq 'HASH' ? {map { $_ => $join->{$_} }
                grep { $_ ne 'joins' } keys %$join} : $join;
            $result{joins}{$id} = {path => "$path.$name", value => $value};
            $walk_joins->($join->{joins}, $id, "$path.$name.joins") if ref($join) eq 'HASH';
        }
    };
    $walk_joins->($document->{joins}, '', '$.joins');
    for my $key (sort keys %{_map($document->{writes})}) {
        my $value = $document->{writes}{$key};
        if (ref($value) eq 'HASH' && $key =~ /\A(?:operations|fields|relationships|transitions|unique_keys)\z/) {
            $result{writes}{"$key.$_"} = {path => "\$.writes.$key.$_", value => $value->{$_}}
                for sort keys %$value;
        } else {
            $result{writes}{$key} = {path => "\$.writes.$key", value => $value};
        }
    }
    my $segments = _map(_map($document->{query_library})->{segments});
    $result{segments}{$_} = {path => "\$.query_library.segments.$_", value => $segments->{$_}}
        for sort keys %$segments;
    my $authorization = _map(_map($document->{extensions})->{authorization});
    for my $key (sort keys %$authorization) {
        if (ref($authorization->{$key}) eq 'HASH') {
            $result{authorization}{"$key.$_"} = {
                path => "\$.extensions.authorization.$key.$_", value => $authorization->{$key}{$_}}
                for sort keys %{$authorization->{$key}};
        } else {
            $result{authorization}{$key} = {
                path => "\$.extensions.authorization.$key", value => $authorization->{$key}};
        }
    }
    return \%result;
}

sub _map { return ref($_[0]) eq 'HASH' ? $_[0] : {} }

sub _changed_paths {
    my ($left, $right, $path) = @_;
    if (ref($left) eq 'HASH' && ref($right) eq 'HASH') {
        my %keys = map { $_ => 1 } (keys %$left, keys %$right);
        return [map { @{_changed_paths($left->{$_}, $right->{$_}, "$path.$_")} } sort keys %keys];
    }
    my $json = Cpanel::JSON::XS->new->canonical->allow_nonref;
    return $json->encode($left) eq $json->encode($right) ? [] : [$path];
}

1;

=head1 NAME

Selecto::DomainCatalog::Diff - named contract surface changes

=head1 METHODS

C<compare($earlier_contract, $current_contract)> returns C<fields>,
C<associations>, C<joins>, C<actions>, C<writes>, C<segments>, and
C<authorization>. Each contains C<added>, C<removed>, C<changed> arrays of
C<{name, path}>; changed entries add C<changes> (changed JSON paths).
Field groups use names such as C<field_groups.account>. No before/after
values, row data, predicates or action assignment values are returned.
This is a declaration comparison, not a compatibility or authorization verdict.

=cut
