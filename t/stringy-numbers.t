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

foreach my $config (0, 1) {
  note 'stringy_numbers = '.$config;
  my $js = JSON::Schema::Modern->new(stringy_numbers => $config);

  cmp_result(
    $js->evaluate(1, { $_ => '1' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/'.$_,
          error => $_.' value is not a number',
        }
      ],
    },
    'strings cannot be used in place of numbers in schema for '.$_,
  ) foreach qw(multipleOf maximum exclusiveMaximum minimum exclusiveMinimum);

  my $schema = {
    allOf => [
      { type => 'string' },
      { type => 'number' },
      { type => 'integer' },
      { type => [ 'object', 'number' ] },
      { type => [ 'object', 'integer' ] },
    ],
  };

  cmp_result(
    $js->evaluate('blah', $schema)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/type',
          error => 'got string, not number',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/3/type',
          error => 'got string, not one of object, number',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/4/type',
          error => 'got string, not one of object, integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          error => 'subschemas 1, 2, 3, 4 are not valid',
        },
      ],
    },
    'strings that do not look like numbers are never valid as numbers',
  );

  cmp_result(
    $js->evaluate('1.1', $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'by default "type": "string" does not accept numbers',
  ) if not $config;

  cmp_result(
    $js->evaluate('1.1', $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/4/type',
          error => 'got string, not one of object, integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          error => 'subschemas 2, 4 are not valid',
        },
      ],
    },
    'using stringy numbers, numeric strings are treated as numbers but are still not always integers',
  ) if $config;


  $schema = {
    maximum => 5,
    exclusiveMaximum => 5,
    minimum => 15,
    exclusiveMinimum => 15,
    allOf => [
      { multipleOf => 2 },
      { multipleOf => 0.3 },
    ],
  };

  $errors = [
    {
      instanceLocation => '',
      keywordLocation => '/maximum',
      error => 'value is larger than 5',
    },
    {
      instanceLocation => '',
      keywordLocation => '/exclusiveMaximum',
      error => 'value is equal to or larger than 5',
    },
    {
      instanceLocation => '',
      keywordLocation => '/minimum',
      error => 'value is smaller than 15',
    },
    {
      instanceLocation => '',
      keywordLocation => '/exclusiveMinimum',
      error => 'value is equal to or smaller than 15',
    },
    {
      instanceLocation => '',
      keywordLocation => '/allOf/0/multipleOf',
      error => 'value is not a multiple of 2',
    },
    {
      instanceLocation => '',
      keywordLocation => '/allOf/1/multipleOf',
      error => 'value is not a multiple of 0.3',
    },
    {
      instanceLocation => '',
      keywordLocation => '/allOf',
      error => 'subschemas 0, 1 are not valid',
    },
  ];

  my $data = 11e0;

  cmp_result(
    $js->evaluate($data, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'real numbers are always evaluated',
  );

  $data = '11e0';

  cmp_result(
    $js->evaluate($data, $schema)->TO_JSON,
    { valid => true },
    'by default, stringy numbers are not evaluated by numeric keywords',
  ) if $config == 0;

  cmp_result(
    $js->evaluate($data, $schema)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'with the config enabled, stringy numbers are treated as numbers by numeric keywords',
  ) if $config == 1;

  is(JSON::Schema::Modern::Utilities::get_type($data), 'string', 'data was not mutated');


  $schema = {
    enum => [11, 12],
    const => 11,
  };

  cmp_result(
    $js->evaluate($data, $schema)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/enum',
          error => 'value does not match',
        },
        {
          instanceLocation => '',
          keywordLocation => '/const',
          error => 'value does not match',
        },
      ],
    },
    'by default, stringy numbers are not the same as numbers using comparison keywords',
  ) if $config == 0;

  cmp_result(
    $js->evaluate($data, $schema)->TO_JSON,
    { valid => true },
    'with the config enabled, stringy numbers are the same as numbers using comparison keywords',
  ) if $config == 1;

  is(JSON::Schema::Modern::Utilities::get_type($data), 'string', 'data was not mutated');
}

done_testing;
