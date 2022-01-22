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
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;
ok(!$js->strict, 'strict defaults to false');

my $schema = {
  '$id' => 'my_loose_schema',
  type => 'string',
  bloop => 'hi',
  barf => 'no',
};

my $document = $js->add_schema('my_loose_schema' => $schema);

cmp_deeply(
  $js->evaluate('hi', $document)->TO_JSON,
  { valid => true },
  'by default, unknown keywords are allowed',
);

$js = JSON::Schema::Modern->new(strict => 1);
$js->add_schema($document);

cmp_deeply(
  $js->evaluate('hi', $document)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '',
        absoluteKeywordLocation => 'my_loose_schema',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during evaluation, even if the document was already traversed',
);

delete $schema->{'$id'};
cmp_deeply(
  $js->evaluate('hi', $schema)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '',
        error => 'unknown keywords found: barf, bloop',
      },
    ],
  },
  'strict mode disallows unknown keywords during traverse',
);

done_testing;
