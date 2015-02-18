package APISchema::Generator::Markdown;
use strict;
use warnings;

# cpan
use Text::MicroTemplate::DataSection qw();

sub new {
    my ($class) = @_;

    my $renderer = Text::MicroTemplate::DataSection->new(
        escape_func => undef
    );
    bless {
        renderer => $renderer,
        map {
            ( $_ => $renderer->build_file($_) );
        } qw(index toc route resource request response
             request_example response_example),
    }, $class;
}

sub resolve_encoding ($) {
    my ($resources) = @_;
    $resources = { body => $resources } unless ref $resources;
    my $encoding = $resources->{encoding} // { '' => 'auto' };
    $encoding = { '' => $encoding } unless ref $encoding;
    return { %$resources, encoding => $encoding };
}

sub format_schema {
    my ($self, $schema) = @_;

    my $renderer = $self->{renderer};
    my $routes = $schema->get_routes;
    my $resources = $schema->get_resources;

    my $root = $schema->get_resource_root;
    my $resolver = APISchema::Generator::Markdown::ResourceResolver->new(
        schema => $root,
    );
    return $self->{index}->(
        $renderer,
        $schema,
        $self->{toc}->(
            $renderer,
            $routes,
            $resources,
        ),
        join('', map {
            my $route = $_;
            my $req = resolve_encoding($route->request_resource);
            my $request_resource = $route->canonical_request_resource($root);

            my $codes = do {
                my $res = $route->response_resource;
                $res = {} unless $res && ref $res;
                [ sort grep { $_ =~ qr!\A[0-9]+\z! } keys %$res ];
            };
            my $default_code = $codes->[0] // 200;
            my $response_resource = $route->canonical_response_resource($root, [
                $default_code
            ]);

            my $res = $_->response_resource;
            $res = scalar @$codes
                ? { map { $_ => resolve_encoding($res->{$_}) } @$codes }
                : { '' => resolve_encoding($res) };

            $self->{route}->(
                $renderer,
                $route,
                {
                    req =>  $self->{request_example}->(
                        $renderer,
                        $route,
                        APISchema::Generator::Markdown::ExampleFormatter->new(
                            resolver => $resolver,
                            spec     => $request_resource,
                        ),
                    ),
                    res => $self->{response_example}->(
                        $renderer,
                        $route,
                        $default_code,
                        APISchema::Generator::Markdown::ExampleFormatter->new(
                            resolver => $resolver,
                            spec     => $response_resource,
                        ),
                    ),
                },
                {
                    req => $self->{request}->($renderer, $route, $req),
                    res => join("\n", map {
                        $self->{response}->($renderer, $route, $_, $res->{$_});
                    } sort keys %$res),
                },
            );
        } @$routes),
        join('', map {
            my $properties = $resolver->properties($_->definition);
            $self->{resource}->($renderer, $resolver, $_, [ map { +{
                path => $_,
                definition => $properties->{$_},
            } } sort keys %$properties ]);
        } grep {
            ( $_->definition->{type} // '' ) ne 'hidden';
        } @$resources),
    );
}

package APISchema::Generator::Markdown::ResourceResolver;
use 5.014;

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
    return $definition->{example} if defined $definition->{example};

    my $ref = $definition->{'$ref'};
    if ($ref) {
        $ref = $ref =~ s/^#//r;
        my $def = JSON::Pointer->get($self->schema, $ref);
        return $self->_collect_example($path, $def) if $def;
    }

    my %result;
    my $type = $definition->{type} || '';
    _foreach_properties($path, $definition, sub {
        my $example = $self->_collect_example(@_) // $_[1]->{default};
        $result{$_[0]->[-1]} = $example if defined $example;
    });

    return \%result if $type eq 'object';

    if ($type eq 'array') {
        return [ $result{'[]'} ] if $result{'[]'};

        my @result;
        for (keys %result) {
            next unless $_ =~ /\A\[([0-9]+)\]\z/;
            $result[$1] = $result{$_};
        }
        return \@result;
    }

    return undef;
}

sub properties {
    my ($self, $resource) = @_;
    return $self->_collect_properties([], $resource);
}

sub example {
    my ($self, $resource) = @_;
    return $self->_collect_example([], $resource);
}

package APISchema::Generator::Markdown::Formatter;
use 5.014;

# core
use Exporter qw(import);
our @EXPORT = qw(type json code restriction desc anchor method methods content_type http_status http_status_code);

