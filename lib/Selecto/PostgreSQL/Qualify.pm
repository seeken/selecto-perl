package Selecto::PostgreSQL::Qualify;

use 5.034;
use strict;
use warnings;
use Selecto::Error ();

# R46 FINAL-2 / R47. PostgreSQL resolves an unqualified operator or function
# by argument types across the whole search_path and prefers an exact type
# match over a coercion whatever the schema order: a user
# public.=(varchar, varchar) beats pg_catalog's text = text for a varchar
# column, and public.lower(varchar) beats pg_catalog.lower(text). Every
# statement the PostgreSQL adapter executes passes through qualify(), the one
# emitter that writes the generated SQL so nothing resolves through the
# session:
#   - every binary and prefix operator becomes OPERATOR(pg_catalog.op) (or
#     OPERATOR(<schema>.op) when an operand is a column of an extension
#     member type, so citext and the like keep their own semantics), with
#     both operands parenthesized as PostgreSQL's precedence groups them:
#     OPERATOR() syntax binds like a user operator, so the grouping is made
#     explicit rather than left to it;
#   - every call of a pg_catalog function is written pg_catalog.name(...).
# The adapter never emits the constructs whose operator PostgreSQL looks up
# implicitly (an IN list, BETWEEN, IS [NOT] DISTINCT FROM, LIKE, NULLIF, a
# simple CASE): its emitters write those with explicit operators. lint()
# reports SQL that still holds any of them, a bare operator, or an
# unqualified pg_catalog function call.

my %KEYWORD = map { ($_ => 1) } qw(
    AND OR NOT IN IS EXISTS ANY ALL SOME ARRAY ROW VALUES CAST EXTRACT TRIM SUBSTRING POSITION
    OVERLAY COALESCE GREATEST LEAST CASE WHEN THEN ELSE END OVER FILTER WITHIN SELECT FROM WHERE JOIN ON USING AS
    INTO UPDATE SET DELETE INSERT RETURNING WITH RECURSIVE LATERAL UNION INTERSECT EXCEPT ORDER BY GROUP HAVING
    LIMIT OFFSET DISTINCT CONFLICT DO NOTHING ROWS RANGE GROUPS PARTITION GROUPING SETS ROLLUP CUBE FOR
    SHARE NOWAIT SKIP LOCKED ONLY TABLE NATURAL LEFT RIGHT INNER OUTER FULL CROSS INTERVAL
    ZONE AT COLLATE VARIADIC ORDINALITY DESC ASC NULLS FIRST LAST FETCH NEXT OPERATOR ESCAPE BETWEEN LIKE
    ILIKE SIMILAR NULLIF UNBOUNDED PRECEDING FOLLOWING EXCLUDE TIES OTHERS MATERIALIZED NO KEY
    CHARACTER VARYING DOUBLE PRECISION WITHOUT DECLARE CURSOR SCROLL HOLD SAVEPOINT RELEASE ROLLBACK BEGIN
    COMMIT LOCK MODE EXCLUSIVE SYMMETRIC ASYMMETRIC LEADING TRAILING BOTH PLACING NORMALIZE DEFAULT
);
my %CONSTANT = map { ($_ => 1) } qw(TRUE FALSE NULL CURRENT_DATE CURRENT_TIMESTAMP CURRENT_TIME LOCALTIMESTAMP
    LOCALTIME CURRENT_USER SESSION_USER CURRENT_ROLE);
