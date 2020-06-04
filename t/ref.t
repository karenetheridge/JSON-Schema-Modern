use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

subtest 'local JSON pointer' => sub {
  ok($js->evaluate(true, { '$defs' => { true => true }, '$ref' => '#/$defs/true' }),
    'can follow local $ref to a true schema');

  ok(!$js->evaluate(true, { '$defs' => { false => false }, '$ref' => '#/$defs/false' }),
    'can follow local $ref to a false schema');

  is(
    exception {
      my $result = $js->evaluate(true, { '$ref' => '#/$defs/nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{unable to find resource \#/\$defs/nowhere},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

subtest 'fragment with URI-escaped and JSON Pointer-escaped characters' => sub {
  ok(
    $js->evaluate(
      1,
      {
        '$defs' => { 'foo-bar-tilde~-slash/-braces{}-def' => true },
        '$ref' => '#/$defs/foo-bar-tilde~0-slash~1-braces%7B%7D-def',
      },
    ),
    'can follow $ref with escaped components',
  );
};

subtest 'local anchor' => sub {
  ok(
    $js->evaluate(
      true,
      {
        '$defs' => {
          true => {
            '$anchor' => 'true',
          },
        },
        '$ref' => '#true',
      },
    ),
    'can follow local $ref to an $anchor to a true schema',
  );

  ok(
    !$js->evaluate(
      true,
      {
        '$defs' => {
          false => {
            '$anchor' => 'false',
            not => true,
          },
        },
        '$ref' => '#false',
      },
    ),
    'can follow local $ref to an $anchor to a false schema',
  );

  is(
    exception {
      my $result = $js->evaluate(true, { '$ref' => '#nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{unable to find resource \#nowhere},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

subtest '$id with an empty fragment' => sub {
  my $js = JSON::Schema::Draft201909->new(max_traversal_depth => 2);
  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$defs' => {
          foo => {
            '$id' => 'http://localhost:4242/my_foo#',
            type => 'string',
          },
          reference_to_foo => {
            '$ref' => 'http://localhost:4242/my_foo',
          },
        },
        allOf => [
          { '$ref' => 'http://localhost:4242/my_foo' },
          { '$ref' => '#/$defs/reference_to_foo' },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/type',
          absoluteKeywordLocation => 'http://localhost:4242/my_foo#/type',
          error => 'wrong type (expected string)',
        },
        {
          absoluteKeywordLocation => 'http://localhost:4242/my_foo',
          error => 'EXCEPTION: maximum traversal depth exceeded',
          instanceLocation => '',
          keywordLocation => "/allOf/1/\$ref/\$ref",
        },
      ],
    },
    '$id with empty fragment can be found by $ref that did not include it; fragment not included in error either',
  );
};

subtest '$recursiveRef without nesting' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => { bar => 'hello', baz => 1 } },
      {
        '$id' => 'http://localhost:4242',
        '$recursiveAnchor' => true,
        anyOf => [
          { type => 'string' },
          {
            type => 'object',
            additionalProperties => { '$recursiveRef' => '#' },
          },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        # /anyOf/1 with ''
        # /anyOf/1/additionalProperties/$recursiveRef with '/foo'
        # /anyOf/1/additionalProperties/$recursiveRef/anyOf/0 - wrong type
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        # /anyOf/1/additionalProperties/$recursiveRef/anyOf/1 with /foo
        # additionalProperties:  consider /foo/bar
        # /anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef
        # /anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef/anyOf/0 - is string, so no error
        # /anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef/anyOf/1 - is object
        # additionalProperties:  consider /foo/baz
        # is neither string or object
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf',
          error => 'no subschemas are valid',
        },
        # and now we start to unwind.
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/additionalProperties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/additionalProperties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    '$recursiveRef without nested $recursiveAnchor behaves like $ref',
  );
};

subtest '$recursiveRef without $recursiveAnchor' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => { bar => 1 } },
      {
        properties => { foo => { '$recursiveRef' => '#' } },
        additionalProperties => false,
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/properties/foo/$recursiveRef/additionalProperties',
          absoluteKeywordLocation => '#/additionalProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/$recursiveRef/additionalProperties',
          absoluteKeywordLocation => '#/additionalProperties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
  );
};

subtest '$recursiveAnchor is not at a schema resource root' => sub {
  my $schema = {
    '$defs' => {
      myobject => {
        '$recursiveAnchor' => true,
        anyOf => [
          { type => 'integer' },
          {
            type => 'object',
            additionalProperties => { '$recursiveRef' => '#' },
          },
        ],
      },
    },
    anyOf => [
      { type => 'integer' },
      { '$ref' => '#/$defs/myobject' },
    ],
  };

  cmp_deeply(
    $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/$ref/$recursiveAnchor',
          absoluteKeywordLocation => '#/$defs/myobject/$recursiveAnchor',
          error => 'EXCEPTION: "$recursiveAnchor" keyword used without "$id"',
        },
      ],
    },
  );

  $schema->{'$defs'}{myobject}{'$id'} = 'myobject.json';

  cmp_deeply(
    $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
    {
      valid => bool(1),
    },
  );
};

