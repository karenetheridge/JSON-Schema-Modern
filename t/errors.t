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
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(short_circuit => 0);
my $js_short = JSON::Schema::Modern->new(short_circuit => 1);

subtest 'multiple types' => sub {
  my $result = $js->evaluate(true, { type => ['string','number'] });
  ok(!$result->valid, 'type returned false');
  is($result->error_count, 1, 'got error count');

  cmp_result(
    [ $result->errors ],
    [
      all(
        isa('JSON::Schema::Modern::Error'),
        methods(
          instance_location => '',
          keyword_location => '/type',
          absolute_keyword_location => undef,
          error => 'got boolean, not one of string, number',
        ),
      ),
    ],
    'correct error generated from type',
  );

  cmp_result(
    $result->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          error => 'got boolean, not one of string, number',
        },
      ],
    },
    'result object serializes correctly',
  );
};

subtest 'multipleOf' => sub {
  cmp_result(
    $js->evaluate(3, { multipleOf => 2 })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/multipleOf',
          error => 'value is not a multiple of 2',
        },
      ],
    },
    'correct error generated from multipleOf',
  );
};

subtest 'uniqueItems' => sub {
  cmp_result(
    $js->evaluate([qw(a b c d c)], { uniqueItems => true })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/uniqueItems',
          error => 'items at indices 2 and 4 are not unique',
        },
      ],
    },
    'correct error generated from uniqueItems',
  );
};

