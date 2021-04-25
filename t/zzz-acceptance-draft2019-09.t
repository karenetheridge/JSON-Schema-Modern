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

my $version = 'draft2019-09';

acceptance_tests(
  acceptance => {
    specification => $version,
    skip_dir => 'optional/format',
  },
  evaluator => {
    specification_version => 'draft2019-09',
    validate_formats => 0,
  },
  output_file => $version.'.txt',
  test => {
    $ENV{NO_TODO} ? () : ( todo_tests => [
      { file => [
          'optional/bignum.json',                     # TODO: see issue #10
          'optional/ecmascript-regex.json',           # TODO: see issue #27
          'optional/float-overflow.json',             # see slack logs re multipleOf algo
        ] },
      # various edge cases that are difficult to accomodate
      $Config{ivsize} < 8 || $Config{nvsize} < 8 ?            # see issue #10
        { file => 'const.json',
          group_description => 'float and integers are equal up to 64-bit representation limits',
          test_description => 'float is valid' }
        : (),
      $Config{nvsize} >= 16 ? # see https://github.com/json-schema-org/JSON-Schema-Test-Suite/pull/438#issuecomment-714670854
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
see t/results/draft2019-09.txt for test results
