package Plack::Middleware::APISchema::ResponseValidator;
use strict;
use warnings;

use parent qw(Plack::Middleware APISchema::HasSchema);
use Plack::Util ();
use Plack::Util::Accessor qw(schema validator);
use Plack::Response;
use APISchema::Generator::Router::Simple;
use APISchema::Validator;
use APISchema::JSON;

use constant DEFAULT_VALIDATOR_CLASS => 'Valiemon';

sub call {
    my ($self, $env) = @_;

    Plack::Util::response_cb($self->app->($env), sub {
        my $res = shift;

        my $schema = $self->prepare_schema($env);

        my ($matched, $route) = $self->router($schema)->routematch($env);
        $matched or return;

        my $plack_res = Plack::Response->new(@$res);
        my $body;
        Plack::Util::foreach($res->[2] // [], sub { $body .= $_[0] });

        my $validator_class = $self->validator // DEFAULT_VALIDATOR_CLASS;
        my $validator = APISchema::Validator->for_response(
            validator_class => $validator_class,
        );
        my $result = $validator->validate($route->name => {
            status_code => $res->[0],
            header => +{ map {
                my $field = lc($_) =~ s/[-]/_/gr;
                ( $field => $plack_res->header($_) );
            } $plack_res->headers->header_field_names },
            body => $body,
            content_type => scalar $plack_res->content_type,
        }, $schema);

        my $errors = $result->errors;
        if (scalar keys %$errors) {
            my $error_cause = join '+', __PACKAGE__, $validator_class;
            @$res = (
                500,
                [ 'Content-Type' => 'application/json', 'X-Error-Cause' => $error_cause ],
                [ encode_json_canonical($errors) ],
            );
            return;
        }

        $res->[2] = [ $body ];
    });
}

sub router {
    my ($self, $schema) = @_;

    my $generator = APISchema::Generator::Router::Simple->new;
    $generator->generate_router($schema);
}

1;
