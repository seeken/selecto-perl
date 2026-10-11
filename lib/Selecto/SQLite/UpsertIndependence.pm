package Selecto::SQLite::UpsertIndependence;

use 5.034;
use strict;
use warnings;
no overloading;
use Scalar::Util qw(blessed refaddr);
use JSON::PP ();
use Selecto::Error ();
use Selecto::QueryEnforcement ();
require Selecto::SQL;

# Whole-plan independence for protected SQLite UPSERT candidates.
#
# Every candidate in a plan was projected against storage before any of the
# plan's DML ran. A candidate is admitted only when no other operation in the
# plan, before or after it, can change its selected branch, its prior row or
# its final row, and it cannot change theirs. Each protected candidate is
# checked against every other command on its table; two protected candidates
# are checked in both directions. Values and predicates are compared by SQLite
# itself, through the target columns' affinity and collation. Anything the
# proof cannot establish refuses as required_data_rule_pending before DML.

my $SERIAL = 0;
my $PAIR_LIMIT = 4096;
my $C = 'Selecto::SQLite::UpsertCandidate';

sub _pending { Selecto::SQLite::UpsertCandidate::_pending($_[0] // 'plan_independence_unavailable') }
sub _rows { Selecto::SQLite::UpsertCandidate::_rows(@_) }
sub _q { Selecto::SQLite::UpsertCandidate::_q(@_) }
sub _identity { Selecto::SQLite::UpsertCandidate::_identity(@_) }

sub validate {
    my ($class, $adapter, $pairs, $commands, $cleanup) = @_;
    return 1 unless @$pairs;
    my %protected = map { (refaddr($_->[0]) => $_->[1]) } @$pairs;
    my $checked = 0;
    for my $pair (@$pairs) {
        my ($command, $entry) = @$pair;
        # Owned-set cleanup deletes rows it has not materialized yet.
        for my $other (@{$cleanup // []}) {
            _pending() if _same_table($other, $entry);
        }
        for my $other (@$commands) {
            next if refaddr($other) == refaddr($command);
            next unless _same_table($other, $entry);
            _pending('plan_independence_budget') if ++$checked > $PAIR_LIMIT;
            # An unknown generated rowid could equal any other row's key.
            _pending('generated_identity_unavailable') if _generated_identity($entry);
            my $ok = eval {
                if (my $candidate = $protected{refaddr($other)}) { _independent($adapter, $entry, $candidate) }
                else { _ordinary($adapter, $entry, $other) }
                1;
            };
            next if $ok;
            my $error = $@;
            die $error if ref($error) eq 'Selecto::Error'
                && $error->code =~ /\A(?:required_data_rule_pending|evaluation_limit)\z/;
            _pending();
        }
    }
    return 1;
}

sub _same_table {
    my ($command, $entry) = @_;
    my $relation = $command->relation;
    return 1 unless defined($relation) && !ref($relation);
    $relation =~ s/\Amain\.//i;
    return 1 if $relation =~ /\./;
    return Selecto::SQLite::UpsertCandidate::_same($relation, $entry->{table});
}
sub _generated_identity {
    my ($state) = @_;
    return $state->{branch} eq 'insert' && $state->{arbiter}{kind} eq 'rowid'
        && scalar(grep { !defined } @{$state->{keys}});
}
sub _same_physical {
    my ($left, $right) = @_;
    return defined($left->{physical_id}) && defined($right->{physical_id})
        && _identity($left->{physical_id}) eq _identity($right->{physical_id});
}

# Two protected candidates: the other one's final row must not carry this
# candidate's arbiter key. The reverse pair checks the other direction.
sub _independent {
    my ($adapter, $entry, $other) = @_;
    return 1 if $other->{effect} eq 'nothing';
    _pending('generated_identity_unavailable') if _generated_identity($other);
    _pending('ambiguous_candidate_identity') if _same_physical($entry, $other);
    _pending('ambiguous_candidate_identity')
        if _row_matches_keys($adapter, $entry, _final_row($other), $entry->{arbiter}, $entry->{keys});
    return 1;
}

sub _ordinary {
    my ($adapter, $entry, $other) = @_;
    my $operation = $other->operation;
    if ($operation eq 'insert') {
        _insertion_disjoint($adapter, $entry, $other);
        return 1;
    }
    if ($operation eq 'upsert') {
        _pending() if defined $other->predicate;
        my $prospect = _prospect($adapter, $entry, $other);
        _pending() if _same_physical($entry, $prospect);
        _insertion_disjoint($adapter, $entry, $other);
        # Different keys under this candidate's arbiter do not stop the other
        # UPSERT from matching this candidate's row through its own arbiter,
        # nor from moving its own conflict row onto this candidate's key.
        _pending() if _row_matches_keys($adapter, $entry, _final_row($prospect), $entry->{arbiter}, $entry->{keys});
        _pending() if _row_matches_keys($adapter, $entry, _final_row($entry), $prospect->{arbiter}, $prospect->{keys});
        return 1;
    }
    if ($operation eq 'update' || $operation eq 'delete') {
        my $predicate = Selecto::QueryEnforcement::combine($other->predicate, $other->scope_predicate,
            $other->query_enforcement ? $other->query_enforcement->predicate : undef);
        _pending() unless defined $predicate;
        # The stored row the candidate selected, and the row the candidate
        # will leave behind, must both be outside the predicate: an earlier
        # INSERT can create a match, and a DO UPDATE can make one.
        _pending() if defined($entry->{physical_id}) && _stored_selected($adapter, $entry, $predicate);
        _pending() if _row_matches_predicate($adapter, $entry, _final_row($entry), $predicate);
        _changed_keys($adapter, $entry, $other) if $operation eq 'update';
        return 1;
    }
    _pending();
}

sub _insertion_disjoint {
    my ($adapter, $entry, $other) = @_;
    my $submitted = Selecto::SQLite::UpsertCandidate::_submitted($other, $entry);
    _pending() if _row_matches_keys($adapter, $entry, {kind => 'insert', values => $submitted},
        $entry->{arbiter}, $entry->{keys});
    return 1;
}

# Project an ordinary UPSERT exactly as a protected one: its own arbiter,
# insertion keys and stored branch, without registering a receipt.
sub _prospect {
    my ($adapter, $entry, $other) = @_;
    my $facts = Selecto::SQLite::UpsertCandidate::_schema($adapter, $other,
        {field_types => $entry->{request}{field_types}, dependencies => []});
    _pending() unless $facts->{table} eq $entry->{table};
    my $submitted = Selecto::SQLite::UpsertCandidate::_submitted($other, $facts);
    my @keys = grep { !($facts->{schema}{$_}{rowid_alias} && !defined($submitted->{$_})) } @{$facts->{target}};
    my $inserted = Selecto::SQLite::UpsertCandidate::_project_values($adapter, $facts, 'insert', $submitted, \@keys);
    my $selection = Selecto::SQLite::UpsertCandidate::_select($adapter, $facts, $inserted);
    return {%$facts, %$selection, inserted => $inserted};
}

# An UPDATE whose written arbiter fields all equal this candidate's key could
# move another row onto it. One written component that differs is enough.
sub _changed_keys {
    my ($adapter, $entry, $other) = @_;
    return 1 if grep { !defined } @{$entry->{keys}};
    my $assignments = $other->assignments;
    my %assigned;
    for my $field (keys %$assignments) {
        $assigned{Selecto::SQLite::UpsertCandidate::_canonical_field($field, $entry->{schema})} = $assignments->{$field};
    }
    my @fields = @{$entry->{arbiter}{fields}};
    my @changed = grep { exists $assigned{$fields[$_][0]} } 0 .. $#fields;
    return 1 unless @changed;
    for my $index (@changed) {
        my ($field, $collation) = @{$fields[$index]};
        my $value = $assigned{$field};
        if (ref($value) eq 'Selecto::Write::Expression') {
            _pending() unless $value->kind eq 'literal';
            $value = $value->arguments->[0];
        }
        _pending() if ref($value) && !JSON::PP::is_bool($value);
        return 1 unless _row_matches_keys($adapter, $entry, {kind => 'insert', values => {$field => $value}},
            {fields => [[$field, $collation]]}, [$entry->{keys}[$index]]);
    }
    _pending();
}

sub _final_row {
    my ($state) = @_;
    return {kind => 'insert', values => $state->{inserted}} if $state->{branch} eq 'insert';
    my $mask = $state->{effect} && $state->{effect} eq 'nothing' ? [] : $state->{mask};
    _pending() if grep { !exists $state->{inserted}{$_} } @$mask;
    _pending() unless ref($state->{physical_id}) eq 'ARRAY' && @{$state->{physical_id}};
    return {kind => 'stored', physical_id => $state->{physical_id},
        overlay => {map { ($_ => $state->{inserted}{$_}) } @$mask}};
}

sub _stored_selected {
    my ($adapter, $entry, $predicate) = @_;
    my @params;
    my $where = $adapter->_compile_write_predicate($predicate, \@params);
    my @witness = @{$entry->{witness}};
    _pending() unless @witness == @{$entry->{physical_id}};
    push @params, @{$entry->{physical_id}};
    my $rows = $adapter->_read_only(sub {
        _rows($adapter, 'SELECT 1 FROM main.' . _q($adapter, $entry->{table}) . ' WHERE (' . $where . ') AND '
            . join(' AND ', map { _q($adapter, $_) . ' = ?' } @witness) . ' LIMIT 1', \@params, 1);
    });
    return scalar @$rows;
}

sub _row_matches_keys {
    my ($adapter, $facts, $row, $arbiter, $keys) = @_;
    # SQLite UNIQUE treats every NULL as distinct.
    return 0 if grep { !defined } @$keys;
    my @fields = @{$arbiter->{fields}};
    return _with_row($adapter, $facts, $row, [map { $_->[0] } @fields], sub {
        my ($name) = @_;
        my $sql = 'SELECT ' . join(' AND ', map {
            '(' . _q($adapter, $_->[0]) . ' COLLATE ' . _q($adapter, $_->[1]) . ') = (? COLLATE ' . _q($adapter, $_->[1]) . ')'
        } @fields) . ' FROM temp.' . _q($adapter, $name);
        my $rows = _rows($adapter, $sql, [@$keys], 1);
        _pending() unless @$rows == 1;
        my $equal = $rows->[0][0];
        return defined($equal) && "$equal" eq '1' ? 1 : 0;
    });
}

sub _row_matches_predicate {
    my ($adapter, $facts, $row, $predicate) = @_;
    my %fields;
    _predicate_fields($predicate, $facts, \%fields, 0, \(my $nodes = 0));
    return _with_row($adapter, $facts, $row, [keys %fields], sub {
        my ($name) = @_;
        my @params;
        my $where = $adapter->_compile_write_predicate($predicate, \@params);
        my $rows = _rows($adapter, 'SELECT count(*) FROM temp.' . _q($adapter, $name) . ' WHERE ' . $where, \@params, 1);
        _pending() unless @$rows == 1 && defined($rows->[0][0]);
        return $rows->[0][0] ? 1 : 0;
    });
}
sub _predicate_fields {
    my ($expression, $facts, $fields, $depth, $nodes) = @_;
    _pending('predicate_limit') if $depth > 64 || ++$$nodes > 1024;
    _pending() unless blessed($expression) && $expression->isa('Selecto::Expression');
    my $kind = $expression->kind;
    my $arguments = $expression->arguments;
    if ($kind =~ /\A(?:eq|ne|gt|gte|lt|lte|is_null|not_null|in)\z/) {
        my $field = Selecto::SQL::_write_field($arguments->[0]);
        $fields->{Selecto::SQLite::UpsertCandidate::_canonical_field($field, $facts->{schema})} = 1;
        return;
    }
    if ($kind eq 'and' || $kind eq 'or') {
        _pending() unless ref($arguments->[0]) eq 'ARRAY' && @{$arguments->[0]};
        _predicate_fields($_, $facts, $fields, $depth + 1, $nodes) for @{$arguments->[0]};
        return;
    }
    return _predicate_fields($arguments->[0], $facts, $fields, $depth + 1, $nodes) if $kind eq 'not';
    _pending();
}

# Materialize the named fields of one prospective row in a TEMP table that
# carries the target columns' affinity and collation, then roll it back. An
# inserted row resolves omitted fields to their literal defaults; a generated
# rowid or volatile default is unknown. A stored row is copied natively.
sub _with_row {
    my ($adapter, $facts, $row, $fields, $work) = @_;
    my %seen;
    my @fields = sort grep { !$seen{$_}++ } @$fields;
    _pending() unless @fields;
    my (@definitions, @values, @params);
    for my $field (@fields) {
        my $column = $facts->{schema}{$field};
        _pending() unless $column;
        push @definitions, _q($adapter, $field) . ' ' . _affinity($column->{type}) . ' COLLATE ' . _q($adapter, $column->{collation});
    }
    my $name = 'selecto_upsert_independence_' . ++$SERIAL;
    my $insert = 'INSERT INTO temp.' . _q($adapter, $name);
    if ($row->{kind} eq 'insert') {
        for my $field (@fields) {
            my $value;
            if (exists $row->{values}{$field}) { $value = $row->{values}{$field} }
            elsif ($facts->{schema}{$field}{rowid_alias}) { _pending('generated_identity_unavailable') }
            else {
                my $default = $facts->{schema}{$field}{default};
                $value = defined($default) ? Selecto::SQLite::UpsertCandidate::_default($adapter, $default) : undef;
            }
            _pending() if ref($value) && !JSON::PP::is_bool($value);
            push @params, $value;
        }
        $insert .= ' VALUES(' . join(',', ('?') x @fields) . ')';
    } elsif ($row->{kind} eq 'stored') {
        my @witness = @{$facts->{witness}};
        _pending() unless @witness == @{$row->{physical_id}};
        for my $field (@fields) {
            if (exists $row->{overlay}{$field}) {
                my $value = $row->{overlay}{$field};
                _pending() if ref($value) && !JSON::PP::is_bool($value);
                push @values, '?'; push @params, $value;
            } else { push @values, _q($adapter, $field) }
        }
        push @params, @{$row->{physical_id}};
        $insert .= ' SELECT ' . join(',', @values) . ' FROM main.' . _q($adapter, $facts->{table})
            . ' WHERE ' . join(' AND ', map { _q($adapter, $_) . ' = ?' } @witness) . ' LIMIT 2';
    } else { _pending() }
    my $savepoint = 'selecto_upsert_independence_probe_' . $SERIAL;
    my ($answer, $error);
    _rows($adapter, 'SAVEPOINT ' . $savepoint, [], 1);
    my $ok = eval {
        _rows($adapter, 'CREATE TEMP TABLE ' . _q($adapter, $name) . '(' . join(',', @definitions) . ')', [], 1);
        _rows($adapter, $insert, \@params, 1);
        my $count = _rows($adapter, 'SELECT count(*) FROM temp.' . _q($adapter, $name), [], 1);
        _pending('candidate_row_unavailable') unless @$count == 1 && $count->[0][0] == 1;
        $answer = $work->($name);
        1;
    };
    $error = $@ unless $ok;
    my $restored = eval {
        _rows($adapter, 'ROLLBACK TO ' . $savepoint, [], 1);
        _rows($adapter, 'RELEASE ' . $savepoint, [], 1); 1;
    };
    _pending('projection_restore_failed') unless $restored;
    die $error unless $ok;
    return $answer;
}

# SQLite's column affinity rules, applied to the declared type text.
sub _affinity {
    my ($declared) = @_;
    my $type = uc($declared // '');
    return 'INTEGER' if $type =~ /INT/;
    return 'TEXT' if $type =~ /CHAR|CLOB|TEXT/;
    return 'BLOB' if $type eq '' || $type =~ /BLOB/;
    return 'REAL' if $type =~ /REAL|FLOA|DOUB/;
    return 'NUMERIC';
}

1;

__END__

=head1 NAME

Selecto::SQLite::UpsertIndependence - whole-plan independence for protected SQLite UPSERTs

=head1 DESCRIPTION

Internal part of L<Selecto::SQLite>. Admits a batch that contains protected
UPSERT candidates only when every candidate is provably independent of every
other command on its table, in both directions, and refuses with
C<required_data_rule_pending> before any business statement otherwise.

=cut
