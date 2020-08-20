use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new(short_circuit => 0);
is($js->output_format, 'basic', 'output_format defaults to basic');

my $result = $js->evaluate(
  { alpha => 1, beta => 1 },
  {
    required => [ 'foo' ],
    properties => {
      alpha => false,
      beta => { multipleOf => 2 },
    },
    not => true,
  },
);

is($result->output_format, 'basic', 'Result object gets the output_format from the evaluator');

cmp_deeply(
  $result->TO_JSON,
  {
    valid => bool(0),
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/required',
        error => 'missing property: foo',
      },
      {
        instanceLocation => '',
        keywordLocation => '/not',
        error => 'subschema is valid',
      },
      {
        instanceLocation => '/alpha',
        keywordLocation => '/properties/alpha',
        error => 'subschema is false',
      },
      {
        instanceLocation => '/beta',
        keywordLocation => '/properties/beta/multipleOf',
        error => 'value is not a multiple of 2',
      },
      {
        instanceLocation => '',
        keywordLocation => '/properties',
        error => 'not all properties are valid',
      },
    ],
  },
  'basic format includes all errors linearly',
);

$result->output_format('flag');
cmp_deeply(
  $result->TO_JSON,
  {
    valid => bool(0),
  },
  'flag format only includes the valid property',
);

done_testing;