subtest 'allOf, not, and false schema' => sub {
  cmp_result(
    $js->evaluate(
      my $data = 1,
      my $schema = { allOf => [ true, false, { not => { not => false } } ] },
    )->TO_JSON,
    {
      valid => false,
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
    'correct errors with locations; did not collect errors inside "not"',
  );

  cmp_result(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => false,
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
  cmp_result(
    $js->evaluate(
      my $data = 1,
      my $schema = { anyOf => [ false, false ] },
    )->TO_JSON,
    my $result = {
      valid => false,
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
    'correct errors with locations; did not collect errors inside "not"',
  );

  cmp_result(
    $js_short->evaluate($data, $schema)->TO_JSON,
    $result,
    'short-circuited results contain the same errors (short-circuiting not possible)',
  );

  cmp_result(
    $result = $js->evaluate(1, { anyOf => [ false, true ], not => true })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          error => 'subschema is valid',
        },
      ],
    },
    'did not collect errors from failure paths from successful anyOf',
  );

  cmp_result(
    $js->evaluate(1, { anyOf => [ false, true ] })->TO_JSON,
    { valid => true },
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

  cmp_result(
    $result->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/0/minimum',
          error => 'value is less than 2',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/1/allOf/0/maximum',
          error => 'value is greater than -1',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/1/allOf/1/maximum',
          error => 'value is greater than 0',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/1/allOf',
          error => 'subschemas 0, 1 are not valid',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf',
          error => 'no subschemas are valid',
        },
        # these errors are discarded because /items/anyOf passes on instance /1
        #{
        #  instanceLocation => '/1',
        #  keywordLocation => '/items/anyOf/1/allOf/0/maximum',
        #  error => 'value is greater than -1',
        #},
        #{
        #  instanceLocation => '/1',
        #  keywordLocation => '/items/anyOf/1/allOf/1/maximum',
        #  error => 'value is greater than 0',
        #},
        #{
        #  instanceLocation => '/1',
        #  keywordLocation => '/items/anyOf/1/allOf',
        #  error => 'subschemas 0, 1 are not valid',
        #},
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'collected all errors from subschemas for failing branches only (passing branches discard errors)',
  );

  cmp_result(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/0/minimum',
          error => 'value is less than 2'
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/anyOf/1/allOf/0/maximum',
          error => 'value is greater than -1',
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

  cmp_result(
    $result->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          error => 'subschema is valid',
        },
        # these errors are discarded because /contains passes on instance /1
        #{
        #  instanceLocation => '/0/foo',
        #  keywordLocation => '/contains/properties/foo',
        #  error => 'subschema is false',
        #},
        #{
        #  instanceLocation => '/0',
        #  keywordLocation => '/contains/properties',
        #  error => 'not all properties are valid',
        #},
      ],
    },
    'collected all errors from subschemas for failing branches only (passing branches discard errors)',
  );

  cmp_result(
    $js_short->evaluate($data, $schema)->TO_JSON,
    {
      valid => false,
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

  # evaluation order:
  # /items/properties/x/$ref (mydef) /$ref (myint) /multipleOf
  # /items/properties/x/$ref (mydef) /type
  # /items/properties/x/$ref (mydef) /minimum
  # /items/properties/x/maximum

  cmp_result(
    $result->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0/x',
          keywordLocation => '/items/properties/x/$ref/$ref/multipleOf',
          absoluteKeywordLocation => '#/$defs/myint/multipleOf',
          error => 'value is not a multiple of 5',
        },
        {
          instanceLocation => '/0/x',
          keywordLocation => '/items/properties/x/$ref/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/minimum',
          error => 'value is less than 5',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/1/x',
          keywordLocation => '/items/properties/x/$ref/$ref/multipleOf',
          absoluteKeywordLocation => '#/$defs/myint/multipleOf',
          error => 'value is not a multiple of 5',
        },
        {
          instanceLocation => '/1/x',
          keywordLocation => '/items/properties/x/$ref/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/minimum',
          error => 'value is less than 5',
        },
        {
          instanceLocation => '/1',
          keywordLocation => '/items/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/2/x',
          keywordLocation => '/items/properties/x/$ref/$ref/multipleOf',
          absoluteKeywordLocation => '#/$defs/myint/multipleOf',
          error => 'value is not a multiple of 5',
        },
        {
          instanceLocation => '/2/x',
          keywordLocation => '/items/properties/x/$ref/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/minimum',
          error => 'value is less than 5',
        },
        {
          instanceLocation => '/2/x',
          keywordLocation => '/items/properties/x/maximum',
          error => 'value is greater than 2',
        },
        {
          instanceLocation => '/2',
          keywordLocation => '/items/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'errors have correct absolute keyword location via $ref',
  );
};

subtest 'const and enum' => sub {
  cmp_result(
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
      valid => false,
      errors => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/allOf/0/const',
          error => 'value does not match (at \'/a/b/c/d\': integers not equal)',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/allOf/1/enum',
          error => 'value does not match (from enum 0 at \'\': wrong type: object vs integer; from enum 1 at \'\': wrong type: object vs string; from enum 2 at \'/a/b/c/d\': integers not equal)',
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
  cmp_result(
    (my $result = $js->evaluate_json_string('[ 1, 2, 3, whargarbl ]', true))->TO_JSON,
    {
      valid => false,
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
  ok($result->exception, 'exception flag is true on the result');

  cmp_result(
    ($result = $js->evaluate(
      { x => 'hello' },
      {
        allOf => [
          { properties => { x => 1 } },
          { properties => { x => 'hi' } },
        ],
      }
    ))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/properties/x',
          error => 'invalid schema type: integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/properties/x',
          error => 'invalid schema type: string',
        },
      ],
    },
    'a subschema of an invalid type returns an error at the right position, and evaluation continues',
  );
  ok($result->exception, 'exception flag is true on the result');

  cmp_result(
    ($result = $js->evaluate(
      1,
      {
        allOf => [
          { type => 'whargarbl' },
          { type => 'whoops' },
        ],
      }
    ))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/type',
          error => 'unrecognized type "whargarbl"',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/type',
          error => 'unrecognized type "whoops"',
        },
      ],
    },
    'invalid argument to "type" returns an error at the right position, and evaluation continues',
  );
  ok($result->exception, 'exception flag is true on the result');
};

