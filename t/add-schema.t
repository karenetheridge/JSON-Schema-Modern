use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $schema = { properties => { foo => { type => 'string' } } };

my $doc = JSON::Schema::Draft201909::Document->new(data => $schema);
cmp_deeply(
  $doc,
  methods(
    base_uri => ...?
    data => $schema,
  ),
  'constructed a schema document',
);

my $js = JSON::Schema::Draft201909->new;

$js->add_schema($doc);

# now test $js->schemas   <- this should contain all found $ids and $anchors in uri form...


done_testing;
