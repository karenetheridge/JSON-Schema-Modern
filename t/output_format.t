use strict;
use warnings;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Fatal;
use JSON::Schema::Modern;
use Scalar::Util 'refaddr';
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(short_circuit => 0, collect_annotations => 1);
is($js->output_format, 'basic', 'output_format defaults to basic');

my $result = $js->evaluate(
  { alpha => 1, beta => 1, foo => 1, gamma => [ 0, 1 ], theta => [ 1 ], zulu => 2 },
  {
    required => [ 'bar' ],
    allOf => [
      { type => 'number' },
      { oneOf => [ { type => 'number' } ] },
      { oneOf => [ true, true ] },
    ],
    anyOf => [ { type => 'number' }, { if => true, then => { type => 'array' }, else => false } ],
    if => false, then => false, else => { type => 'number' },
    not => true,
    properties => {
      alpha => false,
      beta => { multipleOf => 2 },
      gamma => {
        prefixItems => [ false ],
        items => false,
        unevaluatedItems => false,
      },
      theta => { items => false },
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
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/allOf/0/type',
        error => 'got object, not number',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf/1/oneOf/0/type',
        error => 'got object, not number',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf/1/oneOf',
        error => 'no subschemas are valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf/2/oneOf',
        error => 'multiple subschemas are valid: 0, 1',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf',
        error => 'subschemas 0, 1, 2 are not valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/0/type',
        error => 'got object, not number',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/1/then/type',
        error => 'got object, not array',
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
        error => 'got object, not number',
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
        keywordLocation => '/properties/gamma/prefixItems/0',
        error => 'item not permitted',
      },
      {
        instanceLocation => '/gamma',
        keywordLocation => '/properties/gamma/prefixItems',
        error => 'not all items are valid',
      },
      {
        instanceLocation => '/gamma/1',
        keywordLocation => '/properties/gamma/items',
        error => 'additional item not permitted',
      },
      {
        instanceLocation => '/gamma',
        keywordLocation => '/properties/gamma/items',
        error => 'subschema is not valid against all items',
      },
      {
        instanceLocation => '/theta/0',
        keywordLocation => '/properties/theta/items',
        error => 'item not permitted',
      },
      {
        instanceLocation => '/theta',
        keywordLocation => '/properties/theta/items',
        error => 'subschema is not valid against all items',
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
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'missing property: bar',
      },
    ],
  },
  'basic format includes all errors linearly',
);

$result->output_format('flag');
cmp_deeply(
  $result->TO_JSON,
  {
    valid => false,
  },
  'flag format only includes the valid property',
);

$result->output_format('terse');
cmp_deeply(
  $result->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/allOf/0/type',
        error => 'got object, not number',
      },
      {
        instanceLocation => '',
        keywordLocation => '/allOf/1/oneOf/0/type',
        error => 'got object, not number',
      },
      # - "summary" error from /allOf/1/oneOf is omitted
      {
        instanceLocation => '',
        keywordLocation => '/allOf/2/oneOf',
        error => 'multiple subschemas are valid: 0, 1',
      },
      # - "summary" error from /allOf is omitted
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/0/type',
        error => 'got object, not number',
      },
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/1/then/type',
        error => 'got object, not array',
      },
      # - "summary" error from /anyOf/1/then is omitted
      # - "summary" error from /anyOf is omitted
      {
        instanceLocation => '',
        keywordLocation => '/not',
        error => 'subschema is valid',
      },
      {
        instanceLocation => '',
        keywordLocation => '/else/type',
        error => 'got object, not number',
      },
      # - "summary" error from /else is omitted
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
        keywordLocation => '/properties/gamma/prefixItems/0',
        error => 'item not permitted',
      },
      # - "summary" error from /properties/gamma/prefixItems is omitted
      {
        instanceLocation => '/gamma/1',
        keywordLocation => '/properties/gamma/items',
        error => 'additional item not permitted',
      },
      # - "summary" error from /properties/gamma/items is omitted
      # - "summary" error from /properties/gamma/unevaluatedItems is omitted
      {
        instanceLocation => '/theta/0',
        keywordLocation => '/properties/theta/items',
        error => 'item not permitted',
      },
      # - "summary" error from /properties/theta/items is omitted
      # - "summary" error from /properties is omitted
      {
        instanceLocation => '/foo',
        keywordLocation => '/patternProperties/o',
        error => 'property not permitted',
      },
      # - "summary" error from /patternProperties is omitted
      {
        instanceLocation => '/zulu',
        keywordLocation => '/additionalProperties',
        error => 'additional property not permitted',
      },
      # - "summary" error from /additionalProperties is omitted
      # - "summary" error from /unevaluatedProperties is omitted
      {
        instanceLocation => '/zulu',
        keywordLocation => '/propertyNames/pattern',
        error => 'pattern does not match',
      },
      # - "summary" error from /propertyNames is omitted
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'missing property: bar',
      },
    ],
  },
  'terse format omits errors from redundant applicator keywords',
);