subtest 'errors after crossing multiple $refs using $id and $anchor' => sub {
  cmp_result(
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
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref/$ref/$ref/type',
          absoluteKeywordLocation => 'http://localhost:4242/object.json#/type',
          error => 'got integer, not object',
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
          error => 'value is greater than or equal to 1',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/maximum',
          absoluteKeywordLocation => 'def1.json#/maximum',
          error => 'value is greater than -1',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/minimum',
          absoluteKeywordLocation => 'def1.json#/minimum',
          error => 'value is less than 5',
        },
      ],
    },
    'errors have correct absolute keyword location via $ref',
  );

  cmp_result(
    $js->evaluate(
      1,
      {
        '$id' => 'http://localhost:1234/hello',
        '$defs' => {
          foo => {
            '$id' => 'http://localhost:1234/a/b.json',
            '$defs' => {
              bar => {
                '$anchor' => 'my_anchor',
                '$defs' => {
                  baz => {
                    '$anchor' => 'another_anchor',
                    not => true
                  },
                },
              },
            },
          },
        },
        '$ref' => 'http://localhost:1234/hello#/$defs/foo/$defs/bar/$defs/baz',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/not',
          absoluteKeywordLocation => 'http://localhost:1234/a/b.json#/$defs/bar/$defs/baz/not',
          error => 'subschema is valid',
        },
      ],
    },
    'absolute keyword location is correct, even when not used in the $ref',
  );
};

subtest 'unresolvable $ref to a local resource' => sub {
  cmp_result(
    (my $result = $js->evaluate(
      1,
      {
        '$ref' => '#/$defs/myint',
        '$defs' => {
          myint => {
            '$ref' => '#/$defs/does-not-exist',
          },
        },
        anyOf => [ false ],
      },
    ))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref',
          absoluteKeywordLocation => '#/$defs/myint/$ref',
          error => 'EXCEPTION: unable to find resource "#/$defs/does-not-exist"',
        },
      ],
    },
    'error for a bad $ref reports the correct absolute location that was referred to',
  );
  ok($result->exception, 'exception flag is true on the result');
};

subtest 'unresolvable $ref to a remote resource' => sub {
  # new evaluator, with no resources remembered
  my $js = JSON::Schema::Modern->new;

  cmp_result(
    (my $result = $js->evaluate(
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
    ))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/$ref',
          absoluteKeywordLocation => 'http://localhost:4242/baz/myint.json#/$ref',
          error => 'EXCEPTION: unable to find resource "http://localhost:4242/baz/does-not-exist.json"',
        },
      ],
    },
    'error for a bad $ref reports the correct absolute location that was referred to',
  );
  ok($result->exception, 'exception flag is true on the result');
};

subtest 'unresolvable $ref to plain-name fragment' => sub {
  cmp_result(
    (my $result = $js->evaluate(1, { '$ref' => '#nowhere' }))->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref',
          error => 'EXCEPTION: unable to find resource "#nowhere"',
        },
      ],
    },
    'properly handled a bad $ref to an anchor',
  );
  ok($result->exception, 'exception flag is true on the result');
};

subtest 'abort due to a schema error' => sub {
  cmp_result(
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
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/oneOf/2/type',
          error => 'unrecognized type "whargarbl"',
        },
      ],
    },
    'exception inside a oneOf (where errors are localized) are still included in the result',
  );
};

