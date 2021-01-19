use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
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

done_testing;
