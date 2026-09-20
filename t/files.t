use 5.034;
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use File::Spec ();
use File::Temp qw(tempdir);
use JSON::PP ();
use Selecto::Files;

sub service {
    my (%args) = @_;
    my %service = (
        secret => 'test-secret',
        descriptor => {
            id => 'invoice-files', domain_fingerprint => 'invoice-v1',
            roles => { documents => { max_files => 2, max_bytes => 64, media_types => ['application/pdf'] } },
        },
    );
    $service{storage} = $args{storage} if $args{storage};
    return Selecto::Files->new(%service);
}

my $service = service();
my $owner = { domain_fingerprint => 'invoice-v1', key => { id => 42 } };
my $a = $service->bind(tenant => 'tenant-a', actor => 'user-1')->for_record($owner);
my $b = $service->bind(tenant => 'tenant-b', actor => 'user-1')->for_record($owner);
my $other_record = $service->bind(tenant => 'tenant-a', actor => 'user-1')->for_record({
    domain_fingerprint => 'invoice-v1', key => { id => 43 },
});
my %upload = (role => 'documents', bytes => '%PDF-perl', name => 'invoice.pdf',
    media_type => 'application/pdf', idempotency_key => 'upload-1');
my $first = $a->upload(%upload);
my $retry = $a->upload(%upload);
is($retry->{attachment_id}, $first->{attachment_id}, 'same operation returns stable attachment');
eval { $other_record->upload(%upload) };
is($@->code, 'not_found', 'another record cannot replay a matching operation key');
eval { $other_record->upload(%upload, bytes => '%PDF-other') };
is($@->code, 'not_found', 'another record cannot probe a mismatched operation key');
is($a->download($first->{attachment_id}), '%PDF-perl', 'downloads through record facade');
is_deeply($b->list(role => 'documents'), [], 'tenant collision is isolated');
eval { $b->download($first->{attachment_id}) };
isa_ok($@, 'Selecto::Error', 'cross-tenant attachment is hidden');
my $public = JSON::PP->new->encode($first);
unlike($public, qr/(?:tenant|scope|bucket|object_key|storage_ref|credentials|provider)/, 'projection hides infrastructure');

$a->detach($first->{attachment_id}, expected_revision => $first->{revision});
$a->place_hold($first->{version_id}, authority => 'legal-case');
eval { $a->purge($first->{version_id}) };
is($@->code, 'conflict', 'active hold blocks purge');
eval { $b->release_hold($first->{version_id}, authority => 'legal-case') };
is($@->code, 'not_found', 'another tenant cannot release the hold');
eval { $other_record->release_hold($first->{version_id}, authority => 'legal-case') };
is($@->code, 'not_found', 'another record cannot release the hold');
eval { $a->purge($first->{version_id}) };
is($@->code, 'conflict', 'foreign release attempt leaves the hold active');
$a->release_hold($first->{version_id}, authority => 'legal-case');
$a->purge($first->{version_id});
pass('released exact version purges');

eval { Selecto::Files::_owner({ domain_fingerprint => 'x', key => { id => 9_007_199_254_740_992 } }) };
isa_ok($@, 'Selecto::Error', 'unsafe owner integer rejected');
eval { Selecto::Files::_owner({ domain_fingerprint => 'x', key => { id => 1 }, tenant => 'bad' }) };
isa_ok($@, 'Selecto::Error', 'protected owner field rejected');
my $boolean_owner = Selecto::Files::_owner({
    domain_fingerprint => 'x', key => { active => JSON::PP::true },
});
ok($boolean_owner->{key}{active}, 'canonical boolean owner value accepted');

