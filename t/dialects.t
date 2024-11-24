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

use Test::Warnings qw(warnings :no_end_test had_no_warnings allow_warnings);
use Test::Fatal;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(short_circuit => 0, validate_formats => 1);

subtest 'invalid use of the $schema keyword' => sub {
  cmp_result(
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
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$schema',
          error => '$schema can only appear at the schema resource root',
        },
      ],
    },
    '$schema can only appear at the root of a schema, when there is no canonical URI',
  );

  cmp_result(
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
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$schema',
          absoluteKeywordLocation => 'https://bloop.com#/allOf/1/$schema',
          error => '$schema can only appear at the schema resource root',
        },
      ],
    },
    '$schema can only appear where the canonical URI has no fragment, when there is a canonical URI',
  );

  cmp_result(
    $js->evaluate(
      1,
      {
        '$id' => 'https://bloop3.com',
        '$defs' => {
          my_def => {
            '$schema' => 'https://json-schema.org/draft/2019-09/schema',
          },
        },
        '$ref' => '#/$defs/my_def',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs/my_def/$schema',
          absoluteKeywordLocation => 'https://bloop3.com#/$defs/my_def/$schema',
          error => '$schema can only appear at the schema resource root',
        },
      ],
    },
    'this is still not a resource root, even in a $ref target',
  );
};

subtest 'defaults without a $schema keyword' => sub {
  cmp_result(
    $js->evaluate(1, true)->TO_JSON,
    { valid => true },
    'boolean schema: no $id, no $schema',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => ignore, # for boolean schemas, vocabularies do not matter
    }),
    'boolean schema: defaults to draft2020-12 without a $schema keyword',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      { unevaluatedProperties => false },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/unevaluatedProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'object schema: no $id, no $schema',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated) ],
    }),
    'object schema: defaults to draft2020-12 without a $schema keyword',
  );

  cmp_result(
    $js->evaluate(
      1,
      { '$defs' => { foo => { not => 'invalid subschema' } } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs/foo/not',
          error => 'invalid schema type: string',
        },
      ],
    },
    '"not" keyword, from the Applicator vocabulary, is traversed at the root level',
  );


  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-no-schema1',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/unevaluatedProperties',
          absoluteKeywordLocation => 'https://id-no-schema1#/unevaluatedProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          absoluteKeywordLocation => 'https://id-no-schema1#/unevaluatedProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'object schema: $id, no $schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://id-no-schema1'},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated) ],
    }),
    'named resource defaults to draft2020-12 without a $schema keyword',
  );


  my $js = JSON::Schema::Modern->new(short_circuit => 0, specification_version => 'draft7');

  cmp_result(
    $js->evaluate(1, true)->TO_JSON,
    { valid => true },
    'boolean schema: no $id, no $schema',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => ignore, # for boolean schemas, vocabularies do not matter
    }),
    'boolean schema: specification_version overridden',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      { unevaluatedProperties => 'not a schema' },
    )->TO_JSON,
    { valid => true },
    'object schema: no $id, no $schema, specification version overridden, other keywords are ignored during traversal',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      { unevaluatedProperties => false },
    )->TO_JSON,
    { valid => true },
    'object schema: no $id, no $schema, specification version overridden, other keywords are ignored during evaluation',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'object schema: overridden to draft7',
  );


  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-no-schema2',
        unevaluatedProperties => 'not a schema',
      },
    )->TO_JSON,
    { valid => true },
    'object schema: $id, no $schema, unrecognized+invalid keywords are ignored during traversal',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-no-schema3',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    'object schema: $id, no $schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://id-no-schema3'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'object schema: overridden to draft7 and other keywords are ignored',
  );
};

