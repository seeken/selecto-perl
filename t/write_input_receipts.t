use 5.034;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Selecto;
use Selecto::Write::PortableCommand;

{
    package ReceiptAdapter;
    use parent 'Selecto::SQLite';
    sub requires_dbh { 0 }
    sub write_capabilities { die 'unexpected capability provider' }
    sub execute_query { die 'unexpected stored query' }
    sub rule_project_subject { die 'unexpected stored projection' }
}
sub domain {
    my ($table) = @_;
    return {name => 'Receipt phases', source => {source_table => $table, primary_key => 'id',
        fields => [qw(id name)], columns => {id => {type => 'integer'}, name => {type => 'string', text_case => 'uppercase'}},
        associations => {}}, schemas => {}, joins => {}, writes => {
            operations => {insert => {enabled => JSON::PP::true}},
            fields => {id => {insertable => JSON::PP::true}, name => {insertable => JSON::PP::true,
                validators => [['inclusion', ['MIXED']]]}}},
        rules => {schema => 'selecto.data_rules.v1', definitions => {raw => {version => 1,
            test => {op => 'text.pattern', profile => 'ascii_v1', pattern => '[a-z]+', match => 'full', flags => []}}},
            normalizers => {}, bindings => {raw => {subject => {scope => 'input', path => ['name']},
                operations => ['insert'], rule => {id => 'raw', version => 1}}}}};
}
sub error {
    my ($work) = @_;
    return undef if eval { $work->();1 };
    my $error = $@;
    die "untyped failure: $error" unless ref($error) eq 'Selecto::Error';
    return $error->code;
}
my $adapter = ReceiptAdapter->new;
sub engine {
    my ($raw, %args) = @_;
    return Selecto::Engine->new(domain => Selecto::Domain->parse($raw), adapter => $adapter, %args);
}
sub compile {
    my ($raw) = @_;
    return Selecto::Write::PortableCommand->compile(Selecto::Write::Operation->new($raw)->insert({id => 1, name => 'mixed'}))->{command};
}
sub prepared {
    my ($engine, $command, $proof) = @_;
    return Selecto::WriteRules->prepare_submitted($engine, $engine->governed_write($command),
        accepted_input => $proof);
}

my $raw = domain('items');my $engine = engine($raw);my $command = compile($raw);
is($command->assignments->{name}, 'MIXED', 'compiler actually applies field normalization after raw INPUT');
my $proof = Selecto::Write::PortableCommand->_accepted_input($command);
ok(defined $proof, 'original compiler command owns private INPUT evidence');
Selecto::Write::Capabilities->requirements($command);
is(error(sub { Selecto::Write::PortableCommand->_accepted_input($command) }), undef,
    'ordinary structural capability admission preserves original compiler identity');
is(error(sub { prepared($engine, $command, undef) }), 'data_rule_failed', 'raw normalized assignment still fails the lowercase INPUT rule');
for (1..2) {
    is(prepared($engine, $command, $proof)->assignments->{name}, 'MIXED', 'independent native preparation reuses only original INPUT evidence');
}
my $copy = $command->with_metadata($command->metadata);
ok(!defined Selecto::Write::PortableCommand->_accepted_input($copy), 'public command reconstruction inherits no compiler receipt');
is(error(sub { prepared($engine, $copy, undef) }), 'data_rule_failed', 'reconstructed command remains subject to raw INPUT enforcement');
my $fake = bless \(my $identity = 0), 'Selecto::Write::PortableCommand::_InputProof';
is(error(sub { prepared($engine, $command, $fake) }), 'compiled_input_mismatch', 'same-class manufactured proof grants no preparation authority');
my $changed = compile($raw);$changed->{assignments}{name} = 'FORGED';
is(error(sub { Selecto::Write::PortableCommand->_accepted_input($changed) }), 'compiled_input_mismatch', 'direct command mutation fails full snapshot validation');
my ($nv_a,$nv_b)=(0.1,0.10000000000000002);
is("$nv_a","$nv_b",'distinct delivered NV counterexample has identical default text');
isnt(pack('F',$nv_a),pack('F',$nv_b),'counterexample has distinct native NV bytes');
isnt(Selecto::Write::PortableCommand::_receipt_digest($nv_a),
    Selecto::Write::PortableCommand::_receipt_digest($nv_b),'receipt identity retains exact native NV bytes');
