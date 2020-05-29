use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;

my $js = JSON::Schema::Draft201909->new(max_traversal_depth => 5);
cmp_deeply(
  $js->evaluate(
    1,
    {
      '$defs' => {
        loop_a => {
          '$ref' => '#/$defs/loop_b',
        },
        loop_b => {
          '$ref' => '#/$defs/loop_a',
        },
      },
      '$ref' => '#/$defs/loop_a',
    },
  )->TO_JSON,
  {
    valid => bool(0),
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/$ref/$ref/$ref/$ref/$ref/$ref',
        absoluteKeywordLocation => '#/$defs/loop_b',
        error => 'EXCEPTION: maximum traversal depth exceeded',
      },
    ],
  },
  'evaluation is halted when traversal gets too deep',
);

done_testing;
