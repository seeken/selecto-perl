package Selecto::DomainCatalog::Source::Store;

use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed);
use Selecto::Error ();
use Cpanel::JSON::XS ();

sub new ($class, %args) {
    Selecto::Error->throw('invalid_catalog_source', 'store must implement list and fetch')
        unless blessed($args{store}) && $args{store}->can('list') && $args{store}->can('fetch');
    return $class->SUPER::new(%args);
}

sub revision ($self, $key, $revision) {
    my $value = eval {
        my $document = $self->{store}->fetch($key, $revision);
        ref($document) ? $document : Cpanel::JSON::XS->new->decode($document);
    };
    my $failed = $@ ? 1 : 0;
    return {value => $value, failed => $failed,
        source => {kind => 'store', ref => {key => $key, revision => $revision,
            (defined($self->{label}) ? (label => $self->{label}) : ())}}};
}

sub records ($self) {
    my $keys = eval { $self->{store}->list };
    Selecto::Error->throw('catalog_source_failed', 'cannot list contract store')
        if $@ || ref($keys) ne 'ARRAY';
    my @records;
    for my $item (@$keys) {
        Selecto::Error->throw('invalid_catalog_source', 'store list requires keys and revisions')
            unless ref($item) eq 'HASH' && defined($item->{key}) && !ref($item->{key})
                && defined($item->{revision}) && !ref($item->{revision});
        my $record = $self->revision(@$item{qw(key revision)});
        my $value = $record->{value};
        my $metadata = ref($value) eq 'HASH' && ref($value->{extensions}) eq 'HASH'
            && ref($value->{extensions}{catalog}) eq 'HASH' ? $value->{extensions}{catalog} : {};
        $record->{id} = $metadata->{id} // $item->{key};
        $record->{missing_id} = !defined($metadata->{id});
        push @records, $record;
    }
    return \@records;
}

1;

=head1 NAME

Selecto::DomainCatalog::Source::Store - host-owned revisioned contract store

=head1 METHODS

C<new(store =E<gt> $store, label =E<gt> $optional_label)>, C<records>, and
C<revision($key, $revision)>.

The host implements C<list> returning C<[{key, revision}, ...]> with exactly
one current revision per key, and C<fetch($key, $revision)> returning that
contract (a hash or JSON string). Revisions MUST be immutable and available
while pinned; list MUST identify the current revision atomically, and fetch
MUST fetch that exact revision, never silently fall back to current. Publish a
new revision before moving the current pointer. Missing revisions must throw.
IDs live in C<extensions.catalog.id> (independent of storage keys).

=cut
