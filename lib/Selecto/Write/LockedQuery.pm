package Selecto::Write::LockedQuery;

use 5.034;
use strict;
use warnings;
use Hash::Util::FieldHash qw(fieldhash);
use Selecto::Write::Editable ();
use Selecto::QueryBinding ();
use Selecto::Domain::QueryContract ();
use Selecto::Expression ();
use Selecto::Error ();

fieldhash my %STATE;
sub new {
    my ($class, $query, @fields) = @_;
    my $engine = Selecto::QueryBinding->owner($query);
    Selecto::Error->throw('invalid_edit_handle', 'select_for_update requires a configured engine query') unless $engine;
    $engine->validate_query($query);
    Selecto::Write::Session->require_live($engine);
    Selecto::Write::Editable->validate_read($engine, $query)
        if @{$query->selections};
    @fields = @{$fields[0]} if @fields == 1 && ref($fields[0]) eq 'ARRAY';
    my $projection = Selecto::Domain::QueryContract->copy_declaration({fields => \@fields})->{fields};
    my %seen;
    Selecto::Error->throw('invalid_edit_handle', 'select_for_update needs native root field names')
        unless @$projection && !grep { !defined($_) || ref($_) || $seen{$_}++ } @$projection;
    my $selected = $query->replace_selections(@$projection)->_copy(row_lock => 'update');
    Selecto::Write::Editable->validate_read($engine, $selected);
    my $library = $query->applied_query_library;
    Selecto::Error->throw('invalid_edit_handle', 'editable reads cannot use query-library transformations')
        if grep { ref($_) eq 'ARRAY' ? @$_ : defined($_) } values %$library;
    # Own a fresh bounded root query, including independent predicate objects.
    my $predicate = $query->predicate;
    my $snapshot = $engine->query->select(@$projection)
        ->where(Selecto::Expression->new($predicate->kind, @{$predicate->arguments}))
        ->limit(2)->_copy(row_lock => 'update');
    $snapshot = $snapshot->use_timezone($query->timezone) if defined $query->timezone;
    my $token = 0;
    my $self = bless \$token, __PACKAGE__;
    $STATE{$self} = {engine => $engine, query => $snapshot};
    return $self;
}
sub _state {
    Selecto::Error->throw('invalid_edit_handle', 'original locked query required') unless exists $STATE{$_[0]};
    my $s = $STATE{$_[0]};
    Selecto::Write::Session->require_live($s->{engine});
    return $s;
}
sub preview {
    my ($self) = @_;
    my $s = _state($self);
    my $statement = $s->{engine}->compile($s->{query});
    return {sql => $statement->sql, params => $statement->params};
}
sub execute {
    my ($self) = @_;
    my $s = _state($self);
    return Selecto::Write::Editable->locked_read($s->{engine}, $s->{query});
}

1;