# cpan
use HTTP::Status qw(status_message);
use URI::Escape qw(uri_escape_utf8);
use JSON::XS ();
my $JSON = JSON::XS->new->canonical(1);

use constant +{
    RESTRICTIONS => [qw(required max_items min_items max_length min_length maximum minimum pattern)],
    SHORT_DESCRIPTION_LENGTH => 100,
};

sub type ($) {
    my $def = shift;
    my $bar = '&#124;';

    my $ref = ref $def ? $def->{'$ref'} : $def;
    if ($ref) {
        $ref = $ref =~ s!^#/resource/!!r;
        my $ref_text = "`$ref`";
        my $name = $ref =~ s!/.*$!!r;
        $ref_text = sprintf('[%s](#%s)', $ref_text, anchor(resource => $name)) if $name;
        return $ref_text;
    }

    my $type = $def->{type};
    if ($type) {
        return sprintf '`%s`', $type unless ref $type;
        return join $bar, map { code($_) } @{$type} if ref $type eq 'ARRAY';
    }

    return join $bar, map { code($_) } @{$def->{enum}} if $def->{enum};

    return 'undefined';
}

sub json ($) {
    my $x = shift;
    if (ref $x) {
        $x = $JSON->encode($x);
    } else {
        $x = $JSON->encode([$x]);
        $x =~ s/^\[(.*)\]$/$1/;
    }
    return $x;
}

