use 5.034;
use strict;
use warnings;

use Test::More;
use Selecto::CannedPage ();
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::PostgreSQL ();

my $domain = Selecto::Domain->new(
    name => 'Places', table => 'places',
    fields => {id => 'integer', name => 'string', city => 'string'},
);
my $engine = Selecto::Engine->new(
    domain => $domain,
    adapter => Selecto::PostgreSQL->new(dbh => bless({}, 'Test::CannedPageDBH')),
);
my $page = Selecto::CannedPage->new(
    id => 'places', domain => $domain,
    dataset => {query => $engine->query, entity_key => ['id']},
    views => [{id => 'list', kind => 'detail',
        query => $engine->query->select('id', 'name', 'city')}],
    controls => [
        {id => 'name', field => 'name', kind => 'text', ignore_case => 1},
        {id => 'city', field => 'city', kind => 'text'},
        {id => 'names', field => 'name', kind => 'text', multiple => 1},
    ],
);

my $insensitive = $engine->compile(
    $page->plan({filters => {name => 'MiX%_!'}})->{query},
);
like $insensitive->sql, qr/LOWER\([^)]*name[^)]*\) LIKE LOWER\(\$\d+\) ESCAPE '!'/,
    'case-insensitive text control lowers both field and bound prefix';
ok scalar(grep { defined($_) && $_ eq 'MiX!%!_!!%' } @{$insensitive->params}),
    'case-insensitive prefix still escapes LIKE wildcards and binds the value';

my $sensitive = $engine->compile(
    $page->plan({filters => {city => 'New'}})->{query},
);
like $sensitive->sql, qr/\bcity\b[^\n]* LIKE \$\d+ ESCAPE '!'/,
    'ordinary text controls retain case-sensitive prefix matching';
unlike $sensitive->sql, qr/LOWER\([^)]*city[^)]*\)/,
    'ordinary controls do not lowercase the field';

my $several = $engine->compile(
    $page->plan({filters => {names => "ab1, cd2\nab1;ef%\n"}})->{query},
);
is scalar(() = $several->sql =~ /LIKE \$\d+ ESCAPE '!'/g), 3,
    'a multiple text control matches each distinct value';
like $several->sql, qr/ OR /, 'any value may match';
ok grep({ defined($_) && $_ eq 'ef!%%' } @{$several->params}),
    'each value is still a literal prefix';
is_deeply $page->normalize_state({filters => {names => " \n"}})->{filters}{names}, " \n",
    'blank input is kept as entered';
unlike $engine->compile($page->plan({filters => {names => " \n"}})->{query})->sql, qr/LIKE/,
    'blank input does not filter';
ok !eval { $page->plan({filters => {names => join ' ', 1 .. 101}}); 1 },
    'a multiple text control takes at most 100 values';
ok !eval { $page->plan({filters => {city => 'x' x 300}}); 1 },
    'a single text control keeps its short limit';

my $invalid = eval {
    Selecto::CannedPage->new(
        id => 'invalid', domain => $domain,
        dataset => {query => $engine->query, entity_key => ['id']},
        views => [{id => 'list', kind => 'detail', query => $engine->query->select('id')}],
        controls => [{id => 'name', field => 'name', kind => 'text', ignore_case => 'sometimes'}],
    );
    1;
};
ok !$invalid, 'invalid ignore_case values are rejected';

done_testing;
