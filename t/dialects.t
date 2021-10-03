use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use Test::Warnings qw(warnings :no_end_test had_no_warnings);
use Test::Deep;
use Test::Fatal;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(short_circuit => 0, validate_formats => 1);

subtest 'invalid use of the $schema keyword' => sub {
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

  cmp_deeply(
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
  cmp_deeply(
    $js->evaluate(1, true)->TO_JSON,
    { valid => true },
    'boolean schema: no $id, no $schema',
  );
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => ignore, # for boolean schemas, vocabularies do not matter
    }),
    'boolean schema: defaults to draft2020-12 without a $schema keyword',
  );

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData Unevaluated) ],
    }),
    'object schema: defaults to draft2020-12 without a $schema keyword',
  );

  cmp_deeply(
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


  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{'https://id-no-schema1'},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData Unevaluated) ],
    }),
    'named resource defaults to draft2020-12 without a $schema keyword',
  );


  my $js = JSON::Schema::Modern->new(short_circuit => 0, specification_version => 'draft7');

  cmp_deeply(
    $js->evaluate(1, true)->TO_JSON,
    { valid => true },
    'boolean schema: no $id, no $schema',
  );
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => ignore, # for boolean schemas, vocabularies do not matter
    }),
    'boolean schema: specification_version overridden',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      { unevaluatedProperties => 'not a schema' },
    )->TO_JSON,
    { valid => true },
    'object schema: no $id, no $schema, specification version overridden, other keywords are ignored during traversal',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      { unevaluatedProperties => false },
    )->TO_JSON,
    { valid => true },
    'object schema: no $id, no $schema, specification version overridden, other keywords are ignored during evaluation',
  );
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'object schema: overridden to draft7',
  );


  cmp_deeply(
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

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{'https://id-no-schema3'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'object schema: overridden to draft7 and other keywords are ignored',
  );
};

