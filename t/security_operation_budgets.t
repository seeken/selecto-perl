use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use Selecto::Domain;
use Selecto::Expression;
use Selecto::ValueExpression;
use Selecto::OperationBudget;
use Selecto::Limits;
use Selecto::DataRules;
use Selecto::Pattern;
use Selecto::Importer;

sub code { my ($run) = @_; return eval { $run->(); 1 } ? 'ok' : ref($@) && $@->can('code') ? $@->code : "$@" }
sub budget { Selecto::OperationBudget->new(limits => Selecto::Limits->new(@_), code => 'limited') }
sub rule {
    my ($test, $limits) = @_;
    return Selecto::DataRules->parse({schema => 'selecto.data_rules.v1',
        definitions => {check => {version => 1, test => $test}}, normalizers => {},
        bindings => {check => {subject => {scope => 'input', path => ['v']}, operations => [], rule => {id => 'check', version => 1}}}},
        defined($limits) ? (limits => $limits) : ());
}
sub evaluate { $_[0]->evaluate(stage => 'input', subject => {v => $_[1]}) }

subtest 'iterative structure admission and separate parameter accounting' => sub {
    my $b = budget(max_expression_nodes => 2, max_expression_depth => 1, max_state_bytes => 3, max_value_bytes => 3, max_parameter_bytes => 3);
    is $b->check_tree(['abc']), 3, 'exact structure nodes, depth and bytes admitted';
    is $b->consume_value('abc'), 'abc', 'tree admission did not consume parameter bytes';
    is code(sub { $b->consume_value('x') }), 'limited', 'parameter bytes accumulate';
    is code(sub { budget(max_expression_nodes => 1)->check_tree(['x']) }), 'limited', 'one node over refused';
    is code(sub { budget(max_expression_depth => 1)->check_tree([['x']]) }), 'limited', 'one level over refused';
    is code(sub { budget(max_state_bytes => 3)->check_tree(['éé']) }), 'limited', 'UTF-8 bytes counted';
    my $same = ['x'];
    is code(sub { budget(max_expression_nodes => 4)->check_tree([$same, $same]) }), 'limited', 'reused node occurrences count independently';
    my $cycle = []; push @$cycle, $cycle;
    is code(sub { budget()->check_tree($cycle) }), 'limited', 'cycle rejected without recursion';
    pop @$cycle;
    is code(sub { budget()->check_tree(sub {}) }), 'limited', 'unsupported references rejected';
    is code(sub { budget(max_generated_parameters => 2)->consume_parameters(['a','b','c']) }), 'limited', 'final parameter count enforced';
    is code(sub { budget(max_parameter_bytes => 3)->consume_parameters(['ab','cd']) }), 'limited', 'final parameter aggregate enforced';
};

subtest 'filter/value ASTs share all literal accounting' => sub {
    my $policy = Selecto::Limits->new(max_filter_values => 2, max_expression_arity => 2, max_value_bytes => 3, max_parameter_bytes => 5);
    my $new = sub { Selecto::OperationBudget->new(limits => $policy, code => 'limited') };
    is code(sub { Selecto::Expression->from_filter_ast(['in','id',[1,2]], 0, $new->()) }), 'ok', 'membership boundary accepted';
    is code(sub { Selecto::Expression->from_filter_ast(['in','id',[1,2,3]], 0, $new->()) }), 'invalid_query', 'membership overflow refused';
    is code(sub { Selecto::Expression->from_filter_ast(['array_overlap','id',[1,2,3]], 0, $new->()) }), 'invalid_query', 'array overflow refused';
    is code(sub { Selecto::Expression->from_filter_ast(['and', [['eq','id','abc'], ['eq','id','def']]], 0, $new->()) }), 'limited', 'literal bytes aggregate across filters';
    is code(sub { Selecto::Expression->from_filter_ast(['and', [map { ['eq','id',1] } 1..3]], 0, $new->()) }), 'invalid_query', 'Boolean fanout enforced';
    is code(sub { Selecto::ValueExpression->parse(['concat',['literal','abc'],['literal','def']], limits => $policy) }), 'invalid_value_expression', 'value literals aggregate';
    is code(sub { Selecto::ValueExpression->parse(['case', [['eq','id','abc'], ['literal','def']]], limits => $policy) }), 'invalid_value_expression', 'embedded condition shares value literal budget';
    my $ast = ['literal', 'x']; $ast = ['upper', $ast] for 1..66;
    is code(sub { Selecto::Expression->value($ast) }), 'invalid_value_expression', 'unary depth refused before recursion';
    is code(sub { Selecto::Expression->value(['concat', map { ['literal','x'] } 1..10001]) }), 'invalid_value_expression', 'broad tree refused before clone';
    is code(sub { Selecto::ValueExpression->parse(['json_text','metadata',[qw(a b c)]], limits => Selecto::Limits->new(max_json_path_segments => 2)) }), 'invalid_value_expression', 'path segment ceiling enforced';
    my $json = {}; $json->{cycle} = $json;
    is code(sub { Selecto::Expression->from_filter_ast(['json_contains','metadata',$json]) }), 'invalid_query', 'JSON cycle refused before encoding';
    delete $json->{cycle};
    $json->{cycle} = $json;
    is code(sub { Selecto::Expression->json_contains('metadata', $json) }), 'invalid_query', 'direct constructor rejects before recursive clone';
    delete $json->{cycle};
    is code(sub { Selecto::Expression->in('id', [1..101]) }), 'invalid_query', 'direct membership constructor has safe defaults';
};