# Keywords that introduce a typed literal: INTERVAL '1 day'.
my %TYPED_LITERAL = map { ($_ => 1) } qw(INTERVAL DATE TIME TIMESTAMP TIMESTAMPTZ);
my %COMPARISON = map { ($_ => 1) } qw(< > = <= >= <> !=);
my $OPERATOR_CHARS = qr{[+\-*/<>=~!@#%^&|`?]};

sub tokenize {
    my ($sql) = @_;
    my @tokens;
    pos($sql) = 0;
    while (pos($sql) < length $sql) {
        if ($sql =~ /\G(\s+)/gc) { push @tokens, ['ws', $1] }
        elsif ($sql =~ /\G(--[^\n]*|\/\*.*?\*\/)/gcs) { push @tokens, ['ws', $1] }
        elsif ($sql =~ /\G((?:[Ee])?'(?:[^']|'')*')/gc) { push @tokens, ['str', $1] }
        elsif ($sql =~ /\G("(?:[^"]|"")*")/gc) { push @tokens, ['qid', $1] }
        elsif ($sql =~ /\G(\$[0-9]+)/gc) { push @tokens, ['param', $1] }
        # DBD::Pg reads every bare ? as a placeholder.
        elsif ($sql =~ /\G(\?)/gc) { push @tokens, ['param', $1] }
        elsif ($sql =~ /\G(\$([A-Za-z_]*)\$.*?\$\2\$)/gcs) { push @tokens, ['str', $1] }
        elsif ($sql =~ /\G([0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?|\.[0-9]+(?:[eE][+-]?[0-9]+)?)/gc) { push @tokens, ['num', $1] }
        elsif ($sql =~ /\G([A-Za-z_][A-Za-z0-9_\$]*)/gc) { push @tokens, ['id', $1] }
        elsif ($sql =~ /\G(::|=>)/gc) { push @tokens, ['punct', $1] }
        elsif ($sql =~ /\G($OPERATOR_CHARS+)/gc) {
            my $op = $1;
            my $full = length $op;
            # PostgreSQL's lexer: a multi-character operator ends in + or -
            # only if it holds one of ~ ! @ # % ^ & | ` ?.
            while (length($op) > 1 && $op =~ /[+\-]\z/ && $op !~ /[~!@#%^&|`?]/) { chop $op }
            pos($sql) -= $full - length($op);
            push @tokens, ['op', $op];
        }
        elsif ($sql =~ /\G([()\[\],.;:])/gc) { push @tokens, ['punct', $1] }
        else {
            Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL could not be tokenized for operator qualification',
                {reason => 'sql_unqualifiable'});
        }
    }
    my @significant = grep { $_->[0] ne 'ws' } @tokens;
    # Each token keeps its position, so slices still name it.
    $significant[$_][2] = $_ for 0 .. $#significant;
    return \@significant;
}

# ---- Parsing into a light tree --------------------------------------------
#
# The token stream is read into nodes: an expression run is a sequence of
# atoms joined by operators; anything else (keywords, commas, AS aliases)
# passes through unchanged. Each run is regrouped by PostgreSQL precedence and
# re-emitted with OPERATOR() and explicit parentheses.

sub new_state {
    my ($functions, $columns) = @_;
    return {functions => $functions // {}, columns => $columns // {}, problems => []};
}

sub qualify {
    my ($sql, $functions, $columns) = @_;
    my $state = new_state($functions, $columns);
    my $tokens = tokenize($sql);
    # $columns: {relations => {lc "schema.table" => {lc column => {op => schema}}}}
    # (columns of extension member types, or domains over one, by relation).
    $state->{scopes} = _scopes($tokens) if ref($columns) eq 'HASH' && ref($columns->{relations}) eq 'HASH' && %{$columns->{relations}};
    my $pos = 0;
    my $out = _sequence($state, $tokens, \$pos, undef);
    Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL has unbalanced parentheses',
        {reason => 'sql_unqualifiable'}) if $pos < @$tokens;
    return $out;
}

sub _upper { return defined($_[0]) && $_[0][0] eq 'id' ? uc $_[0][1] : '' }

# A sequence of items up to (not including) the closing token $close (')' or
# ']') or the end. Expression runs are qualified; the rest copied.
sub _sequence {
    my ($state, $tokens, $pos, $close) = @_;
    my @parts;
    my @run;
    my $set_list = 0;
    my $flush = sub {
        if (@run) { push @parts, _emit_run($state, \@run); @run = () }
    };
    while ($$pos < @$tokens) {
        my $token = $tokens->[$$pos];
        last if $token->[0] eq 'punct' && defined($close) && $token->[1] eq $close;
        my $up = _upper($token);
        if ($up eq 'SET') { $flush->(); push @parts, $token->[1]; $$pos++; $set_list = 1; next }
        if ($set_list && $up =~ /\A(?:WHERE|RETURNING|FROM)\z/) { $set_list = 0 }
        # An assignment "col = expr" in an UPDATE ... SET list.
        if ($set_list && $token->[0] eq 'op' && $token->[1] eq '=' && @run == 1 && $run[0]{kind} eq 'atom'
            && $run[0]{column} && (!@parts || $parts[-1] eq ',' || uc($parts[-1]) eq 'SET')) {
            $flush->();
            push @parts, '=';
            $$pos++;
            next;
        }
        # SELECT *, COUNT(*): a star with nothing to its left is not an operator.
        if ($token->[0] eq 'op' && $token->[1] eq '*' && (!@run || $run[-1]{kind} eq 'op')) {
            push @run, {kind => 'atom', sql => '*'};
            $$pos++;
            next;
        }
        if ($token->[0] eq 'op' || ($up eq 'OPERATOR' && _peek_punct($tokens, $$pos + 1, '('))) {
            push @run, _operator($tokens, $pos);
            next;
        }
        # IN, BETWEEN, LIKE/ILIKE and IS [NOT] DISTINCT FROM resolve their
        # operator through the session: rewritten with explicit operators.
        if (@run && $run[-1]{kind} eq 'atom' && $token->[0] eq 'id') {
            my $construct = _construct($state, $tokens, $pos, \@run);
            if (defined $construct) { push @run, $construct; next }
        }
        my $atom = _atom($state, $tokens, $pos);
        if (defined $atom) {
            # Two atoms in a row (an alias after an expression): a new run.
            $flush->() if @run && $run[-1]{kind} eq 'atom';
            push @run, $atom;
            next;
        }
        # A boundary: a keyword, comma, or other punctuation.
        $flush->();
        if ($token->[0] eq 'punct' && $token->[1] eq '(') {
            $$pos++;
            my $inner = _sequence($state, $tokens, $pos, ')');
            _expect($tokens, $pos, ')');
            push @parts, "($inner)";
            next;
        }
        if ($token->[0] eq 'punct' && $token->[1] eq '[') {
            $$pos++;
            my $inner = _sequence($state, $tokens, $pos, ']');
            _expect($tokens, $pos, ']');
            push @parts, "[$inner]";
            next;
        }
        if ($token->[0] eq 'punct' && ($token->[1] eq ')' || $token->[1] eq ']')) {
            Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL has unbalanced parentheses',
                {reason => 'sql_unqualifiable'});
        }
        _note_construct($state, $tokens, $$pos);
        push @parts, $token->[1];
        $$pos++;
    }
    $flush->();
    return join ' ', @parts;
}

sub _peek_punct {
    my ($tokens, $at, $text) = @_;
    return $at < @$tokens && $tokens->[$at][0] eq 'punct' && $tokens->[$at][1] eq $text;
}

sub _expect {
    my ($tokens, $pos, $text) = @_;
    Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL has unbalanced parentheses',
        {reason => 'sql_unqualifiable'}) unless _peek_punct($tokens, $$pos, $text);
    $$pos++;
}

# The operand of a construct that follows a run: the run's trailing
# expression above comparison precedence (IN, BETWEEN and LIKE bind tighter
# than comparisons, looser than every other operator). It is removed from
# the run and returned as a rendered tree.
sub _take_operand {
    my ($state, $run) = @_;
    my $j = $#$run;
    $j-- while $j >= 0 && !($run->[$j]{kind} eq 'op' && !$run->[$j]{explicit} && _rank($run->[$j]{op}) == 2
        && $j > 0 && $run->[$j - 1]{kind} eq 'atom');
    my @operand = splice(@$run, $j + 1);
    my $i = 0;
    my $tree = _climb($state, \@operand, \$i, 0);
    return $tree;
}

# One expression run read from the tokens up to a boundary (a keyword that
# is not part of an atom, a comma, a closing bracket), or until $stop.
sub _read_run {
    my ($state, $tokens, $pos, $stop) = @_;
    my @items;
    while ($$pos < @$tokens) {
        my $token = $tokens->[$$pos];
        last if defined($stop) && _upper($token) eq $stop;
        if ($token->[0] eq 'op' && $token->[1] eq '*' && (!@items || $items[-1]{kind} eq 'op')) {
            push @items, {kind => 'atom', sql => '*'};
            $$pos++;
            next;
        }
        if ($token->[0] eq 'op' || (_upper($token) eq 'OPERATOR' && _peek_punct($tokens, $$pos + 1, '('))) {
            push @items, _operator($tokens, $pos);
            next;
        }
        last if @items && $items[-1]{kind} eq 'atom' && $token->[0] ne 'op';
        my $atom = _atom($state, $tokens, $pos);
        last unless defined $atom;
        push @items, $atom;
    }
    Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL could not be parsed for operator qualification',
        {reason => 'sql_unqualifiable'}) unless @items;
    my $i = 0;
    return _climb($state, \@items, \$i, 0);
}

sub _paren { my ($sql) = @_; return "($sql)" }

sub _construct {
    my ($state, $tokens, $pos, $run) = @_;
    my $at = $$pos;
    my $up = _upper($tokens->[$at]);
    my $negate = 0;
    if ($up eq 'NOT' && $at + 1 < @$tokens && _upper($tokens->[$at + 1]) =~ /\A(?:IN|BETWEEN|LIKE|ILIKE)\z/) {
        $negate = 1;
        $at++;
        $up = _upper($tokens->[$at]);
    }
    my $sql;
    if ($up eq 'IN' && _peek_punct($tokens, $at + 1, '(')) {
        my $operand = _take_operand($state, $run);
        my $left = _render($state, $operand);
        my $inner = $at + 2 < @$tokens ? _upper($tokens->[$at + 2]) : '';
        $$pos = $at + 2;
        if ($inner eq 'SELECT' || $inner eq 'WITH' || $inner eq 'VALUES') {
            my $query = _sequence($state, $tokens, $pos, ')');
            _expect($tokens, $pos, ')');
            my $op = _op_sql($state, {kind => 'op', op => $negate ? '<>' : '='}, $operand, undef);
            $sql = "(($left) $op " . ($negate ? 'ALL' : 'ANY') . " ($query))";
        } else {
            my @terms;
            while (1) {
                my $element = _read_run($state, $tokens, $pos, undef);
                my $op = _op_sql($state, {kind => 'op', op => '='}, $operand, $element);
                push @terms, "(($left) $op (" . _render($state, $element) . '))';
                last unless _peek_punct($tokens, $$pos, ',');
                $$pos++;
            }
            _expect($tokens, $pos, ')');
            $sql = '(' . join(' OR ', @terms) . ')';
            $sql = "(NOT $sql)" if $negate;
        }
        return {kind => 'atom', sql => $sql};
    }
    if ($up eq 'BETWEEN') {
        my $operand = _take_operand($state, $run);
        my $left = _render($state, $operand);
        $$pos = $at + 1;
        my $low = _read_run($state, $tokens, $pos, 'AND');
        _expect_word($tokens, $pos, 'AND');
        my $high = _read_run($state, $tokens, $pos, undef);
        my $ge = _op_sql($state, {kind => 'op', op => '>='}, $operand, $low);
        my $le = _op_sql($state, {kind => 'op', op => '<='}, $operand, $high);
        $sql = "(($left) $ge (" . _render($state, $low) . ") AND ($left) $le (" . _render($state, $high) . '))';
        $sql = "(NOT $sql)" if $negate;
        return {kind => 'atom', sql => $sql};
    }
    if ($up eq 'LIKE' || $up eq 'ILIKE') {
        my $operand = _take_operand($state, $run);
        my $left = _render($state, $operand);
        $$pos = $at + 1;
        my $pattern = _render($state, _read_run($state, $tokens, $pos, 'ESCAPE'));
        if (_upper($tokens->[$$pos]) eq 'ESCAPE') {
            $$pos++;
            my $escape = _atom($state, $tokens, $pos);
            Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL could not be parsed for operator qualification',
                {reason => 'sql_unqualifiable'}) unless defined $escape;
            $pattern = "pg_catalog.like_escape($pattern, $escape->{sql})";
        }
        my $op = _op_sql($state, {kind => 'op', op => ($negate ? '!' : '') . ($up eq 'LIKE' ? '~~' : '~~*')}, $operand, undef);
        return {kind => 'atom', sql => "(($left) $op ($pattern))"};
    }
    if ($up eq 'IS' && $at + 1 < @$tokens) {
        my $k = $at + 1;
        my $not = 0;
        if (_upper($tokens->[$k]) eq 'NOT') { $not = 1; $k++ }
        return undef unless _upper($tokens->[$k]) eq 'DISTINCT' && _upper($tokens->[$k + 1]) eq 'FROM';
        my $operand = _take_operand($state, $run);
        my $left = _render($state, $operand);
        $$pos = $k + 2;
        my $right_tree = _read_run($state, $tokens, $pos, undef);
        my $right = _render($state, $right_tree);
        my $op = _op_sql($state, {kind => 'op', op => '='}, $operand, $right_tree);
        $sql = "(COALESCE(($left) $op ($right), FALSE) OR (($left) IS NULL AND ($right) IS NULL))";
        $sql = "(NOT $sql)" unless $not;
        return {kind => 'atom', sql => $sql};
    }
    return undef;
}

