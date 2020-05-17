use strict;
use warnings;

use Test::More;
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
    $js->evaluate_json_string('[ 1, 2, 3, wargarbl ]', true)->TO_JSON,
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
          error => 'EXCEPTION: unrecognized schema type "number"',
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

done_testing;
