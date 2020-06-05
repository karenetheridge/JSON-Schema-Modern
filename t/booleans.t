use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

my @tests = (
  { schema => false, result => false },
  { schema => true, result => true },
  { schema => {}, result => true },
);

foreach my $test (@tests) {
  my $data = 'hello';
  is(
    exception {
      my $result = $js->evaluate($data, $test->{schema});
      ok(!($result xor $test->{result}), json_sprintf('schema: %s evaluates to: %s', $test->{schema}, $test->{result}));
    },
    undef,
    'no exceptions in evaluate',
  );
}

cmp_deeply(
  $js->evaluate('hello', [])->TO_JSON,
  {
    valid => bool(0),
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '',
        error => 'EXCEPTION: unrecognized schema type "array"',
      },
    ],
  },
  'invalid schema type results in error',
);

done_testing;