# Constructs whose operator PostgreSQL looks up implicitly.
sub _note_construct {
    my ($state, $tokens, $at) = @_;
    my $up = _upper($tokens->[$at]);
    my $prev = $at > 0 ? _upper($tokens->[$at - 1]) : '';
    my $next = $at + 1 < @$tokens ? $tokens->[$at + 1] : undef;
    push @{$state->{problems}}, 'IN list' if $up eq 'IN' && $next && $next->[1] eq '(' && do {
        my $inner = $at + 2 < @$tokens ? _upper($tokens->[$at + 2]) : '';
        $inner ne 'SELECT' && $inner ne 'WITH' && $inner ne 'VALUES';
    };
    push @{$state->{problems}}, 'IN subquery' if $up eq 'IN' && $next && $next->[1] eq '(' && do {
        my $inner = $at + 2 < @$tokens ? _upper($tokens->[$at + 2]) : '';
        $inner eq 'SELECT' || $inner eq 'WITH' || $inner eq 'VALUES';
    };
    push @{$state->{problems}}, 'BETWEEN' if $up eq 'BETWEEN' && $prev !~ /\A(?:ROWS|RANGE|GROUPS)\z/;
    push @{$state->{problems}}, 'IS DISTINCT FROM' if $up eq 'DISTINCT' && _upper($next) eq 'FROM';
    push @{$state->{problems}}, $up if $up =~ /\A(?:LIKE|ILIKE|SIMILAR|NULLIF)\z/;
    push @{$state->{problems}}, 'simple CASE' if $up eq 'CASE' && _upper($next) ne 'WHEN';
}

