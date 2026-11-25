package Selecto::DomainCatalog::Source::Code;

use Mojo::Base -base, -signatures;
use Selecto::Error ();

sub new ($class, %args) {
    Selecto::Error->throw('invalid_catalog_source', 'code source requires a factory map')
        unless ref($args{domains}) eq 'HASH'
            && !grep { ref($_) ne 'CODE' } values %{$args{domains}};
    return $class->SUPER::new(%args);
}

sub records ($self) {
    return $self->{records} if $self->{records};
    my @records;
    for my $id (sort keys %{$self->{domains}}) {
        my $value = eval { $self->{domains}{$id}->() };
        my $failed = $@ ? 1 : 0;
        push @records, {id => $id, value => $value, failed => $failed,
            adapter => $self->{adapter},
            source => {kind => 'code', ref => {label => $self->{label} // 'code'}}};
    }
    return $self->{records} = \@records;
}

1;

=head1 NAME

Selecto::DomainCatalog::Source::Code - trusted domain factories

=head1 METHODS

C<new(domains =E<gt> {orders =E<gt> sub {...}}, label =E<gt> 'orders registry',
 adapter =E<gt> 'sqlite')> registers factories returning a domain or contract.
C<records> evaluates each factory once per source instance. Exceptions are
redacted. IDs come from the map; adapter defaults to the catalog's adapter.
Factories remain trusted application code and retain their existing scope.

=cut
