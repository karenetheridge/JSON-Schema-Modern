use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use JSON::Schema::Draft201909;
use JSON::PP;

use constant {
    true => JSON::PP::true,
    false => JSON::PP::false,
};

{
  my $js = JSON::Schema::Draft201909->new;
  my $result = $js->evaluate([ 'arbitrary data' ], true);
  ok($result, 'true schema evaluates to true');
  ok($result->isa('JSON::PP::Boolean'), '..which is a json boolean');
}

{
  my $js = JSON::Schema::Draft201909->new(schema => false);
  my $result = $js->evaluate({ more => 'barbitrary data' }, false);
  ok(!$result, 'false schema evaluates to false');
  ok($result->isa('JSON::PP::Boolean'), '..which is a json boolean');
}

done_testing;