subtest 'behaviour with a $schema keyword' => sub {
  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => 'not a schema',
      },
    )->TO_JSON,
    { valid => true },
    'object schema: no $id, has $schema, unrecognized+invalid keywords are ignored during traversal',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    'object schema: no $id, has $schema, unrecognized keywords are ignored during evaluation',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'semantics can be changed to another draft version',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$schema' => 'http://json-schema.org/draft-07/schema',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    'schema is accepted with $schema without an empty fragment',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    '..and is still recognized as draft7',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-and-schema1',
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => 'not a schema',
      },
    )->TO_JSON,
    { valid => true },
    '$id and $schema, unrecognized+invalid keywords are ignored during traversal',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-and-schema2',
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    '$id and $schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://id-and-schema2'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'named resource can be changed to another draft version and other keywords are ignored',
  );


  my $js = JSON::Schema::Modern->new(short_circuit => 0, specification_version => 'draft2019-09');

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => 'not a schema',
      },
    )->TO_JSON,
    { valid => true },
    'no $id, specification version overridden twice; unrecognized+invalid keywords are ignored during traversal',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    'no $id, specification version overridden twice, other keywords are ignored during evaluation',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'unnamed resource can be changed to another draft version',
  );


  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-and-schema3',
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => 'not a schema',
      },
    )->TO_JSON,
    { valid => true },
    'no $id, specification version overridden twice; unrecognized+invalid keywords are ignored during traversal',
  );

  cmp_result(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'https://id-and-schema4',
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    'no $id, specification version overridden twice, other keywords are ignored during evaluation',
  );
  cmp_result(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'unnamed resource can be changed to another draft version',
  );
};

subtest 'setting or changing specification versions in a single document' => sub {
  cmp_result(
    $js->evaluate(
      1,
      {
        '$id' => 'https://bloop2.com',
        allOf => [
          true,
          {
            '$id' => 'https://newid.com',
            '$schema' => 'https://json-schema.org/draft/2020-12/schema',
          },
        ],
      },
    )->TO_JSON,
    { valid => true },
    '$schema can appear adjacent to any $id',
  );
};

subtest 'changing specification versions across documents' => sub {
  my $expected = [ re(qr!^\Qno-longer-supported "dependencies" keyword present (at location "https://iam.draft2019-09.com")!) ];
  $expected = superbagof(@$expected) if not $ENV{AUTHOR_TESTING};
  cmp_result(
    [ warnings {
      $js->add_schema({
        '$id' => 'https://iam.draft2019-09.com',
        '$schema' => 'https://json-schema.org/draft/2019-09/schema',
        '$ref' => 'https://iam.draft7.com',
        dependencies => { foo => false },
        dependentSchemas => { foo => false },
        additionalProperties => { format => 'ipv6' },
      })
    } ],
    $expected,
    'no unexpected warnings',
  );
  $js->add_schema({
    '$id' => 'https://iam.draft7.com',
    '$schema' => 'http://json-schema.org/draft-07/schema#',
    dependencies => { foo => false },
    dependentSchemas => { foo => false },
    additionalProperties => { format => 'ipv4' },
    unevaluatedProperties => false, # this should be ignored
  });

  cmp_result(
    $js->evaluate({ foo => 'hi' }, 'https://iam.draft2019-09.com')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/dependencies/foo',
          absoluteKeywordLocation => 'https://iam.draft7.com#/dependencies/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/dependencies',
          absoluteKeywordLocation => 'https://iam.draft7.com#/dependencies',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/$ref/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft7.com#/additionalProperties/format',
          error => 'not a valid ipv4',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft7.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas/foo',
          absoluteKeywordLocation => 'https://iam.draft2019-09.com#/dependentSchemas/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas',
          absoluteKeywordLocation => 'https://iam.draft2019-09.com#/dependentSchemas',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft2019-09.com#/additionalProperties/format',
          error => 'not a valid ipv6',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft2019-09.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'switching between specification versions is acceptable when crossing document boundaries',
  );
  cmp_result(
    $js->{_resource_index}{'https://iam.draft2019-09.com'},
    superhashof({
      specification_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://iam.draft7.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'resources for subschema',
  );


  $expected = [ re(qr!^\Qno-longer-supported "dependencies" keyword present (at location "https://iam.draft2020-12-2.com")!) ];
  $expected = superbagof(@$expected) if not $ENV{AUTHOR_TESTING};
  $js->add_schema({
    '$id' => 'https://iam.draft7-2.com',
    '$schema' => 'http://json-schema.org/draft-07/schema#',
    allOf => [ { '$ref' => 'https://iam.draft2020-12-2.com' } ],
    dependencies => { foo => false },
    dependentSchemas => { foo => false },
    additionalProperties => { format => 'ipv4' },
    unevaluatedProperties => false, # this should be ignored
  });
  cmp_result(
    [ warnings {
      $js->add_schema({
        '$id' => 'https://iam.draft2020-12-2.com',
        '$schema' => 'https://json-schema.org/draft/2020-12/schema',
        dependencies => { foo => false },
        dependentSchemas => { foo => false },
        additionalProperties => { format => 'ipv6' },
      })
    } ],
    $expected,
    'no unexpected warnings',
  );

  cmp_result(
    $js->evaluate({ foo => 'hi' }, 'https://iam.draft7-2.com')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/dependentSchemas/foo',
          absoluteKeywordLocation => 'https://iam.draft2020-12-2.com#/dependentSchemas/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/dependentSchemas',
          absoluteKeywordLocation => 'https://iam.draft2020-12-2.com#/dependentSchemas',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/allOf/0/$ref/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft2020-12-2.com#/additionalProperties/format',
          error => 'not a valid ipv6',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft2020-12-2.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://iam.draft7-2.com#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependencies/foo',
          absoluteKeywordLocation => 'https://iam.draft7-2.com#/dependencies/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependencies',
          absoluteKeywordLocation => 'https://iam.draft7-2.com#/dependencies',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft7-2.com#/additionalProperties/format',
          error => 'not a valid ipv4',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft7-2.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'switching between specification versions is acceptable when crossing document boundaries',
  );
  cmp_result(
    $js->{_resource_index}{'https://iam.draft7-2.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://iam.draft2020-12-2.com'},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated) ],
    }),
    'resources for subschema',
  );
};

