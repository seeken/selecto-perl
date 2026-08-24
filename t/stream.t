use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;

my $dbh = TestSelecto::DBH->new({
    rows => [[1, 'Ada'], [2, 'Grace'], [3, 'Linus']],
    types => [qw(int4 text)],
});
my $adapter = Selecto::PostgreSQL->new(dbh => $dbh);
my $engine = Selecto::Engine->new(
    domain => TestSelecto::people_domain(),
    adapter => $adapter,
);
my $stream = $engine->stream(
    $engine->query->select('id', 'name')->order_by('id'),
    fetch_size => 2,
);
isa_ok($stream, 'Selecto::Stream');
is_deeply($stream->columns, [qw(id name)], 'stream exposes stable result columns');
is_deeply($stream->next, [1, 'Ada'], 'stream decodes its first row lazily');
is_deeply($stream->next, [2, 'Grace'], 'stream advances one row at a time');
ok(!$stream->closed, 'stream remains open while rows remain');
is_deeply($stream->next, [3, 'Linus'], 'stream yields the final row');
is($stream->next, undef, 'stream signals exhaustion without materializing another result');
ok($stream->closed, 'exhaustion closes the statement stream');
is($stream->next, undef, 'a closed stream remains exhausted');
is(scalar(@{$dbh->prepared}), 1, 'streaming executes one database statement');

eval {
    $engine->stream($engine->query->select('id'), fetch_size => 0);
};
is($@->code, 'invalid_stream', 'invalid stream fetch sizes fail closed');

{
    package TestSelecto::NoStream;
    our @ISA = ('Selecto::PostgreSQL');
    sub supports { return 0 if "$_[1]" eq 'stream'; return $_[0]->SUPER::supports($_[1]); }
}
my $unsupported = Selecto::Engine->new(
    domain => TestSelecto::people_domain(),
    adapter => TestSelecto::NoStream->new(dbh => TestSelecto::DBH->new),
);
eval { $unsupported->stream($unsupported->query->select('id')) };
is($@->code, 'unsupported_feature', 'adapters without streaming fail before execution');

done_testing;
