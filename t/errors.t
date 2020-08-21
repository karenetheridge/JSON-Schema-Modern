use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new(short_circuit => 0);
my $js_short = JSON::Schema::Draft201909->new(short_circuit => 1);

subtest 'multiple types' => sub {
  my $result = $js->evaluate(true, { type => ['string','number'] });
  ok(!$result, 'type returned false');
  is($result, 1, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    [
      all(
        isa('JSON::Schema::Draft201909::Error'),
        methods(
          instance_location => '',
          keyword_location => '/type',
          absolute_keyword_location => undef,
          error => 'wrong type (expected one of string, number)',
        ),
      ),
    ],
    'correct error generated from type',
  );

  cmp_deeply(
    $result->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          error => 'wrong type (expected one of string, number)',
        },
      ],
    },
    'result object serializes correctly',
  );
};

subtest 'multipleOf' => sub {
  my $result = $js->evaluate(3, { multipleOf => 2 });
  ok(!$result, 'multipleOf returned false');
  is($result, 1, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    [
      all(
        isa('JSON::Schema::Draft201909::Error'),
        methods(
          instance_location => '',
          keyword_location => '/multipleOf',
          absolute_keyword_location => undef,
          error => 'value is not a multiple of 2',
        ),
      ),
    ],
    'correct error generated from multipleOf',
  );

  cmp_deeply(
    $result->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/multipleOf',
          error => 'value is not a multiple of 2',
        },
      ],
    },
    'result object serializes correctly',
  );
};

subtest 'uniqueItems' => sub {
  my $result = $js->evaluate([qw(a b c d c)], { uniqueItems => true });
  ok(!$result, 'uniqueItems returned false');
  is($result, 1, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    [
      all(
        isa('JSON::Schema::Draft201909::Error'),
        methods(
          instance_location => '',
          keyword_location => '/uniqueItems',
          absolute_keyword_location => undef,
          error => 'items at indices 2 and 4 are not unique',
        ),
      ),
    ],
    'correct error generated from uniqueItems',
  );

  cmp_deeply(
    $result->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/uniqueItems',
          error => 'items at indices 2 and 4 are not unique',
        },
      ],
    },
    'result object serializes correctly',
  );
};

subtest 'allOf, not, and false schema' => sub {
  my $result = $js->evaluate(
    my $data = 1,
    my $schema = { allOf => [ true, false, { not => { not => false } } ] },
  );
  ok(!$result, 'allOf returned false');
  is($result, 3, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    all(
      array_each(isa('JSON::Schema::Draft201909::Error')),
      [
        methods(
          instance_location => '',
          keyword_location => '/allOf/1',
          absolute_keyword_location => undef,
          error => 'subschema is false',
        ),
        methods(
          instance_location => '',
          keyword_location => '/allOf/2/not',
          absolute_keyword_location => undef,
          error => 'subschema is valid',
        ),
        methods(
          instance_location => '',
          keyword_location => '/allOf',
          absolute_keyword_location => undef,
          error => 'subschemas 1, 2 are not valid',
        ),
      ],
    ),
    'correct errors with locations; did not collect errors inside "not"',
  );

  cmp_deeply(
    $result->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          error => 'subschemas 1, 2 are not valid',
        },
      ],
    },
    'result object serializes correctly',
  );

  cmp_deeply(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          error => 'subschema 1 is not valid',
        },
      ],
    },
    'short-circuited results contain fewer errors',
  );
};