my $nv_domain=domain('items');push @{$nv_domain->{source}{fields}},'amount';
$nv_domain->{source}{columns}{amount}={type=>'float'};
$nv_domain->{writes}{fields}{amount}={insertable=>JSON::PP::true};
my $nv_command=Selecto::Write::Operation->new($nv_domain)->insert({id=>1,name=>'mixed',amount=>$nv_a})->compile->{command};
ok(defined Selecto::Write::PortableCommand->_accepted_input($nv_command),'original native NV assignment has compiler evidence');
$nv_command->{assignments}{amount}=$nv_b;
is(error(sub { Selecto::Write::PortableCommand->_accepted_input($nv_command) }), 'compiled_input_mismatch',
    'changing a delivered NV with identical default text invalidates the full command snapshot');
my $unicode_domain=domain('items');delete $unicode_domain->{source}{columns}{name}{text_case};
delete $unicode_domain->{writes}{fields}{name}{validators};
$unicode_domain->{rules}{definitions}{raw}{test}={op=>'text.length',unit=>'unicode_scalar',exact=>1};
my $unicode=chr(0xe9);utf8::upgrade($unicode);
my $unicode_command=Selecto::Write::Operation->new($unicode_domain)->insert({id=>1,name=>$unicode})->compile->{command};
ok(defined Selecto::Write::PortableCommand->_accepted_input($unicode_command), 'Unicode scalar command owns its original INPUT evidence');
$unicode_command->{assignments}{name}=pack('C*',0xc3,0xa9);
is(error(sub { Selecto::Write::PortableCommand->_accepted_input($unicode_command) }), 'compiled_input_mismatch',
    'same encoded bytes with different Unicode identity invalidate compiler INPUT');
for my $boolean_class (qw(JSON::PP::Boolean JSON::XS::Boolean Types::Serialiser::Boolean)) {
    my $boolean_domain=domain('items');my $truth=1;
    $boolean_domain->{writes}{operations}{insert}{enabled}=bless \$truth,$boolean_class;
    my $boolean_command=compile($boolean_domain);
    ok(defined Selecto::Write::PortableCommand->_accepted_input($boolean_command),
        "$boolean_class is admitted through the canonical plain Boolean copier");
}
my $bool_domain=domain('items');push @{$bool_domain->{source}{fields}},'flag';
$bool_domain->{source}{columns}{flag}={type=>'boolean'};
$bool_domain->{writes}{fields}{flag}={insertable=>JSON::PP::true};
my $bool_command=Selecto::Write::Operation->new($bool_domain)->insert({id=>1,name=>'mixed',flag=>JSON::PP::true})->compile->{command};
ok(defined Selecto::Write::PortableCommand->_accepted_input($bool_command),'canonical assigned Boolean owns its original evidence');
$bool_command->{assignments}{flag}=bless \(my $noncanonical_boolean=2),'JSON::PP::Boolean';
is(error(sub { Selecto::Write::PortableCommand->_accepted_input($bool_command) }),'compiled_input_mismatch',
    'noncanonical Boolean payload cannot reuse a canonical true snapshot');
my $different = domain('items');$different->{rules}{definitions}{raw}{test}{pattern} = '[A-Z]+';
is(error(sub { prepared(engine($different), $command, $proof) }), 'compiled_input_mismatch', 'changed host rules cannot borrow compiler evidence');
is(error(sub { prepared(engine($raw, write_context => {tenant_id => 'other'}), $command, $proof) }),
    'compiled_input_mismatch', 'different trusted context cannot reuse compiler evidence');
