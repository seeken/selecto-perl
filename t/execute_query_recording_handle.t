use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::PostgreSQL ();
use Selecto::Statement ();

# Companions test their routes on a recording handle that answers only what a
# read asks of it. Asking such a handle whether the fetch failed must not fail
# the read; a handle that can say so must still be heard.
package RecordingSTH {
    sub new { my ($class, %args) = @_; return bless {%args, pg_type => ['int4']}, $class; }
    sub execute { return 1; }
    sub fetchall_arrayref { return [[7]]; }
    sub fetchrow_array { return; }
}

package ReportingSTH {
    our @ISA = ('RecordingSTH');
    sub err    { return 1; }
    sub errstr { return 'the connection went away during the fetch'; }
}

package RecordingDBH {
    our @ISA = ('TestSelecto::DBH');
    sub prepare { return $_[0]{sth_class}->new; }
}

package main;

sub read_with {
    my ($class) = @_;
    my $dbh = RecordingDBH->new;
    $dbh->{sth_class} = $class;
    my $statement = Selecto::Statement->new(sql => 'SELECT 7 AS value', columns => ['value'], adapter_name => 'postgresql');
    return Selecto::PostgreSQL->new(dbh => $dbh)->execute_query($statement);
}

my $answer = eval { read_with('RecordingSTH') };
is $@, '', 'a handle with no err method can still answer a read';
is_deeply $answer && $answer->{rows}, [[7]], 'and its rows come back';

my $reported = eval { read_with('ReportingSTH'); 1 };
my $error = $@;
ok !$reported, 'a fetch the handle reports as failed is not an answer';
is ref($error) ? $error->code : $error, 'query_error', 'it stays a query error';

done_testing;
