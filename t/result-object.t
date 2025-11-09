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

use Test2::Tools::Exception;
use builtin::compat 'refaddr';
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

cmp_result(
  $result->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'object is missing property: bar',
      },
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
        error => 'subschema is true',
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
    ],
  },
  'basic format includes all errors linearly',
);

$result->output_format('flag');
cmp_result(
  $result->TO_JSON,
  {
    valid => false,
  },
  'flag format only includes the valid property',
);

$result->output_format('terse');
cmp_result(
  $result->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'object is missing property: bar',
      },
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
        error => 'subschema is true',
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
    ],
  },
  'terse format omits errors from redundant applicator keywords',
);


$js = JSON::Schema::Modern->new(validate_formats => 1);
{
  $result = $js->evaluate(
    'foo',
    { format => 'uuid'},
  );

  cmp_result(
    $result->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          error => 'not a valid uuid string',
        },
      ],
    },
    'basic format includes all errors linearly',
  );

  $result->output_format('terse');
  cmp_result(
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

  cmp_result(
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
          error => 'value is less than 6',
        },
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/patternProperties/%5B~0~1%5D/minimum',  # [~/]
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties/%5B~0~1%5D/minimum',  # [~/]
          error => 'value is less than 7',
        },
        {
          instanceLocation => '#/%7B%7D/my~0tilde~1slash-property',
          keywordLocation => '#/properties/%7B%7D/patternProperties/~0/minimum',  # ~
          absoluteKeywordLocation => 'foo.json#/properties/%7B%7D/patternProperties/~0/minimum',  # ~
          error => 'value is less than 5',
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
          depth => 0,
          mode => 'evaluate',
          keyword => 'keyword '.$count.'-'.$_,
          instance_location => '/instance_location/'.$count.'-'.$_,
          keyword_location => '/keyword_location/'.$count.'-'.$_,
          $valid ? (annotation => 'annotation '.$count.'-'.$_) : (error => 'error '.$count.'-'.$_),
        ), 0..1
      ],
    )
  } 0..3;

  cmp_result(
    (my $one_true = $results[0] & $results[1]),
    all(
      methods(valid => bool(0)),
      listmethods(
        errors => [
          map methods(TO_JSON => {
            instanceLocation => '/instance_location/0-'.$_,
            keywordLocation => '/keyword_location/0-'.$_,
            error => 'error 0-'.$_,
          }), 0..1
        ],
        annotations => [
          map methods(TO_JSON => {
            instanceLocation => '/instance_location/1-'.$_,
            keywordLocation => '/keyword_location/1-'.$_,
            annotation => 'annotation 1-'.$_,
          }), 0..1
        ],
      ),
    ),
    'ANDing true and false results = invalid, but errors and annotations both preserved',
  );

  cmp_result(
    (my $both_true = $results[1] & $results[3]),
    all(
      methods(valid => bool(1)),
      listmethods(
        annotations => [
          map {
            my $count = $_;
            map methods(TO_JSON => {
              instanceLocation => '/instance_location/'.$count.'-'.$_,
              keywordLocation => '/keyword_location/'.$count.'-'.$_,
              annotation => 'annotation '.$count.'-'.$_,
            }), 0..1
          } 1,3
        ],
      ),
    ),
    'ANDing two true results = valid',
  );

  cmp_result(
    (my $both_false = $results[0] & $results[2]),
    all(
      methods(valid => bool(0)),
      listmethods(
        errors => [
          map {
            my $count = $_;
            map methods(TO_JSON => {
              instanceLocation => '/instance_location/'.$count.'-'.$_,
              keywordLocation => '/keyword_location/'.$count.'-'.$_,
              error => 'error '.$count.'-'.$_,
            }), 0..1
          } 0,2
        ],
      ),
    ),
    'ANDing two false results = invalid',
  );

  like(
    dies { $results[0] & 0 },
    qr/wrong type for \& operation/,
    'only Result objects can be processed',
  );

  is(
    refaddr(my $itself = $results[0] & $results[0]),
    refaddr($results[0]),
    'ANDing a result with itself is a no-op',
  );
};

subtest annotations => sub {
  my %args = (
    valid => 1,
    annotations => [
      JSON::Schema::Modern::Annotation->new(
        depth => 0,
        keyword => 'foo',
        instance_location => '/instance_location',
        keyword_location => '/keyword_location ',
        annotation => 'annotation',
      )
    ],
  );

  cmp_result(
    JSON::Schema::Modern::Result->new(%args)->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/instance_location',
          keywordLocation => '/keyword_location ',
          annotation => 'annotation',
        },
      ],
    },
    'by default, annotations are included in the formatted output',
  );

  cmp_result(
    JSON::Schema::Modern::Result->new(%args, formatted_annotations => 0)->TO_JSON,
    { valid => true },
    'but inclusion can be disabled',
  );
};

subtest 'data_only' => sub {
  my $result = JSON::Schema::Modern::Result->new(
    valid => 0,
    errors => [
      JSON::Schema::Modern::Error->new(
        depth => 1,
        mode => 'evaluate',
        keyword => 'hello',
        instance_location => '/foo/bar',
        keyword_location => '/allOf/0/hello',
        error => 'schema is invalid',
      ),
      JSON::Schema::Modern::Error->new(
        depth => 1,
        mode => 'evaluate',
        keyword => 'goodbye',
        instance_location => '/foo/bar',
        keyword_location => '/allOf/1/goodbye',
        error => 'schema is invalid',
      ),
      JSON::Schema::Modern::Error->new(
        depth => 0,
        mode => 'evaluate',
        keyword => 'allOf',
        instance_location => '/foo/bar',
        keyword_location => '/allOf',
        error => 'subschemas 0, 1 are not valid',
      ),
    ],
  );

  is(
    $result->format('data_only'),
    "'/foo/bar': schema is invalid\n'/foo/bar': subschemas 0, 1 are not valid",
    'data_only format outputs a string of data locations only, with duplicates removed',
  );

  is(
    JSON::Schema::Modern::Result->new(
      valid => 0,
      errors => [
        map JSON::Schema::Modern::Error->new(
          do { my $e = $_; map +($_ => $e->$_), qw(depth keyword instance_location keyword_location error) },
          mode => 'traverse',
        ), $result->errors
      ],
    )->format('data_only'),
    "'/allOf/0/hello': schema is invalid\n'/allOf/1/goodbye': schema is invalid\n'/allOf': subschemas 0, 1 are not valid",
    'data_only format uses keyword locations when result came from traverse',
  );
};

subtest 'construction errors' => sub {
  my $error = JSON::Schema::Modern::Error->new(
    error => 'oh no!',
    mode => 'evaluate',
    depth => 1,
    keyword => 'me',
    instance_location => '',
    keyword_location => '',
  );

  like(
    dies { JSON::Schema::Modern::Result->new(valid => true, errors => [$error]) },
    qr/^inconsistent inputs: errors is not empty but valid is true/,
    'valid results must not have errors',
  );

  like(
    dies { JSON::Schema::Modern::Result->new(valid => false, errors => []) },
    qr/^inconsistent inputs: errors is empty but valid is false/,
    'invalid results must have errors',
  );

  ok(
    lives { JSON::Schema::Modern::Result->new(valid => true, errors => []) },
    'no errors when valid is true and errors is empty',
  );

  ok(
    lives { JSON::Schema::Modern::Result->new(valid => false, errors => [$error]) },
    'no errors when valid is false and errors is not empty',
  );
};

done_testing;