# An operator item: a bare operator token, or an explicit OPERATOR(schema.op).
sub _operator {
    my ($tokens, $pos) = @_;
    my $token = $tokens->[$$pos];
    if ($token->[0] eq 'op') {
        $$pos++;
        return {kind => 'op', op => $token->[1]};
    }
    my $start = $$pos;
    $$pos += 2;
    my @text;
    while ($$pos < @$tokens && !_peek_punct($tokens, $$pos, ')')) { push @text, $tokens->[$$pos][1]; $$pos++ }
    _expect($tokens, $pos, ')');
    my $inner = join '', @text;
    my ($schema, $op) = $inner =~ /\A(.+)\.([^.]+)\z/ ? ($1, $2) : ('pg_catalog', $inner);
    return {kind => 'op', op => $op, schema => $schema, explicit => 1};
}

# An atom (literal, parameter, column, function call, parenthesized group,
# CASE ... END, CAST(...), EXISTS(...), ARRAY[...], ANY/ALL(...), typed
# literal) with its postfix (::type, [subscript], AT TIME ZONE x, COLLATE x,
# IS [NOT] NULL/TRUE/FALSE), or undef at a boundary.
sub _atom {
    my ($state, $tokens, $pos) = @_;
    my $token = $tokens->[$$pos];
    my ($type, $text) = @$token;
    my $up = _upper($token);
    my ($sql, $column);
    if ($type eq 'num' || $type eq 'str' || $type eq 'param') {
        $sql = $text; $$pos++;
    } elsif ($type eq 'id' && $CONSTANT{$up} && !_peek_punct($tokens, $$pos + 1, '(')) {
        $sql = $text; $$pos++;
    } elsif ($type eq 'id' && $TYPED_LITERAL{$up} && $$pos + 1 < @$tokens && $tokens->[$$pos + 1][0] eq 'str') {
        $sql = "$text $tokens->[$$pos + 1][1]"; $$pos += 2;
    } elsif ($type eq 'op' && $text eq '*') {
        return undef;
    } elsif ($type eq 'id' && $up eq 'CASE') {
        $$pos++;
        if (_upper($tokens->[$$pos]) ne 'WHEN') {
            # A simple CASE x WHEN v ...: searched, with explicit operators.
            my $subject = _read_run($state, $tokens, $pos, 'WHEN');
            my $left = _render($state, $subject);
            my @parts;
            while (_upper($tokens->[$$pos]) eq 'WHEN') {
                $$pos++;
                my $value = _read_run($state, $tokens, $pos, 'THEN');
                _expect_word($tokens, $pos, 'THEN');
                my $result = _read_run($state, $tokens, $pos, undef);
                my $op = _op_sql($state, {kind => 'op', op => '='}, $subject, $value);
                push @parts, "WHEN ($left) $op (" . _render($state, $value) . ') THEN ' . _render($state, $result);
            }
            if (_upper($tokens->[$$pos]) eq 'ELSE') {
                $$pos++;
                push @parts, 'ELSE ' . _render($state, _read_run($state, $tokens, $pos, undef));
            }
            _expect_word($tokens, $pos, 'END');
            $sql = 'CASE ' . join(' ', @parts) . ' END';
        } else {
            my $inner = _sequence_until_end($state, $tokens, $pos);
            $sql = "CASE $inner END";
        }
    } elsif ($type eq 'id' && $up =~ /\A(?:CAST|EXISTS|ARRAY|ANY|ALL|SOME|EXTRACT|COALESCE|GREATEST|LEAST|ROW|TRIM|SUBSTRING|POSITION|OVERLAY|NULLIF)\z/
        && ($$pos + 1 < @$tokens) && ($tokens->[$$pos + 1][1] eq '(' || ($up eq 'ARRAY' && $tokens->[$$pos + 1][1] eq '['))) {
        if ($up eq 'NULLIF') {
            # NULLIF(a, b) resolves = through the session: CASE with an
            # explicit operator instead.
            $$pos += 2;
            my $a = _read_run($state, $tokens, $pos, undef);
            _expect($tokens, $pos, ',');
            my $b = _read_run($state, $tokens, $pos, undef);
            _expect($tokens, $pos, ')');
            my $left = _render($state, $a);
            my $op = _op_sql($state, {kind => 'op', op => '='}, $a, $b);
            return _postfix($state, $tokens, $pos,
                "(CASE WHEN ($left) $op (" . _render($state, $b) . ") THEN NULL ELSE ($left) END)", undef);
        }
        my $open = $tokens->[$$pos + 1][1];
        my $close = $open eq '(' ? ')' : ']';
        $$pos += 2;
        my $inner = _sequence($state, $tokens, $pos, $close);
        _expect($tokens, $pos, $close);
        $sql = "$text$open$inner$close";
    } elsif ($type eq 'punct' && $text eq '(') {
        $$pos++;
        my $inner = _sequence($state, $tokens, $pos, ')');
        _expect($tokens, $pos, ')');
        $sql = "($inner)";
    } elsif ($type eq 'id' && !$KEYWORD{$up} || $type eq 'qid') {
        # A name chain: a.b.c, possibly a function call.
        my $start = $token->[2];
        my @names = ($text);
        my @kinds = ($type);
        $$pos++;
        while (_peek_punct($tokens, $$pos, '.') && $$pos + 1 < @$tokens
            && ($tokens->[$$pos + 1][0] =~ /\A(?:id|qid)\z/ || ($tokens->[$$pos + 1][0] eq 'op' && $tokens->[$$pos + 1][1] eq '*'))) {
            push @names, $tokens->[$$pos + 1][1];
            push @kinds, $tokens->[$$pos + 1][0];
            $$pos += 2;
        }
        if (_peek_punct($tokens, $$pos, '(')) {
            $$pos++;
            my $inner = _sequence($state, $tokens, $pos, ')');
            _expect($tokens, $pos, ')');
            my $name = join '.', @names;
            if (@names == 1 && $kinds[0] eq 'id' && $state->{functions}{lc $names[0]}) {
                $name = "pg_catalog.$names[0]";
            }
            $sql = "$name($inner)";
            # FILTER (WHERE ...) / OVER (...) / WITHIN GROUP (...) follow.
            while ($$pos < @$tokens && _upper($tokens->[$$pos]) =~ /\A(?:FILTER|OVER|WITHIN)\z/) {
                my $word = $tokens->[$$pos][1];
                $$pos++;
                if (_upper($tokens->[$$pos]) eq 'GROUP') { $word .= ' ' . $tokens->[$$pos][1]; $$pos++ }
                if (_peek_punct($tokens, $$pos, '(')) {
                    $$pos++;
                    my $clause = _sequence($state, $tokens, $pos, ')');
                    _expect($tokens, $pos, ')');
                    $sql .= " $word ($clause)";
                } else {
                    $sql .= " $word " . $tokens->[$$pos][1];
                    $$pos++;
                }
            }
        } else {
            $sql = join '.', @names;
            $column = {names => [map { _unquote($_) } @names], at => $start};
        }
    } else {
        return undef;
    }
    return _postfix($state, $tokens, $pos, $sql, $column);
}