subtest 'anyOf keeps all errors for false paths when invalid, discards errors for false paths when valid' => sub {
  my $result = $js->evaluate(
    my $data = 1,
    my $schema = { anyOf => [ false, false ] },
  );
  ok(!$result, 'anyOf returned false');
  is($result, 3, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    all(
      array_each(isa('JSON::Schema::Draft201909::Error')),
      [
        methods(
          instance_location => '',
          keyword_location => '/anyOf/0',
          absolute_keyword_location => undef,
          error => 'subschema is false',
        ),
        methods(
          instance_location => '',
          keyword_location => '/anyOf/1',
          absolute_keyword_location => undef,
          error => 'subschema is false',
        ),
        methods(
          instance_location => '',
          keyword_location => '/anyOf',
          absolute_keyword_location => undef,
          error => 'no subschemas are valid',
        ),
      ],
    ),
    'correct errors with locations; did not collect errors inside "not"',
  );

  cmp_deeply(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    'short-circuited results contain the same errors (short-circuiting not possible)',
  );


  $result = $js->evaluate(1, { anyOf => [ false, true ], not => true });
  ok(!$result, 'anyOf returned false');
  is($result, 1, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    all(
      array_each(isa('JSON::Schema::Draft201909::Error')),
      [
        methods(
          instance_location => '',
          keyword_location => '/not',
          absolute_keyword_location => undef,
          error => 'subschema is valid',
        ),
      ],
    ),
    'did not collect errors from failure paths from successful anyOf',
  );

  $result = $js->evaluate(1, { anyOf => [ false, true ] });
  ok($result, 'anyOf returned true');
  is($result, 0, 'got error count');

  cmp_deeply(
    [ $result->errors ],
    [],
    'no errors collected for true validation',
  );
};

subtest 'applicators with non-boolean subschemas, discarding intermediary errors - items' => sub {
  my $result = $js->evaluate(
    my $data = [ 1, 2 ],
    my $schema = {
      items => {
        anyOf => [
          { minimum => 2 },
          { allOf => [ { maximum => -1 }, { maximum => 0 } ] },
        ]
      },
    },
  );

  ok(!$result, 'items returned false');
  is($result, 6, 'got error count');

# - evaluate /items on instance ''
#   - evaluate /items on instance /0
#     - evaluate /items/anyOf on instance /0
#       - evaluate /items/anyOf/0 on instance /0
#         - evaluate /items/anyOf/0/minimum on instance /0            FAIL
#         /items/anyOf/0 FAILS
#       - evaluate /items/anyOf/1 on instance /0
#         - evaluate /items/anyOf/1/allOf on instance /0
#           - evaluate /items/anyOf/1/allOf/0 on instance /0
#             - evaluate /items/anyOf/1/allOf/0/maximum on instance /0  FAIL
#           - evaluate /items/anyOf/1/allOf/1 on instance /0
#             - evaluate /items/anyOf/1/allOf/1/maximum on instance /0  FAIL
#           /items/anyOf/1/allOf FAILS
#         /items/anyOf/1 FAILS (no message)
#       /items/anyOf FAILS
#     /items FAILS on instance /0 (no message)

#   - evaluate /items on instance /1
#     - evaluate /items/anyOf on instance /1
#       - evaluate /items/anyOf/0 on instance /1
#         - evaluate /items/anyOf/0/minimum on instance /1            PASS
#         /items/anyOf/0 PASSES
#       - evaluate /items/anyOf/1 on instance /1
#         - evaluate /items/anyOf/1/allOf on instance /1
#           - evaluate /items/anyOf/1/allOf/0 on instance /1
#             - evaluate /items/anyOf/1/allOf/0/maximum on instance /1  FAIL
#           - evaluate /items/anyOf/1/allOf/1 on instance /1
#             - evaluate /items/anyOf/1/allOf/1/maximum on instance /1  FAIL
#           /items/anyOf/1/allOf FAILS
#         /items/anyOf/1 FAILS (no message)
#       /items/anyOf PASSES -- all failures above are discarded
#     /items PASSES on instance /1
#   /items FAILS (across all instances)
# entire schema FAILS

  cmp_deeply(
    [ $result->errors ],
    all(
      array_each(isa('JSON::Schema::Draft201909::Error')),
      array_each(methods(absolute_keyword_location => undef)),
      [
        methods(
          instance_location => '/0',
          keyword_location => '/items/anyOf/0/minimum',
          error => 'value is smaller than 2',
        ),
        methods(
          instance_location => '/0',
          keyword_location => '/items/anyOf/1/allOf/0/maximum',
          error => 'value is larger than -1',
        ),
        methods(
          instance_location => '/0',
          keyword_location => '/items/anyOf/1/allOf/1/maximum',
          error => 'value is larger than 0',
        ),
        methods(
          instance_location => '/0',
          keyword_location => '/items/anyOf/1/allOf',
          error => 'subschemas 0, 1 are not valid',
        ),
        methods(
          instance_location => '/0',
          keyword_location => '/items/anyOf',
          error => 'no subschemas are valid',
        ),

        # these errors are discarded because /items/anyOf passes on instance /1
        #methods(
        #  instance_location => '/1',
        #  keyword_location => '/items/anyOf/1/allOf/0/maximum',
        #  error => 'value is larger than -1',
        #),
        #methods(
        #  instance_location => '/1',
        #  keyword_location => '/items/anyOf/1/allOf/1/maximum',
        #  error => 'value is larger than 0',
        #),
        #methods(
        #  instance_location => '/1',
        #  keyword_location => '/items/anyOf/1/allOf',
        #  error => 'subschemas 0, 1 are not valid',
        #),
        methods(
          instance_location => '',
          keyword_location => '/items',
          error => 'subschema is not valid against all items',
        ),
      ],
    ),
    'collected all errors from subschemas for failing branches only (passing branches discard errors)',
  );

  cmp_deeply(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/0/minimum',
          error => 'value is smaller than 2'
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/1/allOf/0/maximum',
          error => 'value is larger than -1',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/1/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'short-circuited results contain fewer errors',
  );
};

