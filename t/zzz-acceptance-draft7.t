# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use List::Util 1.50 'head';
use Config;
use lib 't/lib';
use Acceptance;

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not -d '.git' and not grep $ENV{$_}, @variables;
}

my $version = 'draft7';

acceptance_tests(
  acceptance => {
    specification => $version,
    skip_dir => 'optional/format',
  },
  evaluator => {
    specification_version => $version,
    validate_formats => 0,
  },
  output_file => $version.'-acceptance.txt',
  test => {
    $ENV{NO_TODO} ? () : ( todo_tests => [
      { file => 'optional/bignum.json' },     # TODO: see issue #10
      { file => 'optional/content.json' },    # assertion behaviour removed in draft2019-09; will not implement
      # various edge cases that are difficult to accomodate
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 regex $ does not match trailing newline', test_description => 'matches in Python, but should not in jsonschema' }, # typo - fixed in test suite commit 878b0ad5
      { file => 'optional/ecmascript-regex.json', group_description => [ 'ECMA 262 \d matches ascii digits only', 'ECMA 262 \D matches everything but ascii digits', 'ECMA 262 \w matches ascii letters only', 'ECMA 262 \W matches everything but ascii letters' ] }, # TODO, see test suite PR#505
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 \s matches whitespace', test_description => 'zero-width whitespace matches' }, # bad test: \ufeff is not a space character
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 \S matches everything but whitespace', test_description => 'zero-width whitespace does not match' }, # ""
      { file => 'optional/float-overflow.json' },             # see slack logs re multipleOf algo
      $Config{ivsize} < 8 || $Config{nvsize} < 8 ?            # see issue #10
        { file => 'const.json',
          group_description => 'float and integers are equal up to 64-bit representation limits',
          test_description => 'float is valid' }
        : (),
      $Config{nvsize} >= 12 ? # see https://github.com/json-schema-org/JSON-Schema-Test-Suite/pull/438#issuecomment-714670854
        { file => 'multipleOf.json',
          group_description => 'invalid instance should not raise error when float division = inf',
          test_description => 'always invalid, but naive implementations may raise an overflow error' }
        : (),
    ] ),
  },
);

END {
diag <<DIAG

###############################

Attention CPANTesters: you do not need to file a ticket when this test fails. I will receive the test reports and act on it soon. thank you!

###############################
DIAG
  if not Test::Builder->new->is_passing;
}

done_testing;
__END__
see t/results/draft7-acceptance.txt for test results