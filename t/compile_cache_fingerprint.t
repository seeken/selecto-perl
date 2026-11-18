use strict;
use warnings;
use Test::More;
use Selecto;
use Selecto::Expression;
use Selecto::Retarget;
use DBI;

my $adapter=Selecto->adapter(sqlite=>dbh=>DBI->connect('dbi:SQLite:dbname=:memory:','',''));
sub declaration {
    return (name=>'fp',table=>'items',fields=>{id=>'integer',tenant=>'integer',label=>'string'},
        tenant_field=>'tenant',associations=>{related=>{table=>'related',fields=>{id=>'integer',label=>'string'},owner_key=>'id',related_key=>'id'}});
}
my $base=Selecto::Domain->new(declaration());
for my $change (
    [table=>'other'], [fields=>{id=>'integer',tenant=>'integer',label=>'integer'}],
    [tenant_field=>'id'], [primary_key=>'label'],
    [required_predicate=>Selecto::Expression->eq('id',1)],
    [associations=>{related=>{table=>'other_related',fields=>{id=>'integer'},owner_key=>'id',related_key=>'id'}}],
    [associations=>{related=>{table=>'related',fields=>{id=>'integer'},owner_key=>'label',related_key=>'id'}}],
    [associations=>{related=>{table=>'related',fields=>{id=>'integer'},owner_key=>'id',related_key=>'id',join_type=>'inner'}}],
    [associations=>{related=>{table=>'related',fields=>{id=>'integer'},owner_key=>'id',related_key=>'id',where=>{id=>2}}}],
    [associations=>{related=>{table=>'related',fields=>{id=>'integer'},owner_key=>'id',related_key=>'id',through=>{table=>'bridge',owner_key=>'owner',related_key=>'related'}}}],
) {
    my $d=Selecto::Domain->new(declaration(),@$change);
    isnt($d->fingerprint,$base->fingerprint,"$change->[0] changes generation");
    isnt($d->with_required_predicate(Selecto::Expression->eq('id',7))->fingerprint,
        $base->with_required_predicate(Selecto::Expression->eq('id',7))->fingerprint,
        "$change->[0] preserved in derived generation") unless $change->[0] eq 'required_predicate';
}
my $a=$base->with_required_predicate(Selecto::Expression->eq('id',1));
my $b=$base->with_required_predicate(Selecto::Expression->gt('id',1));
isnt($a->fingerprint,$b->fingerprint,'required operator is fingerprinted');
isnt($a->fingerprint,$base->with_required_predicate(Selecto::Expression->eq('id',2))->fingerprint,
    'required literal is fingerprinted conservatively');

my $raw={schema_version=>1,name=>'policy',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id label)],
    columns=>{id=>{type=>'integer'},label=>{type=>'string'}},associations=>{}},
    schemas=>{},joins=>{},required_selected=>['id']};
my $p1=Selecto::Domain->parse($raw);
my $p2=Selecto::Domain->parse({%$raw,required_selected=>['label']});
isnt($p1->fingerprint,$p2->fingerprint,'canonical document includes required policy');
my $required=Selecto::Expression->eq('id',1);
isnt($p1->with_required_predicate($required)->fingerprint,$p2->with_required_predicate($required)->fingerprint,
    'derived fingerprint retains required query policy');
my $d1=$p1->with_required_predicate($required);
my $d2=$p2->with_required_predicate($required);
my $q=Selecto::Query->new->select('label');
my $snapshot=$d1->contract;
my $e1=Selecto::Engine->new(domain=>$d1,adapter=>$adapter);
my $e2=Selecto::Engine->new(domain=>$d2,adapter=>$adapter);
$e1->compile($q) for 1..2;
is_deeply($d1->contract,$snapshot,'lookup does not insert missing keys or mutate the contract');
is_deeply($e2->compile($q)->columns,['label'],'new derived policy cannot reuse stale required selection');
my $scoped=Selecto::Engine->new(domain=>$base,adapter=>$adapter)->with_scope(tenant=>1);
isnt($scoped->read_domain->fingerprint,$base->fingerprint,'Engine scope fingerprints required predicate');
my $prefix=Selecto::Engine->new(domain=>$p1,adapter=>$adapter)->with_read_context({prefix=>'tenant_one'});
isnt($prefix->read_domain->fingerprint,$p1->fingerprint,'Engine prefix copy refreshes fingerprint');
my $prefix2=Selecto::Engine->new(domain=>$p1,adapter=>$adapter)->with_read_context({prefix=>'tenant_two'});
isnt($prefix->read_domain->fingerprint,$prefix2->read_domain->fingerprint,'prefix value is fingerprinted');

# Repeat each main per-request authority/admission check on a warmed hit.
my $owned=$scoped->query->select('id')->where(Selecto::Expression->eq('id',7));
$scoped->compile($owned) for 1..2;
my %counts;
my @names=qw(Selecto::Engine::validate_tenant_scope Selecto::QueryBinding::validate
    Selecto::OperationBudget::check_tree Selecto::OperationBudget::consume_count Selecto::SQLite::admit_parameters);
{
    no strict 'refs'; no warnings qw(redefine once);
    my @original=map { \&{$_} } @names;
    local *Selecto::Engine::validate_tenant_scope=sub { ++$counts{$names[0]}; goto &{$original[0]} };
    local *Selecto::QueryBinding::validate=sub { ++$counts{$names[1]}; goto &{$original[1]} };
    local *Selecto::OperationBudget::check_tree=sub { ++$counts{$names[2]}; goto &{$original[2]} };
    local *Selecto::OperationBudget::consume_count=sub { ++$counts{$names[3]}; goto &{$original[3]} };
    local *Selecto::SQLite::admit_parameters=sub { ++$counts{$names[4]}; goto &{$original[4]} };
    my @runs;
    for my $enabled (1,0) {
        local $adapter->{compile_cache}=$enabled;
        %counts=(); $scoped->compile($owned); push @runs,{%counts};
    }
    is_deeply($runs[0],$runs[1],'warm render hit preserves main check call counts');
    for my $name (@names) { ok($runs[0]{$name},"$name runs on a hit"); }
}
done_testing;
