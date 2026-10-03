package Selecto::API::ResultFormatter;

use 5.034;
use utf8;

use Encode qw(encode);
use File::Temp qw(tempfile);
use File::Find ();
use JSON::PP ();
use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed looks_like_number);
use Selecto::Error ();
use Selecto::Limits ();
use Selecto::OperationBudget ();
use Text::CSV ();

my %FORMAT = (
    json => {
        content_type => 'application/json; charset=utf-8',
        media_type => 'application/json', extension => 'json',
    },
    csv => {
        content_type => 'text/csv; charset=utf-8',
        media_type => 'text/csv', extension => 'csv',
    },
    tsv => {
        content_type => 'text/tab-separated-values; charset=utf-8',
        media_type => 'text/tab-separated-values', extension => 'tsv',
    },
    xlsx => {
        content_type => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        media_type => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        extension => 'xlsx',
    },
);

sub formats ($class) {
    return [map {{
        id => $_,
        content_type => $FORMAT{$_}{content_type},
        media_type => $FORMAT{$_}{media_type},
        extension => $FORMAT{$_}{extension},
    }} qw(json csv tsv xlsx)];
}

sub openapi_parameters ($class) {
    return [
        {
            in => 'query', name => 'format', required => JSON::PP::false,
            description => 'Response representation. The Accept header may be used instead.',
            schema => {type => 'string', enum => [qw(json csv tsv xlsx)], default => 'json'},
        },
        {
            in => 'query', name => 'filename', required => JSON::PP::false,
            description => 'Safe download filename for CSV, TSV, or XLSX; the matching extension is required.',
            schema => {type => 'string', maxLength => 160, pattern => '^[A-Za-z0-9][A-Za-z0-9._ ()-]*\\.(csv|tsv|xlsx)$'},
        },
    ];
}

sub openapi_content ($class) {
    return {
        'application/json' => {},
        'text/csv' => {schema => {type => 'string'}},
        'text/tab-separated-values' => {schema => {type => 'string'}},
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => {
            schema => {type => 'string', format => 'binary'},
        },
    };
}

sub normalize ($class, $value) {
    return undef unless defined $value;
    return '' if ref($value);
    my $format = lc "$value";
    $format =~ s/\A\s+|\s+\z//g;
    $format = 'xlsx' if $format eq 'excel';
    return exists($FORMAT{$format}) ? $format : '';
}

sub negotiate ($class, $explicit = undef, $accept = undef) {
    if (defined($explicit) && ref($explicit)) {
        Selecto::Error->throw(
            'invalid_response_format',
            'response format must be json, csv, tsv, or xlsx',
        );
    }
    if (defined($explicit) && "$explicit" ne '') {
        my $format = $class->normalize($explicit);
        Selecto::Error->throw(
            'invalid_response_format',
            'response format must be json, csv, tsv, or xlsx',
            {format => ref($explicit) ? undef : "$explicit"},
        ) unless defined($format) && length($format);
        return $format;
    }
    return 'json' unless defined($accept) && !ref($accept) && "$accept" ne '';

    my @ranges;
    my $position = 0;
    for my $entry (split /,/, lc "$accept") {
        my ($media_type, @parameters) = split /;/, $entry;
        $media_type =~ s/\A\s+|\s+\z//g;
        my $quality = 1;
        for my $parameter (@parameters) {
            next unless $parameter =~ /\A\s*q\s*=/;
            $quality = $parameter =~ /\A\s*q\s*=\s*(0(?:\.\d+)?|1(?:\.0+)?)\s*\z/
                ? 0 + $1 : 0;
        }
        push @ranges, {media_type => $media_type, quality => $quality, position => $position++}
            if length($media_type);
    }
    my @candidates;
    my $preference = 0;
    for my $format (qw(json csv tsv xlsx)) {
        my @matches = grep {
            _media_range_specificity($_->{media_type}, $FORMAT{$format}{media_type}) >= 0
        } @ranges;
        my ($range) = sort {
            _media_range_specificity($b->{media_type}, $FORMAT{$format}{media_type})
                <=> _media_range_specificity($a->{media_type}, $FORMAT{$format}{media_type})
                || $a->{position} <=> $b->{position}
        } @matches;
        push @candidates, {
            format => $format, quality => $range->{quality}, preference => $preference,
        } if $range && $range->{quality} > 0;
        $preference++;
    }
    my ($selected) = sort {
        $b->{quality} <=> $a->{quality} || $a->{preference} <=> $b->{preference}
    } @candidates;
    return $selected->{format} if $selected;
    Selecto::Error->throw(
        'response_format_not_acceptable',
        'Accept must allow application/json, text/csv, text/tab-separated-values, or XLSX',
        {accept => "$accept"},
    );
}

