package Selecto::SQLite::FtsIndex;

use 5.034;
use strict;
use warnings;
use bytes ();
use Scalar::Util qw(blessed);
use Selecto::Error ();

# A supplied external-content index is a declaration, never catalog authority.
# Each compilation proves its ordinary main relation, rowid identity, stored
# text columns and actual FTS5 options on this connected handle.
sub compile {
    my ($class, $adapter, $domain, $expression, $params) = @_;
    my ($fields, $literal, $options) = @{$expression->arguments};
    _fail('invalid_query', 'SQLite external FTS5 requires governed fields')
        unless ref($fields) eq 'ARRAY' && @$fields && @$fields <= 128;
    my @names;
    for my $field (@$fields) {
        my $resolved = $adapter->_governed_dialect_field($domain, $field);
        my $name = $resolved->{field};
        my $metadata = $domain->field_metadata($name);
        _fail('unsupported_feature', 'SQLite external FTS5 requires public stored root text fields')
            unless !$resolved->{association} && _identifier($name)
                && ($resolved->{type} // '') =~ /\A(?:string|text)\z/
                && ref($metadata) eq 'HASH' && !$metadata->{internal}
                && !exists($metadata->{computed});
        push @names, $name;
    }
    _fail('invalid_query', 'SQLite text search requires the simple configuration')
        unless ($options->{configuration} // '') eq 'simple';
    _fail('invalid_query', 'SQLite text search requires a bounded literal string')
        unless blessed($literal) && $literal->isa('Selecto::Expression')
            && $literal->kind eq 'literal' && defined($literal->arguments->[0])
            && !ref($literal->arguments->[0]) && bytes::length($literal->arguments->[0]) <= 4096
            && length($literal->arguments->[0]);

    my $text = $literal->arguments->[0];
    my $mode = $options->{mode} // 'plain';
    my $prefix = $mode eq 'prefix';
    if ($prefix) {
        _fail('invalid_query', 'SQLite prefix search requires normalized word prefixes')
            unless $text =~ /\A[\p{L}\p{N}_]+:\*(?: & [\p{L}\p{N}_]+:\*)*\z/u;
    } elsif ($mode eq 'plain') {
        my @terms = ($text =~ /([\p{L}\p{N}_]+)/gu);
        _fail('invalid_query', 'SQLite plain search requires words') unless @terms;
        $text = join(' AND ', map { _quote_term($_) } @terms);
    } elsif ($mode eq 'phrase') {
        $text = _quote_term($text);
    } elsif ($mode ne 'boolean' && $mode ne 'websearch') {
        _fail('invalid_query', 'SQLite text search mode is unavailable');
    }

    my $index = $adapter->_read_only(sub { _prove($adapter, $domain, \@names) });
    push @$params, $text;
    my $placeholder = $adapter->placeholder(scalar @$params);
    my $query = $prefix
        ? "replace(replace($placeholder, ':*', '*'), ' & ', ' AND ')" : $placeholder;
    my $restriction = '{' . join(' ', @names) . '}:(';
    my $match = "('$restriction' || $query || ')')";
    my $table = $adapter->quote_identifier($index->{table});
    my $hidden = "$table.$table";
    my $owner_key = $adapter->_qualified($adapter->_root_alias, $index->{key});
    my $where = "$hidden MATCH $match AND $table.rowid = $owner_key";
    return "(SELECT BM25($table) FROM main.$table WHERE $where LIMIT 1)"
        if $expression->kind eq 'text_rank';
    return "EXISTS (SELECT 1 FROM main.$table WHERE $where)";
}

sub _prove {
    my ($adapter, $domain, $fields) = @_;
    my $dbh = $adapter->dbh;
    _fail('unsupported_feature', 'SQLite external FTS5 requires a connected native catalog')
        unless blessed($dbh) && UNIVERSAL::isa($dbh, 'DBI::db')
            && ($dbh->{Driver}{Name} // '') eq 'SQLite';
    my $index = $domain->fts5_index;
    my ($root, $table, $key) = ($domain->table, $index->{table}, $index->{key});
    _fail('unsupported_feature', 'SQLite external FTS5 declaration is unavailable')
        unless _identifier($root) && _identifier($table) && _identifier($key)
            && $key eq $domain->primary_key && ($domain->fields->{$key} // '') eq 'integer';
    my $key_metadata = $domain->field_metadata($key);
    _fail('unsupported_feature', 'SQLite external FTS5 requires a public stored integer key')
        unless !$key_metadata->{internal} && !exists($key_metadata->{computed});

    my $temp = _rows($dbh, 'SELECT name FROM temp.sqlite_schema LIMIT 4097');
    _fail('unsupported_feature', 'SQLite FTS5 main identity has a TEMP shadow')
        if grep { _identity($_->[0], $root) || _identity($_->[0], $table) } @$temp;
    my $tables = _rows($dbh, 'PRAGMA main.table_list');
    my @root_tables = grep { $_->[0] eq 'main' && _identity($_->[1], $root) } @$tables;
    my @index_tables = grep { $_->[0] eq 'main' && _identity($_->[1], $table) } @$tables;
    _fail('unsupported_feature', 'SQLite external FTS5 requires an ordinary main rowid relation and native virtual index')
        unless @root_tables == 1 && $root_tables[0][2] eq 'table' && !$root_tables[0][4]
            && @index_tables == 1 && $index_tables[0][2] eq 'virtual';
    my $columns = _rows($dbh, 'PRAGMA main.table_xinfo(' . $adapter->quote_identifier($root) . ')');
    my @keys = grep { $_->[5] > 0 } @$columns;
    _fail('unsupported_feature', 'SQLite external FTS5 key is not a sole INTEGER rowid alias')
        unless @keys == 1 && _identity($keys[0][1], $key) && uc($keys[0][2]) eq 'INTEGER'
            && $keys[0][5] == 1 && !$keys[0][6];
    my $indexes = _rows($dbh, 'PRAGMA main.index_list(' . $adapter->quote_identifier($root) . ')');
    _fail('unsupported_feature', 'SQLite external FTS5 key has a separate primary index')
        if grep { $_->[3] eq 'pk' } @$indexes;
    for my $field (@$fields) {
        my @matches = grep { _identity($_->[1], $field) } @$columns;
        _fail('unsupported_feature', 'SQLite external FTS5 requires native stored text affinity')
            unless @matches == 1 && !$matches[0][6] && _text_affinity($matches[0][2]);
    }
    my $ddl_rows = _rows($dbh,
        q{SELECT sql FROM main.sqlite_schema WHERE CAST(name AS BLOB) = CAST(? AS BLOB) AND CAST(type AS BLOB) = CAST('table' AS BLOB) LIMIT 2},
        $index_tables[0][1]);
    _fail('unsupported_feature', 'SQLite external FTS5 declaration is missing or ambiguous')
        unless @$ddl_rows == 1 && defined($ddl_rows->[0][0])
            && bytes::length($ddl_rows->[0][0]) <= 16384;
    my ($indexed, $options) = _declaration($ddl_rows->[0][0]);
    _fail('unsupported_feature', 'SQLite external FTS5 options do not match the governed content')
        unless _identity($options->{content}, $root) && _identity($options->{content_rowid}, $key)
            && lc($options->{tokenize} // 'unicode61') eq 'unicode61'
            && lc($options->{detail} // 'full') eq 'full';
    for my $field (@$fields) {
        _fail('unsupported_feature', 'SQLite external FTS5 does not index the requested field')
            unless grep { _identity($_, $field) } @$indexed;
    }
    return {table => $table, key => $key};
}

sub prove_root {
    my ($class, $adapter, $domain, $fields) = @_;
    return $adapter->_read_only(sub {
        my $dbh = $adapter->dbh;
        my $root = $domain->table;
        _fail('unsupported_feature', 'SQLite root FTS5 requires a connected native catalog')
            unless blessed($dbh) && UNIVERSAL::isa($dbh, 'DBI::db')
                && ($dbh->{Driver}{Name} // '') eq 'SQLite' && _identifier($root);
        my $temp = _rows($dbh, 'SELECT name FROM temp.sqlite_schema LIMIT 4097');
        _fail('unsupported_feature', 'SQLite root FTS5 has a TEMP shadow')
            if grep { _identity($_->[0], $root) } @$temp;
        my $tables = _rows($dbh, 'PRAGMA main.table_list');
        my @matches = grep { $_->[0] eq 'main' && _identity($_->[1], $root) } @$tables;
        _fail('unsupported_feature', 'SQLite root FTS5 is not a native main virtual relation')
            unless @matches == 1 && $matches[0][2] eq 'virtual';
        my $ddl = _rows($dbh,
            q{SELECT sql FROM main.sqlite_schema WHERE CAST(name AS BLOB) = CAST(? AS BLOB) AND CAST(type AS BLOB) = CAST('table' AS BLOB) LIMIT 2},
            $matches[0][1]);
        _fail('unsupported_feature', 'SQLite root FTS5 declaration is unavailable')
            unless @$ddl == 1 && defined($ddl->[0][0]) && bytes::length($ddl->[0][0]) <= 16384;
        _fts5_arguments($ddl->[0][0]);
        my $columns = _rows($dbh, 'PRAGMA main.table_xinfo(' . $adapter->quote_identifier($root) . ')');
        for my $field (@$fields) {
            _fail('unsupported_feature', 'SQLite root FTS5 requires native visible columns')
                unless _identifier($field) && grep { _identity($_->[1], $field) && !$_->[6] } @$columns;
        }
        return 1;
    });
}

# Native methods bypass a DBI-compatible wrapper's fabricated catalog rows.
# Fetching stops at the admission bound even for large real schemas.
sub _rows {
    my ($dbh, $sql, @params) = @_;
    my $statement = DBI::db::prepare($dbh, $sql);
    _fail('unsupported_feature', 'SQLite native FTS5 catalog could not be inspected') unless $statement;
    my @rows;
    my $ok = eval {
        defined(DBI::st::execute($statement, @params)) or die 'native catalog execute failed';
        while (my $row = DBI::st::fetchrow_arrayref($statement)) {
            push @rows, [@$row];
            _fail('unsupported_feature', 'SQLite FTS5 catalog exceeds its row bound') if @rows > 4096;
        }
        die 'native catalog fetch failed' if DBI::st->can('err')->($statement);
        1;
    };
    my $error = $@;
    DBI::st::finish($statement);
    die $error unless $ok;
    return \@rows;
}

sub _declaration {
    my ($ddl) = @_;
    my $args = _fts5_arguments($ddl);
    my (@parts, $current, $quote);
    $current = '';
    for (my $i = 0; $i < length($args); $i++) {
        my $char = substr($args, $i, 1);
        if (defined $quote) {
            $current .= $char;
            if ($char eq $quote) {
                if (substr($args, $i + 1, 1) eq $quote) { $current .= $quote; $i++; }
                else { undef $quote; }
            }
        } elsif ($char eq q{'} || $char eq q{"} || $char eq q{`}) {
            $quote = $char; $current .= $char;
        } elsif ($char eq ',') {
            push @parts, $current; $current = '';
            _fail('unsupported_feature', 'SQLite FTS5 declaration exceeds its argument bound') if @parts > 128;
        } else { $current .= $char; }
    }
    _fail('unsupported_feature', 'SQLite FTS5 declaration has unmatched quoting') if defined $quote;
    push @parts, $current;
    _fail('unsupported_feature', 'SQLite FTS5 declaration exceeds its argument bound') if @parts > 128;
    my (@columns, %options, %columns);
    for my $part (@parts) {
        if ($part =~ /\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/s) {
            my ($key, $value) = (lc($1), _atom($2));
            _fail('unsupported_feature', 'SQLite FTS5 declaration option is unavailable or ambiguous')
                unless $key =~ /\A(?:content|content_rowid|tokenize|detail)\z/ && !exists $options{$key};
            $options{$key} = $value;
        } else {
            my $unindexed = $part =~ s/\s+UNINDEXED\s*\z//i;
            my $column = _atom($part);
            _fail('unsupported_feature', 'SQLite FTS5 indexed column is ambiguous') if $columns{lc($column)}++;
            push @columns, $column unless $unindexed;
        }
    }
    return (\@columns, \%options);
}

sub _fts5_arguments {
    my ($ddl) = @_;
    _fail('unsupported_feature', 'SQLite index is not a supported native FTS5 declaration')
        unless $ddl =~ /\A\s*CREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:[A-Za-z_][A-Za-z0-9_]*|"[A-Za-z_][A-Za-z0-9_]*"|`[A-Za-z_][A-Za-z0-9_]*`|\[[A-Za-z_][A-Za-z0-9_]*\])\s+USING\s+fts5\s*\((.*)\)\s*\z/is;
    return $1;
}

sub _atom {
    my ($value) = @_;
    $value =~ s/\A\s+|\s+\z//g;
    $value = $2 if $value =~ /\A(['"`])([^'"`]+)\1\z/;
    _fail('unsupported_feature', 'SQLite FTS5 declaration identifier is unavailable') unless _identifier($value);
    return $value;
}
sub _identifier { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/ }
sub _identity {
    return 0 unless _identifier($_[0]) && _identifier($_[1]);
    my ($left, $right) = @_;
    $left =~ tr/A-Z/a-z/;
    $right =~ tr/A-Z/a-z/;
    return $left eq $right;
}
sub _text_affinity { my $type = uc($_[0]); return $type !~ /INT/ && $type =~ /(?:CHAR|CLOB|TEXT)/; }
sub _quote_term { my ($term) = @_; $term =~ s/"/""/g; return '"' . $term . '"'; }
sub _fail { Selecto::Error->throw($_[0], $_[1]); }

1;
