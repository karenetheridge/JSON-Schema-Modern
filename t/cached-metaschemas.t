use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Draft201909' => 'share' } };

subtest 'load cached metaschema' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    $js->_get_resource('https://json-schema.org/draft/2019-09/schema'),
    undef,
    'this resource is not yet known',
  );

  cmp_deeply(
    $js->_get_or_load_resource('https://json-schema.org/draft/2019-09/schema'),
    my $resource = +{
      canonical_uri => str('https://json-schema.org/draft/2019-09/schema'),
      path => '',
      document => all(
        isa('JSON::Schema::Draft201909::Document'),
        methods(
          schema => superhashof({
            '$schema' => str('https://json-schema.org/draft/2019-09/schema'),
            '$id' => 'https://json-schema.org/draft/2019-09/schema',
          }),
          canonical_uri => str('https://json-schema.org/draft/2019-09/schema'),
          resource_index => ignore,
        ),
      ),
    },
    'loaded metaschema from sharedir cache',
  );

  cmp_deeply(
    $js->_get_resource('https://json-schema.org/draft/2019-09/schema'),
    $resource,
    'this resource is now in the resource index',
  );
};

subtest 'resource collision with cached metaschema' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(1, { '$id' => 'https://json-schema.org/draft/2019-09/schema' })->TO_JSON,
    {
      valid => bool(0),
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
