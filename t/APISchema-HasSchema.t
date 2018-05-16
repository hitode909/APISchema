package t::APISchema::HasSchema;
use lib '.';
use t::test;
use APISchema::Schema;

sub _require : Test(startup => 1) {
    my ($self) = @_;

    BEGIN{ use_ok 'APISchema::HasSchema'; }
}

package SchemaHolder {
    use parent qw(APISchema::HasSchema);
    sub new {
        my ($class, %params) = @_;
        bless {%params}, $class;
    }
};

sub prepare_schema : Tests {
    subtest 'pass schema directly' => sub {
        my $schema = APISchema::Schema->new;
        my $env = {};
        my $holder = SchemaHolder->new(schema => $schema);
        is $holder->prepare_schema($env), $schema;
    };
    subtest 'fetch schema from env' => sub {
        my $schema = APISchema::Schema->new;
        my $env = {my_schema => $schema};
        my $holder = SchemaHolder->new(schema => sub { $_[0]->{my_schema}});
        is $holder->prepare_schema($env), $schema;
    };
}
