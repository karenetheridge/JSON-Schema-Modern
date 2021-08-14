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
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft2020-12',
    })),
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
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft2020-12',
    })),
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
    $js->{_resource_index}{'https://id-no-schema1'}{document},
    noclass(superhashof({
      specification_version => 'draft2020-12',
    })),
    'named resource defaults to draft2020-12 without a $schema keyword',
  );


  my $js = JSON::Schema::Modern->new(short_circuit => 0, specification_version => 'draft7');

  cmp_deeply(
    $js->evaluate(1, true)->TO_JSON,
    { valid => true },
    'boolean schema: no $id, no $schema',
  );
  cmp_deeply(
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
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
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
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
    $js->{_resource_index}{'https://id-no-schema3'}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
    'object schema: overridden to draft7 and other keywords are ignored',
  );
};

subtest 'behaviour with a $schema keyword' => sub {
  TODO: { local $TODO = 'vocabularies are not yet swapped out once traverse starts';
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
  }

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
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
    'semantics can be changed to another draft version',
  );


  TODO: { local $TODO = 'vocabularies are not yet swapped out once traverse starts';

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
  }
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
    $js->{_resource_index}{'https://id-and-schema2'}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
    'named resource can be changed to another draft version and other keywords are ignored',
  );


  local $TODO = 'specification version cannot yet be changed from the global override';
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
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
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
    $js->{_resource_index}{''}{document},
    noclass(superhashof({
      specification_version => 'draft7',
    })),
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

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'https://bloop.com',
        '$schema' => 'https://json-schema.org/draft/2019-09/schema',
        allOf => [
          true,
          {
            '$id' => 'https://zardos.com',
            '$schema' => 'http://json-schema.org/draft-07/schema#',
          },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$schema',
          absoluteKeywordLocation => 'https://zardos.com#/$schema',
          error => 'draft specification version cannot change within a single schema document',
        },
      ],
    },
    'TODO: once a specification version has been set, it cannot change later on in the document',
  );

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'https://bloop.com',
        allOf => [
          true,
          {
            '$id' => 'https://zardos.com',
            '$schema' => 'http://json-schema.org/draft-07/schema#',
          },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$schema',
          absoluteKeywordLocation => 'https://zardos.com#/$schema',
          error => 'draft specification version cannot change within a single schema document',
        },
      ],
    },
    'TODO: root schema specification version defaults to draft 2019-09, and it is too late to change it in a subschema',
  );
};

subtest 'changing schema semantics across documents' => sub {
  local $TODO = 'vocabularies are not yet swapped out in the middle of evaluation';
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
        additionalProperties => { format => 'date' },
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
    additionalProperties => { format => 'time' },
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
          error => 'not a time',
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
          error => 'not a date',
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


  $expected = [ re(qr!^\Qno-longer-supported "dependencies" keyword present (at location "https://iam.draft2020-12-2.com")!) ];
  $expected = superbagof(@$expected) if not $ENV{AUTHOR_TESTING};
  $js->add_schema({
    '$id' => 'https://iam.draft7-2.com',
    '$schema' => 'http://json-schema.org/draft-07/schema#',
    allOf => [ { '$ref' => 'https://iam.draft2020-12-2.com' } ],
    dependencies => { foo => false },
    dependentSchemas => { foo => false },
    additionalProperties => { format => 'time' },
    unevaluatedProperties => false, # this should be ignored
  });
  cmp_deeply(
    [ warnings {
      $js->add_schema({
        '$id' => 'https://iam.draft2020-12-2.com',
        '$schema' => 'https://json-schema.org/draft/2020-12/schema',
        dependencies => { foo => false },
        dependentSchemas => { foo => false },
        additionalProperties => { format => 'date' },
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
          error => 'not a date',
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
          error => 'not a time',
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
};

subtest 'changing schema semantics within documents' => sub {
  local $TODO = 'not currently allowing for $schema keyword lower down in a document';
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
            additionalProperties => { format => 'time' },
            unevaluatedProperties => false,       # this should be ignored
          },
        ],
        dependentSchemas => { foo => false },
        additionalProperties => { format => 'date' },
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
          error => 'not a time',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/additionalProperties',
          absoluteKeywordLocation => 'https://iam.draft7-3.com#/additionalProperties',
          error => 'not all additional properties are valid',
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
          error => 'not a date',
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
            additionalProperties => { format => 'time' },
          },
        ],
        dependencies => { foo => false },
        dependentSchemas => { foo => false }, # this should be ignored
        additionalProperties => { format => 'date' },
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
          error => 'not a time',
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
          error => 'not a date',
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
};

subtest '$vocabulary' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      1,
      { '$vocabulary' => { 'https://foo' => 1 } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$vocabulary/https:~1~1foo',
          error => '$vocabulary value is not a boolean',
        },
      ],
    },
    '$vocabulary syntax check',
  );

  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      1,
      { items => { '$vocabulary' => { 'https://foo' => true } } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/items/$vocabulary',
          error => '$vocabulary can only appear at the schema resource root',
        },
      ],
    },
    '$vocabulary location check - resource root',
  );

  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      1,
      { items => { '$id' => 'foobar', '$vocabulary' => { 'https://foo' => true } } },
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

  is($metaschema_document->specification_version, 'draft2019-09',
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
};

had_no_warnings() if $ENV{AUTHOR_TESTING};
done_testing;
