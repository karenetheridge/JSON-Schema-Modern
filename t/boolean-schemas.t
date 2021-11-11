use strict;
use warnings;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

my @tests = (
  { schema => false, valid => false },
  { schema => true, valid => true },
  { schema => {}, valid => true },
  { schema => 0, valid => false },
  { schema => 1, valid => false },
  { schema => \0, valid => false },
  { schema => \1, valid => false },
);

foreach my $test (@tests) {
  my $data = 'hello';
  is(
    exception {
      my $result = $js->evaluate($data, $test->{schema});
      ok(!($result xor $test->{valid}), json_sprintf('schema: %s evaluates to: %s', $test->{schema}, $test->{valid}));

      cmp_deeply(
        $result->TO_JSON,
        {
          valid => $test->{valid},
          $test->{valid} ? () : (errors => supersetof()),
        },
        'invalid result structure looks correct',
      );
    },
    undef,
    'no exceptions in evaluate',
  );
}

cmp_deeply(
  $js->evaluate('hello', [])->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '',
        error => 'invalid schema type: array',
      },
    ],
  },
  'invalid schema type results in error',
);

$js = JSON::Schema::Modern->new(scalarref_booleans => 1);

cmp_deeply(
  $js->evaluate('hello', \0)->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '',
        error => 'invalid schema type: reference to SCALAR',
      },
    ],
  },
  'scalarref for schema results in error, even when scalarref_booleans is true',
);

done_testing;