sub _postfix {
    my ($state, $tokens, $pos, $sql, $column) = @_;
    while ($$pos < @$tokens) {
        my $t = $tokens->[$$pos];
        if ($t->[0] eq 'punct' && $t->[1] eq '::') {
            $$pos++;
            my @type = ($tokens->[$$pos][1]);
            $$pos++;
            while (_peek_punct($tokens, $$pos, '.')) { push @type, $tokens->[$$pos + 1][1]; $$pos += 2 }
            my $cast = join '.', @type;
            if (_peek_punct($tokens, $$pos, '(')) {
                $$pos++;
                my @args;
                while (!_peek_punct($tokens, $$pos, ')')) { push @args, $tokens->[$$pos][1]; $$pos++ }
                $$pos++;
                $cast .= '(' . join('', @args) . ')';
            }
            while (_peek_punct($tokens, $$pos, '[') && _peek_punct($tokens, $$pos + 1, ']')) { $cast .= '[]'; $$pos += 2 }
            $sql .= "::$cast";
            $column = undef;
        } elsif ($t->[0] eq 'punct' && $t->[1] eq '[') {
            $$pos++;
            my $inner = _sequence($state, $tokens, $pos, ']');
            _expect($tokens, $pos, ']');
            $sql .= "[$inner]";
            $column = undef;
        } elsif (_upper($t) eq 'AT' && _upper($tokens->[$$pos + 1]) eq 'TIME' && _upper($tokens->[$$pos + 2]) eq 'ZONE') {
            $$pos += 3;
            my $zone = _atom($state, $tokens, $pos);
            Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL could not be parsed for operator qualification',
                {reason => 'sql_unqualifiable'}) unless defined $zone;
            $sql = "($sql AT TIME ZONE $zone->{sql})";
            $column = undef;
        } elsif (_upper($t) eq 'COLLATE') {
            $$pos++;
            my @name = ($tokens->[$$pos][1]);
            $$pos++;
            while (_peek_punct($tokens, $$pos, '.')) { push @name, $tokens->[$$pos + 1][1]; $$pos += 2 }
            $sql = "($sql COLLATE " . join('.', @name) . ')';
            $column = undef;
        } else {
            last;
        }
    }
    return {kind => 'atom', sql => $sql, column => $column};
}

# CASE ... END: WHEN/THEN/ELSE are boundaries inside.
sub _sequence_until_end {
    my ($state, $tokens, $pos) = @_;
    my @parts;
    while ($$pos < @$tokens && _upper($tokens->[$$pos]) ne 'END') {
        my $token = $tokens->[$$pos];
        if (_upper($token) =~ /\A(?:WHEN|THEN|ELSE)\z/) { push @parts, $token->[1]; $$pos++; next }
        # One expression up to the next WHEN/THEN/ELSE/END.
        my @chunk;
        my $depth = 0;
        my $start = $$pos;
        while ($$pos < @$tokens) {
            my $t = $tokens->[$$pos];
            last if !$depth && _upper($t) =~ /\A(?:WHEN|THEN|ELSE|END)\z/;
            $depth++ if $t->[0] eq 'punct' && ($t->[1] eq '(' || $t->[1] eq '[');
            $depth-- if $t->[0] eq 'punct' && ($t->[1] eq ')' || $t->[1] eq ']');
            if (!$depth && _upper($t) eq 'CASE') {
                # A nested CASE: skip to its END.
                my $nest = 1;
                $$pos++;
                while ($$pos < @$tokens && $nest) {
                    my $u = _upper($tokens->[$$pos]);
                    $nest++ if $u eq 'CASE';
                    $nest-- if $u eq 'END';
                    $$pos++;
                }
                next;
            }
            $$pos++;
        }
        my @slice = @{$tokens}[$start .. $$pos - 1];
        my $p = 0;
        push @parts, _sequence($state, \@slice, \$p, undef);
    }
    _expect_word($tokens, $pos, 'END');
    return join ' ', @parts;
}