subtest 'rules admit subjects before clone and decimal allocation' => sub {
    my $rules = rule({op => 'number.gt', bound => '0'}, Selecto::Limits->new(max_rule_numeric_digits => 3));
    is evaluate($rules, '999')->{state}, 'passed', 'exact digit boundary accepted';
    is evaluate($rules, '0.99')->{state}, 'passed', 'fractional digits counted';
    is evaluate($rules, '0.999')->{code}, 'evaluation_limit', 'fractional digit overflow refused';
    is evaluate($rules, '-99')->{code}, 'numeric_bound', 'sign does not consume a digit';
    is evaluate($rules, '01')->{code}, 'invalid_type', 'leading-zero grammar unchanged';
    my $calls = 0;
    {
        no warnings 'redefine';
        local *Math::BigRat::new = sub { $calls++; die 'must not allocate' };
        is evaluate($rules, '9999')->{code}, 'evaluation_limit', 'oversized number rejected';
    }
    is $calls, 0, 'oversized subject never invokes BigRat';
    is code(sub { rule({op => 'number.gt', bound => '9999'}, Selecto::Limits->new(max_rule_numeric_digits => 3)) }), 'invalid_data_rules_contract', 'trusted bound obeys digit limit';
    my $clones = 0;
    my $tiny = rule({op => 'number.gt', bound => '0'});
    my $subject = {}; $subject->{cycle} = $subject;
    {
        no warnings 'redefine';
        local *Selecto::DataRules::dclone = sub { $clones++; die 'must not clone' };
        is $tiny->evaluate(stage => 'input', subject => $subject)->{code}, 'evaluation_limit', 'cyclic subject refused';
    }
    delete $subject->{cycle};
    is $clones, 0, 'subject admission precedes cloning';
    is evaluate(rule({op => 'number.gt', bound => '0'}), '9' x 1024)->{state}, 'passed', 'exact precision retained through default ceiling';
    is evaluate(rule({op => 'number.gt', bound => '0'}), '9' x 1025)->{code}, 'evaluation_limit', 'default digit ceiling plus one refused';
};

subtest 'ascii_v1 regular language uses bounded non-backtracking evaluation' => sub {
    my @patterns = ('a', '.', 'a|aa', '(ab|c)+', '(a+)+', 'a*a*a*a*a*a*a*a*a*a*',
        '[a-c]{1,3}', '[^a-c]?', '\\d+', '\\D+', '\\s+', '\\w+', '\\W+', 'a{0}', 'a{0,2}', 'a{2,}',
        '(a|)b', 'a|', '[a-]+', '[]a]+', '\\.', '\\$', 'a?b*');
    my @texts = ('', 'a', 'aa', 'abc', 'ababc', 'c', 'b', '1', '12', 'a!', '.', '$', '-', ']', "\n", ' ');
    for my $pattern (@patterns) {
        my $compiled = Selecto::Pattern->compile($pattern);
        for my $text (@texts) {
            for my $mode (qw(full search)) {
                my $expected = $mode eq 'full' ? ($text =~ /\A(?:$pattern)\z/ ? 1 : 0) : ($text =~ /$pattern/ ? 1 : 0);
                my ($actual, $error) = $compiled->matches($text, match => $mode);
                is defined($error) ? $error : $actual, $expected, "$mode $pattern on " . JSON::PP->new->allow_nonref->encode($text);
            }
        }
    }
    my $pathological = rule({op => 'text.pattern', profile => 'ascii_v1', pattern => 'a*a*a*a*a*a*a*a*a*a*', match => 'full', flags => []});
    is evaluate($pathological, ('a' x 512) . '!')->{code}, 'pattern_mismatch', 'previously slow near miss completes normally';
    my ($value, $failure) = Selecto::Pattern->compile('(a+)+')->matches('a' x 20, limits => Selecto::Limits->new(max_rule_work => 10));
    is $failure, 'evaluation_limit', 'deterministic matcher work ceiling';
    is code(sub { Selecto::Pattern->compile('(a{1,1024}){1,1024}') }), 'invalid_text_pattern', 'expanded repetition is bounded at compile time';
    for my $invalid ('(?=a)', '^a', 'a$', 'a++', 'a+?', '\\1', '\\p{L}', '[a', '(a', 'a{999999999999999999999}') {
        is code(sub { Selecto::Pattern->compile($invalid) }), 'invalid_text_pattern', "unsupported or oversized $invalid refused";
    }
    my $unicode = rule({op => 'text.pattern', profile => 'ascii_v1', pattern => '.*', match => 'full', flags => []});
    is evaluate($unicode, 'é' x 2048)->{state}, 'passed', '4096 UTF-8 bytes accepted';
    is evaluate($unicode, 'é' x 2049)->{code}, 'evaluation_limit', '4098 UTF-8 bytes refused';
};