subtest 'behaviour with a $schema keyword' => sub {
  cmp_deeply(
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

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'semantics can be changed to another draft version',
  );


  cmp_deeply(
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

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{'https://id-and-schema2'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'named resource can be changed to another draft version and other keywords are ignored',
  );


  my $js = JSON::Schema::Modern->new(short_circuit => 0, specification_version => 'draft2019-09');

  cmp_deeply(
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

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'unnamed resource can be changed to another draft version',
  );


  cmp_deeply(
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

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{''},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'unnamed resource can be changed to another draft version',
  );
};

subtest 'setting or changing schema semantics in a single document' => sub {
  cmp_deeply(
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

subtest 'changing schema semantics across documents' => sub {
  my $expected = [ re(qr!^\Qno-longer-supported "dependencies" keyword present (at location "https://iam.draft2019-09.com")!) ];
  $expected = superbagof(@$expected) if not $ENV{AUTHOR_TESTING};
  cmp_deeply(
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

  cmp_deeply(
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
          error => 'not an ipv4',
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
          error => 'not an ipv6',
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
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft2019-09.com'},
    superhashof({
      specification_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft7.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
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
  cmp_deeply(
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

  cmp_deeply(
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
          error => 'not an ipv6',
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
          error => 'not an ipv4',
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
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft7-2.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft2020-12-2.com'},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData Unevaluated) ],
    }),
    'resources for subschema',
  );
};

subtest 'changing schema semantics within documents' => sub {
  cmp_deeply(
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
            dependentSchemas => { foo => false }, # this should be ignored
            additionalProperties => { format => 'ipv4' },
            unevaluatedProperties => false,       # this should be ignored
          },
        ],
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
          error => 'not an ipv4',
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
          error => 'not an ipv6',
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
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft2019-09-3.com'},
    superhashof({
      specification_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft7-3.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'resources for subschema',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 'hi' },
      {
        '$id' => 'https://iam.draft7-4.com',
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        allOf => [
          {
            '$id' => 'https://iam.draft2020-12-4.com',
            '$schema' => 'https://json-schema.org/draft/2020-12/schema',
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
          error => 'not an ipv4',
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
          error => 'not an ipv6',
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
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft7-4.com'},
    superhashof({
      specification_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    'resources for top level schema',
  );
  cmp_deeply(
    $js->{_resource_index}{'https://iam.draft2020-12-4.com'},
    superhashof({
      specification_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData Unevaluated) ],
    }),
    'resources for subschema',
  );
};

undef $js;

subtest '$vocabulary' => sub {
  cmp_deeply(
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
          error => '$vocabulary value is not a boolean',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$vocabulary',
          error => 'metaschemas must have an $id',
        },
      ],
    },
    '$vocabulary syntax checks',
  );

  cmp_deeply(
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

  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      1,
      {
        items => {
          '$id' => 'foobar',
          '$vocabulary' => { 'https://json-schema.org/draft/2020-12/vocab/core' => true },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/items/$vocabulary',
          absoluteKeywordLocation => 'foobar#/$vocabulary',
          error => '$vocabulary can only appear at the document root',
        },
      ],
    },
    '$vocabulary location check - document root',
  );


  my $js = JSON::Schema::Modern->new;
  cmp_deeply(
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

  cmp_deeply(
    $js->{_resource_index}{'http://mymetaschema'},
    {
      canonical_uri => str('http://mymetaschema'),
      path => '',
      specification_version => 'draft2020-12',
      document => ignore,
      vocabularies => [
        map 'JSON::Schema::Modern::Vocabulary::'.$_,
          qw(Core Applicator Validation FormatAnnotation Content MetaData Unevaluated),
      ],
    },
    'metaschemas are not saved on the resource',
  );

  ok($js->evaluate(1, { '$schema' => 'http://mymetaschema' }), '..but once we use the schema as a metaschema,');

  cmp_deeply(
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

subtest 'standard metaschemas' => sub {
  my $js = JSON::Schema::Modern->new;
  my ($draft202012_metaschema) = $js->get('https://json-schema.org/draft/2020-12/schema');

  cmp_deeply(
    $js->evaluate($draft202012_metaschema, 'https://json-schema.org/draft/2020-12/schema')->TO_JSON,
    { valid => true },
    'main metaschema evaluated against its own URI',
  );

  cmp_deeply(
    $js->evaluate($draft202012_metaschema, $draft202012_metaschema)->TO_JSON,
    { valid => true },
    'main metaschema evaluated against its own content',
  );

  my ($draft202012_core_metaschema) = $js->get('https://json-schema.org/draft/2020-12/meta/core');

  cmp_deeply(
    $js->evaluate($draft202012_core_metaschema, 'https://json-schema.org/draft/2020-12/schema')->TO_JSON,
    { valid => true },
    'core metaschema evaluated against the main metaschema URI',
  );

  cmp_deeply(
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

  cmp_deeply(
    $js->evaluate(false, 'http://localhost:1234/my-meta-schema')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          absoluteKeywordLocation => 'http://localhost:1234/my-meta-schema#/type',
          error => 'wrong type (expected object)',
        },
      ],
    },
    'custom metaschema restricts schemas to objects',
  );

  # the evaluation of $recursiveAnchor in the schema proves that the proper specification version
  # was detected via the $schema keyword
  cmp_deeply(
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
          error => 'wrong type (expected object)',
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

  cmp_deeply(
    $js->evaluate({ allOf => [ {} ] }, 'http://localhost:1234/my-meta-schema')->TO_JSON,
    { valid => true },
    'objects are acceptable schemas to this metaschema',
  );

  cmp_deeply(
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
  cmp_deeply(
    $js->{_resource_index}{'https://localhost:1234/my-schema'},
    superhashof({
      specification_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Applicator Validation FormatAnnotation Content MetaData) ],
    }),
    '..and schema uses the correct spec version and vocabularies',
  );
};

subtest 'custom metaschemas, with custom vocabularies' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_deeply(
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
    '$id' => 'https://metaschema/with/wrong/spec',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2019-09/vocab/validation' => true,
      'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
      'https://unknown' => true,
      'https://unknown2' => false,
    },
  });
  cmp_deeply(
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
  cmp_deeply(
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
  cmp_deeply(
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
  cmp_deeply(
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
  cmp_deeply(
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

  cmp_deeply(
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

  cmp_deeply(
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
  cmp_deeply(
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

  cmp_deeply(
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

had_no_warnings() if $ENV{AUTHOR_TESTING};
done_testing;
