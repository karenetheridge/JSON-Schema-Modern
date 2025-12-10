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
use JSON::Schema::Modern::Utilities 'jsonp_set';

my $js = JSON::Schema::Modern->new(with_defaults => 1);

subtest 'basic example' => sub {
  my $result = $js->evaluate(
    my $data = {
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

  my $defaults = $result->defaults;
  jsonp_set($data, $_, $defaults->{$_}) foreach keys %$defaults;

  cmp_result(
    $data,
    {
      my_object => { alpha => 1, beta => 10, gamma => 3 },
      my_array => [ 'yellow', 'green' ],
    },
    'defaults have been populated into the data instance',
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

subtest 'jsonp_set permutations' => sub {
  my $data = '';
  my $newdata = jsonp_set($data, '', { foo => 1 }),
  cmp_result(
    $data,
    '',
    'cannot overwrite a non-reference with a hashref',
  );
  cmp_result(
    $newdata,
    { foo => 1 },
    '...but the reference is returned',
  );

  like(
    dies { jsonp_set($data = '', '1', 2) },
    qr/^cannot write into non-reference in void context/,
    'when root type is a non-reference, result must be assigned',
  );

  $data = { foo => 1 };
  $newdata = jsonp_set($data, '', 'a' );
  cmp_result(
    $data,
    { foo => 1 },
    'cannot overwrite the hashref with a non-reference',
  );
  cmp_result(
    $newdata,
    'a',
    '...but the new primitive is returned',
  );
  like(
    dies { jsonp_set($data = { foo => 1 }, '', 'a') },
    qr/^cannot write into reference of different type in void context/,
    'when root type of original and new data do not match, result must be assigned',
  );

  $data = [ 1, 2, 3 ];
  $newdata = jsonp_set($data, '', 'a' );
  cmp_result(
    $data,
    [ 1, 2, 3 ],
    'cannot overwrite the arrayref with a non-reference',
  );
  cmp_result(
    $newdata,
    'a',
    '...but the new primitive is returned',
  );
  like(
    dies { jsonp_set($data = [ 1, 2, 3 ], '', 'a') },
    qr/^cannot write into reference of different type in void context/,
    'when root type of original and new data do not match, result must be assigned',
  );

  $data = [ 0, 1, 2 ];
  like(
    dies { jsonp_set($data, '/foo', 'foo') },
    qr/^cannot write hashref into a reference to an array in void context/,
    'cannot use a string path in an array at the top level without mutating',
  );

  $data = { a => 1 };
  jsonp_set($data, '', { foo => 1 }),
  cmp_result(
    $data,
    { foo => 1 },
    'assigning to the root hash overwrites all data',
  );

  $data = [ 1..3 ];
  jsonp_set($data, '', [ 4..6 ]),
  cmp_result(
    $data,
    [ 4..6 ],
    'assigning to the root array overwrites all data',
  );

  $data = { a => 1 };
  jsonp_set($data, '/', 3),
  cmp_result(
    $data,
    { '' => 3, a => 1 },
    'empty key is legal',
  );

  $data = { a => 1 };
  jsonp_set($data, '/a', 2),
  cmp_result(
    $data,
    { a => 2 },
    'an existing key is overwritten',
  );

  $data = { a => 1 };
  jsonp_set($data, '/b', 2),
  cmp_result(
    $data,
    { a => 1, b => 2 },
    'a new key is inserted',
  );

  $data = { a => { b => 1 } };
  jsonp_set($data, '/a/b', 2),
  cmp_result(
    $data,
    { a => { b => 2 } },
    'an existing key is overwritten at the second level',
  );

  $data = { a => { b => 1 } };
  jsonp_set($data, '/a/c', 2),
  cmp_result(
    $data,
    { a => { b => 1, c => 2 } },
    'a new key is added at the second level',
  );

  $data = { a => { b => 1 } };
  jsonp_set($data, '/c/d', 2),
  cmp_result(
    $data,
    { a => { b => 1 }, c => { d => 2 } },
    'a new key is added at the first level with data added at the second',
  );

  $data = { a => 1 };
  jsonp_set($data, '/a/b', { c => 1 });
  cmp_result(
    $data,
    { a => { b => { c => 1 } } },
    'a leaf node is overwritten with a hash',
  );

  $data = { a => 1 };
  jsonp_set($data, '/a/1/0', 2);
  cmp_result(
    $data,
    { a => [ undef, [ 2 ] ] },
    'a non-terminal node is overwritten with an array',
  );

  $data = { a => 1 };
  jsonp_set($data, '/a/b/c', { d => 1 });
  cmp_result(
    $data,
    { a => { b => { c => { d => 1 } } } },
    'a leaf node is overwritten with a deeper hash',
  );

  $data = [];
  jsonp_set($data, '/0', 1);
  cmp_result(
    $data,
    [ 1 ],
    'insert an array element at the first level',
  );

  $data = [ 1, 2, 3, 4 ];
  jsonp_set($data, '/2', 'a');
  cmp_result(
    $data,
    [ 1, 2, 'a', 4 ],
    'overwrite an array element at the first level',
  );

  $data = [ 4, 5, [ 6, 7, [ 1, 2 ] ] ];
  jsonp_set($data, '/2/1', 'a');
  cmp_result(
    $data,
    [ 4, 5, [ 6, 'a', [ 1, 2 ] ] ],
    'overwrite array entry at second level',
  );

  $data = [ 4, 5, 6 ];
  jsonp_set($data, '/2/1', 'a');
  cmp_result(
    $data,
    [ 4, 5, [ undef, 'a' ] ],
    'overwrite non-ref entry at second level',
  );

  $data = { a => 1 };
  jsonp_set($data, '/a/0', 3);
  cmp_result(
    $data,
    { a => [ 3 ] },
    'overwrote non-reference terminal node with an arrayref',
  );

  $data = { a => { b => 1 } };
  jsonp_set($data, '/a/0', 3);
  cmp_result(
    $data,
    { a => { b => 1, 0 => 3 } },
    'new data added at the second level in existing hash - numeric value treated as hash key',
  );

  $data = { a => [ 1, 2, 3 ] };
  jsonp_set($data, '/a/foo', 9);
  cmp_result(
    $data,
    { a => { foo => 9 } },
    'array data at terminal node overwritten by new hash',
  );

  $data = { a => [ 1, 2, 3 ] };
  jsonp_set($data, '/a/foo/0', 9);
  cmp_result(
    $data,
    { a => { foo => [ 9 ] } },
    'array data not at terminal node overwritten by new hash',
  );

  $data = { a => 1 };
  jsonp_set($data, '/a/b/0/c', 5);
  cmp_result(
    $data,
    { a => { b => [ { c => 5 } ] } },
    'deep autovivification, with both arrays and hashes',
  );

  $data = [ 0, 1 ];
  jsonp_set($data, '/0/1', 5);
  cmp_result(
    $data,
    [ [ undef, 5 ], 1 ],
    'a non-ref is overwritten with an arrayref',
  );

  $data = [ 0, 1 ];
  jsonp_set($data, '/3/a/b', 5);
  cmp_result(
    $data,
    [ 0, 1, undef, { a => { b => 5 } } ],
    'an array is extended with a hashref',
  );

  $data = [ 0, 1 ];
  jsonp_set($data, '/3/1/1', 5);
  cmp_result(
    $data,
    [ 0, 1, undef, [ undef, [ undef, 5 ] ] ],
    'an array is extended with an arrayref',
  );

  $data = {};
  jsonp_set($data, '/paths/~1foo~1{foo_id}/get/~0ether', { operationId => 'foo' });
  cmp_result(
    $data,
    { paths => { '/foo/{foo_id}' => { get => { '~ether' => { operationId => 'foo' } } } } },
    'json pointer escaping is done properly',
  );

  $data = { a => 1, b => { c => 3, d => 4 } };
  my $defaults = {
    '/b/d' => 5,
    '/b/e' => 6,
    '/f' => 7,
    '/g/h/i/1' => [ 10 ],
  };
  jsonp_set($data, $_, $defaults->{$_}) foreach keys %$defaults;
  cmp_result(
    $data,
    { a => 1, b => { c => 3, d => 5, e => 6 }, f => 7, g => { h => { i => [ undef, [ 10 ] ] } } },
    'pod example',
  );
};

done_testing;
