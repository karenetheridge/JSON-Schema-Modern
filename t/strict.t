use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
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
ok(!$js->strict, 'strict defaults to false');

my $schema = {
  '$id' => 'my_loose_schema',
  type => 'object',
  properties => {
    foo => {
      bloop => 'hi',
      barf => 'no',
    },
  },
};

my $document = $js->add_schema('my_loose_schema' => $schema);

cmp_deeply(
  $js->evaluate({ foo => 1 }, 'my_loose_schema')->TO_JSON,
  { valid => true },
  'by default, unknown keywords are allowed',
);

cmp_deeply(
  $js->evaluate({ foo => 1 }, 'my_loose_schema', { strict => 1 })->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/foo',
        keywordLocation => '/properties/foo',
        absoluteKeywordLocation => 'my_loose_schema#/properties/foo',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during evaluation via a config override',
);

$js = JSON::Schema::Modern->new(strict => 1);
$js->add_schema($document);

cmp_deeply(
  $js->evaluate({ foo => 1 }, $document)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '/foo',
        keywordLocation => '/properties/foo',
        absoluteKeywordLocation => 'my_loose_schema#/properties/foo',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during evaluation, even if the document was already traversed',
);

delete $schema->{'$id'};
cmp_deeply(
  $js->evaluate({ foo => 1 }, $schema)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '', # note no instance location - indicating evaluation has not started
        keywordLocation => '/properties/foo',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during traverse',
);

done_testing;