subtest 'applicators with non-boolean subschemas, discarding intermediary errors - contains' => sub {
  my $result = $js->evaluate(
    my $data = [
      { foo => 1 },
      { bar => 2 },
    ],
    my $schema = {
      not => true,
      contains => {
        properties => {
          foo => false,   # if 'foo' is present, then we fail
        },
      },
    },
  );

  ok(!$result, 'evaluation returned false');
  is($result, 1, 'got error count');

# - evaluate /not on instance ''
#   - evaluate subschema "true" - PASS
#   /not FAILS.
# - evaluate /contains on instance ''
#   - evaluate /contains on instance /0
#     - evaluate /contains/properties on instance /0
#       - evaluate /contains/properties/foo on instance /0/foo
#         schema is FALSE.
#       /contains/properties FAILS
#     /contains does not match on instance /0
#   - evaluate /contains on instance /1
#     - evaluate /contains/properties on instance /1
#       - evaluate /contains/properties/foo on instance /1/foo - does not exist.
#         /contains/properties/foo PASSES
#       /contains/properties PASSES
#     /contains matches on instance /1
#   /contains has at least 1 match; it PASSES
# entire schema FAILS

  cmp_deeply(
    [ $result->errors ],
    all(
      array_each(isa('JSON::Schema::Draft201909::Error')),
      array_each(methods(absolute_keyword_location => undef)),
      [
        methods(
          instance_location => '',
          keyword_location => '/not',
          error => 'subschema is valid',
        ),
        # these errors are discarded because /contains passes on instance /1
        #methods(
        #  instance_location => '/0/foo',
        #  keyword_location => '/contains/properties/foo',
        #  error => 'subschema is false',
        #),
        #methods(
        #  instance_location => '/0',
        #  keyword_location => '/contains/properties',
        #  error => 'not all properties are valid',
        #),
      ],
    ),
    'collected all errors from subschemas for failing branches only (passing branches discard errors)',
  );

  cmp_deeply(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          error => 'subschema is valid',
        },
      ],
    },
    'short-circuited results contain the same errors',
  );
};