subtest '$recursiveAnchor and $recursiveRef - standard usecases' => sub {
  my $schema = {
    '$defs' => {
      allow_ints => {
        '$recursiveAnchor' => true,
        anyOf => [
          { '$ref' => '#/$defs/base' },   # the base: all leaf nodes must be booleans
          { type => 'integer' },          # or, integers are okay too
        ],
      },
      base => {
        '$recursiveAnchor' => true,
        anyOf => [
          { type => 'boolean' },
          {
            type => 'object',
            additionalProperties => { '$recursiveRef' => '#' }, # allow schema mods here too
          },
        ],
      },
    },
    '$recursiveAnchor' => true,
    # here is where I insert a $ref to whatever subschema I want.
  };

  cmp_deeply(
    $js->evaluate(
      { foo => true },
      { %$schema, '$ref' => '#/$defs/base' },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    '$recursiveRef with a single $recursiveAnchor in scope',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      { %$schema, '$ref' => '#/$defs/base' },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
# 0 data: ''       schema: $ref/anyOf/0  - fails, not bool
#   data: /foo   schema: $ref/anyOf/0/additionalProperties/$recursiveRef
# 1 data: /foo   schema: $ref/anyOf/0/additionalProperties/$recursiveRef/anyOf/0/type       # - fails, not bool
# 2 data: /foo/1 schema: $ref/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/type       # - fails, not object.
# 3                        $ref/anyOf/1/additionalProperties/$recursiveRef/anyOf fails
# 4                        $ref/anyOf/1/additionalProperties fails
# 5                        $ref/anyOf fails
        {
          instanceLocation => '',
          keywordLocation => '/$ref/anyOf/0/type',
          absoluteKeywordLocation => '#/$defs/base/anyOf/0/type',
          error => 'wrong type (expected boolean)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/$ref/anyOf/1/additionalProperties/$recursiveRef/$ref/anyOf/0/type',
          absoluteKeywordLocation => '#/$defs/base/anyOf/0/type',
          error => 'wrong type (expected boolean)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/$ref/anyOf/1/additionalProperties/$recursiveRef/$ref/anyOf/1/type',
          absoluteKeywordLocation => '#/$defs/base/anyOf/1/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/$ref/anyOf/1/additionalProperties/$recursiveRef/$ref/anyOf',
          absoluteKeywordLocation => '#/$defs/base/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/anyOf/1/additionalProperties',
          absoluteKeywordLocation => '#/$defs/base/anyOf/1/additionalProperties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/anyOf',
          absoluteKeywordLocation => '#/$defs/base/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    'validation requires the override that is not in scope',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => true },
      { %$schema, '$ref' => '#/$defs/allow_ints' },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    '$recursiveRef with both $recursiveAnchors in scope',
  );

  cmp_deeply(
    $js->evaluate(
      {
        foo => 1,
      },
      $schema,
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'validation makes use of the override that is now in scope',
  );
};

done_testing;