subtest 'changing specification versions within documents' => sub {
  allow_warnings(1);
  cmp_result(
    $js->evaluate(
      { foo => 'hi' },
      {
        '$id' => 'https://iam.draft2019-09-3.com',
        '$schema' => 'https://json-schema.org/draft/2019-09/schema',
        allOf => [
          {
            '$id' => 'https://iam.draft7-3.com',
            '$schema' => 'http://json-schema.org/draft-07/schema#',
            dependencies => { foo => false },
            dependentSchemas => 'blurp', # this should be ignored
            additionalProperties => { format => 'ipv4' },
            unevaluatedProperties => 'blurp',       # this should be ignored
          },
        ],
        dependencies => 'blurp',  # this should be ignored
        dependentSchemas => { foo => false },
        additionalProperties => { format => 'ipv6' },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/dependencies/foo',
          absoluteKeywordLocation => 'https://iam.draft7-3.com#/dependencies/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/dependencies',
          absoluteKeywordLocation => 'https://iam.draft7-3.com#/dependencies',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/allOf/0/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft7-3.com#/additionalProperties/format',
          error => 'not a valid ipv4',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft7-3.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://iam.draft2019-09-3.com#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas/foo',
          absoluteKeywordLocation => 'https://iam.draft2019-09-3.com#/dependentSchemas/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas',
          absoluteKeywordLocation => 'https://iam.draft2019-09-3.com#/dependentSchemas',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft2019-09-3.com#/additionalProperties/format',
          error => 'not a valid ipv6',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft2019-09-3.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'switching between specification versions is acceptable within a document, draft2019-09 -> draft7',
  );
  allow_warnings(0);

  cmp_result(
    $js->{_resource_index}{'https://iam.draft2019-09-3.com'},
    superhashof({
      specification_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://iam.draft7-3.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'resources for subschema',
  );

  allow_warnings(1);
  cmp_result(
    $js->evaluate(
      { foo => 'hi' },
      {
        '$id' => 'https://iam.draft7-4.com',
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        allOf => [
          {
            '$id' => 'https://iam.draft2020-12-4.com',
            '$schema' => 'https://json-schema.org/draft/2020-12/schema',
            dependencies => { foo => false }, # this should be ignored
            dependentSchemas => { foo => false },
            additionalProperties => { format => 'ipv4' },
          },
        ],
        dependencies => { foo => false },
        dependentSchemas => { foo => false }, # this should be ignored
        additionalProperties => { format => 'ipv6' },
        unevaluatedProperties => false,       # this should be ignored
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/dependentSchemas/foo',
          absoluteKeywordLocation => 'https://iam.draft2020-12-4.com#/dependentSchemas/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/dependentSchemas',
          absoluteKeywordLocation => 'https://iam.draft2020-12-4.com#/dependentSchemas',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/allOf/0/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft2020-12-4.com#/additionalProperties/format',
          error => 'not a valid ipv4',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft2020-12-4.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://iam.draft7-4.com#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependencies/foo',
          absoluteKeywordLocation => 'https://iam.draft7-4.com#/dependencies/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependencies',
          absoluteKeywordLocation => 'https://iam.draft7-4.com#/dependencies',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft7-4.com#/additionalProperties/format',
          error => 'not a valid ipv6',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft7-4.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'switching between specification versions is acceptable within a document, draft7 -> draf2020-12',
  );
  allow_warnings(0);
  cmp_result(
    $js->{_resource_index}{'https://iam.draft7-4.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_result(
    $js->{_resource_index}{'https://iam.draft2020-12-4.com'},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated) ],
    }),
    'resources for subschema',
  );

  allow_warnings(1);
  cmp_result(
    $js->evaluate(
      { foo => 'hi' },
      {
        '$id' => 'https://iam.draft2020-12-5.com',
        '$schema' => 'https://json-schema.org/draft/2020-12/schema',
        allOf => [
          {
            id => 'https://iam.draft4-5.com',
            '$schema' => 'http://json-schema.org/draft-04/schema#',
            definitions => { blah => false },
            dependencies => { foo => false },
            dependentSchemas => { foo => false }, # this should be ignored
            allOf => [ { '$ref' => '#/definitions/blah' } ],
            additionalProperties => { format => 'ipv4' },
          },
        ],
        dependencies => { foo => false },         # this should be ignored
        dependentSchemas => { foo => false },
        additionalProperties => { format => 'ipv6' },
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/allOf/0/$ref',
          absoluteKeywordLocation => 'https://iam.draft4-5.com#/definitions/blah',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/allOf',
          absoluteKeywordLocation => 'https://iam.draft4-5.com#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/dependencies/foo',
          absoluteKeywordLocation => 'https://iam.draft4-5.com#/dependencies/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/dependencies',
          absoluteKeywordLocation => 'https://iam.draft4-5.com#/dependencies',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/allOf/0/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft4-5.com#/additionalProperties/format',
          error => 'not a valid ipv4',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft4-5.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://iam.draft2020-12-5.com#/allOf',
          error => 'subschema 0 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas/foo',
          absoluteKeywordLocation => 'https://iam.draft2020-12-5.com#/dependentSchemas/foo',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas',
          absoluteKeywordLocation => 'https://iam.draft2020-12-5.com#/dependentSchemas',
          error => 'not all dependencies are satisfied',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/format',
          absoluteKeywordLocation => 'https://iam.draft2020-12-5.com#/additionalProperties/format',
          error => 'not a valid ipv6',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft2020-12-5.com#/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'switching between specification versions is acceptable within a document, draft2020-12 -> draft4',
  );
  allow_warnings(0);

  # XXX check resources here too
};

undef $js;

subtest '$vocabulary syntax' => sub {
  cmp_result(
    JSON::Schema::Modern->new->evaluate(
      1,
      {
        '$vocabulary' => {
          'https://json-schema.org/draft/2020-12/vocab/core' => true,
          '#/notauri' => false,
          'https://foo' => 1,
          'https://json-schema.org/draft/2019-09/vocab/validation' => true,
          'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
          'https://unknown' => true,    # ignored.. for now
          'https://unknown2' => false,  # ""
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$vocabulary/#~1notauri',
          error => '"#/notauri" is not a valid URI',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$vocabulary/https:~1~1foo',
          error => '$vocabulary value at "https://foo" is not a boolean',
        },
      ],
    },
    '$vocabulary syntax checks',
  );

  cmp_result(
    JSON::Schema::Modern->new->evaluate(
      1,
      {
        '$id' => 'http://mymetaschema',
        items => { '$vocabulary' => { 'https://json-schema.org/draft/2020-12/vocab/applicator' => true } },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/items/$vocabulary',
          absoluteKeywordLocation => 'http://mymetaschema#/items/$vocabulary',
          error => '$vocabulary can only appear at the schema resource root',
        },
      ],
    },
    '$vocabulary location check - resource root',
  );

  cmp_result(
    JSON::Schema::Modern->new->evaluate(
      1,
      {
        items => {
          '$id' => 'foobar',
          '$vocabulary' => { 'https://json-schema.org/draft/2020-12/vocab/core' => true },
        },
      },
    )->TO_JSON,
    { valid => true },
    '$vocabulary location check - document root',
  );


  my $js = JSON::Schema::Modern->new;
  cmp_result(
    $js->evaluate(
      1,
      {
        '$id' => 'http://mymetaschema',
        '$vocabulary' => {
          'https://json-schema.org/draft/2020-12/vocab/core' => true,
          'https://json-schema.org/draft/2020-12/vocab/applicator' => false,
        },
      },
    )->TO_JSON,
    { valid => true },
    'successfully evaluated a metaschema that specifies vocabularies',
  );

  cmp_result(
    $js->{_resource_index}{'http://mymetaschema'},
    {
      canonical_uri => str('http://mymetaschema'),
      path => '',
      specification_version => 'draft2020-12',
      document => ignore,
      vocabularies => [
        map 'JSON::Schema::Modern::Vocabulary::'.$_,
          qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated),
      ],
      configs => {},
    },
    'metaschemas are not saved on the resource',
  );

  cmp_result(
    $js->evaluate(1, { '$schema' => 'http://mymetaschema' })->TO_JSON,
    { valid => true },
    '..but once we use the schema as a metaschema,',
  );

  cmp_result(
    $js->{_metaschema_vocabulary_classes}{'http://mymetaschema'},
    [
      'draft2020-12',
      [
        'JSON::Schema::Modern::Vocabulary::Core',
        'JSON::Schema::Modern::Vocabulary::Applicator',
      ],
    ],
    '... the vocabulary information is now cached in the evaluator',
  );
};

subtest 'changing dialects (same specification version)' => sub {
  my $js = JSON::Schema::Modern->new(collect_annotations => 1);

  $js->add_schema({
    '$id' => 'https://my_metaschema',
    '$schema' => 'https://json-schema.org/draft/2020-12/schema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/validation' => true,
      # no applicator!
    },
  });

  $js->add_schema({
    '$id' => 'https://my_other_schema',
    '$schema' => 'https://my_metaschema',
    type => 'object',
    properties => { bar => false }, # this keyword should only annotate
    zeta => 1,
  });

  cmp_result(
    $js->evaluate(
      { foo => { bar => 1 } },
      {
        '$id' => 'https://example.com',
        additionalProperties => {
          '$ref' => 'https://my_other_schema',
        },
      },
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/$ref/properties',
          absoluteKeywordLocation => 'https://my_other_schema#/properties',
          annotation => { bar => false },
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/$ref/zeta',
          absoluteKeywordLocation => 'https://my_other_schema#/zeta',
          annotation => 1,
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://example.com#/additionalProperties',
          annotation => ['foo'],
        },
      ],
    },
    'evaluation of the subschema in another document correctly uses the new $id and $schema',
  );

  cmp_result(
    $js->evaluate(
      { foo => { bar => 1 } },
      {
        '$id' => 'https://example2.com',
        '$defs' => {
          'my_def' => {
            '$id' => 'https://my_other_schema2',
            '$schema' => 'https://my_metaschema',
            type => 'object',
            properties => { bar => false }, # this keyword should only annotate
            zeta => 1,
          },
        },
        additionalProperties => {
          '$ref' => 'https://my_other_schema2',
        },
      },
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/$ref/properties',
          absoluteKeywordLocation => 'https://my_other_schema2#/properties',
          annotation => { bar => false },
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/$ref/zeta',
          absoluteKeywordLocation => 'https://my_other_schema2#/zeta',
          annotation => 1,
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://example2.com#/additionalProperties',
          annotation => ['foo'],
        },
      ],
    },
    'evaluation of the subschema in the same document via a $ref correctly uses the new $id and $schema',
  );

  cmp_result(
    $js->evaluate(
      { foo => { bar => 1 } },
      {
        '$id' => 'https://example3.com',
        additionalProperties => {
          '$id' => 'https://my_other_schema3',
          '$schema' => 'https://my_metaschema',
          type => 'object',
          properties => { bar => false }, # this keyword should only annotate
          zeta => 1,
        },
      },
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/properties',
          absoluteKeywordLocation => 'https://my_other_schema3#/properties',
          annotation => { bar => false },
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/zeta',
          absoluteKeywordLocation => 'https://my_other_schema3#/zeta',
          annotation => 1,
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://example3.com#/additionalProperties',
          annotation => ['foo'],
        },
      ],
    },
    'evaluation of the subschema in the same document with no $ref correctly uses the new $id and $schema',
  );

  cmp_result(
    $js->traverse({
      '$id' => 'https://example4.com',
      additionalProperties => {
        '$id' => 'https://my_other_schema4',
        '$schema' => 'https://my_metaschema',
        type => 'object',
        properties => 1,  # this is not a real keyword as the assertion vocabulary is not present
      },
    }),
    superhashof({ errors => [] }),
    'no errors found when traversing a document with a malformed keyword outside the dialect',
  );
};