subtest 'errors with $refs' => sub {
  my $result = $js->evaluate(
    [ { x => 1 }, { x => 2 }, { x => 3 } ],
    {
      '$defs' => {
        mydef => {
          type => 'integer',
          minimum => 5,
          '$ref' => '#/$defs/myint',
        },
        myint => {
          multipleOf => 5,
        },
      },
      items => {
        properties => {
          x => {
            '$ref' => '#/$defs/mydef',
            maximum => 2,
          },
        },
      }
    },
  );

  ok(!$result, 'evaluation returned false');
  is($result, 11, 'got error count');

  # evaluation order:
  # /items/properties/x/$ref (mydef) /$ref (myint) /multipleOf
  # /items/properties/x/$ref (mydef) /type
  # /items/properties/x/$ref (mydef) /minimum
  # /items/properties/x/maximum

  cmp_deeply(
    [ $result->errors ],
    all(
      array_each(isa('JSON::Schema::Draft201909::Error')),
      [
        methods(
          instance_location => '/0/x',
          keyword_location => '/items/properties/x/$ref/$ref/multipleOf',
          absolute_keyword_location => '#/$defs/myint/multipleOf',
          error => 'value is not a multiple of 5',
        ),
        methods(
          instance_location => '/0/x',
          keyword_location => '/items/properties/x/$ref/minimum',
          absolute_keyword_location => '#/$defs/mydef/minimum',
          error => 'value is smaller than 5',
        ),
        methods(
          instance_location => '/0',
          keyword_location => '/items/properties',
          absolute_keyword_location => undef,
          error => 'not all properties are valid',
        ),
        methods(
          instance_location => '/1/x',
          keyword_location => '/items/properties/x/$ref/$ref/multipleOf',
          absolute_keyword_location => '#/$defs/myint/multipleOf',
          error => 'value is not a multiple of 5',
        ),
        methods(
          instance_location => '/1/x',
          keyword_location => '/items/properties/x/$ref/minimum',
          absolute_keyword_location => '#/$defs/mydef/minimum',
          error => 'value is smaller than 5',
        ),
        methods(
          instance_location => '/1',
          keyword_location => '/items/properties',
          absolute_keyword_location => undef,
          error => 'not all properties are valid',
        ),
        methods(
          instance_location => '/2/x',
          keyword_location => '/items/properties/x/$ref/$ref/multipleOf',
          absolute_keyword_location => '#/$defs/myint/multipleOf',
          error => 'value is not a multiple of 5',
        ),
        methods(
          instance_location => '/2/x',
          keyword_location => '/items/properties/x/$ref/minimum',
          absolute_keyword_location => '#/$defs/mydef/minimum',
          error => 'value is smaller than 5',
        ),
        methods(
          instance_location => '/2/x',
          keyword_location => '/items/properties/x/maximum',
          absolute_keyword_location => undef,
          error => 'value is larger than 2',
        ),
        methods(
          instance_location => '/2',
          keyword_location => '/items/properties',
          absolute_keyword_location => undef,
          error => 'not all properties are valid',
        ),
        methods(
          instance_location => '',
          keyword_location => '/items',
          absolute_keyword_location => undef,
          error => 'subschema is not valid against all items',
        ),
      ],
    ),
    'errors have correct absolute keyword location via $ref',
  );
};

subtest 'const and enum' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => { a => { b => { c => { d => 1 } } } } },
      {
        properties => {
          foo => {
            allOf => [
              { const => { a => { b => { c => { d => 2 } } } } },
              { enum => [ 0, 'whargarbl', { a => { b => { c => { d => 2 } } } } ] },
            ],
          }
        },
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/allOf/0/const',
          error => 'value does not match (differences start at "/a/b/c/d")',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/allOf/1/enum',
          error => 'value does not match (differences start from #0 at "", from #1 at "", from #2 at "/a/b/c/d")',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/allOf',
          error => 'subschemas 0, 1 are not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'got details about object differences in errors from const and enum',
  );
};

subtest 'exceptions' => sub {
  cmp_deeply(
    $js->evaluate_json_string('[ 1, 2, 3, whargarbl ]', true)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => re(qr/malformed JSON string/),
        },
      ],
    },
    'attempting to evaluate a json string returns the exception as an error',
  );

  cmp_deeply(
    $js->evaluate(
      { x => 'hello' },
      {
        allOf => [
          { properties => { x => 1 } },
          { properties => { x => false } },
        ],
      }
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/x',
          keywordLocation => '/allOf/0/properties/x',
          error => 'EXCEPTION: invalid schema type: number',
        },
      ],
    },
    'a subschema of an invalid type returns an error at the right position, and evaluation aborts',
  );

  cmp_deeply(
    $js->evaluate(
      1,
      {
        allOf => [
          { type => 'whargarbl' },
          false,
        ],
      }
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/type',
          error => 'EXCEPTION: unrecognized type "whargarbl"',
        },
      ],
    },
    'invalid argument to "type" returns an error at the right position, and evaluation aborts',
  );
};

