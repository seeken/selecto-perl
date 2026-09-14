use 5.034;
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestSelecto;
use Selecto::MSSQL;

my $domain = Selecto::Domain->new(name => 'Exact decimals', table => 'decimal_fixture',
    fields => { id => 'integer', amount => 'decimal', label => 'string' });
my $engine = Selecto::Engine->new(domain => $domain,
    adapter => Selecto::MSSQL->new(dbh => TestSelecto::DBH->new));
my $x = 'Selecto::Expression';
for my $predicate ($x->eq('amount', '1.23451'), $x->gt('amount', '1.23449'),
        $x->in('amount', '1.23451', '1.23449')) {
    my $statement = $engine->compile($engine->query->select('id')->where($predicate));
    like($statement->sql, qr/CAST\(\? AS DECIMAL\(38,5\)\)/, 'parameter owns exact scale');
    unlike($statement->sql, qr/1\.234/, 'decimal remains separately bound');
}
my $text = $engine->compile($engine->query->select('id')->where($x->eq('label', '1.23451')));
unlike($text->sql, qr/DECIMAL/, 'numeric-looking text retains string comparison');
my $large = '9999999999999999999999999999999999.0001';
my $exact = $engine->compile($engine->query->select('id')->where($x->eq('amount', $large)));
is_deeply($exact->params, [$large], 'maximum-precision decimal remains exact text');
eval { $engine->compile($engine->query->select('id')->where($x->eq('amount', '9' x 39))) };
is($@->code, 'unsupported_precision', 'excess precision fails before execution');
done_testing;