subtest 'sorted property names' => sub {
  cmp_result(
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
      valid => false,
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
  cmp_result(
    $js->evaluate(
      {
        my_pattern => 'foo',
        my_patternProperties => { foo => 1 },
      },
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
          my_runtime_pattern => {
            type => 'string',
            pattern => '\p{main::IsFoo}', # qr/$pattern/ will not find this error, but m/$pattern/ will
          },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/properties/my_pattern/pattern',
          error => re(qr/^Unmatched \( in regex/),
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties/my_patternProperties/patternProperties/(',
          error => re(qr/^Unmatched \( in regex/),
        },
        # Note no error for missing IsFoo
      ],
    },
    'bad "pattern" and "patternProperties" regexes are properly noted in error',
  );

  cmp_result(
    $js->evaluate(
      { my_runtime_pattern => 'foo' },
      $schema = {
        $schema->%{type},
        properties => +{ $schema->{properties}->%{my_runtime_pattern} },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/my_runtime_pattern',
          keywordLocation => '/properties/my_runtime_pattern/pattern',
          # in 5.28 and earlier: Can't find Unicode property definition "IsFoo"
          # in 5.30 and later:   Unknown user-defined property name \p{main::IsFoo}
          error => re(qr/^EXCEPTION: .*property.*IsFoo/),
        },
      ],
    },
    'bad "pattern" regex is properly noted in error',
  );

  no warnings 'once';
  *IsFoo = sub { "0066\n006F\n" }; # accepts 'f', 'o'

  cmp_result(
    $js->evaluate(
      { my_runtime_pattern => 'foo' },
      $schema,
    )->TO_JSON,
    {
      valid => true,
    },
    '"pattern" regex is now valid, due to the Unicode property becoming defined',
  );
};

subtest 'JSON pointer escaping' => sub {
  cmp_result(
    $js->evaluate(
      { '{}' => { 'my~tilde/slash-property' => 1 } },
      my $schema = {
        '$defs' => {
          mydef => {
            properties => {
              '{}' => {
                properties => {
                  'my~tilde/slash-property' => false,
                },
                patternProperties => {
                  '/' => { minimum => 6 },
                  '[~/]' => { minimum => 7 },
                  '~' => { minimum => 5 },
                  '~.*/' => false,
                },
              },
            },
          },
        },
        '$ref' => '#/$defs/mydef',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/properties/my~0tilde~1slash-property',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/properties/my~0tilde~1slash-property',
          error => 'property not permitted',
        },
        {
          instanceLocation => '/{}',
          keywordLocation => '/$ref/properties/{}/properties',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/~1/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/~1/minimum',  # /
          error => 'value is less than 6',
        },
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/[~0~1]/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/%5B~0~1%5D/minimum',  # [~/]
          error => 'value is less than 7',
        },
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/~0/minimum',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/~0/minimum',  # ~
          error => 'value is less than 5',
        },
        {
          instanceLocation => '/{}/my~0tilde~1slash-property',
          keywordLocation => '/$ref/properties/{}/patternProperties/~0.*~1',
          absoluteKeywordLocation => '#/$defs/mydef/properties/%7B%7D/patternProperties/~0.*~1', # ~.*/
          error => 'property not permitted',
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

  cmp_result(
    $js->evaluate(
      { '{}' => { 'my~tilde/slash-property' => 1 } },
      $schema->{'$defs'}{mydef},
    )->TO_JSON,
    {
      valid => false,
      errors => [
        map +{
          error => $_->{error},
          instanceLocation => $_->{instanceLocation},
          keywordLocation => $_->{keywordLocation} =~ s{^/\$ref}{}r,
        }, @$errors
      ],
    },
    'absoluteKeywordLocation is omitted when paths are the same, not counting uri encoding',
  );

  cmp_result(
    $js->evaluate(
      { '{}' => { 'my~tilde/slash-property' => 1 } },
      {
        '$defs' => {
          mydef => {
            properties => {
              '{}' => {
                patternProperties => {
                  'a{' => { minimum => 2 }, # this is a broken regex
                },
              },
            },
          },
        },
        '$ref' => '#/$defs/mydef',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs/mydef/properties/{}/patternProperties/a{',
          error => re(qr/^Unescaped left brace in regex is (deprecated|illegal|passed through)/),
        },
      ],
    },
    # all the other _schema_path_suffix cases are tested in the earlier test case
    'use of _schema_path_suffix in a fatal error',
  ) if "$]" >= 5.022;
};

subtest 'absoluteKeywordLocation' => sub {
  cmp_result(
    JSON::Schema::Modern->new(max_traversal_depth => 1)->evaluate(
      [ [ 1 ] ],
      { items => { '$ref' => '#' } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/$ref',
          absoluteKeywordLocation => '',
          error => 'EXCEPTION: maximum evaluation depth (1) exceeded',
        },
      ],
    },
    'absoluteKeywordLocation is included when different from instanceLocation, even when empty',
  );

  cmp_result(
    $js->evaluate(1, { '$ref' => '#does_not_exist' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref',
          error => 'EXCEPTION: unable to find resource "#does_not_exist"',
        },
      ],
    },
    'absoluteKeywordLocation is not included when the path equals keywordLocation, even if a $ref is present',
  );

  $js->add_schema(false);
  cmp_result(
    $js->evaluate(1, '#')->TO_JSON,
    {
      valid => false,
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

  cmp_result(
    $js->evaluate(
      1,
      my $schema = {
        '$id' => 'https://localhost:1234/bloop',
        allOf => [
          {
            '$id' => 'foo.json',
            type => 'object',
          },
          {
            '$id' => 'bar/',
            allOf => [
              {
                '$id' => 'alpha',
                type => 'object',
              },
            ],
          },
          { type => 'object' },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/type',
          absoluteKeywordLocation => 'https://localhost:1234/foo.json#/type',
          error => 'got integer, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/allOf/0/type',
          absoluteKeywordLocation => 'https://localhost:1234/bar/alpha#/type',
          error => 'got integer, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/allOf',
          absoluteKeywordLocation => 'https://localhost:1234/bar/#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/type',
          absoluteKeywordLocation => 'https://localhost:1234/bloop#/allOf/2/type',
          error => 'got integer, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://localhost:1234/bloop#/allOf',
          error => 'subschemas 0, 1, 2 are not valid',
        },
      ],
    },
    'absoluteKeywordLocation reflects the canonical schema uri as it changes when passing through $id',
  );

  $schema->{'$id'} = 'https://example.com';
  $schema->{allOf}[2]{'$id'} = '#my_anchor2';
  cmp_result(
    JSON::Schema::Modern->new(specification_version => 'draft7')->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/type',
          absoluteKeywordLocation => 'https://example.com/foo.json#/type',
          error => 'got integer, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/allOf/0/type',
          absoluteKeywordLocation => 'https://example.com/bar/alpha#/type',
          error => 'got integer, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/allOf',
          absoluteKeywordLocation => 'https://example.com/bar/#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/type',
          absoluteKeywordLocation => 'https://example.com#/allOf/2/type',
          error => 'got integer, not object',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://example.com#/allOf',
          error => 'subschemas 0, 1, 2 are not valid',
        },
      ],
    },
    'plain-name fragment in $id does not change canonical schema uri',
  );
};

