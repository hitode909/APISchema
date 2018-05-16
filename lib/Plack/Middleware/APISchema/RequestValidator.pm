package Plack::Middleware::APISchema::RequestValidator;
use strict;
use warnings;

use parent qw(Plack::Middleware APISchema::HasSchema);
use HTTP::Status qw(:constants);
use Plack::Util::Accessor qw(schema validator);
use Plack::Request;
use APISchema::Generator::Router::Simple;
use APISchema::Validator;
use APISchema::JSON;

use constant DEFAULT_VALIDATOR_CLASS => 'Valiemon';

sub call {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);
    my $schema = $self->prepare_schema($env);

    my ($matched, $route) = $self->router($schema)->routematch($env);
    $matched or return $self->app->($env);

    my $validator = APISchema::Validator->for_request(
        validator_class => $self->validator // DEFAULT_VALIDATOR_CLASS,
    );
    my $result = $validator->validate($route->name => {
        header => +{ map {
            my $field = lc($_) =~ s/[-]/_/gr;
            ( $field => $req->header($_) );
        } $req->headers->header_field_names },
        parameter => $env->{QUERY_STRING},
        body => $req->content,
        content_type => $req->content_type,
    }, $schema);

    my $errors = $result->errors;
    my $status_code = $self->_resolve_status_code($result);
    return [
        $status_code,
        [ 'Content-Type' => 'application/json' ],
        [ encode_json_canonical($errors) ],
    ] if scalar keys %$errors;

    $self->app->($env);
}

sub router {
    my ($self, $schema) = @_;

    my $generator = APISchema::Generator::Router::Simple->new;
    $generator->generate_router($schema);
}

sub _resolve_status_code {
    my ($self, $validation_result) = @_;
    my $error_message = $validation_result->errors->{body}->{message} // '';
    return $error_message =~ m/Wrong content-type/ ? HTTP_UNSUPPORTED_MEDIA_TYPE : HTTP_UNPROCESSABLE_ENTITY;
}


1;
