use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

subtest 'evaluation callbacks' => sub {
  my @used_ref_at;
  my $result = $js->evaluate(
    [ { a => { b => { c => { d => 'e' } } } } ],
    my $schema = {
      '$defs' => {
        object_or_string => {
          anyOf => [
            {
              type => 'object',
              additionalProperties => { '$ref' => '#/$defs/object_or_string' },
            },
            {
              type => 'string'
            },
          ],
        },
      },
      contains => { '$ref' => '#/$defs/object_or_string' },
    },
    my $config = {
      callbacks => {
        '$ref' => sub ($data, $schema, $state) {
          push @used_ref_at, $state->{data_path};
        },
      },
    },
  );
  ok($result, 'evaluation was successful');
  cmp_deeply(
    \@used_ref_at,
    bag(
      '/0',
      '/0/a',
      '/0/a/b',
      '/0/a/b/c',
      '/0/a/b/c/d',
    ),
    'identified all data paths where a $ref was used',
  );


  undef @used_ref_at;
  $result = $js->evaluate(
    [ { a => { b => 2 } } ],
    $schema,
    $config,
  );
  ok(!$result, 'evaluation was not successful');
  cmp_deeply(
    \@used_ref_at,
    [],
    'no callbacks on failure: innermost $ref failed, so all other $refs failed too',
  );


  undef @used_ref_at;
  $result = $js->evaluate(
    [
      { a => { b => 'c' } },
      { x => { y => 1 } },
    ],
    {
      '$defs' => {
        object_or_string => {
          anyOf => [
            {
              type => 'object',
              additionalProperties => { '$ref' => '#/$defs/object_or_string' },
            },
            {
              type => 'string'
            },
          ],
        },
      },
      contains => { '$ref' => '#/$defs/object_or_string' },
    },
    $config,
  );
  ok($result, 'evaluation was successful');

  cmp_deeply(
    \@used_ref_at,
    bag(
      '/0',
      '/0/a',
      '/0/a/b',
    ),
    'successful subschemas have callbacks called, but not failed subschemas',
  );
};

subtest 'callbacks for keywords without eval subs' => sub {
  my %keywords;
  my $result = $js->evaluate(
    'hello',
    {
      '$id' => 'my_weird_schema',
      '$schema' => 'https://json-schema.org/draft/2020-12/schema',
      '$vocabulary' => { 'https://json-schema.org/draft/2020-12/vocab/core' => true },
      '$anchor' => 'my_anchor',
      '$comment' => 'my comment',
      '$defs' => { foo => true },
      '$dynamicAnchor' => 'dynamicanchor',
      if => true, then => true, else => true,
    },
    {
      callbacks => {
        map +($_ => sub ($data, $schema, $state) {
          ++$keywords{$state->{keyword}}
        }), qw($anchor $comment $defs $dynamicAnchor if then else $schema $vocabulary),
      },
    },
  );
  ok($result, 'evaluation was successful');

  cmp_deeply(
    \%keywords,
    { map +($_ => 1), qw($anchor $comment $defs $dynamicAnchor if then else $schema $vocabulary) },
    'callbacks are triggered for keywords even when they lack evaluation subs',
  );
};

subtest 'callbacks that produce errors' => sub {
  my $result = $js->evaluate(
    my $data = {
      alpha => 1,
      beta => 'foo',
    },
    my $schema = {
      properties => { alpha => { type => 'number' } },
      additionalProperties => { type => 'number' },
    },
    my $configs = {
      callbacks => {
        type => sub ($data, $schema, $state) {
          JSON::Schema::Modern::Utilities::E($state, 'this is a callback error');
        },
      },
    },
  );
  cmp_deeply(
    $result->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/alpha',
          keywordLocation => '/properties/alpha/type',
          error => 'this is a callback error',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/beta',
          keywordLocation => '/additionalProperties/type',
          error => 'got string, not number',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'result object contains the callback error, and the other errors',
  );

  $result = $js->evaluate($data, $schema, { %$configs, short_circuit => 1 });
  cmp_deeply(
    $result->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/alpha',
          keywordLocation => '/properties/alpha/type',
          error => 'this is a callback error',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'result object contains the callback error, and short-circuits execution',
  );
};

done_testing;
