use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use JSON::Schema::Draft201909;

pass('this test is TODO!');
done_testing;