$js = JSON::Schema::Modern->new(short_circuit => 0, collect_annotations => 0);
foreach my $keyword (qw(unevaluatedItems unevaluatedProperties)) {
  $result = $js->evaluate(
    1,
    { $keyword => false },
  );

  cmp_deeply(
    $result->TO_JSON,
    {
      valid => false,
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
      valid => false,
      errors => $errors,
    },
    'terse format does not omit these crucial errors',
  );
}

subtest 'strict_basic' => sub {
  # see "JSON pointer escaping" in t/errors.t

  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft2019-09', output_format => 'strict_basic')->evaluate(
      { '{}' => { 'my~tilde/slash-property' => 1 } },
      {
        '$id' => 'foo.json',
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
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/properties/my~0tilde~1slash-property',
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/properties/my~0tilde~1slash-property',
          error => 'property not permitted',
        },
        {
          instanceLocation => '#/%7B%7D',
          keywordLocation => '#/properties/%7B%7D/properties',
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/patternProperties/~1/minimum',  # /
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties/~1/minimum',  # /
          error => 'value is smaller than 6',
        },
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/patternProperties/%5B~0~1%5D/minimum',  # [~/]
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties/%5B~0~1%5D/minimum',  # [~/]
          error => 'value is smaller than 7',
        },
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/patternProperties/~0/minimum',  # ~
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties/~0/minimum',  # ~
          error => 'value is smaller than 5',
        },
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/patternProperties/~0.*~1', # ~.*/
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties/~0.*~1', # ~.*/
          error => 'property not permitted',
        },
        {
          instanceLocation => '#/%7B%7D',
          keywordLocation => '#/properties/%7B%7D/patternProperties',
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '#',
          keywordLocation => '#/properties',
          absoluteKeywordLocation => 'foo.json#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'strict_basic turns json pointers into URIs, including uri escapes',
  );
};

subtest 'AND two result objects together' => sub {
  my @results = map {
    my $count = $_;
    my $valid = $count % 2;
    JSON::Schema::Modern::Result->new(
      valid => $valid,
      ($valid ? 'annotations' : 'errors') => [
        map ${\ ('JSON::Schema::Modern::'.($valid ? 'Annotation' : 'Error'))}->new(
          keyword => 'keyword '.$count.'-'.$_,
          instance_location => 'instance location '.$count.'-'.$_,
          keyword_location => 'keyword location '.$count.'-'.$_,
          $valid ? (annotation => 'annotation '.$count.'-'.$_) : (error => 'error '.$count.'-'.$_),
        ), 0..1
      ],
    )
  } 0..3;

  cmp_deeply(
    (my $one_true = $results[0] & $results[1]),
    all(
      methods(valid => false),
      listmethods(
        errors => [
          map methods(TO_JSON => {
            instanceLocation => 'instance location 0-'.$_,
            keywordLocation => 'keyword location 0-'.$_,
            error => 'error 0-'.$_,
          }), 0..1
        ],
        annotations => [
          map methods(TO_JSON => {
            instanceLocation => 'instance location 1-'.$_,
            keywordLocation => 'keyword location 1-'.$_,
            annotation => 'annotation 1-'.$_,
          }), 0..1
        ],
      ),
    ),
    'ANDing true and false results = invalid, but errors and annotations both preserved',
  );

  cmp_deeply(
    (my $both_true = $results[1] & $results[3]),
    all(
      methods(valid => true),
      listmethods(
        annotations => [
          map {
            my $count = $_;
            map methods(TO_JSON => {
              instanceLocation => 'instance location '.$count.'-'.$_,
              keywordLocation => 'keyword location '.$count.'-'.$_,
              annotation => 'annotation '.$count.'-'.$_,
            }), 0..1
          } 1,3
        ],
      ),
    ),
    'ANDing two true results = valid',
  );

  cmp_deeply(
    (my $both_false = $results[0] & $results[2]),
    all(
      methods(valid => false),
      listmethods(
        errors => [
          map {
            my $count = $_;
            map methods(TO_JSON => {
              instanceLocation => 'instance location '.$count.'-'.$_,
              keywordLocation => 'keyword location '.$count.'-'.$_,
              error => 'error '.$count.'-'.$_,
            }), 0..1
          } 0,2
        ],
      ),
    ),
    'ANDing two false results = invalid',
  );

  like(
    exception { $results[0] & 0 },
    qr/wrong type for \& operation/,
    'only Result objects can be processed',
  );

  is(
    refaddr(my $itself = $results[0] & $results[0]),
    refaddr($results[0]),
    'ANDing a result with itself is a no-op',
  );
};

done_testing;
