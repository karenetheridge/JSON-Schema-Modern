use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use Test::Warnings qw(warnings :no_end_test had_no_warnings);
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

{
  like(
    exception { ()= JSON::Schema::Modern->new(specification_version => 'ohhai')->evaluate(true, true) },
    qr/^Value "ohhai" did not pass type constraint/,
    'unrecognized $SPECIFICATION_VERSION',
  );
}

subtest '$schema' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      true,
      { '$schema' => 'http://wrong/url' },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => re(qr/^custom \$schema URIs are not yet supported \(must be one of: /),
        },
      ],
    },
    '$schema, when set, must contain a recognizable URI',
  );

  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft7')->evaluate(
      true,
      {
        '$schema' => 'https://json-schema.org/draft/2019-09/schema',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"$schema" indicates a different version than that requested by \'specification_version\'',
        },
      ],
    },
    'specification_version cannot be inconsistent with $schema keyword value',
  );
};

subtest '$ref and older specification versions' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      true,
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        '$ref' => '#/definitions/foo',
      }
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '$schema and $ref cannot be used together in older drafts',
        },
      ],
    },
    '$schema and $ref cannot be used together, when $schema is too old',
  );
};

subtest '<= draft7: $ref in combination with any other keyword causes the other keywords to be ignored' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new(
      specification_version => 'draft7',
      collect_annotations => 1,
    )->evaluate(
      1,
      {
        allOf => [
          true,
          {
            '$ref' => '#/allOf/0',
            maximum => 0,
          },
        ],
      }
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/maximum',
          annotation => 0,
        },
      ],
    },
    'keywords adjacent to $ref are not evaluated',
  );
};

subtest '$ref adjacent to a path used in a $ref' => sub {
  local $TODO = 'fixing this requires traversing the schema to mark which locations are unusable';
  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft7')->evaluate(
      true,
      {
        allOf => [
          true,
          {
            anyOf => [ false, true ],
            '$ref' => '#/allOf/0',
          },
          {
            # a reference that cannot be resolved
            '$ref' => '#/allOf/1/anyOf/1',
          },
        ],
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/$ref',
          error => 'EXCEPTION: unable to find resource #/definitions/bar/anyOf/1',
        },
      ],
    },
    'the presence of $ref also kills the use of other $refs to adjacent locations',
  );
};

subtest '$defs support' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft7')->evaluate(
      1,
      my $schema = {
        '$defs' => 1,
        allOf => [ { '$ref' => '#/$defs/foo' } ],
      }
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref',
          error => 'EXCEPTION: unable to find resource #/$defs/foo',
        },
      ],
    },
    '$defs is not recognized in <= draft7',
  );

  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft2019-09')->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs',
          error => '$defs value is not an object',
        },
      ],
    },
    '$defs is supported in > draft7',
  );
};

subtest 'definitions support' => sub {
  my $schema;
  my @warnings = warnings {
    cmp_deeply(
      JSON::Schema::Modern->new(specification_version => 'draft2019-09')->evaluate(
        1,
        $schema = {
          definitions => 1,
          allOf => [ { '$ref' => '#/definitions/foo' } ],
        }
      )->TO_JSON,
      {
        valid => false,
        errors => [
          {
            instanceLocation => '',
            keywordLocation => '/allOf/0/$ref',
            error => 'EXCEPTION: unable to find resource #/definitions/foo',
          },
        ],
      },
      'definitions is not recognized in >= draft2019-09',
    );
  };
  cmp_deeply(
    \@warnings,
    [ re(qr/^no-longer-supported "definitions" keyword present/) ],
    'warned when using no-longer-supported keyword',
  );

  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft7')->evaluate(1, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/definitions',
          error => 'definitions value is not an object',
        },
      ],
    },
    'definitions is supported in <= draft7',
  );
};

subtest 'dependencies, dependentRequired, dependentSchemas' => sub {
  my $js = JSON::Schema::Modern->new(specification_version => 'draft2019-09');
  my $dependencies_schema;
  my @warnings = warnings {
    cmp_deeply(
      $js->evaluate(
        { alpha => 1, beta => 2 },
        $dependencies_schema = {
          dependencies => {
            alpha => [ qw(a b c) ],
            beta => false,
          },
        }
      )->TO_JSON,
      { valid => true },
      'dependencies is not recognized in >= draft2019-09',
    );
  };

  cmp_deeply(
    $js->evaluate(
      { alpha => 1, beta => 2 },
      my $dependentRequired_schema = {
        dependentRequired => {
          alpha => [ qw(a b c) ],
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/dependentRequired/alpha',
          error => 'missing properties: a, b, c',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentRequired',
          error => 'not all dependencies are satisfied',
        },
      ],
    },
    'dependentRequired is supported in >= draft2019-09',
  );

  cmp_deeply(
    $js->evaluate(
      { alpha => 1, beta => 2 },
      my $dependentSchemas_schema = {
        dependentSchemas => {
          beta => false,
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas/beta',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependentSchemas',
          error => 'not all dependencies are satisfied',
        },
      ],
    },
    'dependentSchemas is supported in >= draft2019-09',
  );

  $js = JSON::Schema::Modern->new(specification_version => 'draft7');
  cmp_deeply(
    $js->evaluate(
      { alpha => 1, beta => 2 },
      $dependencies_schema,
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/dependencies/alpha',
          error => 'missing properties: a, b, c',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependencies/beta',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/dependencies',
          error => 'not all dependencies are satisfied',
        },
      ],
    },
    'dependencies is supported in <= draft7',
  );

  cmp_deeply(
    $js->evaluate(
      { alpha => 1, beta => 2 },
      $dependentRequired_schema,
    )->TO_JSON,
    { valid => true },
    'dependentRequired is not recognized in <= draft7',
  );

  cmp_deeply(
    $js->evaluate(
      { alpha => 1, beta => 2 },
      $dependentSchemas_schema,
    )->TO_JSON,
    { valid => true },
    'dependentSchemas is not recognized in <= draft7',
  );
};

had_no_warnings() if $ENV{AUTHOR_TESTING};
done_testing;
