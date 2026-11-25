package Selecto::DomainCatalog::Source::File;

use Mojo::Base -base, -signatures;
use Cpanel::JSON::XS ();
use File::Spec ();
use Cwd qw(abs_path);
use Selecto::Error ();

sub new ($class, %args) {
    Selecto::Error->throw('invalid_catalog_source', 'file source requires a directory')
        unless defined($args{directory}) && -d $args{directory};
    $args{directory} = abs_path($args{directory});
    return $class->SUPER::new(%args);
}

sub records ($self) {
    opendir(my $directory, $self->{directory})
        or Selecto::Error->throw('catalog_source_failed', 'cannot list contract directory');
    my @names = sort grep { /\.json\z/ && -f File::Spec->catfile($self->{directory}, $_) }
        readdir($directory);
    closedir($directory);
    my @records;
    for my $name (@names) {
        my $path = File::Spec->catfile($self->{directory}, $name);
        my $value = eval {
            open(my $file, '<:raw', $path) or die 'read failed';
            my $bytes = do { local $/; <$file> };
            close($file) or die 'read failed';
            Cpanel::JSON::XS->new->utf8->decode($bytes);
        };
        # A malformed document cannot supply an ID. Keep it inspectable by path.
        my $failed = $@ ? 1 : 0;
        my $metadata = ref($value) eq 'HASH' && ref($value->{extensions}) eq 'HASH'
            && ref($value->{extensions}{catalog}) eq 'HASH' ? $value->{extensions}{catalog} : {};
        push @records, {id => $metadata->{id} // $path, value => $value,
            failed => $failed, missing_id => !defined($metadata->{id}),
            source => {kind => 'file', ref => {path => $path,
                (defined($self->{commit}) ? (commit => $self->{commit}) : ())}}};
    }
    return \@records;
}

1;

=head1 NAME

Selecto::DomainCatalog::Source::File - JSON contracts in one directory

=head1 METHODS

C<new(directory =E<gt> $path, commit =E<gt> $optional_commit)> and C<records>.
Each direct C<*.json> file holds one contract with C<extensions.catalog.id>.
Files are reread on catalog inspection. Supply C<commit> when the host knows
which Git revision these files represent; a dirty working tree has no reliable
commit identity, so this source does not infer one. Invalid JSON or missing IDs
remain reportable under the absolute path and cannot be served.

=cut
