use strict;
use warnings;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Module::Runtime 'use_module';
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new(collect_annotations => 1, short_circuit => 0);

my $initial_state = {
  short_circuit => 0,
  collect_annotations => 1,
  initial_schema_uri => Mojo::URL->new,
  data_path => '',
  schema_path => '',
  traversed_schema_path => '',
  spec_version => 'draft2019-09',
  vocabularies => [
    (map use_module($_)->new,
      map 'JSON::Schema::Modern::Vocabulary::'.$_, qw(Applicator Validation MetaData Unevaluated)),
  ],
  evaluator => $js,
};

subtest 'allOf' => sub {
  my $state = {
    %$initial_state,
    keyword => 'allOf',
    annotations => [],
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
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/allOf/1/title',
          annotation => 'allOf title',
        }),
      ],
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
  $state->{annotations} = [];
  $state->{errors} = [];

  ok(
    $state->{vocabularies}[0]->_eval_keyword_allOf(1, $pass_schema, $state),
    'evaluation of the allOf keyword succeeds',
  );

  cmp_deeply(
    $state,
    {
      %$new_state,
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/allOf/1/title',
          annotation => 'allOf title',
        }),
      ],
      errors => [],
    },
    'passing allOf: state is correct after evaluating',
  );

  cmp_deeply(
    $js->evaluate(1, $pass_schema, { collect_annotations => 0 })->TO_JSON,
    { valid => true },
    'annotation collection can be turned off in evaluate()',
  );

  ok($js->collect_annotations, '...but the value is still true on the object');

  {
    my $js = JSON::Schema::Modern->new;
    ok(!$js->collect_annotations, 'collect_annotations defaults to false');
    cmp_deeply(
      $js->evaluate(1, $pass_schema, { collect_annotations => 1 })->TO_JSON,
      {
        valid => true,
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
    annotations => [],
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
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/oneOf/1/title',
          annotation => 'oneOf title',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/oneOf/2/title',
          annotation => 'oneOf title2',
        }),
      ],
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

  $state->{annotations} = [];
  $state->{errors} = [];

  ok(
    $state->{vocabularies}[0]->_eval_keyword_oneOf(1, $pass_schema, $state),
    'evaluation of the oneOf keyword succeeds',
  );

  cmp_deeply(
    $state,
    {
      %$new_state,
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/oneOf/1/title',
          annotation => 'oneOf title',
        }),
      ],
      errors => [],
    },
    'passing oneOf: state is correct after evaluating',
  );
};

subtest 'not' => sub {
  my $state = {
    %$initial_state,
    keyword => 'not',
    annotations => [],
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
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/not/title',
          annotation => 'not title',
        }),
      ],
      errors => [
        methods(TO_JSON => { instanceLocation => '', keywordLocation => '/not', error => 'subschema is valid' }),
      ],
    },
    'failing not: state is correct after evaluating',
  );

  my $pass_schema = {
    not => { not => { title => 'not title' } },
  };

  $state->{annotations} = [];
  $state->{errors} = [];

  ok(
    $state->{vocabularies}[0]->_eval_keyword_not(1, $pass_schema, $state),
    'evaluation of the not keyword succeeds',
  );

  cmp_deeply(
    $state,
    {
      %$new_state,
      annotations => [],
      errors => [],
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
      valid => true,
    },
    'annotations are still collected inside a "not", otherwise the unevaluatedProperties would have returned false',
  );
};

subtest 'prefixItems' => sub {
  my $state = {
    %$initial_state,
    keyword => 'prefixItems',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_prefixItems([], { prefixItems => [ true ] }, $state),
    'no items means that "prefixItems" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [],
      errors => [],
    },
    'no items: no annotation is produced by prefixItems',
  );

  $state = {
    %$initial_state,
    keyword => 'prefixItems',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_prefixItems([ 1 ], { prefixItems => [ true ] }, $state),
    'one item',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/prefixItems',
          annotation => true,
        }),
      ],
      errors => [],
    },
    'passing prefixItems: one item is annotated',
  );

  $state = {
    %$initial_state,
    keyword => 'prefixItems',
    annotations => [],
    errors => [],
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_prefixItems(
      [ 1, 5, 9 ],
      { prefixItems => [ { title => 'hi', maximum => 3 }, { title => 'hi', maximum => 3 } ] },
      $state),
    'two items, one failing',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '/0',
          keywordLocation => '/prefixItems/0/title',
          annotation => 'hi',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/prefixItems',
          annotation => 1,
        }),
      ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/1',
          keywordLocation => '/prefixItems/1/maximum',
          error => 'value is larger than 3',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/prefixItems',
          error => 'not all items are valid',
        }),
      ],
    },
    'failing prefixItems still collects annotations',
  );
};

