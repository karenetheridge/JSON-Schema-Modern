use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use if "$]" >= 5.022, 'experimental', 're_strict';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Test::Deep;
use Storable 'dclone';
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

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
        qr{^EXCEPTION: unable to find resource \#/\$defs/nowhere},
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
        qr{^EXCEPTION: unable to find resource \#nowhere},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

subtest '$id with an empty fragment' => sub {
  my $js = JSON::Schema::Modern->new(max_traversal_depth => 2);
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
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/type',
          absoluteKeywordLocation => 'http://localhost:4242/my_foo#/type',
          error => 'wrong type (expected string)',
        },
        {
          absoluteKeywordLocation => 'http://localhost:4242/my_foo',
          error => 'EXCEPTION: maximum evaluation depth exceeded',
          instanceLocation => '',
          keywordLocation => "/allOf/1/\$ref/\$ref",
        },
      ],
    },
    '$id with empty fragment can be found by $ref that did not include it; fragment not included in error either',
  );
};

$js = JSON::Schema::Modern->new(specification_version => 'draft2019-09');
subtest '$recursiveRef without nesting behaves like $ref' => sub {
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
      valid => false,
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
          error => 'not all additional properties are valid',
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
          error => 'not all additional properties are valid',
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

subtest '$recursiveRef without $recursiveAnchor behaves like $ref' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => { bar => 1 } },
      {
        properties => { foo => { '$recursiveRef' => '#' } },
        additionalProperties => false,
      },
    )->TO_JSON,
    {
      valid => false,
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
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    '$recursiveRef without $recursiveAnchor behaves like $ref',
  );
};

subtest '$recursiveAnchor must be at a schema resource root' => sub {
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
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs/myobject/$recursiveAnchor',
          error => '"$recursiveAnchor" keyword used without "$id"',
        },
      ],
    },
    '$recursiveAnchor can only appear at a schema resource root',
  );

  $schema = dclone($schema);
  $schema->{'$defs'}{myobject}{'$id'} = 'myobject.json';

  cmp_deeply(
    $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
    {
      valid => true,
    },
    'schema now valid when an $id is added',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        '$defs' => {
          inner => {
            '$recursiveAnchor' => true,   # this is illegal - canonical uri has a fragment
            type => [ qw(integer object) ],
            additionalProperties => { '$recursiveRef' => '#/$defs/inner' },
          },
        },
        type => 'object',
        additionalProperties => { '$recursiveRef' => '#/$defs/inner' },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs/inner/$recursiveAnchor',
          error => '"$recursiveAnchor" keyword used without "$id"',
        },
      ],
    },
    '$recursiveAnchor can only appear at a schema resource root',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        allOf => [
          {
            '$recursiveAnchor' => true,
            type => [ qw(integer object) ],
            additionalProperties => { '$recursiveRef' => '#/allOf/1' },
          },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$recursiveAnchor',
          error => '"$recursiveAnchor" keyword used without "$id"',
        },
      ],
    },
    'properly detecting a bad $recursiveAnchor even before passing through a $ref',
  );
};

subtest '$recursiveAnchor and $recursiveRef - standard usecases' => sub {
  my $schema = {
    '$id' => 'https://base.com',
    #'$recursiveAnchor' => true,  # the presence of this keyword changes everything
    type => [ 'object', 'integer' ],
    additionalProperties => {
      '$id' => 'https://innerbase.com',
      #'$recursiveAnchor' => true,  # the presence of this keyword changes everything
      type => [ 'object', 'boolean' ],
      additionalProperties => {
        '$ref' => '#',    # if this was a $recursiveRef and there are $recursiveAnchors, we will go to base.
      },
    },
  };

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/additionalProperties/additionalProperties/$ref/type',
          absoluteKeywordLocation => 'https://innerbase.com#/type',
          error => 'wrong type (expected one of object, boolean)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/additionalProperties',
          absoluteKeywordLocation => 'https://innerbase.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://base.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'validation requires the override that is not in scope',
  );

  # now make the ref a recursiveRef, but still won't recurse to base because no recursiveanchor.

  delete $js->{_resource_index};
  $schema->{additionalProperties}{additionalProperties}{'$recursiveRef'} =
    delete $schema->{additionalProperties}{additionalProperties}{'$ref'};

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        +{
          %{ $errors->[0] },
          keywordLocation => ($errors->[0]{keywordLocation} =~ s/ref/recursiveRef/r),
        },
        @{$errors}[1..2],
      ],
    },
    '$recursiveRef requires a $recursiveAnchor that does not exist',
  );

  # now we will recurse to the base.

  delete $js->{_resource_index};
  $schema->{'$recursiveAnchor'} = true;

  cmp_deeply(
    $js->evaluate({ foo => true }, $schema)->TO_JSON,
    {
      valid => true,
    },
    '$recursiveRef with both $recursiveAnchors in scope',
  );
};

