package Plack::Middleware::APISchema::RequestValidator;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(schema validator status_code_resolver);
use Plack::Request;
use APISchema::Generator::Router::Simple;
use APISchema::Validator;
use JSON::XS qw(encode_json);

use constant DEFAULT_VALIDATOR_CLASS => 'Valiemon';

sub call {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    my ($matched, $route) = $self->router->routematch($env);
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
    }, $self->schema);

    my $errors = $result->errors;
    my $status_code = ($self->status_code_resolver // sub { 400 })->($result);
    return [
        $status_code,
        [ 'Content-Type' => 'application/json' ],
        [ encode_json($errors) ],
    ] if scalar keys %$errors;

    $self->app->($env);
}

sub router {
    my ($self) = @_;

    $self->{router} //= do {
        my $generator = APISchema::Generator::Router::Simple->new;
        $generator->generate_router($self->schema);
    };
}


1;
