use 5.034;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Selecto;
use Selecto::Engine;
use Selecto::Domain;
use Selecto::Expression;
use Selecto::QueryEnforcement ();
use Selecto::Write ();

# SQL Server, through a recording DBI handle (no server is needed):
# - a governed update under a bound scope (engine tenant, writes.scope, host
#   scope predicate) is refused with write_capability_missing before any
#   DML. SQL Server never re-reads the updated rows (TW-09 post-image), and
#   a view or synonym is not resolved to its base object.
# - a MERGE upsert carrying a write predicate, scope predicate or query
#   enforcement is refused: the MERGE compiler applies none of them, so it
#   updated whichever row held the conflicting key.
package RecordingDBH {
    our @LOG;
    sub new { bless {AutoCommit => 1, Driver => {Name => 'ODBC'}}, shift }
    sub prepare { push @LOG, "PREPARE $_[1]"; bless {}, 'RecordingSTH' }
    sub do { push @LOG, "DO $_[1]"; 1 }
    sub begin_work { push @LOG, 'BEGIN'; $_[0]{AutoCommit} = 0; 1 }
    sub commit { push @LOG, 'COMMIT'; $_[0]{AutoCommit} = 1; 1 }
    sub rollback { push @LOG, 'ROLLBACK'; $_[0]{AutoCommit} = 1; 1 }
    sub selectrow_array { push @LOG, "SELECTROW $_[1]"; return (0) }
    sub selectall_arrayref { push @LOG, "SELECTALL $_[1]"; [] }
    sub selectcol_arrayref { push @LOG, "SELECTCOL $_[1]"; [] }
    sub errstr { '' } sub err { 0 } sub state { '' } sub ping { 1 }
}
package RecordingSTH {
    sub execute { push @RecordingDBH::LOG, 'EXECUTE'; 1 }
    sub rows { 1 } sub fetchrow_array { () } sub fetchall_arrayref { [] } sub fetchrow_arrayref { undef }
    sub finish { 1 } sub err { 0 } sub errstr { '' }
}
package main;

my $x = 'Selecto::Expression';
sub code_of {
    my ($code) = @_;
    @RecordingDBH::LOG = ();
    return eval { $code->(); 'applied' } // (blessed($@) ? $@->code : "died: $@");
}
sub dml { grep { /\APREPARE\s+(?:UPDATE|MERGE|INSERT|DELETE)\b/ } @RecordingDBH::LOG }

sub domain {
    my ($relation, %o) = @_;
    return Selecto::Domain->parse({schema_version => 1, name => 'MssqlScope',
        source => {source_table => $relation, primary_key => 'id', fields => [qw(id note org_key status)],
            columns => {id => {type => 'integer'}, org_key => {type => 'string'}, note => {type => 'string'}, status => {type => 'string'}},
            associations => {}, ($o{tenant_field} ? (tenant_field => 'org_key') : ())},
        schemas => {}, joins => {},
        writes => {operations => {update => {enabled => 1}, upsert => {enabled => 1, conflict_targets => [['org_key', 'id']]}},
            fields => {id => {insertable => 1}, org_key => {insertable => 1}, note => {insertable => 1, updatable => 1},
                status => {updatable => 1}},
            ($o{scope} ? (scope => {tenant => {field => 'org_key', satisfied_by => ['trusted_context']}}) : ())},
        ($o{required} ? (required_filters => $o{required}) : ())});
}

for my $relation ('mssql_rows', 'mssql_view_or_synonym') {
    my $adapter = sub { Selecto->adapter(mssql => (dbh => RecordingDBH->new)) };
    my $update = sub { Selecto::Write::Command->new(operation => 'update', relation => $relation,
        assignments => {note => 'y'}, predicate => $x->eq('id', 1), @_) };
    my %bound = (
        'engine tenant' => sub { (Selecto::Engine->new(adapter => $adapter->(), domain => domain($relation, tenant_field => 1),
            scope => {tenant => 't1'}), $update->()) },
        'writes.scope' => sub { (Selecto::Engine->new(adapter => $adapter->(), domain => domain($relation, scope => 1),
            scope => {tenant => 't1'}), $update->()) },
        'host scope predicate' => sub { (Selecto::Engine->new(adapter => $adapter->(), domain => domain($relation)),
            $update->(scope_predicate => $x->eq('org_key', 't1'))) },
        'required tenant pin' => sub { (Selecto::Engine->new(adapter => $adapter->(),
            domain => domain($relation, tenant_field => 1, required => [['org_key', 't1']])), $update->()) },
    );
    for my $mode (sort keys %bound) {
        my ($engine, $command) = $bound{$mode}->();
        is(code_of(sub { $engine->execute_write($command) }), 'write_capability_missing',
            "$relation, $mode: a bound-scope update is refused");
        is_deeply([dml()], [], "$relation, $mode: before any DML");
    }
    # Updates without a bound scope keep their behaviour.
    for my $case (['no scope', domain($relation)], ['a plain required filter', domain($relation, required => [['status', 'open']])]) {
        my $engine = Selecto::Engine->new(adapter => $adapter->(), domain => $case->[1]);
        is(code_of(sub { $engine->execute_write($update->()) }), 'applied', "$relation, $case->[0]: the update runs");
        is(scalar(dml()), 1, "$relation, $case->[0]: as one UPDATE");
    }

    # Upserts, through the governed and the explicit unsafe path.
    my $upsert = sub { Selecto::Write::Command->new(operation => 'upsert', relation => $relation,
        assignments => {id => 1, org_key => 't1', note => 'x'},
        metadata => {conflict_target => ['org_key', 'id'], upsert_update_fields => ['note']}, @_) };
    my $plain = domain($relation);
    my $qe = Selecto::QueryEnforcement->capture($plain,
        Selecto::Engine->new(adapter => $adapter->(), domain => $plain)->query->where($x->eq('org_key', 't1')));
    for my $case (
        ['scope predicate', [scope_predicate => $x->eq('org_key', 't1')], 'unsupported_scope_predicate'],
        ['predicate', [predicate => $x->eq('note', 'x')], 'unsupported_scope_predicate'],
        ['query enforcement', [query_enforcement => $qe], 'query_enforcement_unsupported_operation'],
    ) {
        my ($label, $extra, $code) = @$case;
        is(code_of(sub { $adapter->()->execute_write_unsafe($upsert->(@$extra)) }), $code,
            "$relation: an unsafe MERGE upsert carrying a $label is refused");
        is_deeply([dml()], [], "$relation: $label, before any DML");
    }
    is(code_of(sub { Selecto::Engine->new(adapter => $adapter->(), domain => domain($relation, tenant_field => 1),
        scope => {tenant => 't1'})->execute_write($upsert->()) }), 'unsupported_scope_predicate',
        "$relation: a governed MERGE upsert under the engine tenant is refused");
    is_deeply([dml()], [], "$relation: engine tenant upsert, before any DML");
    is(code_of(sub { $adapter->()->execute_write_unsafe($upsert->()) }), 'applied', "$relation: an unscoped unsafe MERGE upsert runs");
    like((dml())[0] // '', qr/\APREPARE MERGE INTO/, "$relation: as a MERGE");
}

done_testing;