subtest 'schema-items' => sub {
  my $state = {
    %$initial_state,
    keyword => 'items',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_items([], { items => true }, $state),
    'no items means that "items" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [],
      errors => [],
    },
    'no items: no annotation is produced by items',
  );

  $state = {
    %$initial_state,
    keyword => 'items',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_items([ 1 ], { items => true }, $state),
    'one item',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/items',
          annotation => true,
        }),
      ],
      errors => [],
    },
    'passing items: one item is annotated',
  );

  $state = {
    %$initial_state,
    keyword => 'items',
    annotations => [],
    errors => [],
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_items(
      [ 1, 5 ],
      { items => { title => 'hi', maximum => 3 } },
      $state),
    'two items, one failing',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '/0',
          keywordLocation => '/items/title',
          annotation => 'hi',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/items',
          annotation => true,
        }),
      ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/1',
          keywordLocation => '/items/maximum',
          error => 'value is larger than 3',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        }),
      ],
    },
    'failing items still collects annotations',
  );
};

subtest 'additionalItems' => sub {
  my $state = {
    %$initial_state,
    keyword => 'additionalItems',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_items([], { additionalItems => true }, $state),
    'no items means that "additionalItems" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [],
      errors => [],
    },
    'no items: no annotation is produced by additionaltems',
  );

  $state = {
    %$initial_state,
    keyword => 'additionalItems',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_additionalItems([ 1 ], { additionalItems => false }, $state),
    'one item',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [],
      errors => [],
    },
    'additionalItems does nothing without items',
  );
};

subtest 'properties' => sub {
  my $state = {
    %$initial_state,
    keyword => 'properties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_properties({}, { properties => { foo => true } }, $state),
    'no items means that "properties" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [],
        }),
      ],
      errors => [],
    },
    'no properties: annotation is still produced by properties',
  );

  $state = {
    %$initial_state,
    keyword => 'properties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_properties({ foo => 1 }, { properties => { foo => true } }, $state),
    'one property',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [ 'foo' ],
        }),
      ],
      errors => [],
    },
    'passing properties: one property is annotated',
  );

  $state = {
    %$initial_state,
    keyword => 'properties',
    annotations => [],
    errors => [],
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_properties(
      { foo => 1, bar => 5 },
      { properties => {
          foo => { title => 'hi', maximum => 3 },
          bar => { title => 'hi', maximum => 3 },
        },
      },
      $state),
    'two properties, one failing',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/title',
          annotation => 'hi',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [ qw(bar foo) ],
        }),
      ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/bar',
          keywordLocation => '/properties/bar/maximum',
          error => 'value is larger than 3',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        }),
      ],
    },
    'failing properties still collects annotations',
  );
};

subtest 'patternProperties' => sub {
  my $state = {
    %$initial_state,
    keyword => 'patternProperties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_patternProperties({}, { patternProperties => { foo => true } }, $state),
    'no items means that "patternProperties" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/patternProperties',
          annotation => [],
        }),
      ],
      errors => [],
    },
    'no pProperties: annotation is still produced by patternProperties',
  );

  $state = {
    %$initial_state,
    keyword => 'patternProperties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_patternProperties({ foo => 1 }, { patternProperties => { foo => true } }, $state),
    'one property',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/patternProperties',
          annotation => [ 'foo' ],
        }),
      ],
      errors => [],
    },
    'passing properties: one property is annotated',
  );

  $state = {
    %$initial_state,
    keyword => 'patternProperties',
    annotations => [],
    errors => [],
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_patternProperties(
      { foo => 1, bar => 5 },
      { patternProperties => {
          foo => { title => 'hi', maximum => 3 },
          bar => { title => 'hi', maximum => 3 },
        },
      },
      $state),
    'two properties, one failing',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '/foo',
          keywordLocation => '/patternProperties/foo/title',
          annotation => 'hi',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/patternProperties',
          annotation => [ qw(bar foo) ],
        }),
      ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/bar',
          keywordLocation => '/patternProperties/bar/maximum',
          error => 'value is larger than 3',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/patternProperties',
          error => 'not all properties are valid',
        }),
      ],
    },
    'failing patternProperties still collects annotations',
  );
};

