# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(max_traversal_depth => 6);

cmp_result(
  $js->evaluate(
    [ [ [ [ [ 1 ] ] ] ] ],
    {
      items => { '$ref' => '#' },
    },
  )->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/0/0/0/0',
        keywordLocation => '/items/$ref/items/$ref/items/$ref/items',
        absoluteKeywordLocation => '#/items',
        error => 'EXCEPTION: maximum evaluation depth (6) exceeded',
      },
    ],
  },
  'evaluation is halted when traversal gets too deep',
);

cmp_result(
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
    valid => false,
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

cmp_result(
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
  { valid => true },
  'the seen counter does not confuse URI paths and fragments: /properties/foo vs #/properties/foo',
);

cmp_result(
  $js->evaluate(
    { foo => 1 },
    {
      '$defs' => {
        int => { type => 'integer' },
      },
      anyOf => [
        { additionalProperties => { '$ref' => '#/$defs/int' } },
        { additionalProperties => { '$ref' => '#/$defs/int' } },
      ],
    }
  )->TO_JSON,
  { valid => true },
  'the seen counter does not confuse two subschemas that both apply the same definition to the same instance location',
);

done_testing;
