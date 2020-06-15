use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep '!blessed';
use feature 'current_sub';
use Ref::Util 0.100 qw(is_plain_arrayref is_plain_hashref);
use Scalar::Util 'blessed';
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

# come up with some interesting test cases thta demonstrate that previous short-circuiting behaviour
# on true validation is no longer the case.
#
# if/then/else - collect A from 'if' as well as 'then' or 'else'
# not - collects no A ever
# allOf, anyOf, oneOf are also tricky and some of the previous short-circuiting behaviour for errors
# can be inverted and used here for successes
# also 'contains', 'items'

# make sure that short_circuit is not set to !collect_annotations - remember we need to overlay with
# the existing short_circuit value.
#
# unevaluated* will be special tests but maybe we don't need them as we have the test suite.
#
#
#unevaluatedItems:
# applies to every item if there is no 'items' or 'additionalItems' keywords
#     or if the 'items' or 'additionalItems' evaluations failed
# applies to no item if there is an 'additionalItems' keyword that passes
#


# now, extend this allOf test to all the applicator keywords:
# { keyword => ..., data => ..., schema => ..., }

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
    unbless($state),
    my $new_state = {
      %$state,
      canonical_schema_uri => '',
      annotations => [ 'a previous annotation' ], # annotation from /allOf/1 is not saved
      errors => [
        { instanceLocation => '', keywordLocation => '/allOf/0', error => 'subschema is false' },
        { instanceLocation => '', keywordLocation => '/allOf', error => 'subschema 0 is not valid' },
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
    unbless($state),
    {
      %$new_state,
      annotations => [
        'a previous annotation',
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/title',
          annotation => 'allOf title',
        },
      ],
    },
    'passing allOf: state is correct after evaluating',
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
    unbless($state),
    my $new_state = {
      %$state,
      canonical_schema_uri => '',
      annotations => [ 'a previous annotation' ], # annotations from /oneOf/1, /oneOf/2 are not saved
      errors => [
        { instanceLocation => '', keywordLocation => '/oneOf', error => 'multiple subschemas are valid: 1, 2' },
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
    unbless($state),
    {
      %$new_state,
      annotations => [
        'a previous annotation',
        {
          instanceLocation => '',
          keywordLocation => '/oneOf/1/title',
          annotation => 'oneOf title',
        },
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
    unbless($state),
    my $new_state = {
      %$state,
      canonical_schema_uri => '',
      annotations => [ 'a previous annotation' ], # annotation from /not is not saved
      errors => [
        { instanceLocation => '', keywordLocation => '/not', error => 'subschema is valid' },
      ],
    },
    'failing not: state is correct after evaluating',
  );

  my $pass_schema = {
    not => { not => { title => 'not title' } },
  };

  ok($js->_eval_keyword_not(1, $pass_schema, $state), 'evaluation of the not keyword succeeds');

  cmp_deeply(
    unbless($state),
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

# recursively call ->TO_JSON on everything
sub unbless {
  my $data = shift;

  if (is_plain_arrayref($data)) {
    return [ map __SUB__->($data->[$_]), 0 .. $#{$data} ];
  }
  elsif (is_plain_hashref($data)) {
    return +{ map +($_ => __SUB__->($data->{$_})), keys %$data };
  }
  elsif (blessed $data) {
    return $data->can('TO_JSON') ? $data->TO_JSON : "$data";
  }
  else {
    return $data;
  }
}

done_testing;
