package Selecto::Statement;

use Mojo::Base -base, -signatures;

sub new ($class, %args) {
    return $class->SUPER::new(
        sql => "$args{sql}",
        params => [@{$args{params} // []}],
        columns => [@{$args{columns} // []}],
        adapter_name => defined($args{adapter_name}) ? "$args{adapter_name}" : 'unknown',
    );
}

sub sql ($self) { return $self->{sql}; }
sub params ($self) { return [@{$self->{params}}]; }
sub columns ($self) { return [@{$self->{columns}}]; }
sub adapter_name ($self) { return $self->{adapter_name}; }
sub to_hash ($self) {
    return {
        sql => $self->{sql},
        params => [@{$self->{params}}],
        aliases => [@{$self->{columns}}],
    };
}

1;
