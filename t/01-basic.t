use strict;
use warnings;
no if "$]" >= 5.031008, feature => 'indirect';

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use JSON::Schema::Draft201909;

fail('this test is TODO!');
done_testing;
