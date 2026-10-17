use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use B ();
use JSON::PP ();
use Scalar::Util qw(dualvar refaddr reftype);
use Selecto::DataRules;
use Selecto::Domain;
use Selecto::Domain::DSL;
use Selecto::Action;
use Selecto::Limits;
use Selecto::Write::FieldValidators;

sub contract {
    my ($test, %binding) = @_;
    return {schema=>'selecto.data_rules.v1',definitions=>{one=>{version=>1,test=>$test}},
        normalizers=>{},bindings=>{one=>{subject=>{scope=>'input',path=>['value']},
            rule=>{id=>'one',version=>1},%binding}}};
}
sub error {
    my ($work)=@_;my $ok=eval {$work->();1};return undef if $ok;
    die "untyped failure: $@" unless ref($@) eq 'Selecto::Error';return $@->code;
}
sub evaluate {
    my ($test,$value,%binding)=@_;
    return Selecto::DataRules->parse(contract($test,%binding))->evaluate(stage=>'input',subject=>{value=>$value});
}
sub wire { JSON::PP->new->canonical->allow_nonref->encode($_[0]) }
sub flags { B::svref_2object(\$_[0])->FLAGS }

subtest 'delivered floating literals refuse through the complete public parser' => sub {
    for my $spelling ('1.0','1.25') {
        for my $shape (qw(number count member nested)) {
            my $value=JSON::PP->new->decode($spelling);
            ok((flags($value)&B::SVf_NOK()) && !(flags($value)&B::SVf_IOK()),'actual NOK-only input');
            my $test=$shape eq 'number'?{op=>'number.gte',bound=>$value}
                :$shape eq 'count'?{op=>'collection.count',max=>$value}
                :{op=>'membership.in',values=>[$shape eq 'member'?$value:{nested=>[$value]}]};
            is(error(sub {Selecto::DataRules->parse(contract($test))}),'invalid_data_rules_contract',"$spelling $shape declaration refused");
            is(error(sub {Selecto::DataRules->parse(contract({op=>'presence.required'},condition=>$test))}),
                'invalid_data_rules_contract',"$spelling $shape condition refused");
        }
    }
};
subtest 'exact integer, authored text and runtime floating identity survive' => sub {
    for my $spelling ('9007199254740992','9223372036854775807','-9223372036854775808','18446744073709551615') {
        my $value=JSON::PP->new->decode($spelling);
        my $text=join('',split //,$spelling);
        is(evaluate({op=>'number.gte',bound=>$value},$value)->{state},'passed','exact native bound');
        is(evaluate({op=>'membership.in',values=>[$value]},$text)->{state},'failed','native integer is distinct from same decimal text');
        is(evaluate({op=>'membership.in',values=>[$text]},$value)->{state},'failed','decimal text is distinct from native integer');
        is(evaluate({op=>'membership.in',values=>[{n=>[$value]}]},{n=>[$value]})->{state},'passed','recursive native integer equality');
        my $r=evaluate({op=>'presence.required'},$value);
        is(wire($r->{normalized}{value}),$spelling,'normalized native integer emits numeric JSON');
        my $observed=join('',split //,$spelling);my $numeric=0+$observed;
        $r=evaluate({op=>'membership.in',values=>[$text]},$observed);
        is($r->{state},'passed','observed authored text still matches text');
        is(wire($r->{normalized}{value}),wire($text),'normalized observed text emits quoted JSON');
    }
    for my $spelling ('1.0','1.25') {
        my $value=JSON::PP->new->decode($spelling);
        my $native_bytes=pack('F',$value);
        my $r=evaluate({op=>'number.gt',bound=>'0'},$value);
        is($r->{state},'passed','existing runtime fraction semantics preserved');
        ok((flags($r->{normalized}{value})&B::SVf_NOK()) && !(flags($r->{normalized}{value})&B::SVf_IOK()),
            'normalized runtime NV is not changed to an integer');
        is(pack('F',$r->{normalized}{value}),$native_bytes,'native floating bits are preserved');
    }
    my $below=JSON::PP->new->decode('9007199254740992');my $above=JSON::PP->new->decode('9007199254740993');
    is(evaluate({op=>'number.gt',bound=>$below},$above)->{state},'passed','adjacent native integers retain their difference');
    my $text='1.0';my $observed=0+$text;
    is(evaluate({op=>'number.gte',bound=>$text},1)->{state},'passed','observed decimal text remains a valid exact bound');
    my $dual=dualvar(7,'eight');
    is(evaluate({op=>'membership.in',values=>['eight']},$dual)->{state},'passed','actual dualvar retains its authored text');
    is(evaluate({op=>'membership.in',values=>[7]},$dual)->{state},'failed','dualvar numeric cache grants no numeric identity');
};
subtest 'Domain policy copies do not mutate original floating identity' => sub {
    my $value=JSON::PP->new->decode('1.0');
    my $raw={name=>'Policy copy',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id name)],
        columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
        writes=>{fields=>{name=>{validators=>[['number',[['greater_than',$value]]]]}}}};
    my $domain=Selecto::Domain->parse($raw);
    for my $copy ($domain->contract,$domain->as_contract,{writes=>$domain->writes}) {
        my $bound=$copy->{writes}{fields}{name}{validators}[0][1][0][1];
        ok((flags($bound)&B::SVf_NOK()) && !(flags($bound)&B::SVf_IOK()),'public policy copy retains NV-only declaration');
    }
    my $original=$raw->{writes}{fields}{name}{validators}[0][1][0][1];
    ok((flags($original)&B::SVf_NOK()) && !(flags($original)&B::SVf_IOK()),'parsing and accessors leave caller scalar kind unchanged');
    my $stored=$domain->_contract_view->{writes}{fields}{name}{validators}[0][1][0][1];
    ok((flags($stored)&B::SVf_NOK()) && !(flags($stored)&B::SVf_IOK()),'accessors leave configured policy scalar kind unchanged');
};
subtest 'owned copies preserve aliases, Unicode and Boolean isolation' => sub {
    my $shared={value=>['é',JSON::PP::false]};my $subject={value=>[$shared,$shared]};
    my $rules=Selecto::DataRules->parse(contract({op=>'presence.required'}));
    my $r=$rules->evaluate(stage=>'input',subject=>$subject);
    is_deeply($r->{normalized},$subject,'full independent output has identical values');
    isnt(refaddr($r->{normalized}{value}[0]),refaddr($r->{normalized}{value}[1]),'repeated aliases independently copied');
    $r->{normalized}{value}[0]{value}[0]='changed';
    ${$r->{normalized}{value}[0]{value}[1]}=1;
    is($shared->{value}[0],'é','result mutation cannot change caller Unicode');
    ok(!$shared->{value}[1] && !JSON::PP::false,'result Boolean payload cannot change caller or JSON singleton');
    my $raw=contract({op=>'membership.in',values=>['é']});my $parsed=Selecto::DataRules->parse($raw);
    $raw->{definitions}{one}{test}{values}[0]='changed';
    is($parsed->evaluate(stage=>'input',subject=>{value=>'é'})->{state},'passed','declaration mutation cannot alter compiled registry');
};
{
    package ScalarAdmissionTie;
    our $hooks=0;
    sub TIEHASH {bless {},shift} sub TIEARRAY {bless [],shift} sub TIESCALAR {bless {},shift}
    sub FETCH {++$hooks;undef} sub FETCHSIZE {++$hooks;0} sub FIRSTKEY {++$hooks;undef}
    sub NEXTKEY {++$hooks;undef} sub EXISTS {++$hooks;0}
    package ScalarAdmissionObject;
    use overload '""'=>sub {++$ScalarAdmissionTie::hooks;'x'},bool=>sub {++$ScalarAdmissionTie::hooks;0},fallback=>1;
    sub isa {++$ScalarAdmissionTie::hooks;0}
}
subtest 'plain admission refuses executable and tied shapes before hooks' => sub {
    my ($scalar,%hash,@array);tie $scalar,'ScalarAdmissionTie';tie %hash,'ScalarAdmissionTie';tie @array,'ScalarAdmissionTie';
    for my $work (
        sub {Selecto::DataRules->parse($scalar)},
        sub {Selecto::DataRules->parse(\%hash)},
        sub {Selecto::DataRules->parse(contract({op=>'membership.in',values=>\@array}))},
        sub {Selecto::DataRules->parse(contract({op=>'value.eq',value=>bless({},'ScalarAdmissionObject')}))},
        sub {my $r=contract({op=>'presence.required'});tie $r->{definitions},'ScalarAdmissionTie';Selecto::DataRules->parse($r)},
        sub {my $r=contract({op=>'membership.in',values=>['x']});tie $r->{definitions}{one}{test}{values}[0],'ScalarAdmissionTie';Selecto::DataRules->parse($r)},
    ) {
        $ScalarAdmissionTie::hooks=0;
        is(error($work),'invalid_data_rules_contract','typed plain-shape refusal');
        is($ScalarAdmissionTie::hooks,0,'no callback/overload/tie hook');
    }
};
subtest 'cycles, breadth, depth, bytes and actual shared rule work remain bounded' => sub {
    my $cycle=[];push @$cycle,$cycle;
    is(error(sub {Selecto::DataRules->parse(contract({op=>'value.eq',value=>$cycle}))}),'invalid_data_rules_contract','cycle refused');
    for my $case (
        [max_expression_nodes=>35,{op=>'value.eq',value=>[('x')x100]}],
        [max_expression_depth=>4,{op=>'value.eq',value=>[[[['x']]]]}],
        [max_state_bytes=>80,{op=>'value.eq',value=>'x'x100}],
        [max_rule_numeric_digits=>3,{op=>'number.gt',bound=>'1000'}],
    ) {
        my ($key,$limit,$test)=@$case;
        is(error(sub {Selecto::DataRules->parse(contract($test),limits=>Selecto::Limits->new($key=>$limit))}),
            'invalid_data_rules_contract',"$key retained");
    }
    my $alias=['x'];my $tree=[($alias)x100];
    is(error(sub {Selecto::DataRules->parse(contract({op=>'value.eq',value=>$tree}),limits=>Selecto::Limits->new(max_expression_nodes=>100))}),
        'invalid_data_rules_contract','each alias occurrence counts');
    my $rules=Selecto::DataRules->parse(contract({op=>'presence.required'},enforcement=>'advisory',condition=>{op=>'presence.absent'}));
    my $r=$rules->evaluate(stage=>'input',subject=>{value=>'x'x100},limits=>Selecto::Limits->new(max_state_bytes=>20));
    is_deeply($r,{state=>'error',code=>'evaluation_limit',normalized=>{}},'oversize false advisory branch returns no copied subject');
    is(error(sub {Selecto::DataRules->_with_proof_budget(sub {
        $rules->evaluate(stage=>'input',subject=>{value=>'abcdefgh'});
        Selecto::Write::FieldValidators->validate_values({value=>{validators=>[['length',[['min',1]]]]}}, {value=>'abcdefgh'});
    },limits=>Selecto::Limits->new(max_rule_work=>20))}),'evaluation_limit','generic and legacy work share one protected counter');
};
subtest 'literal opening bracket follows the bounded highest grammar' => sub {
    my $test={op=>'text.pattern',profile=>'ascii_v1',pattern=>'[[]',match=>'full',flags=>[]};
    is(evaluate($test,'[')->{state},'passed','literal opening bracket matches');
    is(evaluate($test,']')->{state},'failed','other bracket does not match');
    is(evaluate($test,'[[')->{state},'failed','full match retains length');
    for my $pattern ('[[:alpha:]]','[a&&b]','[[','[z-a]') {
        is(error(sub {Selecto::DataRules->parse(contract({%$test,pattern=>$pattern}))}),
            'invalid_text_pattern','unsupported or malformed class refuses');
    }
    is(error(sub {Selecto::DataRules->parse(contract($test),limits=>Selecto::Limits->new(max_regex_states=>1))}),
        'invalid_text_pattern','compiled-state limit retained');
};

