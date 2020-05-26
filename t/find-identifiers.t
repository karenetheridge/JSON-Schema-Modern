use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

subtest '_find_all_identifiers' => sub {
  my $js = JSON::Schema::Draft201909->new;
  $js->_find_all_identifiers(
    {
      '$defs' => {
        foo => my $foo_definition = {
          '$id' => 'my_foo',
          const => 'foo value',
        },
      },
      '$ref' => 'my_foo',
    }
  );

  cmp_deeply(
    $js->{resource_index},
    {
      'my_foo' => {
        ref => $foo_definition,
        canonical_uri => str('my_foo'),
      },
    },
    'internal resource index is correct',
  );
};

subtest '$id sets canonical uri' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$defs' => {
          foo => my $foo_definition = {
            '$id' => 'http://localhost:4242/my_foo',
            const => 'foo value',
          },
        },
        '$ref' => 'http://localhost:4242/my_foo',
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/const',
          absoluteKeywordLocation => 'http://localhost:4242/my_foo#/const',
          error => 'value does not match',
        },
      ],
    },
    '$id was recognized - $ref was successfully traversed',
  );

  cmp_deeply(
    $js->{resource_index},
    {
      'http://localhost:4242/my_foo' => {
        ref => $foo_definition,
        canonical_uri => str('http://localhost:4242/my_foo'),
      },
    },
    'internal resource index is correct',
  );
};

subtest 'anchors' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(
      1,
      my $schema = {
        '$defs' => {
          foo => my $foo_definition = {
            '$anchor' => 'my_foo',
            const => 'foo value',
          },
          bar => my $bar_definition = {
            '$anchor' => 'my_bar',
            not => true,
          },
        },
        '$id' => 'http://localhost:4242',
        allOf => [
          { '$ref' => '#my_foo' },
          { '$ref' => '#my_bar' },
          { not => my $not_definition = {
              '$anchor' => 'my_not',
              not => false,
            },
          },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/const',
          absoluteKeywordLocation => 'http://localhost:4242#/$defs/foo/const',
          error => 'value does not match',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$ref/not',
          absoluteKeywordLocation => 'http://localhost:4242#/$defs/bar/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/not',
          absoluteKeywordLocation => 'http://localhost:4242#/allOf/2/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'http://localhost:4242#/allOf',
          error => 'subschemas 0, 1, 2 are not valid',
        },
      ],
    },
    '$id was recognized - absolute locations use json paths, not anchors',
  );

  cmp_deeply(
    $js->{resource_index},
    {
      'http://localhost:4242' => {
        ref => $schema,
        canonical_uri => str('http://localhost:4242'),
      },
      'http://localhost:4242#my_foo' => {
        ref => $foo_definition,
        canonical_uri => str('http://localhost:4242#/$defs/foo'),
      },
      'http://localhost:4242#my_bar' => {
        ref => $bar_definition,
        canonical_uri => str('http://localhost:4242#/$defs/bar'),
      },
      'http://localhost:4242#my_not' => {
        ref => $not_definition,
        canonical_uri => str('http://localhost:4242#/allOf/2/not'),
      },
    },
    'internal resource index is correct',
  );
};

done_testing;
