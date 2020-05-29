use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

subtest 'local JSON pointer' => sub {
  ok($js->evaluate(true, { '$defs' => { true => true }, '$ref' => '#/$defs/true' }),
    'can follow local $ref to a true schema');

  ok(!$js->evaluate(true, { '$defs' => { false => false }, '$ref' => '#/$defs/false' }),
    'can follow local $ref to a false schema');

  is(
    exception {
      my $result = $js->evaluate(true, { '$ref' => '#/$defs/nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{unable to find resource \#/\$defs/nowhere},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

subtest 'local anchor' => sub {
  ok(
    $js->evaluate(
      true,
      {
        '$defs' => {
          true => {
            '$anchor' => 'true',
          },
        },
        '$ref' => '#true',
      },
    ),
    'can follow local $ref to an $anchor to a true schema',
  );

  ok(
    !$js->evaluate(
      true,
      {
        '$defs' => {
          false => {
            '$anchor' => 'false',
            not => true,
          },
        },
        '$ref' => '#false',
      },
    ),
    'can follow local $ref to an $anchor to a false schema',
  );

  is(
    exception {
      my $result = $js->evaluate(true, { '$ref' => '#nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{unable to find resource \#nowhere},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

subtest '$id with an empty fragment' => sub {
  my $js = JSON::Schema::Draft201909->new(max_traversal_depth => 2);
  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$defs' => {
          foo => {
            '$id' => 'http://localhost:4242/my_foo#',
            type => 'string',
          },
          reference_to_foo => {
            '$ref' => 'http://localhost:4242/my_foo',
          },
        },
        allOf => [
          { '$ref' => 'http://localhost:4242/my_foo' },
          { '$ref' => '#/$defs/reference_to_foo' },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/type',
          absoluteKeywordLocation => 'http://localhost:4242/my_foo#/type',
          error => 'wrong type (expected string)',
        },
        {
          absoluteKeywordLocation => 'http://localhost:4242/my_foo',
          error => 'EXCEPTION: maximum traversal depth exceeded',
          instanceLocation => '',
          keywordLocation => "/allOf/1/\$ref/\$ref",
        },
      ],
    },
    '$id with empty fragment can be found by $ref that did not include it; fragment not included in error either',
  );
};

done_testing;