sub _expect_word {
    my ($tokens, $pos, $word) = @_;
    Selecto::Error->throw('query_rule_not_evaluable', 'generated SQL could not be parsed for operator qualification',
        {reason => 'sql_unqualifiable'}) unless $$pos < @$tokens && _upper($tokens->[$$pos]) eq $word;
    $$pos++;
}

# Precedence: PostgreSQL's, highest first: ^; * / %; + -; any other
# operator; comparison. Prefix + and - bind tightest.
sub _rank {
    my ($op) = @_;
    return 6 if $op eq '^';
    return 5 if $op eq '*' || $op eq '/' || $op eq '%';
    return 4 if $op eq '+' || $op eq '-';
    return 2 if $COMPARISON{$op};
    return 3;
}

sub _emit_run {
    my ($state, $run) = @_;
    my @items = @$run;
    my $i = 0;
    my $tree = _climb($state, \@items, \$i, 0);
    my @rest = map { $_->{kind} eq 'atom' ? $_->{sql} : _op_sql($state, $_, undef, undef) } @items[$i .. $#items];
    return join ' ', _render($state, $tree), @rest;
}

sub _primary {
    my ($state, $items, $i) = @_;
    my $item = $items->[$$i];
    return undef unless $item;
    if ($item->{kind} eq 'op') {
        # A prefix operator.
        $$i++;
        my $operand = _climb($state, $items, $i, 7);
        return {prefix => $item, operand => $operand};
    }
    $$i++;
    return {atom => $item};
}

sub _climb {
    my ($state, $items, $i, $min) = @_;
    my $left = _primary($state, $items, $i);
    while ($$i < @$items && $items->[$$i]{kind} eq 'op') {
        my $op = $items->[$$i];
        my $rank = $op->{explicit} ? 3 : _rank($op->{op});
        last if $rank < $min;
        # A trailing operator with no right operand: leave it.
        last unless $$i + 1 < @$items;
        $$i++;
        my $right = _climb($state, $items, $i, $rank + 1);
        $left = {binary => $op, left => $left, right => $right};
    }
    return $left;
}

sub _render {
    my ($state, $node) = @_;
    return '' unless $node;
    return $node->{atom}{sql} if $node->{atom};
    if ($node->{prefix}) {
        my $operand = _render($state, $node->{operand});
        return '(' . _op_sql($state, $node->{prefix}, $node->{operand}, undef) . " ($operand))";
    }
    my $left = _render($state, $node->{left});
    my $right = _render($state, $node->{right});
    # x op ANY/ALL/SOME (array or subquery): the quantifier belongs to the
    # operator's syntax and takes no parentheses of its own.
    my $quantified = $node->{right} && $node->{right}{atom} && $node->{right}{atom}{sql} =~ /\A(?:ANY|ALL|SOME)\(/i;
    return "(($left) " . _op_sql($state, $node->{binary}, $node->{left}, $node->{right}) . ($quantified ? " $right)" : " ($right))");
}

# OPERATOR(schema.op). PostgreSQL's own resolution picks an extension
# type's operator (citext = citext) only when both operands have that type,
# or one has it and the other is an untyped parameter or literal (which takes
# its type); a citext against text resolves to pg_catalog's text operator
# (R48). The same choice is made here, whatever the operand order.
sub _op_sql {
    my ($state, $op, $left, $right) = @_;
    return "OPERATOR($op->{schema}.$op->{op})" if $op->{explicit};
    my @sides = map { _operand_class($state, $_, $op->{op}) } $left, $right;
    my ($l, $r) = @sides;
    my $schema = 'pg_catalog';
    if ($l->{schema} && $r->{schema} && $l->{schema} eq $r->{schema}) { $schema = $l->{schema} }
    elsif ($l->{schema} && $r->{untyped}) { $schema = $l->{schema} }
    elsif ($r->{schema} && $l->{untyped}) { $schema = $r->{schema} }
    return "OPERATOR($schema.$op->{op})";
}

# An operand: {schema => <the extension schema of its type's operator op>}
# for a column of an extension member type, {untyped => 1} for a bare
# parameter or string literal (or a missing operand of a prefix operator),
# else {} (a known non-extension type, or an expression).
sub _operand_class {
    my ($state, $side, $op) = @_;
    return {untyped => 1} unless $side;
    return {} unless $side->{atom};
    my $atom = $side->{atom};
    return {untyped => 1} if !defined($atom->{column}) && $atom->{sql} =~ /\A(?:\$\d+|\?|'(?:[^']|'')*')\z/;
    return {} unless ref($atom->{column}) eq 'HASH' && $state->{scopes};
    my $entry = _resolve_column($state, $atom->{column}{at}, $atom->{column}{names});
    return ref($entry) eq 'HASH' && defined($entry->{$op}) ? {schema => $entry->{$op}} : {};
}

# ---- Column sources by query scope (R48 / review M1) ----------------------
#
# A column reference resolves through the scope it appears in: its alias
# names a relation, a CTE or a derived table (a subquery, a LATERAL join, a
# member) of that scope or an enclosing one. A CTE's or derived table's
# output passes its source column's type on when its select item is that
# column, so citext keeps its operators through member CTEs and laterals,
# and a reused alias ("s0" in a CTE body and in the outer query) resolves to
# its own scope's relation.

sub _scopes {
    my ($tokens) = @_;
    my (@scope_of, @depth_of, %opens, %closes, @scopes, %cte);
    @scopes = ({parent => undef, aliases => {}, items => [], depth => 0, select => undef});
    my @stack = ({scope => 0, open => undef});
    for my $i (0 .. $#$tokens) {
        my $t = $tokens->[$i];
        if ($t->[0] eq 'punct' && $t->[1] eq '(') {
            push @stack, {scope => $stack[-1]{scope}, open => $i};
        } elsif ($t->[0] eq 'punct' && $t->[1] eq ')') {
            my $frame = pop @stack;
            $closes{$frame->{open}} = $i if defined $frame->{open};
            @stack = ({scope => 0, open => undef}) unless @stack;
        } elsif (_upper($t) eq 'SELECT') {
            push @scopes, {parent => $stack[-1]{scope}, aliases => {}, items => [], depth => scalar(@stack), select => $i};
            $stack[-1]{scope} = $#scopes;
            $opens{$stack[-1]{open}} //= $#scopes if defined $stack[-1]{open};
        }
        $scope_of[$i] = $stack[-1]{scope};
        $depth_of[$i] = scalar @stack;
    }
    my $state = {tokens => $tokens, scope_of => \@scope_of, depth_of => \@depth_of, opens => \%opens,
        closes => \%closes, scopes => \@scopes, cte => \%cte};
    my $name_at = sub {
        my ($k) = @_;
        my @names;
        return (undef, $k) unless $k < @$tokens && $tokens->[$k][0] =~ /\A(?:id|qid)\z/;
        push @names, _unquote($tokens->[$k][1]);
        $k++;
        while ($k + 1 < @$tokens && $tokens->[$k][1] eq '.' && $tokens->[$k + 1][0] =~ /\A(?:id|qid)\z/) {
            push @names, _unquote($tokens->[$k + 1][1]);
            $k += 2;
        }
        return (\@names, $k);
    };
    my $cols_at = sub {
        my ($k) = @_;
        return (undef, $k) unless $k < @$tokens && $tokens->[$k][1] eq '(';
        my $end = $closes{$k} // return (undef, $k);
        my @cols = map { _unquote($tokens->[$_][1]) } grep { $tokens->[$_][0] =~ /\A(?:id|qid)\z/ } $k + 1 .. $end - 1;
        return (\@cols, $end + 1);
    };
    # CTEs: WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] ( body ), ...
    for my $i (0 .. $#$tokens) {
        next unless _upper($tokens->[$i]) eq 'WITH';
        my $k = $i + 1;
        $k++ if _upper($tokens->[$k]) eq 'RECURSIVE';
        while (1) {
            my ($names, $after) = $name_at->($k);
            last unless $names && @$names == 1;
            my ($cols, $next) = $cols_at->($after);
            $k = $next;
            last unless _upper($tokens->[$k]) eq 'AS';
            $k++;
            $k++ if _upper($tokens->[$k]) eq 'NOT';
            $k++ if _upper($tokens->[$k]) eq 'MATERIALIZED';
            last unless $k < @$tokens && $tokens->[$k][1] eq '(';
            $cte{lc $names->[0]} = {scope => $opens{$k}, cols => $cols};
            $k = ($closes{$k} // last) + 1;
            last unless $k < @$tokens && $tokens->[$k][1] eq ',';
            $k++;
        }
    }
    # Each scope's select items and FROM items.
    my %stop = map { ($_ => 1) } qw(FROM WHERE GROUP ORDER LIMIT OFFSET UNION INTERSECT EXCEPT HAVING WINDOW FOR INTO RETURNING);
    for my $id (1 .. $#scopes) {
        my $scope = $scopes[$id];
        my $depth = $depth_of[$scope->{select}];
        my @item;
        my $k = $scope->{select} + 1;
        $k++ if _upper($tokens->[$k]) eq 'DISTINCT';
        for (; $k < @$tokens; $k++) {
            last if $depth_of[$k] < $depth;
            if ($depth_of[$k] == $depth && $scope_of[$k] == $id) {
                last if $stop{_upper($tokens->[$k])};
                if ($tokens->[$k][1] eq ',') { push @{$scope->{items}}, [@item]; @item = (); next }
            }
            push @item, $k;
        }
        push @{$scope->{items}}, [@item] if @item;
    }
    for my $k (0 .. $#$tokens) {
        my $up = _upper($tokens->[$k]);
        next unless $up eq 'FROM' || $up eq 'JOIN' || $up eq 'UPDATE' || ($up eq 'INTO' && $k > 0 && _upper($tokens->[$k - 1]) eq 'INSERT');
        my $scope = $scope_of[$k];
        my $j = $k + 1;
        while ($j < @$tokens) {
            $j++ while $j < @$tokens && _upper($tokens->[$j]) =~ /\A(?:LATERAL|ONLY)\z/;
            my ($source, $default);
            # A parenthesised join group, FROM (a JOIN b ON ...): its first
            # item is registered here, the others by their own JOIN.
            if ($j < @$tokens && $tokens->[$j][1] eq '(' && !defined $opens{$j}) {
                $j++;
                next;
            }
            if ($j < @$tokens && $tokens->[$j][1] eq '(') {
                my $close = $closes{$j} // last;
                $source = {derived => $opens{$j}};
                $j = $close + 1;
            } else {
                my ($names, $after) = $name_at->($j);
                last unless $names;
                last if $after < @$tokens && $tokens->[$after][1] eq '(' && $up ne 'INTO';
                $default = $names->[-1];
                $source = @$names == 1 && $cte{lc $names->[0]} ? {cte => lc $names->[0]}
                    : {relation => lc(join '.', @$names)};
                $j = $after;
            }
            $j++ if _upper($tokens->[$j]) eq 'AS';
            my $alias = $default;
            if ($j < @$tokens && $tokens->[$j][0] =~ /\A(?:id|qid)\z/ && !($tokens->[$j][0] eq 'id' && _keyword($tokens->[$j][1]))) {
                $alias = _unquote($tokens->[$j][1]);
                $j++;
            }
            my ($cols, $next) = $cols_at->($j);
            if ($cols && ($source->{derived} || $source->{cte})) { $source->{cols} = $cols; $j = $next }
            $scopes[$scope]{aliases}{lc $alias} = $source if defined $alias;
            last unless $up eq 'FROM' && $j < @$tokens && $tokens->[$j][1] eq ',';
            $j++;
        }
    }
    return $state;
}

sub _keyword { my ($word) = @_; return $KEYWORD{uc $word} || $CONSTANT{uc $word} }

# The extension operators ({op => schema}) of the column a reference at token
# $at names, or undef.
sub _resolve_column {
    my ($state, $at, $names, $guard) = @_;
    my $scopes = $state->{scopes} or return undef;
    return undef if ($guard // 0) > 16 || !@$names || @$names > 3;
    my $scope = $scopes->{scope_of}[$at] // 0;
    return _resolve_in($state, $scope, @$names > 1 ? lc $names->[-2] : undef, lc $names->[-1], ($guard // 0) + 1);
}

sub _resolve_in {
    my ($state, $scope, $qualifier, $column, $guard) = @_;
    my $info = $state->{scopes};
    return undef if $guard > 16;
    for (my $s = $scope; defined $s; $s = $info->{scopes}[$s]{parent}) {
        my $aliases = $info->{scopes}[$s]{aliases};
        my $source;
        if (defined $qualifier) {
            $source = $aliases->{$qualifier};
        } elsif (keys(%$aliases) == 1) {
            ($source) = values %$aliases;
        }
        next unless $source;
        return _source_column($state, $source, $column, $guard + 1);
    }
    return undef;
}

sub _source_column {
    my ($state, $source, $column, $guard) = @_;
    my $info = $state->{scopes};
    if (defined $source->{relation}) {
        my $relations = $state->{columns}{relations};
        my $columns = $relations->{$source->{relation}} // return undef;
        return $columns->{$column};
    }
    my ($scope, $cols);
    if (defined $source->{cte}) {
        my $cte = $info->{cte}{$source->{cte}} // return undef;
        ($scope, $cols) = ($cte->{scope}, $source->{cols} // $cte->{cols});
    } else {
        ($scope, $cols) = ($source->{derived}, $source->{cols});
    }
    return undef unless defined $scope;
    my $items = $info->{scopes}[$scope]{items};
    my $tokens = $info->{tokens};
    for my $index (0 .. $#$items) {
        my @t = map { $tokens->[$_] } @{$items->[$index]};
        # A passthrough item: a [b.]c [[AS] name].
        my @chain;
        my $k = 0;
        while ($k < @t && $t[$k][0] =~ /\A(?:id|qid)\z/) {
            push @chain, _unquote($t[$k][1]);
            $k++;
            last unless $k < @t && $t[$k][1] eq '.';
            $k++;
        }
        next unless @chain && @chain <= 3;
        my $name = $chain[-1];
        if ($k < @t) {
            $k++ if _upper($t[$k]) eq 'AS';
            next unless $k == $#t && $t[$k][0] =~ /\A(?:id|qid)\z/;
            $name = _unquote($t[$k][1]);
        }
        my $output = ref($cols) eq 'ARRAY' && $index < @$cols ? $cols->[$index] : $name;
        next unless lc($output) eq $column;
        return _resolve_in($state, $scope, @chain > 1 ? lc $chain[-2] : undef, lc $chain[-1], $guard + 1);
    }
    return undef;
}

sub _unquote {
    my ($text) = @_;
    return $1 =~ s/""/"/gr if $text =~ /\A"((?:[^"]|"")*)"\z/;
    return lc $text;
}

# A construct whose operator PostgreSQL looks up implicitly, at token $k.
sub _implicit_construct {
    my ($tokens, $k) = @_;
    my $up = uc $tokens->[$k][1];
    my $next = $k + 1 < @$tokens ? $tokens->[$k + 1] : ['', ''];
    my $prev = $k > 0 ? uc $tokens->[$k - 1][1] : '';
    return 'IN list or subquery' if $up eq 'IN' && $next->[1] eq '(';
    return 'BETWEEN' if $up eq 'BETWEEN' && $prev !~ /\A(?:ROWS|RANGE|GROUPS)\z/;
    return 'IS DISTINCT FROM' if $up eq 'DISTINCT' && uc($next->[1]) eq 'FROM' && $prev =~ /\A(?:IS|NOT)\z/;
    return $up if $up =~ /\A(?:LIKE|ILIKE|SIMILAR)\z/;
    return 'NULLIF' if $up eq 'NULLIF' && $next->[1] eq '(';
    return 'simple CASE' if $up eq 'CASE' && uc($next->[1]) ne 'WHEN';
    return undef;
}

# What lint finds: run qualify and report every implicitly resolved
# construct, plus any bare operator or unqualified pg_catalog function that
# survived (none should).
sub lint {
    my ($sql, $functions) = @_;
    my $tokens = tokenize($sql);
    my @problems;
    # A second pass over the original SQL for bare operators and functions.
    for my $k (0 .. $#$tokens) {
        my ($type, $text) = @{$tokens->[$k]};
        my $prev = $k > 0 ? $tokens->[$k - 1] : ['', ''];
        if ($type eq 'op') {
            next if $text eq '*' && ($prev->[1] =~ /\A(?:\(|,|\.)\z/ || uc($prev->[1]) =~ /\A(?:SELECT|DISTINCT|RETURNING)\z/);
            next if $prev->[1] eq '.' && $k >= 4 && uc($tokens->[$k - 4][1]) eq 'OPERATOR';
            next if $text eq '=' && $prev->[0] =~ /\A(?:qid|id)\z/ && $k >= 2
                && ($tokens->[$k - 2][1] eq ',' || uc($tokens->[$k - 2][1]) eq 'SET');
            push @problems, "bare operator $text";
        } elsif ($type eq 'id' && _implicit_construct($tokens, $k)) {
            push @problems, _implicit_construct($tokens, $k);
        } elsif ($type eq 'id' && $k + 1 < @$tokens && $tokens->[$k + 1][1] eq '(' && !$KEYWORD{uc $text}
            && $prev->[1] ne '.' && $prev->[1] ne '::' && uc($prev->[1]) ne 'AS' && $functions->{lc $text}) {
            push @problems, "unqualified function $text";
        }
    }
    return @problems;
}

1;
