# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(with_defaults => 1);

subtest 'basic example' => sub {
  my $result = $js->evaluate(
    {
      my_object => { alpha => 1, gamma => 3 },
      my_array => [ 'yellow' ],
    },
    {
      type => 'object',
      properties => {
        my_object => {
          type => 'object',
          properties => {
            alpha => { type => 'integer', default => 10 },
            beta => { type => 'integer', default => 10 },
            gamma => { type => 'integer', default => 10 },
          },
        },
        my_array => {
          type => 'array',
          prefixItems => [
            { type => 'string', default => 'red' },
            { type => 'string', default => 'green' },
          ],
        },
      },
    },
  );

  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {
        '/my_object/beta' => 10,
        '/my_array/1' => 'green'
      },
    },
    'missing defaults are included in the result data',
  );
};

subtest 'boolean schemas' => sub {
  my $result = $js->evaluate(
    {
      my_object => { alpha => 1, gamma => 3 },
      my_array => [ 'yellow' ],
    },
    {
      type => 'object',
      properties => {
        my_object => {
          type => 'object',
          properties => {
            alpha => true,
            beta => true,
            gamma => true,
          },
        },
        my_array => {
          type => 'array',
          prefixItems => [ true, true ],
        },
      },
    },
  );

  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {},
    },
    'boolean schemas are okay (but produce no defaults, of course)',
  );
};

subtest 'json pointer escaping' => sub {
  my $result = $js->evaluate(
    {
      'my/ob~ject' => {},
      'my+arra~y' => [],
    },
    {
      type => 'object',
      properties => {
        'my/ob~ject' => {
          type => 'object',
          properties => {
            'al/ph~a' => { type => 'integer', default => '~ether/' },
          },
        },
        'my+arra~y' => {
          type => 'array',
          prefixItems => [
            { type => 'string', default => '~ether/' },
          ],
        },
      },
    },
  );

  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {
        '/my~1ob~0ject/al~1ph~0a' => '~ether/',
        '/my+arra~0y/0' => '~ether/'
      },
    },
    'jsonp escaping is done',
  );
};

subtest 'default handling in applicators' => sub {
  my $result = $js->evaluate(
    {
      # in this example data, the invalid property comes before the missing default,
      # so we can immediately skip collecting it
      my_object => { alpha => 'hi', gamma => 3 },
      my_array => [ 'yellow' ],
    },
    my $schema = {
      type => 'object',
      anyOf => [
        {
          properties => {
            my_object => {
              type => 'object',
              properties => {
                alpha => { type => 'integer', default => 10 },
                beta => { type => 'integer', default => 10 },
                gamma => { type => 'integer', default => 10 },
              },
            },
          },
        },
        {
          properties => {
            my_array => {
              type => 'array',
              prefixItems => [
                { type => 'string', default => 'red' },
                { type => 'string', default => 'green' },
              ],
            },
          },
        },
      ],
    },
  );
  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {
        '/my_array/1' => 'green'
      },
    },
    'defaults are not included if the local subschema is already invalid',
  );

  $result = $js->evaluate(
    {
      # in this example data, the invalid property comes after the missing default
      my_object => { alpha => 3, gamma => 'hi' },
      my_array => [ 'yellow' ],
    },
    $schema,
  );
  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {
        '/my_array/1' => 'green'
      },
    },
    'defaults are not included from invalid properties keywords',
  );

  # now we need a schema where 'properties' keywords are still valid, but something else causes the
  # subschema to be invalid, so the defaults from that subschema must be discarded
  $result = $js->evaluate(
    {
      my_object => {},
      my_array => [],
    },
    {
      anyOf => [                      # this keyword is valid (/anyOf/0 is false, /anyOf/1 is true)
        {
          allOf => [                  # this keyword is invalid (/allOf/0 is true, /allOf/1 is false)
            {                         # this schema is valid and produces defaults
              type => 'object',
              properties => {         # this keyword is valid and produces defaults
                my_object => {
                  type => 'object',
                  properties => {
                    alpha => { type => 'integer', default => 10 },
                  },
                },
                my_array => {
                  type => 'array',
                  prefixItems => [
                    { type => 'string', default => 'red' },
                  ],
                },
              },
            },
            false,
          ],
        },
        true,
      ],
    },
  );
  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {},
    },
    'defaults are discarded from all valid subschemas when allOf is invalid',
  );

  $result = $js->evaluate(
    {
      my_object => {},
      my_array => [],
    },
    {
      anyOf => [
        {                         # this schema is invalid and should discard defaults
          type => 'object',
          minProperties => 100,   # this keyword is invalid, making the containing schema invalid
          properties => {         # this keyword is valid and produces defaults
            my_object => {
              type => 'object',
              properties => {
                alpha => { type => 'integer', default => 10 },
              },
            },
            my_array => {
              type => 'array',
              prefixItems => [
                { type => 'string', default => 'red' },
              ],
            },
          },
        },
        true,
      ],
    },
  );
  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {},
    },
    'defaults are discarded from invalid anyOf subschemas',
  );

  $result = $js->evaluate(
    {
      my_object => {},
      my_array => [],
    },
    {
      oneOf => [                  # this schema is valid as there is one valid subschema
        {                         # this schema is invalid and should discard defaults
          type => 'object',
          minProperties => 100,   # this keyword is invalid, making the containing schema invalid
          properties => {         # this keyword is valid and produces defaults
            my_object => {
              type => 'object',
              properties => {
                alpha => { type => 'integer', default => 10 },
              },
            },
          },
        },
        {
          type => 'object',
          properties => {
            my_array => {
              type => 'array',
              prefixItems => [
                { type => 'string', default => 'red' },
              ],
            },
          },
        },
      ],
    },
  );
  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {
        '/my_array/0' => 'red'
      },
    },
    'defaults are discarded from invalid oneOf subschemas, but are kept from the valid subschema',
  );

  # same as above, but now there is a second valid schema. now we need to discard everything
  $result = $js->evaluate(
    {
      my_object => {},
      my_array => [],
    },
    {
      anyOf => [
        {
          oneOf => [                  # this schema is invalid as there are two valid subschemas
            {                         # this schema is invalid and should discard defaults
              type => 'object',
              minProperties => 100,   # this keyword is invalid, making the containing schema invalid
              properties => {         # this keyword is valid and produces defaults
                my_object => {
                  type => 'object',
                  properties => {
                    alpha => { type => 'integer', default => 10 },
                  },
                },
              },
            },
            {
              type => 'object',
              properties => {
                my_array => {
                  type => 'array',
                  prefixItems => [
                    { type => 'string', default => 'red' },
                  ],
                },
              },
            },
            true,
          ],
        },
        true,
      ],
    },
  );
  cmp_result(
    $result->TO_JSON,
    {
      valid => true,
      defaults => {},
    },
    'defaults are discarded from all oneOf subschemas if there is more than one valid schema',
  );
};

done_testing;