subtest 'standard metaschemas' => sub {
  my $js = JSON::Schema::Modern->new;
  my ($draft202012_metaschema) = $js->get('https://json-schema.org/draft/2020-12/schema');

  cmp_result(
    $js->evaluate($draft202012_metaschema, 'https://json-schema.org/draft/2020-12/schema')->TO_JSON,
    { valid => true },
    'main metaschema evaluated against its own URI',
  );

  cmp_result(
    $js->evaluate($draft202012_metaschema, $draft202012_metaschema)->TO_JSON,
    { valid => true },
    'main metaschema evaluated against its own content',
  );

  my ($draft202012_core_metaschema) = $js->get('https://json-schema.org/draft/2020-12/meta/core');

  cmp_result(
    $js->evaluate($draft202012_core_metaschema, 'https://json-schema.org/draft/2020-12/schema')->TO_JSON,
    { valid => true },
    'core metaschema evaluated against the main metaschema URI',
  );

  cmp_result(
    $js->evaluate($draft202012_core_metaschema, $draft202012_core_metaschema)->TO_JSON,
    { valid => true },
    'core metaschema evaluated against its own content',
  );
};

subtest 'custom metaschemas, without custom vocabularies' => sub {
  my $js = JSON::Schema::Modern->new;

  my $metaschema_document = $js->add_schema(my $metaschema = {
    '$id' => 'http://localhost:1234/my-meta-schema',
    '$schema' => 'https://json-schema.org/draft/2019-09/schema',
    type => 'object',
    '$recursiveAnchor' => true,
    allOf => [ { '$ref' => 'https://json-schema.org/draft/2019-09/schema' } ],
  });

  is($metaschema_document->_get_resource($metaschema->{'$id'})->{specification_version}, 'draft2019-09',
    'specification version detected from standard metaschema URI');

  cmp_result(
    $js->evaluate(false, 'http://localhost:1234/my-meta-schema')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          absoluteKeywordLocation => 'http://localhost:1234/my-meta-schema#/type',
          error => 'got boolean, not object',
        },
      ],
    },
    'custom metaschema restricts schemas to objects',
  );

  # the evaluation of $recursiveAnchor in the schema proves that the proper specification version
  # was detected via the $schema keyword
  cmp_result(
    $js->evaluate(
      { allOf => [ false ] },
      'http://localhost:1234/my-meta-schema',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/allOf/0',
          keywordLocation => '/allOf/0/$ref/allOf/1/$ref/properties/allOf/$ref/items/$recursiveRef/type',
          absoluteKeywordLocation => 'http://localhost:1234/my-meta-schema#/type',
          error => 'got boolean, not object',
        },
        {
          instanceLocation => '/allOf',
          keywordLocation => '/allOf/0/$ref/allOf/1/$ref/properties/allOf/$ref/items',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/applicator#/$defs/schemaArray/items',
          error => 'subschema is not valid against all items',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/allOf/1/$ref/properties',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/applicator#/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/allOf',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/schema#/allOf',
          error => 'subschema 1 is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'http://localhost:1234/my-meta-schema#/allOf',
          error => 'subschema 0 is not valid',
        },
      ],
    },
    'custom metaschema recurses to standard metaschema',
  );

  cmp_result(
    $js->evaluate({ allOf => [ {} ] }, 'http://localhost:1234/my-meta-schema')->TO_JSON,
    { valid => true },
    'objects are acceptable schemas to this metaschema',
  );

  cmp_result(
    $js->evaluate(
      1,
      {
        '$id' => 'https://localhost:1234/my-schema',
        '$schema' => 'http://localhost:1234/my-meta-schema',
      },
    )->TO_JSON,
    { valid => true },
    'metaschemas without $vocabulary can still be used in the $schema keyword',
  );
  cmp_result(
    $js->{_resource_index}{'https://localhost:1234/my-schema'},
    superhashof({
      specification_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    '..and schema uses the correct spec version and vocabularies',
  );
};

subtest 'custom metaschemas, with custom vocabularies' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://unknown/metaschema' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => 'EXCEPTION: unable to find resource https://unknown/metaschema',
        },
      ],
    },
    'custom metaschemas are okay, but the document must be known',
  );

  $js->add_schema({
    '$id' => 'https://metaschema/with/misplaced/vocabulary/keyword/base',
    items => {
      '$id' => 'subschema',
      '$vocabulary' => { 'https://json-schema.org/draft/2020-12/vocab/core' => true },
    },
  });
  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://metaschema/with/misplaced/vocabulary/keyword/subschema' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary',
          absoluteKeywordLocation => 'https://metaschema/with/misplaced/vocabulary/keyword/subschema#/$vocabulary',
          error => '$vocabulary can only appear at the document root',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://metaschema/with/misplaced/vocabulary/keyword/subschema" is not a valid metaschema',
        },
      ],
    },
    '$vocabulary location check - document root',
  );


  $js->add_schema('https://metaschema/with/no/id',
    { '$vocabulary' => { 'https://json-schema.org/draft/2020-12/vocab/core' => true } });
  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://metaschema/with/no/id' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary',
          absoluteKeywordLocation => 'https://metaschema/with/no/id#/$vocabulary',
          error => 'metaschemas must have an $id',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://metaschema/with/no/id" is not a valid metaschema',
        },
      ],
    },
    'metaschemas must have an i$id',
  );

  $js->add_schema({
    '$id' => 'https://metaschema/with/wrong/spec',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2019-09/vocab/validation' => true,
      'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
      'https://unknown' => true,
      'https://unknown2' => false,
    },
  });
  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://metaschema/with/wrong/spec' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary/https:~1~1json-schema.org~1draft~12019-09~1vocab~1validation',
          absoluteKeywordLocation => 'https://metaschema/with/wrong/spec#/$vocabulary/https:~1~1json-schema.org~1draft~12019-09~1vocab~1validation',
          error => '"https://json-schema.org/draft/2019-09/vocab/validation" uses draft2019-09, but the metaschema itself uses draft2020-12',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary/https:~1~1unknown',
          absoluteKeywordLocation => 'https://metaschema/with/wrong/spec#/$vocabulary/https:~1~1unknown',
          error => '"https://unknown" is not a known vocabulary',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://metaschema/with/wrong/spec" is not a valid metaschema',
        },
      ],
    },
    '$vocabulary validation that must be deferred until used as a metaschema',
  );

  $js->add_schema({
    '$id' => 'https://metaschema/missing/vocabs',
    '$vocabulary' => {},
  });
  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://metaschema/missing/vocabs' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary',
          absoluteKeywordLocation => 'https://metaschema/missing/vocabs#/$vocabulary',
          error => 'the first vocabulary (by evaluation_order) must be Core',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://metaschema/missing/vocabs" is not a valid metaschema',
        },
      ],
    },
    'metaschemas using "$vocabulary" must contain vocabularies',
  );

  $js->add_schema({
    '$id' => 'https://metaschema/missing/core',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
    },
  });
  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://metaschema/missing/core' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary',
          absoluteKeywordLocation => 'https://metaschema/missing/core#/$vocabulary',
          error => 'the first vocabulary (by evaluation_order) must be Core',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://metaschema/missing/core" is not a valid metaschema',
        },
      ],
    },
    'metaschemas must contain the Core vocabulary',
  );


  $js->add_schema({
    '$id' => 'https://my/first/metaschema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      # note: no validation!
    },
  });
  cmp_result(
    $js->evaluate(
      1,
      {
        '$id' => my $id = 'https://my/first/schema/with/custom/metaschema',
        '$schema' => 'https://my/first/metaschema',
        minimum => 10,
      },
    )->TO_JSON,
    { valid => true },
    'validation succeeds because "minimum" never gets run',
  );
  cmp_result(
    $js->{_resource_index}{$id},
    {
      canonical_uri => str($id),
      path => '',
      specification_version => 'draft2020-12',
      document => ignore,
      vocabularies => [
        map 'JSON::Schema::Modern::Vocabulary::'.$_,
          qw(Core Applicator),
      ],
      configs => {},
    },
    'determined vocabularies to use for this schema',
  );
};

