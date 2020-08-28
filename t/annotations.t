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

my $initial_state = {
  short_circuit => 0,
  collect_annotations => 1,
  canonical_schema_uri => Mojo::URL->new,
  data_path => '',
  schema_path => '',
  traversed_schema_path => '',
};

subtest 'allOf' => sub {
  my $js = JSON::Schema::Draft201909->new(collect_annotations => 1, short_circuit => 0);
  my $state = {
    %$initial_state,
    keyword => 'allOf',
    annotations => [ 'a previous annotation' ],
    errors => [],
  };

  my $fail_schema = {
    allOf => [
      false,                        # fails; creates errors
      { title => 'allOf title' },   # passes; creates annotations
    ],
  };

  ok(!$js->_eval_keyword_allOf(1, $fail_schema, $state), 'evaluation of the allOf keyword fails');

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      canonical_schema_uri => str(''),
      annotations => [ 'a previous annotation' ], # annotation from /allOf/1 is not saved
      errors => [
        methods(TO_JSON => { instanceLocation => '', keywordLocation => '/allOf/0', error => 'subschema is false' }),
        methods(TO_JSON => { instanceLocation => '', keywordLocation => '/allOf', error => 'subschema 0 is not valid' }),
      ],
    },
    'failing allOf: state is correct after evaluating',
  );

  my $pass_schema = {
    allOf => [
      true,
      { title => 'allOf title' }, # passes; creates annotations
      true,
    ],
  };

  ok($js->_eval_keyword_allOf(1, $pass_schema, $state), 'evaluation of the allOf keyword succeeds');

  cmp_deeply(
    $state,
    {
      %$new_state,
      annotations => [
        'a previous annotation',
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/allOf/1/title',
          annotation => 'allOf title',
        }),
      ],
    },
    'passing allOf: state is correct after evaluating',
  );

  cmp_deeply(
    $js->evaluate(1, $pass_schema, { collect_annotations => 0 })->TO_JSON,
    { valid => bool(1) },
    'annotation collection can be turned off in evaluate()',
  );

  ok($js->collect_annotations, '...but the value is still true on the object');

  $js = JSON::Schema::Draft201909->new;
  ok(!$js->collect_annotations, 'collect_annotations defaults to false');
  cmp_deeply(
    $js->evaluate(1, $pass_schema, { collect_annotations => 1 })->TO_JSON,
    {
      valid => bool(1),
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/title',
          annotation => 'allOf title',
        },
      ],
    },
    'annotation collection can be turned on in evaluate() also',
  );
};

subtest 'oneOf' => sub {
  my $js = JSON::Schema::Draft201909->new(collect_annotations => 1, short_circuit => 0);
  my $state = {
    %$initial_state,
    keyword => 'oneOf',
    annotations => [ 'a previous annotation' ],
    errors => [],
  };

  my $fail_schema = {
    oneOf => [
      false,                        # fails; creates errors
      { title => 'oneOf title' },   # passes; creates annotations
      { title => 'oneOf title2' },  # passes; creates annotations
    ],
  };

  ok(!$js->_eval_keyword_oneOf(1, $fail_schema, $state), 'evaluation of the oneOf keyword fails');

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      canonical_schema_uri => str(''),
      annotations => [ 'a previous annotation' ], # annotations from /oneOf/1, /oneOf/2 are not saved
      errors => [
        methods(TO_JSON => { instanceLocation => '', keywordLocation => '/oneOf', error => 'multiple subschemas are valid: 1, 2' }),
      ],
    },
    'failing oneOf: state is correct after evaluating',
  );

  my $pass_schema = {
    oneOf => [
      false,
      { title => 'oneOf title' },  # passes; creates annotations
      false,
    ],
  };

  ok($js->_eval_keyword_oneOf(1, $pass_schema, $state), 'evaluation of the oneOf keyword succeeds');

  cmp_deeply(
    $state,
    {
      %$new_state,
      annotations => [
        'a previous annotation',
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/oneOf/1/title',
          annotation => 'oneOf title',
        }),
      ],
    },
    'passing oneOf: state is correct after evaluating',
  );
};

subtest 'not' => sub {
  my $js = JSON::Schema::Draft201909->new(collect_annotations => 1, short_circuit => 0);
  my $state = {
    %$initial_state,
    keyword => 'not',
    annotations => [ 'a previous annotation' ],
    errors => [],
  };

  my $fail_schema = {
    not => { title => 'not title' },   # passes; creates annotations
  };

  ok(!$js->_eval_keyword_not(1, $fail_schema, $state), 'evaluation of the not keyword fails');

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      canonical_schema_uri => str(''),
      annotations => [ 'a previous annotation' ], # annotation from /not is not saved
      errors => [
        methods(TO_JSON => { instanceLocation => '', keywordLocation => '/not', error => 'subschema is valid' }),
      ],
    },
    'failing not: state is correct after evaluating',
  );

  my $pass_schema = {
    not => { not => { title => 'not title' } },
  };

  ok($js->_eval_keyword_not(1, $pass_schema, $state), 'evaluation of the not keyword succeeds');

  cmp_deeply(
    $state,
    {
      %$new_state,
      annotations => [
        'a previous annotation',
      ],
    },
    'passing not: state is correct after evaluating',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        not => {
          not => {
            '$comment' => 'this subschema must still produce annotations internally, even though the "not" will ultimately discard them',
            anyOf => [
              true,
              { properties => { foo => true } },
            ],
            unevaluatedProperties => false,
          },
        },
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'annotations are still collected inside a "not", otherwuse the unevaluatedProperties would have returned false',
  );
};

done_testing;
