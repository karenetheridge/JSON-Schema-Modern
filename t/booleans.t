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

like(
  exception { $js->evaluate('hello', 'foo') },
  qr/unrecognized schema type "string"/,
  'got exception with invalid schema type',
);

done_testing;
