use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;

my $js = JSON::Schema::Draft201909->new(max_traversal_depth => 6);
cmp_deeply(
  $js->evaluate(
    [ [ [ [ [ 1 ] ] ] ] ],
    {
      items => { '$ref' => '#' },
    },
  )->TO_JSON,
  {
    valid => bool(0),
    errors => [
      {
        instanceLocation => '/0/0/0/0',
        keywordLocation => '/items/$ref/items/$ref/items/$ref/items',
        absoluteKeywordLocation => '#/items',
        error => 'EXCEPTION: maximum evaluation depth exceeded',
      },
    ],
  },
  'evaluation is halted when traversal gets too deep',
);

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
        keywordLocation => '/$ref/$ref/$ref',
        absoluteKeywordLocation => '#/$defs/loop_a',
        error => 'EXCEPTION: infinite loop detected (same location evaluated twice)',
      },
    ],
  },
  'evaluation is halted when an instance location is evaluated against the same schema location a second time',
);

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        '$defs' => { mydef => { '$id' => '/properties/foo' } },
        properties => {
          foo => {
            '$ref' => '/properties/foo',
          },
        },
      },
    )->TO_JSON,
    { valid => bool(1) },
    'the seen counter does not confuse URI paths and fragments: /properties/foo vs #/properties/foo',
  );

done_testing;