sub _media_range_specificity ($range, $media_type) {
    return 2 if $range eq $media_type;
    my ($range_type, $range_subtype) = split m{/}, $range, 2;
    my ($type) = split m{/}, $media_type, 2;
    return 0 if defined($range_subtype) && $range_type eq '*' && $range_subtype eq '*';
    return 1 if defined($range_subtype) && $range_type eq $type && $range_subtype eq '*';
    return -1;
}

sub specification ($class, $format) {
    $format = $class->normalize($format);
    Selecto::Error->throw(
        'invalid_response_format', 'unknown API response format',
    ) unless defined($format) && length($format);
    return {%{$FORMAT{$format}}};
}

sub encode_result ($class, $format, $result, %options) {
    my $limits = $options{limits} // Selecto::Limits->new;
    Selecto::OperationBudget->new(limits => $limits, code => 'api_result_limit_exceeded')
        ->check_tree($result, label => 'tabular result', bytes_limit => 'max_response_bytes');
    $format = $class->normalize($format);
    Selecto::Error->throw(
        'invalid_response_format', 'unknown API response format',
    ) unless defined($format) && length($format) && $format ne 'json';
    my ($columns, $rows) = _tabular_result($result);
    return _delimited($columns, $rows, $format eq 'csv' ? ',' : "\t", $limits)
        if $format eq 'csv' || $format eq 'tsv';
    return _xlsx($columns, $rows, $limits);
}

sub _tabular_result ($result) {
    Selecto::Error->throw(
        'invalid_api_result', 'tabular API response requires columns and rows',
    ) unless ref($result) eq 'HASH'
        && ref($result->{columns}) eq 'ARRAY'
        && ref($result->{rows}) eq 'ARRAY';
    my @columns = map {
        Selecto::Error->throw(
            'invalid_api_result', 'tabular API column names must be scalars',
        ) if !defined($_) || ref($_);
        "$_";
    } @{$result->{columns}};
    my @rows;
    for my $row (@{$result->{rows}}) {
        my @values;
        if (ref($row) eq 'ARRAY') {
            Selecto::Error->throw(
                'invalid_api_result', 'tabular API row width does not match columns',
            ) unless @$row == @columns;
            @values = @$row;
        } elsif (ref($row) eq 'HASH') {
            @values = map { $row->{$_} } @columns;
        } else {
            Selecto::Error->throw(
                'invalid_api_result', 'tabular API rows must be arrays or objects',
            );
        }
        push @rows, \@values;
    }
    return (\@columns, \@rows);
}

sub _delimited ($columns, $rows, $separator, $limits) {
    my $csv = Text::CSV->new({
        binary => 1,
        sep_char => $separator,
    }) or Selecto::Error->throw(
        'response_encoding_failed', 'could not initialize the delimited response writer',
    );
    my $output = '';
    my $append = sub {
        my $line = encode('UTF-8', $csv->string . "\r\n");
        $limits->check_count('max_response_bytes', length($output) + length($line),
            'api_result_limit_exceeded', 'encoded response bytes');
        $output .= $line;
    };
    $csv->combine(map { _spreadsheet_safe($_) } @$columns)
        or Selecto::Error->throw('response_encoding_failed', 'could not encode delimited headings');
    $append->();
    for my $row (@$rows) {
        $csv->combine(map { _spreadsheet_safe(_flat_value($_)) } @$row)
            or Selecto::Error->throw('response_encoding_failed', 'could not encode a delimited row');
        $append->();
    }
    return $output;
}

