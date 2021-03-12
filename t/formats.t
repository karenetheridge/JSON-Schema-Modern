use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Fatal;
use JSON::Schema::Draft201909;

use lib 't/lib';
use Helper;

my ($annotation_result, $validation_result);
subtest 'no validation' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909->new(collect_annotations => 1, validate_formats => 0)
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
    JSON::Schema::Draft201909->new(collect_annotations => 1, validate_formats => 1)
      ->evaluate('abc', { format => 'uuid' }, { validate_formats => 0 })->TO_JSON,
    $annotation_result,
    'format validation can be turned off in evaluate()',
  );
};

subtest 'simple validation' => sub {
  my $js = JSON::Schema::Draft201909->new(collect_annotations => 1, validate_formats => 1);

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

  $js = JSON::Schema::Draft201909->new(collect_annotations => 1);
  ok($js->validate_formats, 'format_validation defaults to true');
  cmp_deeply(
    $js->evaluate('123', { format => 'uuid' }, { validate_formats => 0 })->TO_JSON,
    $annotation_result,
    'format validation can be turned off in evaluate()',
  );

  ok($js->validate_formats, '...but the value is still true on the object');
};

subtest 'unknown format attribute' => sub {
  # see https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.7.2.3
  # "An implementation MUST NOT fail validation or cease processing due to an unknown format
  # attribute."
  my $js = JSON::Schema::Draft201909->new(collect_annotations => 1, validate_formats => 1);
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
      JSON::Schema::Draft201909->new(
        validate_formats => 1,
        format_validations => +{ uuid => 1 },
      )
    },
    qr/Value "1" did not pass type constraint "Optional\[CodeRef\]"/,
    'check syntax of override to existing format',
  );

  like(
    exception {
      JSON::Schema::Draft201909->new(
        validate_formats => 1,
        format_validations => +{ mult_5 => 1 },
      )
    },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation for a new format',
  );

  my $js = JSON::Schema::Draft201909->new(
    collect_annotations => 1,
    validate_formats => 1,
    format_validations => +{
      uuid => sub { $_[0] =~ /^[A-Z]+$/ },
      mult_5 => +{ type => 'integer', sub => sub { ($_[0] % 5) == 0 } },
    },
  );

  cmp_deeply(
    $js->evaluate(
      { uuid => '2eb8aa08-aa98-11ea-b4aa-73b441d16380', mult_5 => 3 },
      {
        properties => {
          uuid => { format => 'uuid' },
          mult_5 => { format => 'mult_5' },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/mult_5',
          keywordLocation => '/properties/mult_5/format',
          error => 'not a mult_5',
        },
        {
          instanceLocation => '/uuid',
          keywordLocation => '/properties/uuid/format',
          error => 'not a uuid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'swapping out format implementation turns success into failure',
  );
};

subtest 'different formats after document creation' => sub {
  # the default evaluator does not know the mult_5 format
  my $document = JSON::Schema::Draft201909::Document->new(schema => { format => 'mult_5' });

  my $js1 = JSON::Schema::Draft201909->new(validate_formats => 1, collect_annotations => 0);
  cmp_deeply(
    $js1->evaluate(3, $document)->TO_JSON,
    {
      valid => true,
    },
    'the default evaluator does not know the mult_5 format',
  );

  my $js2 = JSON::Schema::Draft201909->new(
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

subtest 'vocabulary is required' => sub {
  my $document = JSON::Schema::Draft201909::Document->new(schema => {
    anyOf => [ { format => 'uri-template' }, { format => 'whargarbl' } ]
  });

  my $vocab = $document->dialect->get_vocabulary(3);
  ok(!$vocab->required, 'required flag defaults to false for Format vocabulary');

  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate('abcd', $document)->TO_JSON,
    { valid => true },
    'by default, schemas using uri-template or an unrecognized format can be used for validation',
  );

  # this is a hack, but until the $vocabulary keyword is fully supported, it is the only
  # way to test this.
  $vocab->{required} = 1;

  my $js = JSON::Schema::Draft201909->new;
  my $state = {
    depth => 0,
    data_path => '',
    traversed_schema_path => '',
    canonical_schema_uri => Mojo::URL->new(''),
    schema_path => '',
    errors => [],
    dialect => $document->dialect,
    evaluator => $js,
  };
  $js->_traverse($document->schema, $state);

  cmp_deeply(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/anyOf/0/format',
        error => '"uri-template" format is not supported at this time',
      },
    ],
    'traversing the schema with the format vocabulary set to true generates an error',
  );

  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate('abcd', $document)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/0/format',
          error => '"uri-template" format is not supported at this time',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf/1/format',
          error => 'no implementation found for custom "whargarbl" format',
        },
        {
          instanceLocation => '',
          keywordLocation => '/anyOf',
          error => 'no subschemas are valid',
        },
      ],
    },
    'evaluating the schema with the format vocabulary set to true generates an error',
  );
};

done_testing;
