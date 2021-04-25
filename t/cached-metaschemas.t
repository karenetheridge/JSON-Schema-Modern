use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };

use constant METASCHEMA => 'https://json-schema.org/draft/2019-09/schema';

use lib 't/lib';
use Helper;

subtest 'load cached metaschema' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_deeply(
    $js->_get_resource(METASCHEMA),
    undef,
    'this resource is not yet known',
  );

  cmp_deeply(
    $js->_get_or_load_resource(METASCHEMA),
    my $resource = +{
      canonical_uri => str(METASCHEMA),
      path => '',
      document => all(
        isa('JSON::Schema::Modern::Document'),
        methods(
          schema => superhashof({
            '$schema' => str(METASCHEMA),
            '$id' => METASCHEMA,
          }),
          canonical_uri => str(METASCHEMA),
          resource_index => ignore,
        ),
      ),
    },
    'loaded metaschema from sharedir cache',
  );

  cmp_deeply(
    $js->_get_resource(METASCHEMA),
    $resource,
    'this resource is now in the resource index',
  );
};

subtest 'resource collision with cached metaschema' => sub {
  my $js = JSON::Schema::Modern->new;
  cmp_deeply(
    $js->evaluate(1, { '$id' => METASCHEMA })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => re(qr{^EXCEPTION: \Quri "https://json-schema.org/draft/2019-09/schema" conflicts with an existing meta-schema resource\E}),
        },
      ],
    },
    'cannot introduce another schema whose id collides with a cached schema, even if it isn\'t loaded yet',
  );
};

done_testing;
