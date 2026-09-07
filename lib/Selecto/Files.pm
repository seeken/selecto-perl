package Selecto::Files;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use JSON::PP ();
use Scalar::Util qw(blessed);
use Selecto::Error ();

our $PROFILE = 'files.attachments.v1';
our $MAX_SAFE_INTEGER = 9_007_199_254_740_991;

sub new {
    my ($class, %args) = @_;
    _text($args{secret});
    my $descriptor = $args{descriptor};
    _error('invalid_request') unless ref($descriptor) eq 'HASH';
    my %roles;
    for my $role (keys %{$descriptor->{roles} // {}}) {
        my $policy = $descriptor->{roles}{$role};
        _error('invalid_request') unless ref($policy) eq 'HASH';
        my @types = map { _text($_) } @{$policy->{media_types} // []};
        _error('invalid_request') unless @types && ($policy->{max_files} // 0) > 0 && ($policy->{max_bytes} // 0) > 0;
        $roles{$role} = {
            max_files => 0 + $policy->{max_files}, max_bytes => 0 + $policy->{max_bytes},
            media_types => { map { $_ => 1 } @types },
        };
    }
    _error('invalid_request') unless %roles;
    return bless {
        secret => $args{secret},
        descriptor => {
            id => _text($descriptor->{id}),
            domain_fingerprint => _text($descriptor->{domain_fingerprint}),
            roles => \%roles,
        },
        storage => $args{storage} // Selecto::Files::MemoryStorage->new,
        authorize => $args{authorize} // sub { 1 },
        attachments => {}, collections => {}, operations => {}, versions => {}, holds => {},
        sequence => 0,
    }, $class;
}

sub bind {
    my ($self, %args) = @_;
    my $tenant = _text($args{tenant});
    my $actor = _text($args{actor});
    my $scope = hmac_sha256_hex("tenant:\0$tenant", $self->{secret});
    return bless { service => $self, scope => $scope, actor => $actor }, 'Selecto::Files::Bound';
}

sub _owner {
    my ($value) = @_;
    _error('invalid_request') unless ref($value) eq 'HASH';
    my @keys = sort keys %$value;
    _error('invalid_request') unless "@keys" eq 'domain_fingerprint key';
    my $fingerprint = _text($value->{domain_fingerprint});
    _error('invalid_request') unless ref($value->{key}) eq 'HASH' && keys %{$value->{key}};
    my %key;
    for my $name (keys %{$value->{key}}) {
        _text($name);
        my $item = $value->{key}{$name};
        if (JSON::PP::is_bool($item)) {
            $key{$name} = $item ? JSON::PP::true : JSON::PP::false;
            next;
        }
        _error('invalid_request') unless !ref($item) && defined($item) &&
            ($item !~ /^-?\d+$/ || abs($item) <= $MAX_SAFE_INTEGER);
        $key{$name} = $item;
    }
    return { domain_fingerprint => $fingerprint, key => \%key };
}

sub _text {
    my ($value) = @_;
    _error('invalid_request') unless defined($value) && !ref($value) && length($value) && length($value) <= 2048;
    return "$value";
}

sub _error { Selecto::Error->throw($_[0], $_[0] =~ s/_/ /gr); }

package Selecto::Files::MemoryStorage;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

sub new { bless { objects => {} }, $_[0] }

sub api_version { 1 }

sub write_new {
    my ($self, $reference, $bytes, $media_type) = @_;
    Selecto::Files::_error('conflict') if exists $self->{objects}{$reference};
    $self->{objects}{$reference} = ["$bytes", "$media_type"];
    return { size => length($bytes), sha256 => sha256_hex($bytes), media_type => $media_type };
}

sub write_new_handle {
    my ($self, $reference, $handle, $media_type, %args) = @_;
    Selecto::Files::_error('conflict') if exists $self->{objects}{$reference};
    my $declared_size = $args{declared_size};
    Selecto::Files::_error('invalid_request')
        unless defined($declared_size) && $declared_size =~ /^\d+$/ && $declared_size > 0;
    my $cancelled = $args{cancelled} // sub { 0 };
    Selecto::Files::_error('invalid_request') unless ref($cancelled) eq 'CODE';
    my ($bytes, $total) = ('', 0);
    my $sha = Digest::SHA->new(256);
    while (1) {
        Selecto::Files::_error('cancelled') if $cancelled->();
        my $read = CORE::read($handle, my $chunk, 65_536);
        Selecto::Files::_error('storage_error') unless defined $read;
        last unless $read;
        $total += $read;
        Selecto::Files::_error('quota_exceeded') if $total > $declared_size;
        $sha->add($chunk);
        $bytes .= $chunk;
    }
    Selecto::Files::_error('invalid_request') unless $total == $declared_size;
    Selecto::Files::_error('cancelled') if $cancelled->();
    my $digest = $sha->hexdigest;
    if (defined $args{declared_sha256}) {
        Selecto::Files::_error('invalid_request') unless lc($args{declared_sha256}) eq $digest;
    }
    $self->{objects}{$reference} = [$bytes, "$media_type"];
    return { size => $total, sha256 => $digest, media_type => $media_type };
}

sub read {
    my ($self, $reference) = @_;
    my $value = $self->{objects}{$reference} // Selecto::Files::_error('not_found');
    return [@$value];
}

sub read_stream {
    my ($self, $reference, $consumer, %args) = @_;
    Selecto::Files::_error('invalid_request') unless ref($consumer) eq 'CODE';
    my $cancelled = $args{cancelled} // sub { 0 };
    Selecto::Files::_error('invalid_request') unless ref($cancelled) eq 'CODE';
    my $value = $self->{objects}{$reference} // Selecto::Files::_error('not_found');
    for (my $offset = 0; $offset < length($value->[0]); $offset += 65_536) {
        Selecto::Files::_error('cancelled') if $cancelled->();
        $consumer->(substr($value->[0], $offset, 65_536));
    }
    return;
}

sub delete { delete $_[0]->{objects}{$_[1]}; return; }

package Selecto::Files::LocalStorage;

use 5.034;
use strict;
use warnings;
use Digest::SHA ();
use Errno qw(EEXIST);
use Fcntl qw(O_CREAT O_EXCL O_RDONLY O_WRONLY);
use File::Spec ();
use IO::Handle ();

my $STAGING_SEQUENCE = 0;

sub new {
    my ($class, %args) = @_;
    my $root = Selecto::Files::_text($args{root});
    $root = File::Spec->rel2abs($root);
    if (!lstat($root)) {
        mkdir($root, 0700) or Selecto::Files::_error('storage_error');
        lstat($root) or Selecto::Files::_error('storage_error');
    }
    Selecto::Files::_error('storage_error') if -l _ || !-d _;
    chmod(0700, $root) or Selecto::Files::_error('storage_error');
    return bless { root => $root }, $class;
}

sub api_version { 1 }

sub write_new {
    my ($self, $reference, $bytes, $media_type) = @_;
    open(my $handle, '<', \$bytes) or Selecto::Files::_error('storage_error');
    binmode($handle);
    return $self->write_new_handle(
        $reference, $handle, $media_type,
        declared_size => length($bytes),
        declared_sha256 => Digest::SHA::sha256_hex($bytes),
    );
}

sub write_new_handle {
    my ($self, $reference, $handle, $media_type, %args) = @_;
    my $declared_size = $args{declared_size};
    Selecto::Files::_error('invalid_request')
        unless defined($declared_size) && $declared_size =~ /^\d+$/ && $declared_size > 0;
    my $cancelled = $args{cancelled} // sub { 0 };
    Selecto::Files::_error('invalid_request') unless ref($cancelled) eq 'CODE';
    my ($final, $parent) = $self->_path($reference, 1);
    Selecto::Files::_error('conflict') if lstat($final);

    my ($staging, $output, $published);
    for (1 .. 100) {
        $staging = File::Spec->catfile($parent, sprintf('.selecto-stage-%d-%d', $$, ++$STAGING_SEQUENCE));
        last if sysopen($output, $staging, O_WRONLY | O_CREAT | O_EXCL, 0600);
        Selecto::Files::_error('storage_error') unless $! == EEXIST;
    }
    Selecto::Files::_error('storage_error') unless $output;
    binmode($output);

    my $result = eval {
        my ($total, $sha) = (0, Digest::SHA->new(256));
        while (1) {
            Selecto::Files::_error('cancelled') if $cancelled->();
            my $read = CORE::read($handle, my $chunk, 65_536);
            Selecto::Files::_error('storage_error') unless defined $read;
            last unless $read;
            $total += $read;
            Selecto::Files::_error('quota_exceeded') if $total > $declared_size;
            $sha->add($chunk);
            my $offset = 0;
            while ($offset < $read) {
                my $written = syswrite($output, $chunk, $read - $offset, $offset);
                Selecto::Files::_error('storage_error') unless defined($written) && $written > 0;
                $offset += $written;
            }
        }
        Selecto::Files::_error('invalid_request') unless $total == $declared_size;
        Selecto::Files::_error('cancelled') if $cancelled->();
        my $digest = $sha->hexdigest;
        if (defined $args{declared_sha256}) {
            Selecto::Files::_error('invalid_request') unless lc($args{declared_sha256}) eq $digest;
        }
        $output->sync or Selecto::Files::_error('storage_error');
        close($output) or Selecto::Files::_error('storage_error');
        undef $output;
        if (!link($staging, $final)) {
            Selecto::Files::_error($! == EEXIST ? 'conflict' : 'storage_error');
        }
        $published = 1;
        unlink($staging) or Selecto::Files::_error('storage_error');
        undef $staging;
        sysopen(my $directory, $parent, O_RDONLY) or Selecto::Files::_error('storage_error');
        $directory->sync or Selecto::Files::_error('storage_error');
        close($directory) or Selecto::Files::_error('storage_error');
        return { size => $total, sha256 => $digest, media_type => "$media_type" };
    };
    my $error = $@;
    close($output) if $output;
    unlink($staging) if defined($staging) && lstat($staging);
    unlink($final) if $error && $published && lstat($final);
    die $error if $error;
    return $result;
}

sub read_handle {
    my ($self, $reference) = @_;
    my ($path) = $self->_path($reference, 0);
    my $flags = O_RDONLY | (eval { Fcntl::O_NOFOLLOW() } // 0);
    sysopen(my $handle, $path, $flags) or Selecto::Files::_error('not_found');
    binmode($handle);
    my @stat = stat($handle);
    Selecto::Files::_error('not_found') unless @stat && -f _;
    return $handle;
}

sub read_stream {
    my ($self, $reference, $consumer, %args) = @_;
    Selecto::Files::_error('invalid_request') unless ref($consumer) eq 'CODE';
    my $cancelled = $args{cancelled} // sub { 0 };
    Selecto::Files::_error('invalid_request') unless ref($cancelled) eq 'CODE';
    my $handle = $self->read_handle($reference);
    my $ok = eval {
        while (1) {
            Selecto::Files::_error('cancelled') if $cancelled->();
            my $read = sysread($handle, my $chunk, 65_536);
            Selecto::Files::_error('storage_error') unless defined $read;
            last unless $read;
            $consumer->($chunk);
        }
        1;
    };
    my $error = $@;
    close($handle) or Selecto::Files::_error('storage_error');
    die $error unless $ok;
    return;
}

sub read {
    my ($self, $reference) = @_;
    my $bytes = '';
    $self->read_stream($reference, sub { $bytes .= $_[0] });
    return [$bytes, undef];
}

sub delete {
    my ($self, $reference) = @_;
    my ($path, $parent) = $self->_path($reference, 0);
    lstat($path) or return;
    Selecto::Files::_error('storage_error') if -l _ || !-f _;
    unlink($path) or Selecto::Files::_error('storage_error');
    sysopen(my $directory, $parent, O_RDONLY) or Selecto::Files::_error('storage_error');
    $directory->sync or Selecto::Files::_error('storage_error');
    close($directory) or Selecto::Files::_error('storage_error');
    return;
}

sub _path {
    my ($self, $reference, $create_parent) = @_;
    my @segments = split('/', Selecto::Files::_text($reference), -1);
    Selecto::Files::_error('invalid_request') unless @segments >= 2;
    for my $segment (@segments) {
        Selecto::Files::_error('invalid_request')
            unless $segment =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/;
    }
    my $parent = $self->{root};
    for my $segment (@segments[0 .. $#segments - 1]) {
        $parent = File::Spec->catdir($parent, $segment);
        if (!lstat($parent)) {
            Selecto::Files::_error('not_found') unless $create_parent;
            mkdir($parent, 0700) or Selecto::Files::_error('storage_error');
            lstat($parent) or Selecto::Files::_error('storage_error');
        }
        Selecto::Files::_error('storage_error') if -l _ || !-d _;
    }
    return (File::Spec->catfile($parent, $segments[-1]), $parent);
}

package Selecto::Files::Bound;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

sub for_record {
    my ($self, $raw_owner) = @_;
    my $owner = Selecto::Files::_owner($raw_owner);
    my $service = $self->{service};
    Selecto::Files::_error('invalid_request')
        unless $owner->{domain_fingerprint} eq $service->{descriptor}{domain_fingerprint};
    my $identity = JSON::PP->new->canonical->encode($owner->{key});
    return bless {
        service => $service, scope => $self->{scope}, actor => $self->{actor},
        owner => $owner, owner_fingerprint => sha256_hex($identity),
    }, 'Selecto::Files::Record';
}

package Selecto::Files::Record;

use 5.034;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Time::Piece ();

sub upload {
    my ($self, %args) = @_;
    my ($role, $policy) = $self->_policy($args{role});
    $self->_allow('upload', $role);
    my $name = Selecto::Files::_text($args{name});
    my $media = Selecto::Files::_text($args{media_type});
    my $key = Selecto::Files::_text($args{idempotency_key});
    my $bytes = defined($args{bytes}) ? "$args{bytes}" : Selecto::Files::_error('invalid_request');
    Selecto::Files::_error('quota_exceeded') unless length($bytes) && length($bytes) <= $policy->{max_bytes};
    Selecto::Files::_error('unsupported') unless $policy->{media_types}{$media};
    my $service = $self->{service};
    my $content_sha256 = sha256_hex($bytes);
    my $digest = sha256_hex(join("\0", $role, $name, $media, length($bytes), $content_sha256));
    my $operation_key = join('|', $self->{scope}, $key);
    if (my $existing = $service->{operations}{$operation_key}) {
        Selecto::Files::_error('conflict') unless $existing->{digest} eq $digest;
        return $self->_project($existing->{attachment});
    }
    my ($attachment_id, $version_id, $reference) = $self->_reserve_identifiers($role, $policy);
    my $stored = $service->{storage}->write_new($reference, $bytes, $media);
    return $self->_commit_upload($role, $name, $media, $operation_key, $digest,
        $attachment_id, $version_id, $reference, $stored);
}

sub upload_handle {
    my ($self, %args) = @_;
    my ($role, $policy) = $self->_policy($args{role});
    $self->_allow('upload', $role);
    my $name = Selecto::Files::_text($args{name});
    my $media = Selecto::Files::_text($args{media_type});
    my $key = Selecto::Files::_text($args{idempotency_key});
    my $handle = $args{handle};
    Selecto::Files::_error('invalid_request') unless defined $handle;
    my $declared_size = $args{declared_size};
    Selecto::Files::_error('quota_exceeded')
        unless defined($declared_size) && $declared_size =~ /^\d+$/ && $declared_size > 0 &&
            $declared_size <= $policy->{max_bytes};
    Selecto::Files::_error('unsupported') unless $policy->{media_types}{$media};
    my $declared_sha256 = defined($args{declared_sha256}) ? lc($args{declared_sha256}) : undef;
    Selecto::Files::_error('invalid_request')
        if defined($declared_sha256) && $declared_sha256 !~ /\A[0-9a-f]{64}\z/;
    my $operation_key = join('|', $self->{scope}, $key);
    if (my $existing = $self->{service}{operations}{$operation_key}) {
        Selecto::Files::_error('invalid_request') unless defined $declared_sha256;
        my $digest = sha256_hex(join("\0", $role, $name, $media, $declared_size, $declared_sha256));
        Selecto::Files::_error('conflict') unless $existing->{digest} eq $digest;
        return $self->_project($existing->{attachment});
    }
    my ($attachment_id, $version_id, $reference) = $self->_reserve_identifiers($role, $policy);
    my $stored = $self->{service}{storage}->write_new_handle(
        $reference, $handle, $media,
        declared_size => $declared_size,
        declared_sha256 => $declared_sha256,
        cancelled => ($args{cancelled} // sub { 0 }),
    );
    my $digest = sha256_hex(join("\0", $role, $name, $media, $stored->{size}, $stored->{sha256}));
    return $self->_commit_upload($role, $name, $media, $operation_key, $digest,
        $attachment_id, $version_id, $reference, $stored);
}

sub _reserve_identifiers {
    my ($self, $role, $policy) = @_;
    my $service = $self->{service};
    my $collection = $service->{collections}{$self->_collection_key($role)} //= [];
    Selecto::Files::_error('quota_exceeded') if @$collection >= $policy->{max_files};
    my $attachment_id = sprintf('att_%024x', ++$service->{sequence});
    my $version_id = sprintf('ver_%024x', ++$service->{sequence});
    return ($attachment_id, $version_id, "$self->{scope}/$version_id");
}

sub _commit_upload {
    my ($self, $role, $name, $media, $operation_key, $digest,
        $attachment_id, $version_id, $reference, $stored) = @_;
    my $service = $self->{service};
    my $collection = $service->{collections}{$self->_collection_key($role)} //= [];
    my $attachment = {
        attachment_id => $attachment_id, file_id => sprintf('file_%024x', ++$service->{sequence}),
        version_id => $version_id, name => $name, media_type => $media,
        byte_size => $stored->{size}, caption => undef, role => $role, position => scalar(@$collection),
        primary => 0, state => 'ready', revision => 1, storage_ref => $reference,
        sha256 => $stored->{sha256}, created_at => Time::Piece::gmtime()->datetime . 'Z',
    };
    $service->{attachments}{$attachment_id} = $attachment;
    $service->{versions}{$version_id} = $attachment;
    push @$collection, $attachment_id;
    $service->{operations}{$operation_key} = { digest => $digest, attachment => $attachment };
    return $self->_project($attachment);
}

sub list {
    my ($self, %args) = @_;
    my ($role) = $self->_policy($args{role});
    $self->_allow('list', $role);
    my $ids = $self->{service}{collections}{$self->_collection_key($role)} // [];
    return [map { $self->_project($self->{service}{attachments}{$_}) }
        grep { $self->{service}{attachments}{$_}{state} eq 'ready' } @$ids];
}

sub download {
    my ($self, $id) = @_;
    $self->_allow('download', undef);
    my $attachment = $self->_attachment($id);
    return $self->{service}{storage}->read($attachment->{storage_ref})->[0];
}

sub download_stream {
    my ($self, $id, $consumer, %args) = @_;
    $self->_allow('download', undef);
    Selecto::Files::_error('invalid_request') unless ref($consumer) eq 'CODE';
    my $attachment = $self->_attachment($id);
    my $storage = $self->{service}{storage};
    if ($storage->can('read_stream')) {
        return $storage->read_stream(
            $attachment->{storage_ref}, $consumer,
            cancelled => ($args{cancelled} // sub { 0 }),
        );
    }
    $consumer->($storage->read($attachment->{storage_ref})->[0]);
    return;
}

sub detach {
    my ($self, $id, %args) = @_;
    $self->_allow('detach', undef);
    my $attachment = $self->_attachment($id);
    Selecto::Files::_error('conflict') unless ($args{expected_revision} // -1) == $attachment->{revision};
    $attachment->{state} = 'detached';
    ++$attachment->{revision};
    return;
}

sub place_hold {
    my ($self, $version_id, %args) = @_;
    $self->_allow('hold', undef);
    my $version = $self->{service}{versions}{$version_id};
    Selecto::Files::_error('not_found') unless $self->_owned($version);
    $self->{service}{holds}{$version_id}{Selecto::Files::_text($args{authority})} = 1;
    return;
}

sub release_hold {
    my ($self, $version_id, %args) = @_;
    $self->_allow('hold', undef);
    delete $self->{service}{holds}{$version_id}{Selecto::Files::_text($args{authority})};
    return;
}

sub purge {
    my ($self, $version_id) = @_;
    $self->_allow('purge', undef);
    my $version = $self->{service}{versions}{$version_id};
    Selecto::Files::_error('not_found') unless $self->_owned($version) && $version->{state} eq 'detached';
    Selecto::Files::_error('conflict') if keys %{$self->{service}{holds}{$version_id} // {}};
    $self->{service}{storage}->delete($version->{storage_ref});
    delete $self->{service}{versions}{$version_id};
    return;
}

sub _policy {
    my ($self, $raw_role) = @_;
    my $role = Selecto::Files::_text($raw_role);
    my $policy = $self->{service}{descriptor}{roles}{$role} // Selecto::Files::_error('unsupported');
    return ($role, $policy);
}

sub _allow {
    my ($self, $action, $role) = @_;
    Selecto::Files::_error('not_found') unless $self->{service}{authorize}->($action, $self->{actor}, $self->{owner}, $role);
    return;
}

sub _attachment {
    my ($self, $id) = @_;
    my $attachment = $self->{service}{attachments}{Selecto::Files::_text($id)};
    Selecto::Files::_error('not_found') unless $self->_owned($attachment) && $attachment->{state} eq 'ready';
    return $attachment;
}

sub _owned {
    my ($self, $attachment) = @_;
    return 0 unless $attachment && index($attachment->{storage_ref}, "$self->{scope}/") == 0;
    my $ids = $self->{service}{collections}{$self->_collection_key($attachment->{role})} // [];
    return scalar grep { $_ eq $attachment->{attachment_id} } @$ids;
}

sub _collection_key { join('|', $_[0]->{scope}, $_[0]->{owner_fingerprint}, $_[1]); }

sub _project {
    my ($self, $value) = @_;
    my @actions = grep { $self->{service}{authorize}->($_, $self->{actor}, $self->{owner}, $value->{role}) }
        qw(download replace reorder detach);
    return {
        map { $_ => $value->{$_} } qw(attachment_id file_id version_id name media_type byte_size caption role position primary state revision created_at),
        actions => \@actions,
        content_url => "/attachments/$value->{attachment_id}/content",
    };
}

1;
