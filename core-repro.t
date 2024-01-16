use strict;
use warnings;
use OpenAPI::Modern 0.057;

my $openapi;

# uncommenting this first line also makes the problem go away
#print STDERR "### schema 1 ", JSON::Schema::Modern::Document::OpenAPI->DEFAULT_SCHEMAS->{'strict-dialect.json'}, "\n";
#print STDERR "### schema 2 ", 'https://raw.githubusercontent.com/karenetheridge/OpenAPI-Modern/master/share/strict-dialect.json', "\n";

# when we dump core, the md5_hex of the bad document is   d039c35646bd78730e8714f7c4f3be25
# when everything is good, the md5_hex of the same doc is d039c35646bd78730e8714f7c4f3be25

{
    $openapi = OpenAPI::Modern->new(
        openapi_uri    => 'my-api.yaml',
        openapi_schema => {
            openapi => '3.1.0',
            info    => {
                title   => 'My API',
                version => 'my version',
            },
            components => { schemas => {} },
            paths      => {},
        },
        evaluator => JSON::Schema::Modern->new(),
    );
}

my $js = $openapi->evaluator;

print STDERR "#### evaluating...\n";

{
    my $result = $js->evaluate(
        'hello',
        {
            # switching between these two seems to make a difference??!
            '$schema' => JSON::Schema::Modern::Document::OpenAPI->DEFAULT_SCHEMAS->{'strict-dialect.json'},
       #'$schema' => 'https://raw.githubusercontent.com/karenetheridge/OpenAPI-Modern/master/share/strict-dialect.json',
        },
    )->TO_JSON;
    use Data::Dumper;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Maxdepth = 2;
    print STDERR "### we didn't drop core! got result ", Dumper($result);
}