subtest dependentRequired => sub {
  cmp_result(
    $js->evaluate(1, { dependentRequired => { foo => [ 1 ] } })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/dependentRequired/foo/0',
          error => 'element #0 is not a string',
        },
      ],
    },
    'dependentRequired traversal error',
  );
};

subtest 'numbers in output' => sub {
  cmp_result(
    $js->evaluate(
      5,
      {
        multipleOf => 1.23456789,
        maximum => 4.23456789,
        minimum => 6.23456789,
        exclusiveMaximum => 4.23456789,
        exclusiveMinimum => 6.23456789,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/multipleOf',
          error => 'value is not a multiple of 1.23456789',
        },
        {
          instanceLocation => '',
          keywordLocation => '/maximum',
          error => 'value is greater than 4.23456789',
        },
        {
          instanceLocation => '',
          keywordLocation => '/exclusiveMaximum',
          error => 'value is greater than or equal to 4.23456789',
        },
        {
          instanceLocation => '',
          keywordLocation => '/minimum',
          error => 'value is less than 6.23456789',
        },
        {
          instanceLocation => '',
          keywordLocation => '/exclusiveMinimum',
          error => 'value is less than or equal to 6.23456789',
        },
      ],
    },
    'numbers in errors do not lose any digits of precision',
  );
};