my $scoped=domain('items');push @{$scoped->{source}{fields}},'tenant_id';
$scoped->{source}{columns}{tenant_id}={type=>'integer'};
$scoped->{writes}{scope}{tenant}={required=>JSON::PP::true,field=>'tenant_id',satisfied_by=>['trusted_context']};
my $scoped_command=Selecto::Write::Operation->new($scoped)->insert({id=>1,name=>'mixed'})->compile(context=>{tenant_id=>7})->{command};
my $scoped_proof=Selecto::Write::PortableCommand->_accepted_input($scoped_command);
my $scoped_engine=engine($scoped,write_context=>{tenant_id=>7});
is(error(sub { prepared($scoped_engine,$scoped_command,$scoped_proof) }),undef,
    'same trusted context preserves submitted evidence through native tenant materialization');
my $fk_domain=domain('items');push @{$fk_domain->{source}{fields}},'account_id';
$fk_domain->{source}{columns}{account_id}={type=>'integer'};
$fk_domain->{writes}{fields}{account_id}={insertable=>JSON::PP::true};
$fk_domain->{writes}{constraints}{foreign_keys}{account_id}={source=>['context','account_id'],required=>JSON::PP::true,
    references=>{relation=>'accounts',field=>'id',tenant_field=>JSON::PP::false}};
my $fk_command=Selecto::Write::Operation->new($fk_domain)->insert({id=>1,name=>'mixed'})->compile(context=>{account_id=>42})->{command};
my $fk_proof=Selecto::Write::PortableCommand->_accepted_input($fk_command);
is(error(sub { prepared(engine($fk_domain,write_context=>{account_id=>42}),$fk_command,$fk_proof) }),undef,
    'same exact trusted context preserves generated numeric foreign key through native materialization');
my $tight = engine($raw, limits => Selecto::Limits->new(max_regex_states => 2));
is(error(sub { prepared($tight, $command, $proof) }), 'invalid_text_pattern', 'fresh native pattern-state ceiling is applied without replaying the rule');

subtest 'measured INPUT work is replayed per request and deduplicated within it' => sub {
    Selecto::DataRules->_with_proof_budget(sub {
        my ($work) = Selecto::DataRules->_rule_work_context($engine->limits);
        my $start = $$work;
        Selecto::Write::PortableCommand->_reuse_input($proof, $engine, $command);
        my $first = $$work - $start;my $middle = $$work;
        Selecto::Write::PortableCommand->_reuse_input($proof, $engine, $command);
        my $second = $$work - $middle;
        ok($first > $second, 'fresh scope charges the measured compiler work only on its first use');
        ok($second > 0, 'resource-only rechecks still charge the shared current counter');
    }, limits => $engine->limits);
    Selecto::DataRules->_with_proof_budget(sub {
        my ($work) = Selecto::DataRules->_rule_work_context($engine->limits);
        my $same = compile($raw);my $accepted = Selecto::Write::PortableCommand->_accepted_input($same);
        my $start = $$work;
        Selecto::Write::PortableCommand->_reuse_input($accepted, $engine, $same);
        my $first = $$work - $start;my $middle = $$work;
        Selecto::Write::PortableCommand->_reuse_input($accepted, $engine, $same);
        is($$work - $middle, $first, 'same-scope compile work is already counted, while each resource check remains counted');
    }, limits => $engine->limits);
};

subtest 'final graph owns receipts across compiler returning copies' => sub {
    my $root = compile($raw);my $child = compile(domain('children'));
    my $graph = Selecto::Write::Graph->new(nodes => [
        {id => 'root', command => $root},
        {id => 'child', command => $child, bindings => [{from => 'root', key => 'id', field => 'parent_id'}]},
    ]);
    Selecto::Write::PortableCommand->_capture_graph_inputs($graph, {root => $root, child => $child});
    my $proofs = Selecto::Write::PortableCommand->_accepted_graph_inputs($graph);
    is_deeply([sort keys %$proofs], [qw(child root)], 'final graph binds both actual source receipts');
    is_deeply(Selecto::Write::PortableCommand->_accepted_graph_inputs($graph->validate), {}, 'public graph reconstruction inherits no preparation authority');
    $graph->{nodes}[1]{command}{assignments}{name} = 'FORGED';
    is(error(sub { Selecto::Write::PortableCommand->_accepted_graph_inputs($graph) }), 'compiled_input_mismatch', 'changed final graph fails before any engine preparation');
};

done_testing;