my $root = tempdir(CLEANUP => 1);
my $local = Selecto::Files::LocalStorage->new(root => $root);
my $local_service = service(storage => $local);
my $local_record = $local_service->bind(
    tenant => 'tenant-local', actor => 'user-1',
)->for_record($owner);
my $local_other = $local_service->bind(
    tenant => 'tenant-local', actor => 'user-1',
)->for_record({ domain_fingerprint => 'invoice-v1', key => { id => 43 } });
my $stream_bytes = '%PDF-streamed-perl';
open(my $upload_handle, '<', \$stream_bytes) or die $!;
binmode($upload_handle);
my $streamed = $local_record->upload_handle(
    role => 'documents', handle => $upload_handle, name => 'streamed.pdf',
    media_type => 'application/pdf', idempotency_key => 'stream-1',
    declared_size => length($stream_bytes), declared_sha256 => sha256_hex($stream_bytes),
);
ok(defined(fileno($upload_handle)), 'caller retains ownership of upload handle');
is($local_record->download($streamed->{attachment_id}), $stream_bytes,
    'record facade streams to managed local storage and reads exact bytes');
my $facade_stream = '';
$local_record->download_stream($streamed->{attachment_id}, sub { $facade_stream .= $_[0] });
is($facade_stream, $stream_bytes, 'authorized record facade exposes bounded download callbacks');
my $reentered_attachment;
$local_record->download_stream($streamed->{attachment_id}, sub {
    $reentered_attachment = $local_record->list(role => 'documents')->[0]{attachment_id};
});
is($reentered_attachment, $streamed->{attachment_id},
    'download callback can reenter the record facade');
close($upload_handle) or die $!;
open(my $retry_handle, '<', \$stream_bytes) or die $!;
my $stream_retry = $local_record->upload_handle(
    role => 'documents', handle => $retry_handle, name => 'streamed.pdf',
    media_type => 'application/pdf', idempotency_key => 'stream-1',
    declared_size => length($stream_bytes), declared_sha256 => sha256_hex($stream_bytes),
);
is($stream_retry->{attachment_id}, $streamed->{attachment_id},
    'stream retry with declared digest returns the stable attachment');
is(tell($retry_handle), 0, 'stable retry does not consume a caller-owned stream');
eval {
    $local_other->upload_handle(
        role => 'documents', handle => $retry_handle, name => 'streamed.pdf',
        media_type => 'application/pdf', idempotency_key => 'stream-1',
        declared_size => length($stream_bytes), declared_sha256 => sha256_hex($stream_bytes),
    );
};
is($@->code, 'not_found', 'another record cannot replay a streamed operation key');
is(tell($retry_handle), 0, 'foreign stream replay does not consume the handle');
close($retry_handle) or die $!;

open(my $no_digest_handle, '<', \$stream_bytes) or die $!;
my $no_digest = $local_record->upload_handle(
    role => 'documents', handle => $no_digest_handle, name => 'no-digest.pdf',
    media_type => 'application/pdf', idempotency_key => 'stream-2',
    declared_size => length($stream_bytes),
);
close($no_digest_handle) or die $!;
open(my $no_digest_retry_handle, '<', \$stream_bytes) or die $!;
eval {
    $local_record->upload_handle(
        role => 'documents', handle => $no_digest_retry_handle, name => 'no-digest.pdf',
        media_type => 'application/pdf', idempotency_key => 'stream-2',
        declared_size => length($stream_bytes),
    );
};
is($@->code, 'invalid_request', 'digestless stream retry is rejected without reading');
is(tell($no_digest_retry_handle), 0, 'rejected digestless retry preserves caller handle');
my $no_digest_retry = $local_record->upload_handle(
    role => 'documents', handle => $no_digest_retry_handle, name => 'no-digest.pdf',
    media_type => 'application/pdf', idempotency_key => 'stream-2',
    declared_size => length($stream_bytes), declared_sha256 => sha256_hex($stream_bytes),
);
is($no_digest_retry->{attachment_id}, $no_digest->{attachment_id},
    'first upload without declared digest can be retried with observed digest');
close($no_digest_retry_handle) or die $!;

