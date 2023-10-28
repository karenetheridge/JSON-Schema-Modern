use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::Fatal;

use lib 't/lib';
use Helper;

my ($annotation_result, $validation_result);
subtest 'no validation' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 0)
      ->evaluate('abc', { format => 'uuid' })->TO_JSON,
    $annotation_result = {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          annotation => 'uuid',
        },
      ],
    },
    'validate_formats=0 disables format assertion behaviour; annotation is still produced',
  );

  cmp_deeply(
    JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 1)
      ->evaluate('abc', { format => 'uuid' }, { validate_formats => 0 })->TO_JSON,
    $annotation_result,
    'format validation can be turned off in evaluate()',
  );
};

subtest 'simple validation' => sub {
  my $js = JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 1);

  cmp_deeply(
    $js->evaluate(123, { format => 'uuid' })->TO_JSON,
    $annotation_result,
    'non-string values are valid, and produce an annotation',
  );

  cmp_deeply(
    $js->evaluate(
      '2eb8aa08-aa98-11ea-b4aa-73b441d16380',
      { format => 'uuid' },
    )->TO_JSON,
    $annotation_result,
    'simple success',
  );

  cmp_deeply(
    $js->evaluate('123', { format => 'uuid' })->TO_JSON,
    $validation_result = {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          error => 'not a uuid',
        },
      ],
    },
    'simple failure',
  );

  $js = JSON::Schema::Modern->new(collect_annotations => 1);
  ok(!$js->validate_formats, 'format_validation defaults to false');
  cmp_deeply(
    $js->evaluate('123', { format => 'uuid' }, { validate_formats => 1 })->TO_JSON,
    $validation_result,
    'format validation can be turned on in evaluate()',
  );

  ok(!$js->validate_formats, '...but the value is still false on the object');
};

subtest 'unknown format attribute' => sub {
  # see https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.7.2.3
  # "An implementation MUST NOT fail validation or cease processing due to an unknown format
  # attribute."
  my $js = JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 1);
  cmp_deeply(
    $js->evaluate('hello', { format => 'whargarbl' })->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          annotation => 'whargarbl',
        },
      ],
    },
    'unrecognized format attributes do not cause validation failure; annotation is still produced',
  );
};

subtest 'override a format sub' => sub {
  like(
    exception {
      JSON::Schema::Modern->new(
        validate_formats => 1,
        format_validations => +{ uuid => 1 },
      )
    },
    qr/Value "1" did not pass type constraint "Optional\[CodeRef\]"/,
    'check syntax of override to existing format',
  );

  like(
    exception {
      JSON::Schema::Modern->new(
        validate_formats => 1,
        format_validations => +{ mult_5 => 1 },
      )
    },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation for a new format',
  );

  my $js = JSON::Schema::Modern->new(
    collect_annotations => 1,
    validate_formats => 1,
    format_validations => +{
      uuid => sub { $_[0] =~ /^[A-Z]+$/ },
      mult_5 => +{ type => 'integer', sub => sub { ($_[0] % 5) == 0 } },
    },
  );

  like(
    exception { $js->add_format_validation(
      mult_2 => +{ type => 'integer', sub => sub { ($_[0] % 2) == 0 } },
      uuid_bad => 1,
    ) },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation when adding an override to existing format',
  );

  like(
    exception { $js->add_format_validation(mult_5_bad => 1) },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation when adding a new format',
  );

  cmp_deeply(
    $js->evaluate(
      [
        { uuid => '2eb8aa08-aa98-11ea-b4aa-73b441d16380', mult_5 => 3 },
        { uuid => 3, mult_5 => 'abc' },
      ],
      {
        items => {
          properties => {
            uuid => { format => 'uuid' },
            mult_5 => { format => 'mult_5' },
          },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0/mult_5',
          keywordLocation => '/items/properties/mult_5/format',
          error => 'not a mult_5',
        },
        {
          instanceLocation => '/0/uuid',
          keywordLocation => '/items/properties/uuid/format',
          error => 'not a uuid',
        },
        {
          instanceLocation => '/0',
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
    'swapping out format implementation turns success into failure; wrong types are still valid',
  );
};

subtest 'different formats after document creation' => sub {
  # the default evaluator does not know the mult_5 format
  my $document = JSON::Schema::Modern::Document->new(schema => { format => 'mult_5' });

  my $js1 = JSON::Schema::Modern->new(validate_formats => 1, collect_annotations => 0);
  cmp_deeply(
    $js1->evaluate(3, $document)->TO_JSON,
    {
      valid => true,
    },
    'the default evaluator does not know the mult_5 format',
  );

  my $js2 = JSON::Schema::Modern->new(
    collect_annotations => 1,
    validate_formats => 1,
    format_validations => +{ mult_5 => +{ type => 'integer', sub => sub { ($_[0] % 5) == 0 } } },
  );

  cmp_deeply(
    $js2->evaluate(5, $document)->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          annotation => 'mult_5',
        },
      ],
    },
    'the runtime evaluator is used for annotation configs',
  );

  cmp_deeply(
    $js2->evaluate(3, $document)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          error => 'not a mult_5',
        },
      ],
    },
    'the runtime evaluator is used to fetch the format implementations',
  );
};

