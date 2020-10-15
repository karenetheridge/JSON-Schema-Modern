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

my $js = JSON::Schema::Draft201909->new(short_circuit => 0, collect_annotations => 1);
is($js->output_format, 'basic', 'output_format defaults to basic');

my $result = $js->evaluate(
  { alpha => 1, beta => 1, gamma => [ 0, 1 ], foo => 1, zulu => 2 },
  {
    required => [ 'bar' ],
    allOf => [ { type => 'number' } ],
    anyOf => [ { type => 'number' }, { if => true, then => { type => 'array' }, else => false } ],
    if => false, then => false, else => { type => 'number' },
    not => true,
    properties => {
      alpha => false,
      beta => { multipleOf => 2 },
      gamma => {
        items => [ false ], # this is silly. no reason to special-case do this.
        additionalItems => false,
        unevaluatedItems => false,
      },
    },
    patternProperties => { 'o' => false },
    additionalProperties => false,
    unevaluatedProperties => false,
    propertyNames => { pattern => '[ao]' },
  },
);

is($result->output_format, 'basic', 'Result object gets the output_format from the evaluator');

cmp_deeply(
  $result->TO_JSON,
  {
    valid => bool(0),
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'missing property: bar',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf/0/type',
        error => 'wrong type (expected number)',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf',
        error => 'subschema 0 is not valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/0/type',
        error => 'wrong type (expected number)',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/1/then/type',
        error => 'wrong type (expected array)',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/1/then',
        error => 'subschema is not valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf',
        error => 'no subschemas are valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/not',
        error => 'subschema is valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/else/type',
        error => 'wrong type (expected number)',
      },
      {
        instanceLocation => '',
        keywordLocation => '/else',
        error => 'subschema is not valid',
      },
      {
        instanceLocation => '/alpha',
        keywordLocation => '/properties/alpha',
        error => 'property not permitted',
      },
      {
        instanceLocation => '/beta',
        keywordLocation => '/properties/beta/multipleOf',
        error => 'value is not a multiple of 2',
      },
      {
        instanceLocation => '/gamma/0',
        keywordLocation => '/properties/gamma/items/0',
        error => 'subschema is false',
      },
      {
        instanceLocation => '/gamma',
        keywordLocation => '/properties/gamma/items',
        error => 'subschema is not valid against all items',
      },
      {
        instanceLocation => '/gamma/1',
        keywordLocation => '/properties/gamma/additionalItems',
        error => 'additional item not permitted',
      },
      {
        instanceLocation => '/gamma',
        keywordLocation => '/properties/gamma/additionalItems',
        error => 'subschema is not valid against all additional items',
      },
      (map +{
        instanceLocation => '/gamma/'.$_,
        keywordLocation => '/properties/gamma/unevaluatedItems',
        error => 'additional item not permitted',
      }, (0..1)),
      {
        instanceLocation => '/gamma',
        keywordLocation => '/properties/gamma/unevaluatedItems',
        error => 'subschema is not valid against all additional items',
      },
      {
        instanceLocation => '',
        keywordLocation => '/properties',
        error => 'not all properties are valid',
      },
      {
        instanceLocation => '/foo',
        keywordLocation => '/patternProperties/o',
        error => 'property not permitted',
      },
      {
        instanceLocation => '',
        keywordLocation => '/patternProperties',
        error => 'not all properties are valid',
      },
      {
        instanceLocation => '/zulu',
        keywordLocation => '/additionalProperties',
        error => 'additional property not permitted',
      },
      {
        instanceLocation => '',
        keywordLocation => '/additionalProperties',
        error => 'not all additional properties are valid',
      },
      (map +{
        instanceLocation => '/'.$_,
        keywordLocation => '/unevaluatedProperties',
        error => 'additional property not permitted',
      }, qw(alpha beta foo gamma zulu)),
      {
        instanceLocation => '',
        keywordLocation => '/unevaluatedProperties',
        error => 'not all additional properties are valid',
      },
      {
        instanceLocation => '/zulu',
        keywordLocation => '/propertyNames/pattern',
        error => 'pattern does not match',
      },
      {
        instanceLocation => '',
        keywordLocation => '/propertyNames',
        error => 'not all property names are valid',
      },
    ],
  },
  'basic format includes all errors linearly',
);

