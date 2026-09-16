package Selecto::API::ResultFormatter;

use 5.034;
use utf8;

use Encode qw(encode);
use File::Temp qw(tempfile);
use JSON::PP ();
use Mojo::Base -base, -signatures;
use Scalar::Util qw(blessed looks_like_number);
use Selecto::Error ();
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

sub encode_result ($class, $format, $result) {
    $format = $class->normalize($format);
    Selecto::Error->throw(
        'invalid_response_format', 'unknown API response format',
    ) unless defined($format) && length($format) && $format ne 'json';
    my ($columns, $rows) = _tabular_result($result);
    return _delimited($columns, $rows, $format eq 'csv' ? ',' : "\t")
        if $format eq 'csv' || $format eq 'tsv';
    return _xlsx($columns, $rows);
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

sub _delimited ($columns, $rows, $separator) {
    my $csv = Text::CSV->new({
        binary => 1,
        sep_char => $separator,
    }) or Selecto::Error->throw(
        'response_encoding_failed', 'could not initialize the delimited response writer',
    );
    my @lines;
    $csv->combine(map { _spreadsheet_safe($_) } @$columns)
        or Selecto::Error->throw('response_encoding_failed', 'could not encode delimited headings');
    push @lines, $csv->string;
    for my $row (@$rows) {
        $csv->combine(map { _spreadsheet_safe(_flat_value($_)) } @$row)
            or Selecto::Error->throw('response_encoding_failed', 'could not encode a delimited row');
        push @lines, $csv->string;
    }
    return encode('UTF-8', join("\r\n", @lines) . "\r\n");
}

sub _xlsx ($columns, $rows) {
    require Excel::Writer::XLSX;
    my ($handle) = tempfile(SUFFIX => '.xlsx', UNLINK => 1);
    binmode $handle;
    my $workbook = Excel::Writer::XLSX->new($handle)
        or Selecto::Error->throw('response_encoding_failed', 'could not create the XLSX response');
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
            if (_native_number($value)) {
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

1;