sub _xlsx ($columns, $rows, $limits) {
    require Excel::Writer::XLSX;
    # Reserve conservatively for XML escaping, worksheet/package copies and
    # ZIP overhead before creating any spool files. The tree was admitted
    # before flattening nested cells. Actual spool and output bytes are checked
    # again before the finished workbook is read into memory.
    my $reserved = 262_144;
    my $reserve = sub {
        my ($value) = @_;
        $reserved += 4 * (1024 + 6 * length(encode('UTF-8', _flat_value($value))));
        $limits->check_count('max_response_temp_bytes', $reserved,
            'api_result_limit_exceeded', 'XLSX temporary bytes');
    };
    $limits->check_count('max_response_temp_bytes', $reserved,
        'api_result_limit_exceeded', 'XLSX temporary bytes');
    $reserve->($_) for @$columns;
    for my $row (@$rows) { $reserve->($_) for @$row }
    my $directory = File::Temp->newdir('selecto-api-xlsx-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    # A File::Temp object unlinks at scope exit. tempfile(UNLINK => 1) only
    # schedules end-of-process cleanup, leaking failed responses in workers.
    my $handle = File::Temp->new(DIR => "$directory", SUFFIX => '.xlsx', UNLINK => 1);
    binmode $handle;
    my $workbook = Excel::Writer::XLSX->new($handle)
        or Selecto::Error->throw('response_encoding_failed', 'could not create the XLSX response');
    $workbook->set_tempdir("$directory");
    my $worksheet = $workbook->add_worksheet('Query Results');
    my $header = $workbook->add_format(
        bold => 1, bg_color => '#DCE6F1', bottom => 1,
    );
    my @widths;
    for my $column_index (0 .. $#$columns) {
        my $label = "$columns->[$column_index]";
        $worksheet->write_string(0, $column_index, $label, $header);
        $widths[$column_index] = length($label);
    }
    my $row_index = 1;
    for my $row (@$rows) {
        for my $column_index (0 .. $#$columns) {
            my $value = $row->[$column_index];
            if (!defined $value) {
                $worksheet->write_blank($row_index, $column_index, undef);
                next;
            }
            if (_safe_xlsx_number($value)) {
                $worksheet->write_number($row_index, $column_index, 0 + $value);
            } else {
                my $text = _flat_value($value);
                $worksheet->write_string($row_index, $column_index, $text);
                $widths[$column_index] = length($text)
                    if length($text) > ($widths[$column_index] // 0);
            }
        }
        $row_index++;
    }
    if (@$columns) {
        $worksheet->freeze_panes(1, 0);
        $worksheet->autofilter(0, 0, $row_index - 1, $#$columns);
        for my $column_index (0 .. $#$columns) {
            my $width = ($widths[$column_index] // 0) + 2;
            $width = 10 if $width < 10;
            $width = 60 if $width > 60;
            $worksheet->set_column($column_index, $column_index, $width);
        }
    }
    $workbook->close
        or Selecto::Error->throw('response_encoding_failed', 'could not finish the XLSX response');
    my $output_bytes = -s $handle;
    my $temporary_bytes = 0;
    File::Find::find({no_chdir => 1, wanted => sub {
        $temporary_bytes += -s $_ if -f $_;
    }}, "$directory");
    $limits->check_count('max_response_temp_bytes', $temporary_bytes,
        'api_result_limit_exceeded', 'XLSX temporary bytes');
    $limits->check_count('max_response_bytes', $output_bytes,
        'api_result_limit_exceeded', 'encoded response bytes');
    seek $handle, 0, 0
        or Selecto::Error->throw('response_encoding_failed', 'could not rewind the XLSX response');
    local $/;
    my $output = <$handle>;
    close $handle;
    return $output;
}

sub _flat_value ($value) {
    return '' unless defined $value;
    return $value ? 'true' : 'false'
        if blessed($value) && JSON::PP::is_bool($value);
    return JSON::PP->new->canonical(1)->allow_nonref(1)->utf8(0)->encode($value)
        if ref($value);
    return "$value";
}

sub _spreadsheet_safe ($value) {
    $value = '' unless defined $value;
    $value = "$value";
    return "'$value" if $value =~ /\A[=+\-@\t\r\n]/;
    return $value;
}

sub _native_number ($value) {
    return 0 if ref($value) || !looks_like_number($value);
    my $encoded = JSON::PP->new->allow_nonref(1)->utf8(0)->encode($value);
    return $encoded !~ /\A"/ ? 1 : 0;
}

sub _safe_xlsx_number ($value) {
    return 0 unless _native_number($value);
    my $encoded = JSON::PP->new->allow_nonref(1)->utf8(0)->encode($value);
    if ($encoded =~ /\A-?(?:0|[1-9][0-9]*)\z/) {
        my $digits = $encoded =~ s/\A-//r;
        my $limit = '9007199254740991';
        return 0 if length($digits) > length($limit)
            || (length($digits) == length($limit) && $digits gt $limit);
    }
    return 1;
}

1;

__END__

=head1 NAME

Selecto::API::ResultFormatter - encode canonical API query results as JSON, CSV, TSV or XLSX

=head1 DESCRIPTION

Negotiates the response representation for L<Selecto::API> query routes and
encodes query results as CSV, TSV or XLSX, guarding formula-leading
spreadsheet values.

This module is an internal part of the L<Selecto> distribution. Its interface
may change without notice; applications should use the public entry points
listed in L<Selecto>.

=head1 SEE ALSO

L<Selecto>, L<Selecto::API>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