subtest 'import configuration and row expansion budgets precede resolver work' => sub {
    my $domain = Selecto::Domain->parse({schema_version => 1, name => 'Import budget fixture',
        source => {source_table => 'fixtures', primary_key => 'id', fields => [qw(id name)], columns => {id => {type => 'integer'}, name => {type => 'string'}}, associations => {}}, schemas => {}, joins => {},
        writes => {operations => {insert => {enabled => 1}, update => {enabled => 1}}, fields => {name => {insertable => 1, updatable => 1}}},
        imports => {contract_version => 1, enabled => 1, field_policy => 'declared_only', fields => {name => {sources => [qw(static parameter column)], transforms => ['uppercase']}}, actions => {}, key_sets => [{id => 'name', fields => ['name'], cardinality => 'zero_or_one', allowed_on_match => ['update'], allowed_on_missing => ['insert'], default_on_match => 'update', default_on_missing => 'insert'}]}}, strict => 1);
    my $importer = Selecto::Importer->new(domain => $domain, limits => Selecto::Limits->new(max_value_bytes => 3, max_import_preview_bytes => 1000));
    my $inspection = $importer->inspect_csv("h\nx\ny\n");
    my $config = {config_version => 1, mappings => [{target => 'name', source => {kind => 'static', value => 'abcd'}}], match => {key_set => 'name'}};
    my $clones = 0;
    {
        no warnings 'redefine';
        local *Selecto::Importer::_clone = sub { $clones++; die 'must not clone' };
        is code(sub { $importer->normalize_configuration($config, columns => $inspection->{columns}) }), 'import_configuration_limit_exceeded', 'oversized static refused before clone';
    }
    is $clones, 0, 'static admission precedes configuration clone';
    $config->{mappings}[0]{source} = {kind => 'parameter', name => 'shared'};
    $config->{parameters} = {shared => 'abcd'};
    is code(sub { $importer->normalize_configuration($config, columns => $inspection->{columns}) }), 'import_configuration_limit_exceeded', 'parameter source also bounded';
    delete $config->{parameters};
    $config->{mappings}[0]{source} = {kind => 'static', value => 'éé'};
    is code(sub { $importer->normalize_configuration($config, columns => $inspection->{columns}) }), 'import_configuration_limit_exceeded', 'static UTF-8 bytes bounded';
    $config->{mappings}[0]{source}{value} = 'abc';
    my $resolver_calls = 0;
    my $many = $importer->inspect_csv("h\n" . ("x\n" x 300));
    is code(sub { $importer->preview_rows($many, $config, key_resolver => sub { $resolver_calls++; return {matches => []} }) }), 'import_preview_limit_exceeded', 'small legal static value times rows is bounded';
    is $resolver_calls, 0, 'predictable expansion refuses before resolver';
    my $normal = Selecto::Importer->new(domain => $domain);
    my $preview = $normal->preview_rows($inspection, $config, key_resolver => sub { return {matches => []} });
    is $preview->{returned}, 2, 'ordinary preview preserved';
    my $encoded = JSON::PP->new->canonical->utf8->encode($preview);
    my $n = length($encoded);
    my $exact = Selecto::Importer->new(domain => $domain, limits => Selecto::Limits->new(max_import_preview_bytes => $n));
    is code(sub { $exact->preview_rows($inspection, $config, key_resolver => sub { return {matches => []} }) }), 'ok', 'exact encoded preview boundary accepted';
    my $over = Selecto::Importer->new(domain => $domain, limits => Selecto::Limits->new(max_import_preview_bytes => $n - 1));
    is code(sub { $over->preview_rows($inspection, $config, key_resolver => sub { return {matches => []} }) }), 'import_preview_limit_exceeded', 'one byte over encoded preview refused';
};

done_testing;