subtest 'errors after crossing multiple $refs using $id and $anchor' => sub {
  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'base.json',
        '$defs' => {
          def1 => {
            '$comment' => 'canonical uri: "def1.json"',
            '$id' => 'def1.json',
            '$ref' => 'base.json#/$defs/myint',
            type => 'integer',
            maximum => -1,
            minimum => 5,
          },
          myint => {
            '$comment' => 'canonical uri: "def2.json"',
            '$id' => 'def2.json',
            '$ref' => 'base.json#my_not',
            multipleOf => 5,
            exclusiveMaximum => 1,
          },
          mynot => {
            '$comment' => 'canonical uri: "base.json#/$defs/mynot"',
            '$anchor' => 'my_not',
            '$ref' => 'http://localhost:4242/object.json',
            not => true,
          },
          myobject => {
            '$id' => 'http://localhost:4242/object.json',
            type => 'object',
            anyOf => [ false ],
          },
        },
        '$ref' => '#/$defs/def1',
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/$ref/$ref/type',
          absoluteKeywordLocation => 'http://localhost:4242/object.json#/type',
          error => 'wrong type (expected object)',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/$ref/$ref/anyOf/0',
          absoluteKeywordLocation => 'http://localhost:4242/object.json#/anyOf/0',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/$ref/$ref/anyOf',
          absoluteKeywordLocation => 'http://localhost:4242/object.json#/anyOf',
          error => 'no subschemas are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/$ref/not',
          absoluteKeywordLocation => 'base.json#/$defs/mynot/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/multipleOf',
          absoluteKeywordLocation => 'def2.json#/multipleOf',
          error => 'value is not a multiple of 5',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/exclusiveMaximum',
          absoluteKeywordLocation => 'def2.json#/exclusiveMaximum',
          error => 'value is equal to or larger than 1',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/maximum',
          absoluteKeywordLocation => 'def1.json#/maximum',
          error => 'value is larger than -1',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/minimum',
          absoluteKeywordLocation => 'def1.json#/minimum',
          error => 'value is smaller than 5',
        },
      ],
    },
    'errors have correct absolute keyword location via $ref',
  );
};

subtest 'unresolvable $ref' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'http://localhost:4242/foo/bar/top_id.json',
        '$ref' => '/baz/myint.json',
        '$defs' => {
          myint => {
            '$id' => '/baz/myint.json',
            '$ref' => 'does-not-exist.json',
          },
        },
        anyOf => [ false ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref',
          absoluteKeywordLocation => 'http://localhost:4242/baz/myint.json#/$ref',
          error => 'EXCEPTION: unable to find resource http://localhost:4242/baz/does-not-exist.json',
        },
      ],
    },
    'error for a bad $ref reports the correct absolute location that was referred to',
  );
};

subtest 'unresolvable $ref to plain-name fragment' => sub {
  cmp_deeply(
    $js->evaluate(1, { '$ref' => '#nowhere' })->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref',
          error => 'EXCEPTION: unable to find resource #nowhere',
        },
      ],
    },
    'properly handled a bad $ref to an anchor',
  );
};

subtest 'abort due to a schema error' => sub {
  cmp_deeply(
    $js->evaluate(
      1,
      {
        oneOf => [
          { type => 'number' },
          { type => 'string' },
          { type => 'whargarbl' },
        ],
      }
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/oneOf/2/type',
          error => 'EXCEPTION: unrecognized type "whargarbl"',
        },
      ],
    },
    'exception inside a oneOf (where errors are localized) are still included in the result',
  );
};

