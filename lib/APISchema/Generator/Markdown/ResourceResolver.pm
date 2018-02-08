package APISchema::Generator::Markdown::ResourceResolver;
use 5.014;
use strict;
use warnings;

# cpan
use JSON::Pointer;
use Class::Accessor::Lite (
    new => 1,
    ro  => [qw(schema)],
);

sub _foreach_properties($$&) {
    my ($name_path, $definition, $callback) = @_;
    return unless (ref $definition || '') eq 'HASH';

    if ($definition->{items}) {
        my $items = $definition->{items};
        my $type = ref $items || '';
        if ($type eq 'HASH') {
            $callback->([@$name_path, '[]'], $items);
        } elsif ($type eq 'ARRAY') {
            $callback->([@$name_path, "[$_]"], $items->{$_}) for (0..$#$items);
        }
    }

    if ($definition->{properties}) {
        my $items = $definition->{properties};
        my $type = ref $items || '';
        if ($type eq 'HASH') {
            $callback->([@$name_path, $_], $items->{$_}) for keys %$items;
        }
    }
}

sub _property_name (@) {
    my @name_path = @_;
    return '.' . join '.', @name_path;
}

sub _collect_properties {
    my ($self, $path, $definition) = @_;
    return {} unless (ref $definition || '') eq 'HASH';

    my $ref = $definition->{'$ref'};
    if ($ref) {
        $ref = $ref =~ s/^#//r;
        my $def = JSON::Pointer->get($self->schema, $ref);
        return $self->_collect_properties($path, $def)
            if $def && $ref !~ qr!^/resource/[^/]+$!;

        $definition = +{
            %$definition,
            description => $definition->{description} // $def->{description},
        };
    }

    my $result = { _property_name(@$path) => $definition };
    _foreach_properties($path, $definition, sub {
        $result = +{
            %$result,
            %{$self->_collect_properties(@_)},
        };
    });
    return $result;
}

sub _collect_example {
    my ($self, $path, $definition) = @_;
    return ($definition->{example}, 1) if exists $definition->{example};

    if (my $union = $definition->{oneOf} || $definition->{anyOf} || $definition->{allOf}) {
        return ($self->_collect_example($path, $union->[0]), 1);
    }

    my $ref = $definition->{'$ref'};
    if ($ref) {
        $ref = $ref =~ s/^#//r;
        my $def = JSON::Pointer->get($self->schema, $ref);
        return ($self->_collect_example($path, $def), 1) if $def;
    }

    my %result;
    my $type = $definition->{type} || '';
    _foreach_properties($path, $definition, sub {
        my ($example, $exists) = $self->_collect_example(@_);
        unless ($exists) {
            if (exists $_[1]->{default}) {
                $example = $_[1]->{default};
                $exists = 1;
            }
        }
        $result{$_[0]->[-1]} = $example if $exists;
    });

    return (\%result, 1) if $type eq 'object';

    if ($type eq 'array') {
        return ([ $result{'[]'} ], 1) if $result{'[]'};

        my @result;
        for (keys %result) {
            next unless $_ =~ /\A\[([0-9]+)\]\z/;
            $result[$1] = $result{$_};
        }
        return (\@result, 1);
    }

    return (undef, 0);
}

sub properties {
    my ($self, $resource) = @_;
    return $self->_collect_properties([], $resource);
}

sub example {
    my ($self, $resource) = @_;
    my ($example) = $self->_collect_example([], $resource);
    return $example;
}

1;
