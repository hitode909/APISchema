package APISchema::HasSchema;
use strict;
use warnings;
use 5.014;

sub prepare_schema {
    my ($self, $env) = @_;

    die '$env required' unless $env;

    # resolve from env
    if (ref $self->{schema} eq 'CODE') {
        return $self->{schema}->($env);
    }

    # or return directly
    return $self->{schema};
}

1;
