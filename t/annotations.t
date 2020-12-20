use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Module::Runtime 'use_module';
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new(collect_annotations => 1, short_circuit => 0);

my $initial_state = {
  short_circuit => 0,
  collect_annotations => 1,
  canonical_schema_uri => Mojo::URL->new,
  data_path => '',
  schema_path => '',
  traversed_schema_path => '',
  vocabularies => [
    (map use_module($_)->new(evaluator => $js),
      map 'JSON::Schema::Draft201909::Vocabulary::'.$_, qw(Applicator MetaData)),
  ],
};

subtest 'allOf' => sub {
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

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_allOf(1, $fail_schema, $state),
    'evaluation of the allOf keyword fails',
  );

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

  ok(
    $state->{vocabularies}[0]->_eval_keyword_allOf(1, $pass_schema, $state),
    'evaluation of the allOf keyword succeeds',
  );

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

  {
    my $js = JSON::Schema::Draft201909->new;
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
  }
};

subtest 'oneOf' => sub {
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

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_oneOf(1, $fail_schema, $state),
    'evaluation of the oneOf keyword fails',
  );

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

  ok(
    $state->{vocabularies}[0]->_eval_keyword_oneOf(1, $pass_schema, $state),
    'evaluation of the oneOf keyword succeeds',
  );

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
  my $state = {
    %$initial_state,
    keyword => 'not',
    annotations => [ 'a previous annotation' ],
    errors => [],
  };

  my $fail_schema = {
    not => { title => 'not title' },   # passes; creates annotations
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_not(1, $fail_schema, $state),
    'evaluation of the not keyword fails',
  );

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

  ok(
    $state->{vocabularies}[0]->_eval_keyword_not(1, $pass_schema, $state),
    'evaluation of the not keyword succeeds',
  );

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
    'annotations are still collected inside a "not", otherwise the unevaluatedProperties would have returned false',
  );
};

