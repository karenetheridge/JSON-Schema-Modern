use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new(short_circuit => 0);

subtest '$vocabulary' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate(
      1,
      { '$vocabulary' => { 'https://foo' => 1 } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$vocabulary',
          error => '$vocabulary/https://foo value is not a boolean',
        },
      ],
    },
    '$vocabulary syntax check',
  );

  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate(
      1,
      { items => { '$vocabulary' => { 'https://foo' => true } } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/items/$vocabulary',
          error => '$vocabulary can only appear at the schema resource root',
        },
      ],
    },
    '$vocabulary location check - resource root',
  );

  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate(
      1,
      { items => { '$id' => 'foobar', '$vocabulary' => { 'https://foo' => true } } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/items/$vocabulary',
          absoluteKeywordLocation => 'foobar#/$vocabulary',
          error => '$vocabulary can only appear at the document root',
        },
      ],
    },
    '$vocabulary location check - document root',
  );
};

done_testing;