subtest 'additionalProperties' => sub {
  my $state = {
    %$initial_state,
    keyword => 'additionalProperties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_additionalProperties([], { additionalProperties => true }, $state),
    'no items means that "additionalProperties" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [],
      errors => [],
    },
    'no properties: no annotation is produced by additionalProperties',
  );

  $state = {
    %$initial_state,
    keyword => 'additionalProperties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_additionalProperties({ foo => 1 }, { additionalProperties => true }, $state),
    'one property',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          annotation => [ 'foo' ],
        }),
      ],
      errors => [],
    },
    'passing additionalProperties: one property is annotated',
  );

  $state = {
    %$initial_state,
    keyword => 'additionalProperties',
    annotations => [],
    errors => [],
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_additionalProperties(
      { foo => 1, bar => 3, baz => 5 },
      {
        properties => { foo => true },
        additionalProperties => { title => 'hi', maximum => 3 },
      },
      $state),
    'two properties, one failing',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '/bar',
          keywordLocation => '/additionalProperties/title',
          annotation => 'hi',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          annotation => [ qw(bar baz) ],
        }),
      ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/baz',
          keywordLocation => '/additionalProperties/maximum',
          error => 'value is larger than 3',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          error => 'not all additional properties are valid',
        }),
      ],
    },
    'failing properties still collects annotations',
  );
};

subtest 'unevaluatedProperties' => sub {
  my $state = {
    %$initial_state,
    keyword => 'unevaluatedProperties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_unevaluatedProperties([], { unevaluatedProperties => true }, $state),
    'no items means that "unevaluatedProperties" succeeds',
  );

  cmp_deeply(
    $state,
    my $new_state = {
      %$state,
      initial_schema_uri => str(''),
      annotations => [],
      errors => [],
    },
    'no properties: no annotation is produced by unevaluatedProperties',
  );

  $state = {
    %$initial_state,
    keyword => 'unevaluatedProperties',
    annotations => [],
    errors => [],
  };

  ok(
    $state->{vocabularies}[0]->_eval_keyword_unevaluatedProperties({ foo => 1 }, { unevaluatedProperties => true }, $state),
    'one property',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          annotation => [ 'foo' ],
        }),
      ],
      errors => [],
    },
    'passing unevaluatedProperties: one property is annotated',
  );

  $state = {
    %$initial_state,
    keyword => 'unevaluatedProperties',
    annotations => [],
    errors => [],
  };

  ok(
    !$state->{vocabularies}[0]->_eval_keyword_unevaluatedProperties(
      { foo => 1, bar => 3, baz => 5 },
      {
        properties => { foo => true },
        unevaluatedProperties => { title => 'hi', maximum => 3 },
      },
      $state),
    'two properties, one failing',
  );

  cmp_deeply(
    $state,
    {
      %$state,
      initial_schema_uri => str(''),
      annotations => [
        (map methods(TO_JSON => {
          instanceLocation => '/'.$_,
          keywordLocation => '/unevaluatedProperties/title',
          annotation => 'hi',
        }), qw(bar foo)),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          annotation => [ qw(bar baz foo) ],
        }),
      ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '/baz',
          keywordLocation => '/unevaluatedProperties/maximum',
          error => 'value is larger than 3',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          error => 'not all additional properties are valid',
        }),
      ],
    },
    'failing unevaluatedProperties still collects annotations',
  );
};

