package t::APISchema::Generator::Router::Simple;
use t::test;
use t::test::fixtures;
use APISchema::Schema;

sub _require : Test(startup => 1) {
    my ($self) = @_;

    use_ok 'APISchema::Generator::Router::Simple';
}

sub instantiate : Tests {
    my $generator = APISchema::Generator::Router::Simple->new;
    isa_ok $generator, 'APISchema::Generator::Router::Simple';
}

sub generate : Tests {
    my $schema = t::test::fixtures::prepare_bmi;

    my $generator = APISchema::Generator::Router::Simple->new;
    my $router = $generator->generate_router($schema);

    isa_ok $router, 'Router::Simple';

    cmp_deeply $router->match({ PATH_INFO => '/bmi', HTTP_HOST => 'localhost', REQUEST_METHOD => 'POST' } ), {
        controller      => 'BMI',
        action          => 'calculate',
    };

    note $router->as_string;
}

sub generate_custom_router : Tests {
    my $generator = APISchema::Generator::Router::Simple->new(
        router_class => 'Test::Router::Simple',
    );
    my $schema = APISchema::Schema->new;
    my $router = $generator->generate_router($schema);
    isa_ok $router, 'Test::Router::Simple';
}

package Test::Router::Simple;
use parent qw(Router::Simple);

package t::APISchema::Generator::Router::Simple;