sub _code ($) {
    my $text = shift;
    return '' unless defined $text;
    if ($text =~ /[`|]/) {
        $text =~ s/[|]/&#124;/g;
        return sprintf '<code>%s</code>', $text;
    }
    return sprintf '`%s`', $text;
}

sub code ($) {
    my $text = shift;
    return '' unless defined $text;
    return _code json $text;
}

sub anchor ($$) {
    my ($label, $obj) = @_;
    my $name = ref $obj ? $obj->title : $obj;
    return sprintf '%s-%s', $label, uri_escape_utf8($name);
}

sub restriction ($) {
    my $def = shift;
    return '' unless (ref $def) eq 'HASH';

    my @result = ();
    for my $r (sort @{+RESTRICTIONS}) {
        next unless defined $def->{$r};

        if (ref $def->{$r}) {
            push @result, _code sprintf "$r%s", json $def->{$r};
        } else {
            push @result, _code sprintf "$r(%s)", json $def->{$r};
        }
    }
    return join ' ', @result;
}

sub desc ($) {
    my $text = shift || '';
    $text = $text =~ s/[\r\n].*\z//sr;
    $text = substr($text, 0, SHORT_DESCRIPTION_LENGTH) . '...'
        if length($text) > SHORT_DESCRIPTION_LENGTH;
    return $text;
}

sub method ($) {
    my $method = shift;
    return $method->[0] if (ref $method || '') eq 'ARRAY';
    return $method;
}

sub methods ($) {
    my $method = shift;
    return join ', ', map { _code($_) } @$method
        if (ref $method || '') eq 'ARRAY';
    return _code($method);
}

sub content_type ($) {
    my $type = shift;
    return '-' unless length($type);
    return "`$type`";
}

sub http_status ($) {
    my $code = shift;
    return undef unless $code;
    return join(' ', $code, status_message($code));
}

sub http_status_code {
    return _code http_status shift;
}

package APISchema::Generator::Markdown::ExampleFormatter;
use 5.014;

# cpan
use URI::Escape qw(uri_escape_utf8);
use Class::Accessor::Lite (
    new => 1,
    ro => [qw(resolver spec)],
);

APISchema::Generator::Markdown::Formatter->import('json');

sub example {
    my $self = shift;
    return $self->resolver->example(@_);
}

sub header {
    my ($self) = @_;
    my $header = $self->spec->{header} or return '';
    my $resource = $header->definition or return '';
    my $example = $self->example($resource);

    return '' unless defined $example;
    return '' unless (ref $example) eq 'HASH';
    return '' unless scalar keys %$example;

    return "\n" . join "\n", map {
        sprintf '%s: %s', $_ =~ s/[_]/-/gr, $example->{$_};
    } sort keys %$example;
}

sub parameter {
    my ($self) = @_;
    my $parameter = $self->spec->{parameter} or return '';
    my $resource = $parameter->definition or return '';
    my $example = $self->example($resource);

    return '' unless defined $example;
    return '' unless (ref $example) eq 'HASH';
    return '' unless scalar keys %$example;

    return '?' . join '&', map {
        # TODO multiple values?
        sprintf '%s=%s', map { uri_escape_utf8 $_ } $_, $example->{$_};
    } sort keys %$example;
}

sub body {
    my ($self) = @_;
    my $body = $self->spec->{body} or return '';
    my $resource = $body->definition or return '';
    my $example = $self->example($resource);

    return '' unless defined $example;

    return "\n" . ( ref $example ? json($example) : $example );
}

package APISchema::Generator::Markdown;
APISchema::Generator::Markdown::Formatter->import;

1;
__DATA__
@@ index
? my ($schema, $toc_text, $routes_text, $resources_text) = @_;
# <?= $schema->title || '' ?>

?= $schema->description || ''

?= $toc_text

## <a name="routes"></a> Routes

?= $routes_text

## <a name="resources"></a> Resources

?= $resources_text

----------------------------------------------------------------
Generated by <?= __PACKAGE__ ?>

@@ toc
? my ($routes, $resources) = @_;

- [Routes](#routes)
? for (@$routes) {
    - [<?= $_->title ?>](#<?= anchor(route => $_->title) ?>)
? }
- [Resources](#resources)
? for (@$resources) {
?   next if ( $_->definition->{type} // '' ) eq 'hidden';
    - [<?= $_->title ?>](#<?= anchor(resource => $_->title) ?>)
? }

@@ route
? my ($route, $example, $text) = @_;
### <a name="<?= anchor(route => $route) ?>"></a> <?= $route->title ?>

?= $example->{req}
?= $example->{res}
?= $route->description || ''

?= $text->{req}

?= $text->{res}

@@ request_example
? my ($route, $example) = @_;
```
<?= method($route->method) ?> <?= $route->route ?><?= $example->parameter ?><?= $example->header ?><?= $example->body ?>
```

@@ response_example
? my ($route, $code, $example) = @_;
```
HTTP/1.1 <?= http_status($code) ?><?= $example->header ?><?= $example->body ?>
```

@@ request
? my ($route, $req) = @_;
#### Request  <?= methods($route->method) ?>
?= $req->{description} // ''

? if (scalar grep { $req->{$_} } qw(header parameter body)) {
|Part|Resource|Content-Type|Encoding|
|----|--------|------------|--------|
?   for (qw(header parameter)) {
?     next unless $req->{$_};
|<?= $_ ?>|<?= type($req->{$_}) ?>|-|-|
?   } # for
?   if ($req->{body}) {
?     for (sort keys %{$req->{encoding}}) {
|body|<?= type($req->{body}) ?>|<?= content_type($_) ?>|<?= content_type($req->{encoding}->{$_}) ?>|
?     } # for
?   } # $req->{body}
? } # scalar keys %$req

@@ response
? my ($route, $code, $res) = @_;
#### Response <?= http_status_code($code) ?>
?= $res->{description} // ''

? if (scalar grep { $res->{$_} } qw(header parameter body)) {
|Part|Resource|Content-Type|Encoding|
|----|--------|------------|--------|
?   for (qw(header)) {
?     next unless $res->{$_};
|<?= $_ ?>|<?= type($res->{$_}) ?>|-|-|
?   } # for
?   if ($res->{body}) {
?     for (sort keys %{$res->{encoding}}) {
|body|<?= type($res->{body}) ?>|<?= content_type($_) ?>|<?= content_type($res->{encoding}->{$_}) ?>|
?     } # for
?   } # $res->{body}
? } # scalar keys %$res

@@ resource
? my ($r, $resource, $properties) = @_;
### <a name="<?= anchor(resource => $resource) ?>"></a> `<?= $resource->title ?>` : <?= type($resource->definition) ?>
```javascript
<?= json $r->example($resource->definition) ?>
```

?= $resource->definition->{description} || ''

#### Properties

? if (scalar @$properties) {
|Property|Type|Default|Example|Restrictions|Description|
|--------|----|-------|-------|------------|-----------|
?   for my $prop (@$properties) {
?     my $def = $prop->{definition};
|`<?= $prop->{path} ?>` |<?= type($def) ?> |<?= code($def->{default}) ?> |<?= code($def->{example}) ?> |<?= restriction($def) ?> |<?= desc($def->{description}) ?> |
?   } # $prop
? } # scalar @$properties

