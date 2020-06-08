use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Fatal;
use JSON::Schema::Draft201909;

subtest 'no validation' => sub {
  my $js = JSON::Schema::Draft201909->new(validate_formats => 0);
  cmp_deeply(
    $js->evaluate('abc', { format => 'uuid' })->TO_JSON,
    {
      valid => bool(1),
    },
    'validate_format=0 disables format assertion behaviour',
  );
};

subtest 'simple validation' => sub {
  my $js = JSON::Schema::Draft201909->new(validate_formats => 1);

  cmp_deeply(
    $js->evaluate(123, { format => 'uuid' })->TO_JSON,
    {
      valid => bool(1),
    },
    'non-string values are valid',
  );

  cmp_deeply(
    $js->evaluate(
      '2eb8aa08-aa98-11ea-b4aa-73b441d16380',
      { format => 'uuid' },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'simple success',
  );

  cmp_deeply(
    $js->evaluate('123', { format => 'uuid' })->TO_JSON,
    {
      valid => bool(0),
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
};

subtest 'unknown format attribute' => sub {
  my $js = JSON::Schema::Draft201909->new(validate_formats => 1);
  cmp_deeply(
    $js->evaluate('hello', { format => 'whargarbl' })->TO_JSON,
    {
      valid => bool(1),
    },
    'unrecognized format attributes do not cause validation failure',
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
    qr/^overrides to existing format_validations must be coderefs/,
    'check syntax of override to existing format',
  );

  like(
    exception {
      JSON::Schema::Draft201909->new(
        validate_formats => 1,
        format_validations => +{ mult_5 => 1 },
      )
    },
    qr/^Value "1" did not pass type constraint "Dict.../,
    'check syntax of implementation for a new format',
  );

  my $js = JSON::Schema::Draft201909->new(
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
      valid => bool(0),
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
