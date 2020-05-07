# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More;
use List::Util 1.50 'head';

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not -d '.git' and not grep $ENV{$_}, @variables;
}

use Test::Warnings 0.027 ':fail_on_warning';
use Test::JSON::Schema::Acceptance;
use JSON::Schema::Draft201909;

my $accepter = Test::JSON::Schema::Acceptance->new(specification => 'draft2019-09');
my $js = JSON::Schema::Draft201909->new;

$accepter->acceptance(
  validate_data => sub {
    my ($schema, $instance_data) = @_;
    my $result = $js->evaluate($instance_data, $schema);

    # for now, result is already a boolean, so we just return that.
    $result;
  },
  # TODO: dump our errors on unexpected failure.
  tests => { file => [
      'boolean_schema.json',
      'type.json',
      'enum.json',
      'const.json',
    ],
  },
  todo_tests => [
    { file => 'enum.json', group_description => 'enums in properties' },
  ],
);

# date        Test::JSON::Schema::Acceptance version
#                    result count of running *all* tests
# ----        -----  --------------------------------------
# 2020-05-02  0.991  Looks like you failed 272 tests of 739.
# 2020-05-05  0.991  Looks like you failed 211 tests of 739.
# 2020-05-05  0.992  Looks like you failed 225 tests of 775.
# 2020-05-06  0.992  Looks like you failed 193 tests of 775.


END {
diag <<DIAG

###############################

Attention CPANTesters: you do not need to file a ticket when this test fails. I will receive the test reports and act on it soon. thank you!

###############################
DIAG
  if not Test::Builder->new->is_passing;
}

done_testing;