for my $case (
    ['memory', Selecto::Files::MemoryStorage->new],
    ['local', $local],
) {
    my ($name, $storage) = @$case;
    my $record = service(storage => $storage)->bind(
        tenant => "tenant-mismatch-$name", actor => 'user-1',
    )->for_record($owner);
    my $bytes = '%PDF-digest-probe';
    open(my $bad_handle, '<', \$bytes) or die $!;
    binmode($bad_handle);
    eval {
        $record->upload_handle(
            role => 'documents', handle => $bad_handle, name => 'probe.pdf',
            media_type => 'application/pdf', idempotency_key => 'digest-probe',
            declared_size => length($bytes), declared_sha256 => sha256_hex('other bytes'),
        );
    };
    is($@->code, 'invalid_request', "$name digest mismatch is an invalid request");
    close($bad_handle) or die $!;
    is_deeply($record->list(role => 'documents'), [], "$name mismatch publishes no attachment");
    open(my $good_handle, '<', \$bytes) or die $!;
    binmode($good_handle);
    my $attachment = $record->upload_handle(
        role => 'documents', handle => $good_handle, name => 'probe.pdf',
        media_type => 'application/pdf', idempotency_key => 'digest-probe',
        declared_size => length($bytes), declared_sha256 => sha256_hex($bytes),
    );
    is($record->download($attachment->{attachment_id}), $bytes,
        "$name failed digest attempt releases the operation key");
    close($good_handle) or die $!;
}

my $large = 'x' x 131_073;
open(my $large_handle, '<', \$large) or die $!;
binmode($large_handle);
my $written = $local->write_new_handle(
    'bounded/read-test', $large_handle, 'application/octet-stream',
    declared_size => length($large), declared_sha256 => sha256_hex($large),
);
is($written->{size}, length($large), 'local storage enforces the exact declared size');
my ($read_back, $largest_chunk) = ('', 0);
$local->read_stream('bounded/read-test', sub {
    $largest_chunk = length($_[0]) if length($_[0]) > $largest_chunk;
    $read_back .= $_[0];
});
is(sha256_hex($read_back), sha256_hex($large), 'streamed local read preserves content integrity');
cmp_ok($largest_chunk, '<=', 65_536, 'local reads are delivered in bounded chunks');
close($large_handle) or die $!;

open(my $duplicate_handle, '<', \$large) or die $!;
eval {
    $local->write_new_handle(
        'bounded/read-test', $duplicate_handle, 'application/octet-stream',
        declared_size => length($large),
    );
};
is($@->code, 'conflict', 'managed local publication never overwrites an existing object');
close($duplicate_handle) or die $!;

my $cancel_bytes = 'cancel-me';
open(my $cancel_handle, '<', \$cancel_bytes) or die $!;
my $cancel_checks = 0;
eval {
    $local->write_new_handle(
        'cancelled/object', $cancel_handle, 'application/octet-stream',
        declared_size => length($cancel_bytes), cancelled => sub { ++$cancel_checks > 1 },
    );
};
is($@->code, 'cancelled', 'mid-write cancellation is explicit');
ok(defined(fileno($cancel_handle)), 'cancellation does not close the caller-owned handle');
close($cancel_handle) or die $!;
my $cancel_dir = File::Spec->catdir($root, 'cancelled');
opendir(my $cancel_listing, $cancel_dir) or die $!;
my @cancel_remnants = grep { $_ ne '.' && $_ ne '..' } readdir($cancel_listing);
closedir($cancel_listing) or die $!;
is_deeply(\@cancel_remnants, [], 'cancellation removes private staging content');

eval { $local->write_new('../escape', 'bad', 'text/plain') };
is($@->code, 'invalid_request', 'traversal segment is rejected');
my $outside = tempdir(CLEANUP => 1);
my $link = File::Spec->catdir($root, 'linked');
SKIP: {
    skip 'symlink creation unavailable', 1 unless symlink($outside, $link);
    eval { $local->write_new('linked/escape', 'bad', 'text/plain') };
    is($@->code, 'storage_error', 'symlink path component is rejected');
}

done_testing;
