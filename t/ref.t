# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
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

use Storable 'dclone';
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

subtest 'local JSON pointer' => sub {
  cmp_result(
    $js->evaluate(true, { '$defs' => { true => true }, '$ref' => '#/$defs/true' })->TO_JSON,
    { valid => true },
    'can follow local $ref to a true schema',
  );

  cmp_result(
    $js->evaluate(true, { '$defs' => { false => false }, '$ref' => '#/$defs/false' })->TO_JSON,
    superhashof({ valid => false }),
    'can follow local $ref to a false schema',
  );

  ok(
    lives {
      my $result = $js->evaluate(true, { '$ref' => '#/$defs/nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{^EXCEPTION: unable to find resource "\#/\$defs/nowhere"},
        'got error for unresolvable ref',
      );
    },
    'no exception',
  );
};

subtest 'fragment with URI-escaped and JSON Pointer-escaped characters' => sub {
  cmp_result(
    $js->evaluate(
      1,
      {
        '$defs' => { 'foo-bar-tilde~-slash/-braces{}-def' => true },
        '$ref' => '#/$defs/foo-bar-tilde~0-slash~1-braces%7B%7D-def',
      },
    )->TO_JSON,
    { valid => true },
    'can follow $ref with escaped components',
  );
};

subtest 'local anchor' => sub {
  cmp_result(
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
    )->TO_JSON,
    { valid => true },
    'can follow local $ref to an $anchor to a true schema',
  );

  cmp_result(
    $js->evaluate(
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
    )->TO_JSON,
    superhashof({ valid => false }),
    'can follow local $ref to an $anchor to a false schema',
  );

  is(
    dies {
      my $result = $js->evaluate(true, { '$ref' => '#nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{^EXCEPTION: unable to find resource "\#nowhere"},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

subtest '$id with an empty fragment' => sub {
  my $js = JSON::Schema::Modern->new(max_traversal_depth => 2);
  cmp_result(
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
          error => 'got integer, not string',
        },
        {
          absoluteKeywordLocation => 'http://localhost:4242/my_foo',
          error => 'EXCEPTION: maximum evaluation depth (2) exceeded',
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
  cmp_result(
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
          error => 'got object, not string',
        },
        # /anyOf/1 with ''
        # /anyOf/1/additionalProperties/$recursiveRef with '/foo'
        # /anyOf/1/additionalProperties/$recursiveRef/anyOf/0 - wrong type
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'got object, not string',
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
          error => 'got integer, not string',
        },
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/type',
          error => 'got integer, not object',
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
  cmp_result(
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

  cmp_result(
    $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          keywordLocation => '/$defs/myobject/$recursiveAnchor',
          error => '"$recursiveAnchor" keyword used without "$id"',
        },
      ],
    },
    '$recursiveAnchor can only appear at a schema resource root',
  );

  $schema = dclone($schema);
  $schema->{'$defs'}{myobject}{'$id'} = 'myobject.json';

  cmp_result(
    $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
    {
      valid => true,
    },
    'schema now valid when an $id is added',
  );

  cmp_result(
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
          keywordLocation => '/$defs/inner/$recursiveAnchor',
          error => '"$recursiveAnchor" keyword used without "$id"',
        },
      ],
    },
    '$recursiveAnchor can only appear at a schema resource root',
  );

  cmp_result(
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

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/additionalProperties/additionalProperties/$ref/type',
          absoluteKeywordLocation => 'https://innerbase.com#/type',
          error => 'got integer, not one of object, boolean',
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

  $js->{_resource_index} = {};
  $schema->{additionalProperties}{additionalProperties}{'$recursiveRef'} =
    delete $schema->{additionalProperties}{additionalProperties}{'$ref'};

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        +{
          $errors->[0]->%*,
          keywordLocation => ($errors->[0]{keywordLocation} =~ s/ref/recursiveRef/r),
        },
        $errors->@[1..2],
      ],
    },
    '$recursiveRef requires a $recursiveAnchor that does not exist',
  );

  # now we will recurse to the base.

  $js->{_resource_index} = {};
  $schema->{'$recursiveAnchor'} = true;

  cmp_result(
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

  cmp_result(
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
          error => 'got object, not string',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$ref/anyOf/0/type',
          absoluteKeywordLocation => 'strings_only#/anyOf/0/type',
          error => 'got integer, not string',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$ref/anyOf/1/type',
          absoluteKeywordLocation => 'strings_only#/anyOf/1/type',
          error => 'got integer, not object',
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

  cmp_result(
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

  cmp_result(
    $js->evaluate(
      { foo => { bar => 1 } },
      $schema,
    )->TO_JSON,
    {
      valid => true,
    },
    '$recursiveAnchor does not exist in the target schema - local recursion only, so integers match',
  );

  cmp_result(
    $js->evaluate(
      { foo => true },
      'base',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'base#/anyOf/0/type',
          error => 'got object, not boolean',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/0/type',
          absoluteKeywordLocation => 'inner#/anyOf/0/type',
          error => 'got boolean, not integer',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/type',
          absoluteKeywordLocation => 'inner#/anyOf/1/type',
          error => 'got boolean, not object',
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

  cmp_result(
    $js->evaluate(
      { foo => { bar => true } },
      'base',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/type',
          absoluteKeywordLocation => 'base#/anyOf/0/type',
          error => 'got object, not boolean',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/0/type',
          absoluteKeywordLocation => 'inner#/anyOf/0/type',
          error => 'got object, not integer',
        },
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/additionalProperties/$recursiveRef/anyOf/0/type',
          absoluteKeywordLocation => 'inner#/anyOf/0/type',
          error => 'got boolean, not integer',
        },
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/anyOf/1/additionalProperties/anyOf/1/additionalProperties/$recursiveRef/anyOf/1/type',
          absoluteKeywordLocation => 'inner#/anyOf/1/type',
          error => 'got boolean, not object',
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
  cmp_result(
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
          error => 'got object, not string',
        },
        # /anyOf/1 with ''
        # /anyOf/1/additionalProperties/$dynamicRef with '/foo'
        # /anyOf/1/additionalProperties/$dynamicRef/anyOf/0 - wrong type
        {
          instanceLocation => '/foo',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/0/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/0/type',
          error => 'got object, not string',
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
          error => 'got integer, not string',
        },
        {
          instanceLocation => '/foo/baz',
          keywordLocation => '/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/additionalProperties/$dynamicRef/anyOf/1/type',
          absoluteKeywordLocation => 'http://localhost:4242#/anyOf/1/type',
          error => 'got integer, not object',
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
  cmp_result(
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

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '/foo/bar',
          keywordLocation => '/additionalProperties/additionalProperties/$ref/type',
          absoluteKeywordLocation => 'https://innerbase.com#/type',
          error => 'got integer, not one of object, boolean',
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

  $js->{_resource_index} = {};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} =
    delete $schema->{additionalProperties}{additionalProperties}{'$ref'}; # '#'
  $errors->[0]{keywordLocation} =~ s/ref/dynamicRef/;

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    '$dynamicRef requires a $dynamicAnchor that does not exist',
  );

  # we still won't recurse to the base because $dynamicRef doesn't use the anchor URI.
  $js->{_resource_index} = {};
  $schema->{additionalProperties}{'$dynamicAnchor'} = 'thingy';

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    '$dynamicRef must use a URI containing the dynamic anchor fragment',
  );

  # use the anchor URI for $dynamicRef, but we still won't recurse to the base because there is no
  # outer $dynamicAnchor.
  $js->{_resource_index} = {};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#thingy';

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'there is no outer $dynamicAnchor in scope to recurse to',
  );

  # change $dynamicRef back to $ref, but use the fragment uri.
  $js->{_resource_index} = {};
  $schema->{additionalProperties}{additionalProperties}{'$ref'} =
    delete $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'}; # '#thingy'
  $errors->[0]{keywordLocation} =~ s/dynamicRef/ref/;

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'we have an outer $dynamicAnchor, and are using the fragment URI, but we used $ref rather than $dynamicRef',
  );

  # now add a $dynamicAnchor to base, but we still won't recurse to the base because $dynamicRef
  # doesn't use the anchor.
  $js->{_resource_index} = {};
  delete $schema->{additionalProperties}{additionalProperties}{'$ref'};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#';
  $schema->{'$dynamicAnchor'} = 'thingy';
  $errors->[0]{keywordLocation} =~ s/ref/dynamicRef/;

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'there is an outer $dynamicAnchor in scope to recurse to, but $dynamicRef must use a URI containing the dynamic anchor fragment',
  );

  $js->{_resource_index} = {};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#thingy';

  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => true,
    },
    'now everything is in place to recurse to the base',
  );

  $js->{_resource_index} = {};
  delete $schema->{additionalProperties}{'$dynamicAnchor'};
  $schema->{additionalProperties}{additionalProperties}{'$dynamicRef'} = '#';
  cmp_result(
    $js->evaluate({ foo => { bar => 1 } }, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'there is no $dynamicAnchor at the original target, and no anchor used in the target URI',
  );
};