subtest 'collect_annotations and unevaluated keywords' => sub {
  my $js = JSON::Schema::Draft201909->new(collect_annotations => 0);

  cmp_deeply(
    $js->evaluate(
      [ 1 ],
      {
        '$id' => 'unevaluatedItems.json',
        items => [ true ],
        unevaluatedItems => false,
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/unevaluatedItems',
          absoluteKeywordLocation => 'unevaluatedItems.json#/unevaluatedItems',
          error => 'EXCEPTION: "unevaluatedItems" keyword present, but annotation collection is disabled',
        },
      ],
    },
    'when "collect_annotations" is explicitly set to false, unevaluatedItems cannot be used',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'unevaluatedProperties.json',
        properties => { foo => true },
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          absoluteKeywordLocation => 'unevaluatedProperties.json#/unevaluatedProperties',
          error => 'EXCEPTION: "unevaluatedProperties" keyword present, but annotation collection is disabled',
        },
      ],
    },
    'when "collect_annotations" is explicitly set to false, unevaluatedProperties cannot be used',
  );

  cmp_deeply(
    $js->evaluate(
      {
        item => [ 1 ],
        property => { foo => 1 },
      },
      {
        properties => {
          item => { '$ref' => 'unevaluatedItems.json' },
          property => { '$ref' => 'unevaluatedProperties.json' },
        },
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/item',
          keywordLocation => '/properties/item/$ref/unevaluatedItems',
          absoluteKeywordLocation => 'unevaluatedItems.json#/unevaluatedItems',
          error => 'EXCEPTION: "unevaluatedItems" keyword present, but annotation collection is disabled',
        },
      ],
    },
    'when "collect_annotations" is explicitly set to false, unevaluatedProperties cannot be used, even in other documents',
  );

  $js = JSON::Schema::Draft201909->new(collect_annotations => 1);

  cmp_deeply(
    $js->evaluate(
      [ 1 ],
      {
        items => [ true ],
        unevaluatedItems => false,
      },
    )->TO_JSON,
    {
      valid => bool(1),
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/items',
          annotation => 0,
        },
      ],
    },
    'when "collect_annotations" is set to true, unevaluatedItems works, and annotations are returned',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        properties => { foo => true },
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    {
      valid => bool(1),
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [ 'foo' ],
        },
      ],
    },
    'when "collect_annotations" is set to true, unevaluatedProperties works, and annotations are returned',
  );

  $js = JSON::Schema::Draft201909->new();

  cmp_deeply(
    $js->evaluate(
      [ 1 ],
      {
        '$id' => 'unevaluatedItems.json',
        items => [ true ],
        unevaluatedItems => false,
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'when "collect_annotations" is not set, unevaluatedItems still works, but annotations are not returned',
  );

  cmp_deeply(
    $js->evaluate(
      { foo => 1 },
      {
        '$id' => 'unevaluatedProperties.json',
        properties => { foo => true },
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'when "collect_annotations" is not set, unevaluatedProperties still works, but annotations are not returned',
  );

  cmp_deeply(
    $js->evaluate(
      {
        item => [ 1 ],
        property => { foo => 1 },
      },
      {
        properties => {
          item => { '$ref' => 'unevaluatedItems.json' },
          property => { '$ref' => 'unevaluatedProperties.json' },
        },
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    '... still works when unevaluated keywords are in a separate document',
  );

  my $doc_items = $js->add_schema('items.json', { items => [ true ] });
  my $doc_properties = $js->add_schema('properties.json', { properties => { foo => true } });

  cmp_deeply(
    $doc_items->evaluator_configs,
    {},
    'items.json does not need collect_annotations => 1 to evaluate itself',
  );

  cmp_deeply(
    $doc_properties->evaluator_configs,
    {},
    'properties.json does not need collect_annotations => 1 to evaluate itself',
  );

  cmp_deeply(
    $js->evaluate(
      {
        item => [ 1 ],
        property => { foo => 1 },
      },
      {
        properties => {
          item => {
            '$ref' => 'items.json',
            unevaluatedItems => false,
          },
          property => {
            '$ref' => 'properties.json',
            unevaluatedProperties => false,
          },
        },
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'referenced schemas still produce annotations internally when needed, even when not required to evaluate themselves in isolation',
  );
};

subtest 'annotate_unknown_keywords' => sub {
  my $data = {
    item => [ 1 ],
    property => { foo => 1 },
  };
  my $schema = {
    properties => {
      item => {
        items => [ true, true ],
        unevaluatedItems => false,
        bloop => 5,
      },
      property => {
        properties => { foo => true },
        unevaluatedProperties => false,
        blap => { hi => 1 },
      },
    },
    blip => [ 1, 2, 3 ],
  };

  cmp_deeply(
    JSON::Schema::Draft201909->new(annotate_unknown_keywords => 1)->evaluate(
      $data,
      $schema,
    )->TO_JSON,
    {
      valid => bool(1),
    },
    'no annotations even when config value is true but collect_annotations is false',
  );

  cmp_deeply(
    JSON::Schema::Draft201909->new(collect_annotations => 1, annotate_unknown_keywords => 1)->evaluate(
      $data,
      $schema,
    )->TO_JSON,
    {
      valid => bool(1),
      annotations => [
        {
          instanceLocation => '/item',
          keywordLocation => '/properties/item/items',
          annotation => 0,
        },
        {
          instanceLocation => '/item',
          keywordLocation => '/properties/item/bloop',
          annotation => 5,
        },
        {
          instanceLocation => '/property',
          keywordLocation => '/properties/property/properties',
          annotation => [ 'foo' ],
        },
        {
          instanceLocation => '/property',
          keywordLocation => '/properties/property/blap',
          annotation => { hi => 1 },
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [ 'item', 'property' ],
        },
        {
          instanceLocation => '',
          keywordLocation => '/blip',
          annotation => [ 1, 2, 3 ],
        },
      ],
    },
    'unknown keywords are collected as annotations',
  );
};

done_testing;