sub policy_document {
    return {name=>'Policy authoring',source=>{source_table=>'items',primary_key=>'id',fields=>[qw(id name)],
        columns=>{id=>{type=>'integer'},name=>{type=>'string'}},associations=>{}},schemas=>{},joins=>{},
        writes=>{operations=>{update=>{enabled=>JSON::PP::true,require_filter=>JSON::PP::true}},
            fields=>{name=>{updatable=>JSON::PP::true}}},
        actions=>{set_name=>{type=>'action',scope=>'row',inputs=>{name=>{type=>'string',required=>JSON::PP::true}},
            execution=>{kind=>'updato',operation=>'update',set=>{name=>['input','name']}}}}};
}
sub name_rules {
    my ($test,$action)=@_;my $raw=contract($test);
    $raw->{bindings}{one}{subject}={scope=>$action?'action_input':'input',path=>['name'],
        $action?(action=>'set_name'):()};return $raw;
}
subtest 'compose and DSL preserve policy types before reparsing' => sub {
    my $uv=JSON::PP->new->decode('18446744073709551615');my $base=policy_document();
    $base->{rules}=name_rules({op=>'membership.in',values=>[$uv]});
    my $configured=Selecto::Domain->parse($base);
    my $composed=Selecto::Domain->compose($configured,{source=>{columns=>{name=>{label=>'Name'}}}});
    is($composed->contract->{source}{columns}{name}{label},'Name','unrelated source overlay keeps ordinary merging');
    is($composed->rules->evaluate(stage=>'input',subject=>{name=>'18446744073709551615'})->{state},'failed',
        'harmless overlay cannot turn numeric membership into text membership');
    is(wire($composed->contract->{rules}{definitions}{one}{test}{values}[0]),'18446744073709551615','base policy remains native unsigned');
    my $invalid=name_rules({op=>'number.gt',bound=>JSON::PP->new->decode('1.0')});
    is(error(sub {Selecto::Domain->compose(Selecto::Domain->parse(policy_document()),{rules=>$invalid})}),
        'invalid_data_rules_contract','overlay-added floating declaration refuses');
    my $dsl=Selecto::Domain::DSL->new->section('rules',$invalid)->build;
    ok((flags($dsl->{rules}{definitions}{one}{test}{bound})&B::SVf_NOK())
        && !(flags($dsl->{rules}{definitions}{one}{test}{bound})&B::SVf_IOK()),'DSL preserves native floating declaration');
    is(error(sub {Selecto::Domain->compose(Selecto::Domain->parse(policy_document()),$dsl)}),
        'invalid_data_rules_contract','DSL cannot legalize floating declaration');
    $dsl=Selecto::Domain::DSL->new->section('rules',name_rules({op=>'membership.in',values=>[$uv]}))->build;
    $composed=Selecto::Domain->compose(Selecto::Domain->parse(policy_document()),$dsl);
    is($composed->rules->evaluate(stage=>'input',subject=>{name=>'18446744073709551615'})->{state},'failed','DSL unsigned member stays numeric');
    my $legacy=policy_document();
    $legacy->{writes}{fields}{name}{validators}=[['number',[['greater_than',JSON::PP->new->decode('1.0')]]]];
    $composed=Selecto::Domain->compose(Selecto::Domain->parse($legacy),{writes=>{fields=>{name=>{immutable=>JSON::PP::false}}}});
    is(error(sub {Selecto::Write::FieldValidators->validate_values($composed->writes->{fields},{name=>'2'})}),
        'unsupported_write_rule','deep write-policy merge does not legalize legacy floating bound');
    $dsl=Selecto::Domain::DSL->new->write_field(name=>{updatable=>JSON::PP::true,
        validators=>[['number',[['greater_than',JSON::PP->new->decode('1.0')]]]]})->build;
    $composed=Selecto::Domain->compose(Selecto::Domain->parse(policy_document()),$dsl);
    is(error(sub {Selecto::Write::FieldValidators->validate_values($composed->writes->{fields},{name=>'2'})}),
        'unsupported_write_rule','write_field DSL retains unsupported bound');
    $legacy->{writes}{fields}{name}{validators}=[['number',[['greater_than','1.0']]]];
    $composed=Selecto::Domain->compose(Selecto::Domain->parse($legacy),{writes=>{fields=>{name=>{immutable=>JSON::PP::false}}}});
    ok(!error(sub {Selecto::Write::FieldValidators->validate_values($composed->writes->{fields},{name=>'2'})}),
        'authored decimal text remains an allowed bound after composition');
};
subtest 'raw and configured action paths preserve rules and submitted values' => sub {
    my $raw=policy_document();$raw->{rules}=name_rules({op=>'number.gt',bound=>JSON::PP->new->decode('1.0')},1);
    is(error(sub {Selecto::Action->plan($raw,{action=>'set_name',target=>1,inputs=>{name=>'2'}})}),
        'invalid_data_rules_contract','raw action cannot legalize invalid canonical bound');
    my $uv=JSON::PP->new->decode('18446744073709551615');
    $raw=policy_document();$raw->{rules}=name_rules({op=>'membership.in',values=>[$uv]},1);
    is(error(sub {Selecto::Action->plan($raw,{action=>'set_name',target=>1,inputs=>{name=>'18446744073709551615'}})}),
        'data_rule_failed','raw action cannot turn unsigned policy member into text');
    $raw=policy_document();$raw->{writes}{fields}{name}{validators}=[['number',[['greater_than',0]]]];
    my $domain=Selecto::Domain->parse($raw);my $nv=JSON::PP->new->decode('1.0');
    my $plan=Selecto::Action->plan($domain,{action=>'set_name',target=>1,inputs=>{name=>$nv}});
    ok((flags($plan->changes->{name})&B::SVf_NOK()) && !(flags($plan->changes->{name})&B::SVf_IOK()),'planning digest leaves NV-only assignment unchanged');
    is(error(sub {Selecto::Write::FieldValidators->validate_values($domain->writes->{fields},$plan->changes)}),
        'data_rule_failed','planned assignment retains strict legacy numeric subject refusal');
    my $copy=$plan->to_hash;
    is(pack('F',$copy->{changes}{name}),pack('F',$nv),'plan serialization preserves floating bits');
    $copy->{changes}{name}='changed';ok(!defined(reftype($plan->changes->{name})),'plan copy does not replace original scalar');
    $raw=policy_document();$raw->{source}{columns}{name}{type}='json';$raw->{actions}{set_name}{inputs}{name}{type}='json';
    $raw->{rules}=name_rules({op=>'membership.in',values=>[{n=>$uv}]},1);
    $plan=Selecto::Action->plan(Selecto::Domain->parse($raw),{action=>'set_name',target=>1,inputs=>{name=>{n=>$uv}}});
    is(wire($plan->changes->{name}{n}),'18446744073709551615','ACTION_INPUT JSON subtree preserves unsigned numeric member');
    is(wire($plan->to_hash->{inputs}{name}{n}),'18446744073709551615','plan public input copy preserves unsigned member');
};
subtest 'declared action literals and defaults preserve delivered numeric types' => sub {
    for my $source (qw(literal default)) {
        for my $spelling ('1.0','18446744073709551615') {
            my $value=JSON::PP->new->decode($spelling);my $raw=policy_document();
            if ($source eq 'literal') { $raw->{actions}{set_name}{execution}{set}{name}=$value;delete $raw->{actions}{set_name}{inputs} }
            else { $raw->{actions}{set_name}{inputs}{name}{default}=$value;$raw->{actions}{set_name}{inputs}{name}{required}=JSON::PP::false }
            my $domain=Selecto::Domain->parse($raw);
            my $composed=Selecto::Domain->compose($domain,{actions=>{set_name=>{label=>'Renamed'}}});
            my $dsl=Selecto::Domain::DSL->new->action('set_name',$raw->{actions}{set_name})->build;
            my $dsl_domain=Selecto::Domain->compose(Selecto::Domain->parse(policy_document()),$dsl);
            for my $variant ($composed,$dsl_domain) {
                my $action=$variant->actions->{set_name};
                my $scalar=$source eq 'literal'?$action->{execution}{set}{name}:$action->{inputs}{name}{default};
                if ($spelling eq '1.0') {
                    ok((flags($scalar)&B::SVf_NOK()) && !(flags($scalar)&B::SVf_IOK()),"composed/DSL $source action retains float");
                } else { is(wire($scalar),$spelling,"composed/DSL $source action retains unsigned integer") }
            }
            my $declared=$domain->actions->{set_name};
            my $copy=$source eq 'literal'?$declared->{execution}{set}{name}:$declared->{inputs}{name}{default};
            if ($spelling eq '1.0') {
                ok((flags($copy)&B::SVf_NOK()) && !(flags($copy)&B::SVf_IOK()),"$source action accessor retains native float");
            } else { is(wire($copy),$spelling,"$source action accessor retains unsigned native integer") }
            my $plan=Selecto::Action->plan($domain,{action=>'set_name',target=>1});
            $copy=$plan->changes->{name};
            if ($spelling eq '1.0') {
                ok((flags($copy)&B::SVf_NOK()) && !(flags($copy)&B::SVf_IOK()),"$source action plan retains native float");
            } else { is(wire($copy),$spelling,"$source action plan retains unsigned native integer") }
        }
    }
    my $raw=policy_document();
    $raw->{actions}{set_name}{preconditions}=[['name',JSON::PP->new->decode('1.0')]];
    $raw->{actions}{set_name}{capability}='items.set_name';
    $raw->{capabilities}{'items.set_name'}={operations=>['action','update'],action=>'set_name'};
    my $plan=Selecto::Action->plan(Selecto::Domain->parse($raw),{action=>'set_name',target=>1,inputs=>{name=>'after'}});
    my $request=Selecto::Action->capability_request($plan,'preview');
    ok((flags($request->{preconditions}[0]{value})&B::SVf_NOK())
        && !(flags($request->{preconditions}[0]{value})&B::SVf_IOK()),'public capability request preserves declared floating guard');
    my $seen;
    Selecto::Action->authorize($plan,'preview',resolver=>sub {$seen=flags($_[0]{preconditions}[0]{value});'enabled'});
    ok(($seen&B::SVf_NOK()) && !($seen&B::SVf_IOK()),'actual host resolver observes the original numeric guard kind');
    $request->{preconditions}[0]{value}='changed';
    ok((flags($plan->preconditions->[0]{value})&B::SVf_NOK())
        && !(flags($plan->preconditions->[0]{value})&B::SVf_IOK()),'authorization view cannot mutate plan guard identity');
    $raw->{actions}{set_name}{preconditions}=[['name',JSON::PP->new->decode('18446744073709551615')]];
    $plan=Selecto::Action->plan(Selecto::Domain->parse($raw),{action=>'set_name',target=>1,inputs=>{name=>'after'}});
    $request=Selecto::Action->capability_request($plan,'preview');
    is(wire($request->{preconditions}[0]{value}),'18446744073709551615','public capability request preserves unsigned guard');
    is(wire($request->{filters}[1][1]),'18446744073709551615','public capability request preserves unsigned filter');
    $request->{preconditions}[0]{value}='changed';$request->{filters}[1][1]='changed';
    is(wire($plan->preconditions->[0]{value}),'18446744073709551615','capability guard result is detached');
    is(wire($plan->filters->[1][1]),'18446744073709551615','capability filter result is detached');
};
subtest 'action native expression copies remain narrow and bounded' => sub {
    my $nv=JSON::PP->new->decode('1.0');
    my $expression=Selecto::Write::Expression->literal($nv);
    my $plan=Selecto::Action::Plan->new(changes=>{name=>$expression});
    my $copy=$plan->to_hash;
    is(ref($copy->{changes}{name}),'Selecto::Write::Expression','first-party expression class is preserved');
    ok((flags($copy->{changes}{name}->arguments->[0])&B::SVf_NOK())
        && !(flags($copy->{changes}{name}->arguments->[0])&B::SVf_IOK()),'native expression literal keeps floating identity');
    isnt(refaddr($copy->{changes}{name}),refaddr($expression),'expression record is independently owned');
    $ScalarAdmissionTie::hooks=0;
    my $bad=Selecto::Action::Plan->new(changes=>{name=>bless({},'ScalarAdmissionObject')});
    is(error(sub {$bad->to_hash}),'invalid_planned_operation','unknown object is refused before copying');
    is($ScalarAdmissionTie::hooks,0,'unknown object triggers no callbacks');
    my $tied=Selecto::Action::Plan->new(changes=>{});tie $tied->{changes},'ScalarAdmissionTie';
    is(error(sub {$tied->to_hash}),'invalid_planned_operation','tied public payload refuses before getter');
    is($ScalarAdmissionTie::hooks,0,'tied payload triggers no FETCH');
    my $cycle=[];push @$cycle,$cycle;
    is(error(sub {Selecto::Action::Plan->new(changes=>{name=>$cycle})->to_hash}),'invalid_planned_operation','cyclic action payload is bounded');
    $ScalarAdmissionTie::hooks=0;
    my %tied_policy;tie %tied_policy,'ScalarAdmissionTie';
    is(error(sub {Selecto::Domain::DSL->new->section('writes',\%tied_policy)}),'invalid_domain_overlay','DSL tied policy refuses');
    is($ScalarAdmissionTie::hooks,0,'DSL tied policy invokes no callback');
};
done_testing;