subtest 'sorted property names' => sub {
  cmp_deeply(
    $js->evaluate(
      { foo => 1, bar => 1, baz => 1, hello => 1 },
      {
        properties => {
          foo => false,
          bar => false,
        },
        additionalProperties => false,
      }
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/bar',
          keywordLocation => '/properties/bar',
          error => 'property not permitted',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo',
          error => 'property not permitted',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/baz',
          keywordLocation => '/additionalProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '/hello',
          keywordLocation => '/additionalProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'property names are considered in sorted order',
  );
};

subtest 'bad regex in schema' => sub {
  my $schema = {
    type => 'object',
    properties => {
      my_pattern => {
        type => 'string',
        pattern => '(',
      },
      my_patternProperties => {
        type => 'object',
        patternProperties => { '(' => true },
        additionalProperties => false,
      },
    },
  };

  cmp_deeply(
    $js->evaluate(
      { my_pattern => 'foo' },
      $schema,
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/my_pattern',
          keywordLocation => '/properties/my_pattern/pattern',
          error => re(qr/EXCEPTION: Unmatched \( in regex/),
        },
      ],
    },
    'bad "pattern" regex is properly noted in error',
  );

  cmp_deeply(
    $js->evaluate(
      { my_patternProperties => { foo => 1 } },
      $schema,
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/my_patternProperties',
          keywordLocation => '/properties/my_patternProperties/patternProperties/(',
          error => re(qr/EXCEPTION: Unmatched \( in regex/),
        },
      ],
    },
    'bad "patternProperties" regex is properly noted in error',
  );
};

subtest 'JSON pointer escaping' => sub {
  cmp_deeply(
    $js->evaluate(
      { '{}' => { 'my~tilde/slash-property' => 1 } },
      {
        '$defs' => {
          mydef => {
            properties => {
              '{}' => {
                patternProperties => {
                  '~' => { minimum => 5 },
                  '/' => { minimum => 6 },
                  '[~/]' => { minimum => 7 },
                },
              },
            },
          },
        },
        '$ref' => '#/$defs/mydef',
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/~1/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/~1/minimum',
          error => 'value is smaller than 6',
        },
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/[~0~1]/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/%5B~0~1%5D/minimum',
          error => 'value is smaller than 7',
        },
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/~0/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/~0/minimum',
          error => 'value is smaller than 5',
        },
        {
          instanceLocation => '/{}',
          keywordLocation => '/$ref/properties/{}/patternProperties',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/properties',
          absoluteKeywordLocation => '#/$defs/mydef/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'JSON pointers are properly escaped; URIs doubly so',
  );
};

subtest 'invalid $schema' => sub {
  cmp_deeply(
    $js->evaluate(
      1,
      {
        allOf => [
          true,
          { '$schema' => 'https://json-schema.org/draft/2019-09/schema' },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$schema',
          error => 'EXCEPTION: $schema can only appear at the schema resource root',
        },
      ],
    },
    '$schema can only appear at the root of a schema, when there is no canonical URI',
  );

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'https://bloop.com',
        allOf => [
          true,
          { '$schema' => 'https://json-schema.org/draft/2019-09/schema' },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$schema',
          absoluteKeywordLocation => 'https://bloop.com#/allOf/1/$schema',
          error => 'EXCEPTION: $schema can only appear at the schema resource root',
        },
      ],
    },
    '$schema can only appear where the canonical URI has no fragment, when there is a canonical URI',
  );

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'https://bloop2.com',
        allOf => [
          true,
          {
            '$id' => 'https://newid.com',
            '$schema' => 'https://json-schema.org/draft/2019-09/schema',
          },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    '$schema can appear adjacent to any $id',
  );
};

subtest 'absoluteKeywordLocation' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909->new(max_traversal_depth => 1)->evaluate(
      [ [ 1 ] ],
      { items => { '$ref' => '#' } },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/$ref',
          absoluteKeywordLocation => '',
          error => 'EXCEPTION: maximum traversal depth exceeded',
        },
      ],
    },
    'absoluteKeywordLocation is included when different from instanceLocation, even when empty',
  );

  cmp_deeply(
    $js->evaluate(1, { '$ref' => '#does_not_exist' })->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref',
          error => 'EXCEPTION: unable to find resource #does_not_exist',
        },
      ],
    },
    'absoluteKeywordLocation is not included when the path equals keywordLocation, even if a $ref is present',
  );

  $js->add_schema(false);
  cmp_deeply(
    $js->evaluate(1, '#')->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'subschema is false',
        },
      ],
    },
    'absoluteKeywordLocation is never "#"',
  );
};

done_testing;
