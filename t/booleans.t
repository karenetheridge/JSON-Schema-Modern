use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

# check constructor args here, when we have some

my @tests = (
  { schema => false, result => false },
  { schema => true, result => true },
  { schema => {}, result => true },
  { schema => 'foo', result => false },
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

done_testing;
