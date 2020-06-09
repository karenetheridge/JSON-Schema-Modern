use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;

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

done_testing;