subtest 'custom vocabulary classes with add_vocabulary()' => sub {
  my $js = JSON::Schema::Modern->new;

  like(
    exception { $js->add_vocabulary('MyVocabulary::Does::Not::Exist') },
    qr!an't locate MyVocabulary/Does/Not/Exist.pm in \@INC!,
    'vocabulary class must exist',
  );

  like(
    exception { $js->add_vocabulary('MyVocabulary::MissingRole') },
    qr/Value "MyVocabulary::MissingRole" did not pass type constraint/,
    'vocabulary class must implement the role',
  );

  like(
    exception { $js->add_vocabulary('MyVocabulary::MissingSub') },
    qr/Can't apply JSON::Schema::Modern::Vocabulary to MyVocabulary::MissingSub - missing vocabulary, keywords/,
    'vocabulary class must implement some subs',
  );

  cmp_result(
    [ warnings {
      like(
        exception { $js->add_vocabulary('MyVocabulary::BadVocabularySub1') },
        qr/Undef did not pass type constraint/,
        'vocabulary() sub in the vocabulary class must return uri => specification_version pairs',
      )
    } ],
    [ re(qr/Odd number of elements in pairs/) ],
    'parse error from bad vocab sub',
  );

  like(
    exception { $js->add_vocabulary('MyVocabulary::BadVocabularySub2') },
    qr!Value "https://some/uri#/invalid/uri" did not pass type constraint!,
    'vocabulary() sub in the vocabulary class must contain valid absolute, fragmentless URIs',
  );

  like(
    exception { $js->add_vocabulary('MyVocabulary::BadVocabularySub3') },
    qr/Value "wrongdraft" did not pass type constraint/,
    'vocabulary() sub in the vocabulary class must reference a known specification version',
  );


  is(
    exception { $js->add_vocabulary('MyVocabulary::BadEvaluationOrder') },
    undef,
    'added a vocabulary sub',
  );

  cmp_result(
    $js->{_vocabulary_classes},
    superhashof({ 'https://vocabulary/with/bad/evaluation/order' => [ 'draft2020-12', 'MyVocabulary::BadEvaluationOrder' ] }),
    'vocabulary was successfully added',
  );

  $js->add_schema({
    '$id' => 'https://my/first/metaschema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/validation' => true,
      'https://vocabulary/with/bad/evaluation/order' => true,
    },
  });
  cmp_result(
    $js->evaluate(1, { '$schema' => 'https://my/first/metaschema' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema/$vocabulary',
          absoluteKeywordLocation => 'https://my/first/metaschema#/$vocabulary',
          error => 'JSON::Schema::Modern::Vocabulary::Validation and MyVocabulary::BadEvaluationOrder have a conflicting evaluation_order',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://my/first/metaschema" is not a valid metaschema',
        },
      ],
    },
    'custom vocabulary class has a conflicting evaluation_order',
  );

  is(
    exception { $js->add_vocabulary('MyVocabulary::StringComparison') },
    undef,
    'added another vocabulary sub',
  );

  $js->add_schema({
    '$id' => 'https://my/first/working/metaschema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://vocabulary/string/comparison' => true,
    },
  });

  cmp_result(
    $js->evaluate(
      'bloop',
      {
        '$id' => 'https://my/first/schema/with/custom/metaschema',
        '$schema' => 'https://my/first/working/metaschema',
        stringLessThan => 'alpha',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/stringLessThan',
          absoluteKeywordLocation => 'https://my/first/schema/with/custom/metaschema#/stringLessThan',
          error => 'value is not stringwise less than alpha',
        },
      ],
    },
    'custom vocabulary class used by a custom metaschema used by a schema',
  );
};

subtest '$schema points to a boolean schema' => sub {
  my $js = JSON::Schema::Modern->new;
  $js->add_schema('https://my_boolean_schema' => true);

  cmp_result(
    my $result = $js->evaluate(
      1,
      {
        '$id' => '/foo',
        '$schema' => 'https://my_boolean_schema',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          # we haven't processed $id yet, so we don't know the absolute location
          error => 'metaschemas must be objects',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"https://my_boolean_schema" is not a valid metaschema',
        },
      ],
    },
    '$schema cannot reference a boolean schema',
  );
};

had_no_warnings() if $ENV{AUTHOR_TESTING};
done_testing;