subtest '$recursiveRef without $recursiveAnchor' => sub {
  my $schema = {
    '$id' => 'strings_only',
    '$defs' => {
      allow_ints => {
        '$id' => 'allow_ints',
        anyOf => [
          { type => 'integer' },
          { type => 'object', additionalProperties => { '$ref' => '#' } },
        ],
      },
    },
    anyOf => [
      { type => 'string' },
      { type => 'object', additionalProperties => { '$ref' => '#' } },
    ],
  };

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      $schema,
    )->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'strings_only#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$ref/anyOf/0/type',
          absoluteKeywordLocation => 'strings_only#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$ref/anyOf/1/type',
          absoluteKeywordLocation => 'strings_only#/anyOf/1/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$ref/anyOf',
          absoluteKeywordLocation => 'strings_only#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'strings_only#/anyOf/1/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          absoluteKeywordLocation => 'strings_only#/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    '$ref - one level recursion',
  );

  $js->{_resource_index} = {};

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      $js->_json_decoder->decode($js->_json_decoder->encode($schema) =~ s/\$ref/\$recursiveRef/gr),
    )->TO_JSON,
    {
      valid => false,
      errors => $js->_json_decoder->decode($js->_json_decoder->encode($errors) =~ s/\$ref/\$recursiveRef/gr),
    },
    '$recursiveRef with no $recursiveAnchor in scope has the same outcome',
  );
};

subtest '$recursiveAnchor in our dynamic scope, but not in the target schema' => sub {
  my $schema = {
    '$id' => 'base',
    '$recursiveAnchor' => true,
    anyOf => [
      { type => 'boolean' },
      {
        type => 'object',
        additionalProperties => {
          '$id' => 'inner',
          # note: no $recursiveAnchor here! so we do NOT recurse to the base.
          anyOf => [
            { type => 'integer' },
            { type => 'object', additionalProperties => { '$recursiveRef' => '#' } },
          ],
        },
      },
    ],
  };

  cmp_deeply(
    $js->evaluate(
      { foo => { bar => 1 } },
      $schema,
    )->TO_JSON,
    {
      valid => true,
    },
    '$recursiveAnchor does not exist in the target schema - local recursion only, so integers match',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => true },
      $schema,
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'base#/anyOf/0/type',
          error => 'wrong type (expected boolean)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/0/type',
          absoluteKeywordLocation => 'inner#/anyOf/0/type',
          error => 'wrong type (expected integer)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/type',
          absoluteKeywordLocation => 'inner#/anyOf/1/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf',
          absoluteKeywordLocation => 'inner#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'base#/anyOf/1/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          absoluteKeywordLocation => 'base#/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    '$recursiveAnchor does not exist in the target schema - no recursion',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => { bar => true } },
      $schema,
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'base#/anyOf/0/type',
          error => 'wrong type (expected boolean)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/0/type',
          absoluteKeywordLocation => 'inner#/anyOf/0/type',
          error => 'wrong type (expected integer)',
        },
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/additionalProperties/$recursiveRef/anyOf/0/type',
          absoluteKeywordLocation => 'inner#/anyOf/0/type',
          error => 'wrong type (expected integer)',
        },
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/type',
          absoluteKeywordLocation => 'inner#/anyOf/1/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/additionalProperties/$recursiveRef/anyOf',
          absoluteKeywordLocation => 'inner#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'inner#/anyOf/1/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf',
          absoluteKeywordLocation => 'inner#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'base#/anyOf/1/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          absoluteKeywordLocation => 'base#/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    '$recursiveAnchor does not exist in the target schema - local recursion only',
  );
};