subtest '$dynamicRef to $dynamicAnchor not directly in the evaluation path' => sub {
  $js->{_resource_index} = {};
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

  cmp_result(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$dynamicRef/type',
          absoluteKeywordLocation => 'start#/$defs/main/type',
          error => 'got integer, not string',
        },
      ],
    },
    'second dynamic anchor is not in the evaluation path, but we found it via dynamic scope - type does not match',
  );

  $js->{_resource_index} = {};
  $schema->{'$defs'}{override}{'$anchor'} = 'thingy';

  cmp_result(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'regular $anchor in dynamic scope should not be used by $dynamicRef',
  );

  $js->{_resource_index} = {};
  delete $schema->{'$defs'}{override}{'$anchor'};
  $schema->{'$defs'}{override}{'$dynamicAnchor'} = 'some_other_thingy';

  cmp_result(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'some other $dynamicAnchor in dynamic scope should not be used by $dynamicRef',
  );

  $js->{_resource_index} = {};
  $schema->{'$defs'}{override}{'$dynamicAnchor'} = 'thingy';

  cmp_result(
    $js->evaluate(42, $schema)->TO_JSON,
    {
      valid => true,
    },
    'second dynamic anchor is not in the evaluation path, but we found it via dynamic scope - type matches',
  );

  $js->{_resource_index} = {};
  my $canonical_uri = delete $schema->{'$id'};

  $js->add_schema($canonical_uri => $schema);
  cmp_result(
    $js->evaluate(42, $canonical_uri)->TO_JSON,
    {
      valid => true,
    },
    'the first dynamic scope is set by document uri, not just the $id keyword',
  );
};