subtest 'toggle validate_formats after adding schema' => sub {
  my $js = JSON::Schema::Modern->new;
  my $document = $js->add_schema(my $uri = 'http://localhost:1234/ipv4', { format => 'ipv4' });

  cmp_deeply(
    $js->evaluate('hello', $uri)->TO_JSON,
    { valid => true },
    'assertion behaviour is off initially',
  );

  cmp_deeply(
    $js->evaluate('hello', $uri, { validate_formats => 1 })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'http://localhost:1234/ipv4#/format',
          error => 'not an ipv4',
        },
      ],
    },
    'assertion behaviour can be enabled later with an already-loaded schema',
  );

  cmp_deeply(
    $js->evaluate('127.0.0.1', $uri, { validate_formats => 1 })->TO_JSON,
    { valid => true },
    'valid assertion behaviour does not die',
  );

  my $js2 = JSON::Schema::Modern->new(validate_formats => 1);
  cmp_deeply(
    $js2->evaluate('hello', $document)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'http://localhost:1234/ipv4#/format',
          error => 'not an ipv4',
        },
      ],
    },
    'a schema document can be used with another evaluator with assertion behaviour',
  );

  cmp_deeply(
    $js2->evaluate('127.0.0.1', $uri)->TO_JSON,
    { valid => true },
    'valid assertion behaviour does not die',
  );
};

subtest 'custom metaschemas' => sub {
  my $js = JSON::Schema::Modern->new;
  $js->add_schema({
    '$id' => 'https://metaschema/format-assertion/false',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/format-assertion' => false,
    },
  });
  $js->add_schema({
    '$id' => 'https://metaschema/format-assertion/true',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/format-assertion' => true,
    },
  });

  cmp_deeply(
    $js->evaluate(
      'not-an-ip',
      {
        '$id' => 'https://schema/ipv4/false',
        '$schema' => 'https://metaschema/format-assertion/false',
        type => 'string',
        format => 'ipv4',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'https://schema/ipv4/false#/format',
          error => 'not an ipv4',
        },
      ],
    },
    'custom metaschema using format-assertion=true validates formats',
  );

  cmp_deeply(
    $js->evaluate(
      'not-an-ip',
      {
        '$id' => 'https://schema/ipv4/true',
        '$schema' => 'https://metaschema/format-assertion/true',
        type => 'string',
        format => 'ipv4',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'https://schema/ipv4/true#/format',
          error => 'not an ipv4',
        },
      ],
    },
    'custom metaschema using format-assertion=true validates formats',
  );
};

subtest 'unimplemented formats' => sub {
  my $js = JSON::Schema::Modern->new(validate_formats => 1);
  cmp_deeply(
    $js->evaluate(
      'hello',
      {
        format => 'uri-template',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          error => 'unimplemented format "uri-template"',
        },
      ],
    },
    'error when an unimplemented format is used',
  );

  cmp_deeply(
    $js->evaluate(
      'hello',
      {
        anyOf => [
          { minLength => 1 },
          { format => 'uri-template' },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/format',
          error => 'unimplemented format "uri-template"',
        },
      ],
    },
    'error is seen even when containing subschema would be true',
  );
};

subtest 'format: pure_integer' => sub {
  my $js = JSON::Schema::Modern->new(
    validate_formats => 1,
    format_validations => +{
      pure_integer => +{ type => 'integer', sub => sub ($value) {
        !ref($value) && (B::svref_2object(\$value)->FLAGS & B::SVf_IOK)
      } },
    },
  );

  my $decoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0);
  cmp_deeply(
    $js->evaluate(
      [
        map $decoder->decode($_),
          '"hello"',
          '3.1',
          '3.0',
          '3',
      ],
      {
        items => {
          type => 'integer',
          format => 'pure_integer',
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '/1',
          keywordLocation => '/items/type',
          error => 'got number, not integer',
        },
        {
          instanceLocation => '/2',
          keywordLocation => '/items/format',
          error => 'not a pure_integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'pure_integer format with type',
  );

  cmp_deeply(
    $js->evaluate(
      [
        map $decoder->decode($_),
          '"hello"',
          '3.1',
          '3.0',
          '3',
      ],
      {
        items => {
          format => 'pure_integer',
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/2',
          keywordLocation => '/items/format',
          error => 'not a pure_integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'pure_integer format without type',
  );
};

subtest 'unsupported formats in draft7' => sub {
  my $js = JSON::Schema::Modern->new(specification_version => 'draft7', validate_formats => 1);

  cmp_deeply(
    my $res = $js->evaluate('123', { format => 'duration' })->TO_JSON,
    { valid => true },
    'duration is not implemented in draft7',
  );

  cmp_deeply(
    $js->evaluate('123', { format => 'uuid' })->TO_JSON,
    { valid => true },
    'uuid is not implemented in draft7',
  );
};

done_testing;
