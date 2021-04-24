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

acceptance_tests(
  acceptance => {
    specification => 'draft2019-09',
    skip_dir => 'optional/format',
  },
  evaluator => {
    validate_formats => 0,
  },
  output_file => 'draft2019-09.txt',
  test => {
    $ENV{NO_TODO} ? () : ( todo_tests => [
      { file => [
          'optional/bignum.json',                     # TODO: see issue #10
          'optional/content.json',                    # removed in TJSA 1.003
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

# date        Test::JSON::Schema::Acceptance version
#                    JSON::Schema::Draft201909 version
#                           result count of running *all* tests (with no TODOs)
# ----        -----  ----   --------------------------------------
# 2020-05-02  0.991  0.001  Looks like you failed 272 tests of 739.
# 2020-05-05  0.991  0.001  Looks like you failed 211 tests of 739.
# 2020-05-05  0.992  0.001  Looks like you failed 225 tests of 775.
# 2020-05-06  0.992  0.001  Looks like you failed 193 tests of 775.
# 2020-05-06  0.992  0.001  Looks like you failed 190 tests of 775.
# 2020-05-06  0.992  0.001  Looks like you failed 181 tests of 775.
# 2020-05-07  0.992  0.001  Looks like you failed 177 tests of 775.
# 2020-05-07  0.992  0.001  Looks like you failed 163 tests of 775.
# 2020-05-07  0.992  0.001  Looks like you failed 161 tests of 775.
# 2020-05-07  0.992  0.001  Looks like you failed 150 tests of 775.
# 2020-05-08  0.993  0.001  Looks like you failed 150 tests of 776.
# 2020-05-08  0.993  0.001  Looks like you failed 117 tests of 776.
# 2020-05-08  0.993  0.001  Looks like you failed 107 tests of 776.
# 2020-05-08  0.993  0.001  Looks like you failed 116 tests of 776.
# 2020-05-08  0.993  0.001  Looks like you failed 110 tests of 776.
# 2020-05-08  0.993  0.001  Looks like you failed 97 tests of 776.
# 2020-05-11  0.993  0.001  Looks like you failed 126 tests of 776.
# 2020-05-11  0.993  0.001  Looks like you failed 98 tests of 776.
# 2020-05-12  0.994  0.001  Looks like you failed 171 tests of 959.
# 2020-05-13  0.995  0.001  Looks like you failed 171 tests of 959.
# 2020-05-14  0.996  0.001  Looks like you failed 171 tests of 992.
# 2020-05-19  0.997  0.001  Looks like you failed 171 tests of 994.
# 2020-05-22  0.997  0.002  Looks like you failed 163 tests of 994.
# 2020-06-01  0.997  0.004  Looks like you failed 159 tests of 994.
# 2020-06-08  0.999  0.005  Looks like you failed 176 tests of 1055.
# 2020-06-09  0.999  0.006  Looks like you failed 165 tests of 1055.
# 2020-06-10  0.999  0.006  Looks like you failed 104 tests of 1055.
# 2020-07-07  0.999  0.011  Looks like you failed 31 tests of 1055.
# 2020-08-13  1.000  0.013  Looks like you failed 44 tests of 1210.
# 2020-08-14  1.000  0.013  Looks like you failed 42 tests of 1210.
# 2020-10-16  1.001  0.014  Looks like you failed 42 tests of 1221.
# 2020-11-24  1.002  0.017  Looks like you failed 46 tests of 1233.
# 2020-12-04  1.003  0.018  Looks like you failed 40 tests of 1265.
# 2021-03-17  1.004  0.024  Looks like you failed 17 tests of 1026. <-- manually edited to remove optional/format
# 2021-03-23  1.005  0.024  Looks like you failed 17 tests of 1045.
# 2021-04-08  1.006  0.025  Looks like you failed 17 tests of 1055.
# 2021-04-14  1.007  0.026  Looks like you failed 17 tests of 1068.


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