subtest 'collect_annotations and unevaluated keywords' => sub {
  my $js = JSON::Schema::Modern->new(collect_annotations => 0);

  cmp_deeply(
    $js->evaluate(
      [ 1 ],
      {
        '$id' => 'unevaluatedItems.json',
        prefixItems => [ true ],
        unevaluatedItems => false,
      },
    )->TO_JSON,
    {
      valid => false,
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
      valid => false,
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
      valid => false,
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

  $js = JSON::Schema::Modern->new(collect_annotations => 1);

  cmp_deeply(
    $js->evaluate(
      [ 1 ],
      {
        prefixItems => [ true ],
        unevaluatedItems => false,
      },
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/prefixItems',
          annotation => true,
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
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [ 'foo' ],
        },
        {
          instanceLocation => '',
          keywordLocation => '/unevaluatedProperties',
          annotation => [],
        },
      ],
    },
    'when "collect_annotations" is set to true, unevaluatedProperties passes, and annotations are returned',
  );

  $js = JSON::Schema::Modern->new();

  cmp_deeply(
    $js->evaluate(
      [ 1 ],
      {
        '$id' => 'unevaluatedItems.json',
        prefixItems => [ true ],
        unevaluatedItems => false,
      },
    )->TO_JSON,
    {
      valid => true,
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
      valid => true,
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
      valid => true,
    },
    '... still works when unevaluated keywords are in a separate document',
  );

  my $doc_items = $js->add_schema('prefixItems.json', { prefixItems => [ true ] });

  my $doc_properties = $js->add_schema('properties.json', { properties => { foo => true } });

  cmp_deeply(
    $js->_get_resource('prefixItems.json')->{configs},
    {},
    'items.json does not need collect_annotations => 1 to evaluate itself',
  );

  cmp_deeply(
    $js->_get_resource('properties.json')->{configs},
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
            '$ref' => 'prefixItems.json',
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
      valid => true,
    },
    'referenced schemas still produce annotations internally when needed, even when not required to evaluate themselves in isolation',
  );
};

subtest 'annotate unknown keywords' => sub {
  my $data = {
    item => [ 1 ],
    property => { foo => 1 },
  };
  my $schema = {
    properties => {
      item => {
        items => true,
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
    JSON::Schema::Modern->new->evaluate(
      $data,
      $schema,
    )->TO_JSON,
    {
      valid => true,
    },
    'no annotations even when collect_annotations is false',
  );

  cmp_deeply(
    (my $result = JSON::Schema::Modern->new(collect_annotations => 1)->evaluate(
      $data,
      $schema,
    ))->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/item',
          keywordLocation => '/properties/item/items',
          annotation => true,
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
          keywordLocation => '/properties/property/unevaluatedProperties',
          annotation => [],
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

  cmp_deeply(
    [ $result->annotations ],
    [
      methods(keyword => 'items', unknown => bool(0)),
      methods(keyword => 'bloop', unknown => bool(1)),
      methods(keyword => 'properties', unknown => bool(0)),
      methods(keyword => 'unevaluatedProperties', unknown => bool(0)),
      methods(keyword => 'blap', unknown => bool(1)),
      methods(keyword => 'properties', unknown => bool(0)),
      methods(keyword => 'blip', unknown => bool(1)),
    ],
    '"unknown" keyword is set on the annotation objects for unknown keywords',
  );

  cmp_deeply(
    $result = JSON::Schema::Modern->new(specification_version => 'draft2019-09', collect_annotations => 1)
        ->evaluate(
      $data,
      $schema,
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/item',
          keywordLocation => '/properties/item/items',
          annotation => true,
        },
        # no bloop
        {
          instanceLocation => '/property',
          keywordLocation => '/properties/property/properties',
          annotation => [ 'foo' ],
        },
        {
          instanceLocation => '/property',
          keywordLocation => '/properties/property/unevaluatedProperties',
          annotation => [],
        },
        # no blap
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          annotation => [ 'item', 'property' ],
        },
        # no blip
      ],
    },
    'no annotations from unknown keywords in draft2019-09',
  );
};

subtest 'items + additionalItems, prefixItems + items' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new(specification_version => 'draft2019-09', collect_annotations => 1)
        ->evaluate(
      [ 1, 2, 3 ],
      {
        items => { maximum => 5 },
        additionalItems => { maximum => 0 },
      }
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/items',
          annotation => true,
        },
        # no error nor annotation from additionalItems
      ],
    },
    'schema-based items + additionalItems',
  );

  cmp_deeply(
    my $result = JSON::Schema::Modern->new(collect_annotations => 1)->evaluate(
      [ 1, 2, 3 ],
      {
        prefixItems => [ { maximum => 5 }, { maximum => 5 }, { maximum => 5 } ],
        items => { maximum => 0 },
      }
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/prefixItems',
          annotation => true,
        },
        # no error nor annotation from items
      ],
    },
    'prefixItems + schema-based items',
  );
};

done_testing;