$js = JSON::Schema::Modern->new;
subtest '$dynamicRef without nesting behaves like $ref' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => { bar => 'hello', baz => 1 } },
      {
        '$id' => 'http://localhost:4242',
        '$dynamicAnchor' => 'hi',
        anyOf => [
          { type => 'string' },
          {
            type => 'object',
            additionalProperties => { '$dynamicRef' => '#hi' },
          },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        # /anyOf/1 with ''
        # /anyOf/1/additionalProperties/$dynamicRef with '/foo'
        # /anyOf/1/additionalProperties/$dynamicRef/anyOf/0 - wrong type
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        # /anyOf/1/additionalProperties/$dynamicRef/anyOf/1 with /foo
        # additionalProperties:  consider /foo/bar
        # /anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef
        # /anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef/anyOf/0 - is string, so no error
        # /anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef/anyOf/1 - is object
        # additionalProperties:  consider /foo/baz
        # is neither string or object
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf',
          error => 'no subschemas are valid',
        },
        # and now we start to unwind.
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/additionalProperties',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    '$dynamicRef without nested $dynamicAnchor behaves like $ref',
  );
};

subtest '$recursiveRef without $dynamicAnchor behaves like $ref' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => { bar => 1 } },
      {
        properties => { foo => { '$dynamicRef' => '#' } },
        additionalProperties => false,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/properties/foo/$dynamicRef/additionalProperties',
          absoluteKeywordLocation => '#/additionalProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/$dynamicRef/additionalProperties',
          absoluteKeywordLocation => '#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    '$dynamicRef without $dynamicAnchor behaves like $ref',
  );
};

subtest '$dynamicAnchor and $dynamicRef - standard usecases' => sub {
  my $schema = {
    '$id' => 'https://base.com',
    #'$dynamicAnchor' => 'thingy',        # adding this, and changing the $ref, will make us recurse here.
    type => [ 'object', 'integer' ],
    additionalProperties => {
      '$id' => 'https://innerbase.com',   # without $dynamicRef, we will recurse here.
      #'$dynamicAnchor' => 'thingy',
      type => [ 'object', 'boolean' ],
      additionalProperties => {
        '$ref' => '#',    # if this was a $dynamicRef and there are $dynamicAnchors, we will go to base.
      },
    },
  };

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/additionalProperties/additionalProperties/$ref/type',
          absoluteKeywordLocation => 'https://innerbase.com#/type',
          error => 'wrong type (expected one of object, boolean)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/additionalProperties',
          absoluteKeywordLocation => 'https://innerbase.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://base.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'validation requires the override that is not in scope',
  );

  # now make the ref a dynamicRef, but still won't recurse to base because no dynamicanchor.

  delete $js->{_resource_index};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} =
    delete $schema->{additionalProperties}{additionalProperties}{'$ref'}; # '#'
  $errors->[0]{keywordLocation} =~ s/ref/dynamicRef/;

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    '$dynamicRef requires a $dynamicAnchor that does not exist',
  );

  # we still won't recurse to the base because $dynamicRef doesn't use the anchor URI.
  delete $js->{_resource_index};
  $schema->{additionalProperties}{'$dynamicAnchor'} = 'thingy';

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    '$dynamicRef must use a URI containing the dynamic anchor fragment',
  );

  # use the anchor URI for $dynamicRef, but we still won't recurse to the base because there is no
  # outer $dynamicAnchor.
  delete $js->{_resource_index};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#thingy';

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'there is no outer $dynamicAnchor in scope to recurse to',
  );

  # XXX one more:  change dynamicref back to ref, but use the fragment uri.
  delete $js->{_resource_index};
  $schema->{additionalProperties}{additionalProperties}{'$ref'} =
    delete $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'}; # '#thingy'
  $errors->[0]{keywordLocation} =~ s/dynamicRef/ref/;

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'we have an outer $dynamicAnchor, and are using the fragment URI, but we used $ref rather than $dynamicRef',
  );

  # now add a $dynamicAnchor to base, but we still won't recurse to the base because $dynamicRef
  # doesn't use the anchor.
  delete $js->{_resource_index};
  delete $schema->{additionalProperties}{additionalProperties}{'$ref'};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#';
  $schema->{'$dynamicAnchor'} = 'thingy';
  $errors->[0]{keywordLocation} =~ s/ref/dynamicRef/;

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'there is an outer $dynamicAnchor in scope to recurse to, but $dynamicRef must use a URI containing the dynamic anchor fragment',
  );

  delete $js->{_resource_index};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#thingy';

  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => true,
    },
    'now everything is in place to recurse to the base',
  );

  delete $js->{_resource_index};
  delete $schema->{additionalProperties}{'$dynamicAnchor'};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#';
  cmp_deeply(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'there is no $dynamicAnchor at the original target, and no anchor used in the target URI',
  );
};

