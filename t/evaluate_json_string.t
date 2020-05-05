use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use JSON::Schema::Draft201909;

my $js = JSON::Schema::Draft201909->new;

like(ref($js->_json_decoder), qr/^(?:Cpanel::JSON::XS|JSON::PP)$/, 'we have a JSON decoder');

is(
  exception {
    ok($js->evaluate_json_string('true', {}), 'json data "true" is evaluated successfully');
  },
  undef,
  'no exceptions in evaluate_json_string on good json',
);

is(
  exception {
    ok(!$js->evaluate_json_string('blargh', {}), 'evaluating bad json data returns false');
  },
  undef,
  'no exceptions in evaluate_json_string on bad json',
);

done_testing;
