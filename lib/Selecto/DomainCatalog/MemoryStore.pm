package Selecto::DomainCatalog::MemoryStore;

use Mojo::Base -base, -signatures;
use Storable qw(dclone);
use Selecto::Error ();

has revisions => sub { {} };
has current => sub { {} };

sub put ($self, $key, $revision, $document) {
    Selecto::Error->throw('immutable_revision', 'store revision already exists')
        if exists $self->revisions->{$key}{$revision};
    $self->revisions->{$key}{$revision} = ref($document) ? dclone($document) : $document;
    $self->current->{$key} = $revision;
    return $self;
}

sub list ($self) {
    return [map { +{key => $_, revision => $self->current->{$_}} } sort keys %{$self->current}];
}

sub fetch ($self, $key, $revision) {
    Selecto::Error->throw('revision_not_found', 'store revision is unavailable')
        unless exists $self->revisions->{$key}{$revision};
    my $document = $self->revisions->{$key}{$revision};
    return ref($document) ? dclone($document) : $document;
}

1;

=head1 NAME

Selecto::DomainCatalog::MemoryStore - non-durable reference contract store

=head1 METHODS

C<new>, C<put($key, $revision, $document)>, C<list>, C<fetch($key, $revision)>.
C<put> creates an immutable revision and selects it as current. Reusing a
revision throws C<immutable_revision>. Containers are copied on input/output.
This implementation is for tests and examples: it is NOT durable, shared
between processes, or suitable for production persistence.

=cut
