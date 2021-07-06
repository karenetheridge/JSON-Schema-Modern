use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
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

done_testing;