$result->output_format('flag');
cmp_deeply(
  $result->TO_JSON,
  {
    valid => bool(0),
  },
  'flag format only includes the valid property',
);

$result->output_format('terse');
cmp_deeply(
  $result->TO_JSON,
  {
    valid => bool(0),
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'missing property: bar',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf/0/type',
        error => 'wrong type (expected number)',
      },
      # "summary" error from /allOf is omitted
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/0/type',
        error => 'wrong type (expected number)',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/1/then/type',
        error => 'wrong type (expected array)',
      },
      # "summary" error from /anyOf/1/then is omitted
      # "summary" error from /anyOf is omitted
      {
        instanceLocation => '',
        keywordLocation => '/not',
        error => 'subschema is valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/else/type',
        error => 'wrong type (expected number)',
      },
      # "summary" error from /else is omitted
      {
        instanceLocation => '/alpha',
        keywordLocation => '/properties/alpha',
        error => 'property not permitted',
      },
      {
        instanceLocation => '/beta',
        keywordLocation => '/properties/beta/multipleOf',
        error => 'value is not a multiple of 2',
      },
      {
        instanceLocation => '/gamma/0',
        keywordLocation => '/properties/gamma/items/0',
        error => 'subschema is false',
      },
      # "summary" error from /properties/gamma/items is omitted
      {
        instanceLocation => '/gamma/1',
        keywordLocation => '/properties/gamma/additionalItems',
        error => 'additional item not permitted',
      },
      # "summary" error from /properties/gamma/additionalItems is omitted
      (map +{
        instanceLocation => '/gamma/'.$_,
        keywordLocation => '/properties/gamma/unevaluatedItems',
        error => 'additional item not permitted',
      }, (0..1)),
      # "summary" error from /properties/gamma/unevaluatedItems is omitted
      # "summary" error from /properties is omitted
      {
        instanceLocation => '/foo',
        keywordLocation => '/patternProperties/o',
        error => 'property not permitted',
      },
      # "summary" error from /patternProperties is omitted
      {
        instanceLocation => '/zulu',
        keywordLocation => '/additionalProperties',
        error => 'additional property not permitted',
      },
      # "summary" error from /additionalProperties is omitted
      (map +{
        instanceLocation => '/'.$_,
        keywordLocation => '/unevaluatedProperties',
        error => 'additional property not permitted',
      }, qw(alpha beta foo gamma zulu)),
      # "summary" error from /unevaluatedProperties is omitted
      {
        instanceLocation => '/zulu',
        keywordLocation => '/propertyNames/pattern',
        error => 'pattern does not match',
      },
      # "summary" error from /propertyNames is omitted
    ],
  },
  'terse format omits errors from redundant applicator keywords',
);


$js = JSON::Schema::Draft201909->new(short_circuit => 0, collect_annotations => 0);
foreach my $keyword (qw(unevaluatedItems unevaluatedProperties)) {
  $result = $js->evaluate(
    1,
    { $keyword => false },
  );

  cmp_deeply(
    $result->TO_JSON,
    {
      valid => bool(0),
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/'.$keyword,
          error => 'EXCEPTION: "'.$keyword.'" keyword present, but annotation collection is disabled',
        },
      ],
    },
    'basic format includes all errors linearly',
  );

  $result->output_format('terse');
  cmp_deeply(
    $result->TO_JSON,
    {
      valid => bool(0),
      errors => $errors,
    },
    'terse format does not omit these crucial errors',
  );
}

done_testing;