subtest '$dynamicRef to $dynamicAnchor not directly in the evaluation path' => sub {
  delete $js->{_resource_index};
  my $schema = {
    '$id' => 'base',
    '$defs' => {
      override => {
        # this is in base uri 'base'
        #'$dynamicAnchor' => 'thingy',
        type => 'number',
      },
      start => {
        '$id' => 'start',
        '$defs' => {
          main => {
            # start#thingy
            '$dynamicAnchor' => 'thingy',
            type => 'string',
          },
        },
        '$dynamicRef' => '#thingy',   # -> start#thingy ( -> base#thingy ), when second anchor is in place
      },
    },
    '$ref' => 'start',
  };

  cmp_deeply(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$dynamicRef/type',
          absoluteKeywordLocation => 'start#/$defs/main/type',
          error => 'wrong type (expected string)',
        },
      ],
    },
    'second dynamic anchor is not in the evaluation path, but we found it via dynamic scope - type does not match',
  );

  delete $js->{_resource_index};
  $schema->{'$defs'}{override}{'$anchor'} = 'thingy';

  cmp_deeply(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'regular $anchor in dynamic scope should not be used by $dynamicRef',
  );

  delete $js->{_resource_index};
  delete $schema->{'$defs'}{override}{'$anchor'};
  $schema->{'$defs'}{override}{'$dynamicAnchor'} = 'some_other_thingy';

  cmp_deeply(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'some other $dynamicAnchor in dynamic scope should not be used by $dynamicRef',
  );

  delete $js->{_resource_index};
  $schema->{'$defs'}{override}{'$dynamicAnchor'} = 'thingy';

  cmp_deeply(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => true,
    },
    'second dynamic anchor is not in the evaluation path, but we found it via dynamic scope - type matches',
  );

  delete $js->{_resource_index};
  my $canonical_uri = delete $schema->{'$id'};

  $js->add_schema($canonical_uri => $schema);
  cmp_deeply(
    $js->evaluate(42, $canonical_uri)->TO_JSON,
    {
      valid => true,
    },
    'the first dynamic scope is set by document uri, not just the $id keyword',
  );
};

subtest 'after leaving a dynamic scope, it should not be used by a $dynamicRef' => sub {
  delete $js->{_resource_index};
  my $schema = {
    '$id' => 'main',
    if => {
      '$id' => 'first_scope',
      '$defs' => {
        thingy => {
          # this is first_scope#thingy
          '$dynamicAnchor' => 'thingy',
          type => 'number',
        },
      },
    },
    'then' => {
      '$id' => 'second_scope',
      '$ref' => 'start',
      '$defs' => {
        'thingy' => {
          # this is second_scope#thingy, the final destination of the $dynamicRef
          '$dynamicAnchor' => 'thingy',
          type => 'null',
        },
      },
    },
    '$defs' => {
      start => {
        # this is the landing spot from $ref
        '$id' => 'start',
        '$dynamicRef' => 'inner_scope#thingy',
      },
      'thingy' => {
        # this is the first stop by the $dynamicRef
        '$id' => 'inner_scope',
        '$dynamicAnchor' => 'thingy',
        type => 'string',
      }
    }
  };

  cmp_deeply(
    $js->evaluate(undef, $schema)->TO_JSON,
    {
      valid => true,
    },
    'first_scope is no longer in scope, so it is not used by $dynamicRef',
  );
};

subtest 'anchors do not match' => sub {
  delete $js->{_resource_index};
  my $schema = {
    '$defs' => {
      enhanced => {
        '$dynamicAnchor' => 'thingy', # change this to $anchor and watch what happens
        minimum => 2,
      },
      orig => {
        '$id' => 'orig',
        '$dynamicAnchor' => 'thingy',
        minimum => 10,
      },
    },
    '$dynamicRef' => 'orig#thingy',
  };

  cmp_deeply(
    $js->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$dynamicRef/minimum',
          absoluteKeywordLocation => '#/$defs/enhanced/minimum',
          error => 'value is smaller than 2',
        },
      ],
    },
    '$dynamicRef goes to enhanced schema',
  );

  delete $js->{_resource_index};
  $schema->{'$defs'}{enhanced}{'$anchor'} = delete $schema->{'$defs'}{enhanced}{'$dynamicAnchor'};
  $schema->{'$defs'}{enhanced}{'$dynamicAnchor'} = 'somethingelse';

  cmp_deeply(
    $js->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$dynamicRef/minimum',
          absoluteKeywordLocation => 'orig#/minimum',
          error => 'value is smaller than 10',
        },
      ],
    },
    '$dynamicRef -> $dynamicAnchor -> $anchor is a no go: we stay at the original schema',
  );
};

done_testing;