subtest 'effective_base_uri and overriding starting locations' => sub {
  cmp_result(
    $js->evaluate(
      5,
      {
        '$id' => 'foo',
        '$defs' => { bar => false },
        '$ref' => '#/$defs/bar',
        not => true,
      },
      {
        effective_base_uri => 'https://example.com',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref',
          absoluteKeywordLocation => 'https://example.com/foo#/$defs/bar',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/not',
          absoluteKeywordLocation => 'https://example.com/foo#/not',
          error => 'subschema is valid',
        },
      ],
    },
    'error locations are relative to the effective_base_uri, but $ref usage is not restricted',
  );

  # evaluating this document from its root would do nothing, as it is only definitions
  $js->add_schema('/api', {
    '$defs' => {
      alpha => {
        items => {
          '$ref' => '#/$defs/beta',
        },
      },
      beta => {
        not => true,
      },
    },
  });

  cmp_result(
    $js->evaluate(
      [ 5 ],
      '/api#/$defs/alpha',
      {
        data_path => '/html/body/div/div/h1/div/p',     # reported data location
        traversed_schema_path => '/some/other/document/$ref',   # reported keywords passed through before we start
        effective_base_uri => 'https://example.com',    # base uri to use for document locations
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/html/body/div/div/h1/div/p/0',
          keywordLocation => '/some/other/document/$ref/items/$ref/not',
          absoluteKeywordLocation => 'https://example.com/api#/$defs/beta/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '/html/body/div/div/h1/div/p',
          keywordLocation => '/some/other/document/$ref/items',
          absoluteKeywordLocation => 'https://example.com/api#/$defs/alpha/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'can alter locations with data_path, traversed_schema_path, effective_base_uri',
  );
};

subtest 'recommended_response' => sub {
  cmp_result(
    JSON::Schema::Modern::Result->new(valid => 1)->recommended_response,
    undef,
    'recommended_response is not defined when there are no errors',
  );

  my $result = $js->evaluate(
    { foo => 3 },
    {
      type => 'object',
      properties => {
        foo => {
          type => 'integer',
          minimum => 5,
        },
      },
    },
  );

  cmp_result(
    $result->recommended_response,
    [ 400, q{'/foo': value is less than 5} ],
    'recommended_response uses the first error in the result',
  );

  my $result2 = $js->evaluate(1, { '$ref' => '#/$defs/does_not_exist' });

  cmp_result(
    $result2->recommended_response,
    [ 500, 'Internal Server Error' ],
    'recommended_response indicates an exception occurred',
  );

  my $result3 = JSON::Schema::Modern::Result->new(
    valid => 0,
    errors => [
      $result->errors,
      # TODO: I haven't implemented authentication in OpenAPI::Modern yet, so I'm not sure how
      # exactly these errors are going to look
      JSON::Schema::Modern::Error->new(
        depth => 0,
        mode => 'evaluate',
        keyword => 'authentication',
        instance_location => '/request/headers/Authentication',
        keyword_location => '/paths/foo/get/security',
        error => 'security check failed',
        recommended_response => [ 401, 'Unauthorized' ],
      ),
    ],
  );

  cmp_result(
    $result3->recommended_response,
    [ 401, 'Unauthorized' ],
    'recommended_response uses the one from the error that is explicitly set',
  );
};

subtest 'exclusiveMaximum, exclusiveMinimum across drafts' => sub {
  cmp_result(
    $js->evaluate(4, { maximum => 4, exclusiveMaximum => 4 })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/exclusiveMaximum',
          error => 'value is greater than or equal to 4',
        },
      ],
    },
    'later drafts; errors are produced separately from the keywords',
  );

  cmp_result(
    $js->evaluate(5, { maximum => 4, exclusiveMaximum => 4 })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/maximum',
          error => 'value is greater than 4',
        },
        {
          instanceLocation => '',
          keywordLocation => '/exclusiveMaximum',
          error => 'value is greater than or equal to 4',
        },
      ],
    },
    'later drafts; two errors can result',
  );

  my $js = JSON::Schema::Modern->new(specification_version => 'draft4');

  cmp_result(
    $js->evaluate(4, { maximum => 4, exclusiveMaximum => true })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/maximum',
          error => 'value is greater than or equal to 4',
        },
      ],
    },
    'draft4: one error comes from maximum, but includes the exclusiveMaximum check',
  );

  cmp_result(
    $js->evaluate(5, { maximum => 4, exclusiveMaximum => true })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/maximum',
          error => 'value is greater than or equal to 4',
        },
      ],
    },
    'draft4: maximum + exclusiveMaximum checks are combined',
  );

  cmp_result(
    $js->evaluate(4, { maximum => 4, exclusiveMaximum => false })->TO_JSON,
    { valid => true },
    'draft4: exclusive check uses the right boundary',
  );

  cmp_result(
    $js->evaluate(5, { maximum => 4, exclusiveMaximum => false })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/maximum',
          error => 'value is greater than 4',
        },
      ],
    },
    'draft4: maximum check is correct',
  );
};

done_testing;
