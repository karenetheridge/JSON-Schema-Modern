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

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;
ok(!$js->strict, 'strict defaults to false');

my $schema = {
  '$id' => 'my_loose_schema',
  type => 'object',
  properties => {
    foo => {
      title => 'bloop', # produces an annotation for 'title' with value 'bloop'
      bloop => 'hi',    # unknown keyword
      barf => 'no',     # unknown keyword
    },
  },
};

my $document = $js->add_schema($schema);

cmp_result(
  $js->evaluate({ foo => 1 }, 'my_loose_schema')->TO_JSON,
  { valid => true },
  'by default, unknown keywords are allowed in evaluate()',
);

cmp_result(
  $js->evaluate({ foo => 1 }, 'my_loose_schema', { strict => 1 })->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/foo',
        keywordLocation => '/properties/foo',
        absoluteKeywordLocation => 'my_loose_schema#/properties/foo',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during evaluation via a config override',
);

cmp_result(
  $js->validate_schema($schema)->TO_JSON,
  { valid => true },
  'by default, unknown keywords are allowed in validate_schema()',
);

cmp_result(
  $js->validate_schema($schema, { strict => 1 })->TO_JSON,
  my $schema_result = {
    valid => false,
    errors => [
      {
        instanceLocation => '/properties/foo/barf',
        keywordLocation => '',
        absoluteKeywordLocation => 'https://json-schema.org/draft/2020-12/schema',
        error => 'unknown keyword found in schema: barf',
      },
      {
        instanceLocation => '/properties/foo/bloop',
        keywordLocation => '',
        absoluteKeywordLocation => 'https://json-schema.org/draft/2020-12/schema',
        error => 'unknown keyword found in schema: bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords in validate_schema() via a config override',
);


$js = JSON::Schema::Modern->new(strict => 1);
$js->add_document($document);

cmp_result(
  $js->evaluate({ foo => 1 }, $document->canonical_uri)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/foo',
        keywordLocation => '/properties/foo',
        absoluteKeywordLocation => 'my_loose_schema#/properties/foo',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during evaluation, even if the document was already traversed',
);

cmp_result(
  $js->validate_schema($schema)->TO_JSON,
  $schema_result,
  'strict mode disallows unknown keywords in the schema data passed to validate_schema()',
);

delete $schema->{'$id'};
cmp_result(
  $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '', # note no instance location - indicating evaluation has not started
        keywordLocation => '/properties/foo',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during traverse',
);

my $lax_metaschema = {
  '$id' => 'my_lax_metaschema',
  '$schema' => 'https://json-schema.org/draft/2020-12/schema',
  '$dynamicAnchor' => 'meta',
  '$ref' => 'https://json-schema.org/draft/2020-12/schema',
  properties => {
    bloop => true,    # bloop is now a recognized property
  },
};

$js->add_schema($lax_metaschema);
$schema->{'$schema'} = 'my_lax_metaschema';

cmp_result(
  $js->validate_schema($schema)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/properties/foo/barf',
        keywordLocation => '',
        absoluteKeywordLocation => 'my_lax_metaschema',
        error => 'unknown keyword found in schema: barf',
      },
    ],
  },
  'strict mode only detected one property this time - bloop is evaluated',
);


$schema->{'$schema'} = 'http://json-schema.org/draft-07/schema#';

cmp_result(
  $js->validate_schema($schema)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/properties/foo/barf',
        keywordLocation => '',
        absoluteKeywordLocation => 'http://json-schema.org/draft-07/schema',
        error => 'unknown keyword found in schema: barf',
      },
      {
        instanceLocation => '/properties/foo/bloop',
        keywordLocation => '',
        absoluteKeywordLocation => 'http://json-schema.org/draft-07/schema',
        error => 'unknown keyword found in schema: bloop',
      },
    ],
  },
  'strict mode detects unknown keywords using draft7',
);


subtest 'strict and short-circuit' => sub {
  cmp_result(
    JSON::Schema::Modern->new->evaluate(
      { foo => 1, bar => 2 },
      {
        if => {
          required => ['bar'],
          properties => {
            bar => { const => 1 },
          },
          additionalProperties => false,
          bloop => 1,
        },
        then => false,
        else => true,
      },
      { strict => 1 },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/if',
          error => 'unknown keyword found: bloop',
        },
        # no errors from additionalProperties, because we abort from within the 'if' subschema,
        # and 'if' doesn't preserve its errors
      ],
    },
    'strict mode will work properly even when some keywords short-circuit',
  );

  cmp_result(
    JSON::Schema::Modern->new->evaluate(
      { alpha => { beta => 2, gamma => 3 } },
      # this is not a valid test, because we never preserve errors from 'if'.
      # so we need something with a subschema that preserves errors, like properties.
      my $schema = {
        properties => {
          alpha => {
            required => ['beta'],
            properties => {
              beta => { const => 2 },
            },
            additionalProperties => false,
            bloop => 1,
          },
        },
      },
      { strict => 1, short_circuit => 1 },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
         instanceLocation => '/alpha/gamma',
         keywordLocation => '/properties/alpha/additionalProperties',
         error => 'additional property not permitted',
        },
        {
         instanceLocation => '/alpha',
         keywordLocation => '/properties/alpha/additionalProperties',
         error => 'not all additional properties are valid',
        },
        {
         instanceLocation => '/alpha',
         keywordLocation => '/properties/alpha',
         error => 'unknown keyword found: bloop',
        },
      ],
    },
    'strict mode will still work even when enabled together with short_circuit',
  )
};

done_testing;
