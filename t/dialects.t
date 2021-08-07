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

my $js = JSON::Schema::Modern->new(short_circuit => 0);

subtest 'invalid $schema' => sub {
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
    {
      valid => true,
    },
    '$schema can appear adjacent to any $id',
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
    'once a specification version has been set, it cannot change later on in the document',
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
    'root schema specification version defaults to draft 2019-09, and it is too late to change it in a subschema',
  );

  my $expected = [ re(qr!^\Qno-longer-supported "dependencies" keyword present (at location "https://iam.draft2019-09.com")!) ];
  $expected = superbagof(@$expected) if not $ENV{AUTHOR_TESTING};
  cmp_deeply(
    [ warnings {
      $js->add_schema({
        '$id' => 'https://iam.draft2019-09.com',
        dependencies => { foo => false },
        dependentSchemas => { foo => false },
        '$ref' => 'https://iam.draft7.com',
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
  });

  cmp_deeply(
    $js->evaluate({ foo => 1 }, 'https://iam.draft2019-09.com')->TO_JSON,
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
      ],
    },
    'switching between specification versions is acceptable when crossing document boundaries',
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

had_no_warnings() if $ENV{AUTHOR_TESTING};
done_testing;