subtest 'multiple layers in the dynamic scope' => sub {
  $js->{_resource_index} = {};
  my $schema = {
    # We $ref from base -> first#/$defs/stuff -> second#/$defs/stuff -> third#/$defs/stuff
    # and then follow a $dynamicRef to #length.
    # At no point do we ever actually evaluate at the root schema for each scope.
    # The dynamic scope is [ base, first, second, third ] and we check the scopes in order,
    # therefore the first scope we find with a dynamic anchor "length" is "second".
    '$id' => 'base',
    '$ref' => 'first#/$defs/stuff',
    '$defs' => {
      first => {
        '$id' => 'first',
        '$defs' => {
          stuff => {    # first#/$defs/stuff
            '$ref' => 'second#/$defs/stuff',
          },
          length => {   # first#length
            # no $dynamicAnchor here!
            maxLength => 1,
          },
        },
      },
      second => {
        '$id' => 'second',
        '$defs' => {
          stuff => {    # second#/$defs/stuff
            '$ref' => 'third#/$defs/stuff',
          },
          length => {   # second#length
            '$dynamicAnchor' => 'length',
            maxLength => 2,               # <-- this is the scope that we should find and evaluate
          },
        },
      },
      third => {
        '$id' => 'third',
        '$defs' => {
          stuff => {    # third#/$defs/stuff
            '$dynamicRef' => '#length',
          },
          length => {   # third#length
            '$dynamicAnchor' => 'length',
            maxLength => 3,         # this should never get evaluated
          }
        },
      },
    },
  };
  cmp_result(
    $js->evaluate('hello', $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/$ref/$dynamicRef/maxLength',
          absoluteKeywordLocation => 'second#/$defs/length/maxLength',
          error => 'length is greater than 2',
        },
      ],
    },
    'dynamic scopes are pushed onto the stack even when its root resource (and $id keyword) are not directly evaluated',
  );
};

subtest 'after leaving a dynamic scope, it should not be used by a $dynamicRef' => sub {
  $js->{_resource_index} = {};
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

  cmp_result(
    $js->evaluate(undef, $schema)->TO_JSON,
    {
      valid => true,
    },
    'first_scope is no longer in scope, so it is not used by $dynamicRef',
  );
};

subtest 'anchors do not match' => sub {
  $js->{_resource_index} = {};
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

  cmp_result(
    $js->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$dynamicRef/minimum',
          absoluteKeywordLocation => '#/$defs/enhanced/minimum',
          error => 'value is less than 2',
        },
      ],
    },
    '$dynamicRef goes to enhanced schema',
  );

  $js->{_resource_index} = {};
  $schema->{'$defs'}{enhanced}{'$anchor'} = delete $schema->{'$defs'}{enhanced}{'$dynamicAnchor'};
  $schema->{'$defs'}{enhanced}{'$dynamicAnchor'} = 'somethingelse';

  cmp_result(
    $js->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$dynamicRef/minimum',
          absoluteKeywordLocation => 'orig#/minimum',
          error => 'value is less than 10',
        },
      ],
    },
    '$dynamicRef -> $dynamicAnchor -> $anchor is a no go: we stay at the original schema',
  );
};

subtest 'reference to a non-schema location' => sub {
  $js->{_resource_index} = {};
  my $schema = {
    example => { not_a_schema => true },
    '$defs' => {
      anchor => {
        '$dynamicAnchor' => 'my_anchor',
        '$dynamicRef' => '#/example/not_a_schema',
      },
    },
    type => 'object',
    properties => {
      '$ref' => {
        '$ref' => '#/example/not_a_schema',
      },
      '$dynamicRef' => {
        '$dynamicRef' => '#/example/not_a_schema',
      },
    },
  };

  cmp_result(
    $js->evaluate({ '$ref' => 1 }, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/$ref',
          keywordLocation => '/properties/$ref/$ref',
          error => 'EXCEPTION: bad reference to "#/example/not_a_schema": not a schema',
        },
      ],
    },
    '$ref to a non-schema is not permitted',
  );

  cmp_result(
    $js->evaluate({ '$dynamicRef' => 1 }, '')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/$dynamicRef',
          keywordLocation => '/properties/$dynamicRef/$dynamicRef',
          error => 'EXCEPTION: bad reference to "#/example/not_a_schema": not a schema',
        },
      ],
    },
    '$dynamicRef to a non-schema is not permitted',
  );

  $js->{_resource_index} = {};
  $schema = {
    '$id' => '/foo',
    '$schema' => 'https://json-schema.org/draft/2019-09/schema',
    '$recursiveAnchor' => true,
    example => { not_a_schema => true },
    type => 'object',
    properties => {
      '$recursiveRef' => {
        '$recursiveRef' => '#/example/not_a_schema',
      },
    },
  };

  cmp_result(
    $js->evaluate({ '$recursiveRef' => 1 }, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/$recursiveRef',
          keywordLocation => '/properties/$recursiveRef/$recursiveRef',
          absoluteKeywordLocation => '/foo#/properties/$recursiveRef/$recursiveRef',
          error => 'EXCEPTION: bad reference to "/foo#/example/not_a_schema": not a schema',
        },
      ],
    },
    '$recursiveRef to a non-schema is not permitted',
  );

  package MyDocument {
    use strict; use warnings;
    use Moo;
    extends 'JSON::Schema::Modern::Document';
    use experimental 'signatures';

    sub traverse ($self, @) {
      return {
        initial_schema_uri => $self->canonical_uri,
        errors => [],
        specification_version => 'draft2020-12',
        vocabularies => [],
        identifiers => {},
        subschemas => [],
      };
    }
  };

  $js->{_resource_index} = {};

  my $doc = MyDocument->new(
    schema => [ 'not a json schema' ],
    canonical_uri => 'https://my_non_schema',
  );
  $js->add_document($doc);

  $schema = {
    '$id' => '/foo',
    '$schema' => 'https://my_non_schema',
  };

  cmp_result(
    $js->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          keywordLocation => '/$schema',
          # we haven't processed $id yet, so we don't know the absolute location
          error => 'EXCEPTION: bad reference to $schema "https://my_non_schema": not a schema',
        },
      ],
    },
    '$schema to a non-schema is not permitted',
  );
};

subtest 'evaluate at a non-schema location' => sub {
  $js->{_resource_index} = {};
  $js->add_schema('http://my_schema', { example => { not_a_schema => true } });

  cmp_result(
    $js->evaluate(1, 'http://my_schema#/example/not_a_schema')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'EXCEPTION: "http://my_schema#/example/not_a_schema" is not a schema',
        },
      ],
    },
    'evaluating at a non-schema location is not permitted',
  );
};

subtest 'evaluate at a subschema, with $dynamicRef' => sub {
  # from a real bug I encountered while writing a t/parameters.t test in OpenAPI-Modern!
  # if we evaluate in the middle of a document, and a $dynamicRef is involved, mayhem ensues.
  $js->{_resource_index} = {};
  $js->add_schema({
    '$id' => 'http://strict_metaschema',
    '$defs' => {
      schema => {
        '$dynamicAnchor' => 'meta',
        type => 'object', # disallows boolean
      },
      parameter => {
        '$ref' => 'http://loose_metaschema#/$defs/parameter',
      },
    },
    '$ref' => 'http://loose_metaschema#/intentionally/bad/reference',
  });

  $js->add_schema({
    '$id' => 'http://loose_metaschema',
    '$defs' => {
      schema => {
        '$dynamicAnchor' => 'meta',
        type => [ 'object', 'boolean' ],
      },
      parameter => {
        type => 'object',
        properties => {
          name => { type => 'string' },
          schema => { '$dynamicRef' => '#meta' },
        },
      },
    },
  });

  cmp_result(
    $js->evaluate(
      { name => 'hi', schema => false },
      'http://strict_metaschema#/$defs/parameter',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/schema',
          keywordLocation => '/$ref/properties/schema/$dynamicRef/type',
          absoluteKeywordLocation => 'http://strict_metaschema#/$defs/schema/type',
          error => 'got boolean, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/properties',
          absoluteKeywordLocation => 'http://loose_metaschema#/$defs/parameter/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'correctly navigated a $dynamicRef while evaluating in the middle of a document',
  );
};

done_testing;
