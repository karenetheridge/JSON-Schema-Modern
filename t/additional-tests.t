# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';

use Test::More;
use Test::Warnings 0.027 ':fail_on_warning';
use Test::JSON::Schema::Acceptance 0.993;
use JSON::Schema::Draft201909;

my $accepter = Test::JSON::Schema::Acceptance->new(test_dir => 't/additional-tests', verbose => 1);
my $js = JSON::Schema::Draft201909->new;

plan skip_all => 'no tests in this directory to test' if not @{$accepter->_test_data};

$accepter->acceptance(
  validate_data => sub {
    my ($schema, $instance_data) = @_;
    my $result = $js->evaluate($instance_data, $schema);

    # for now, result is already a boolean, so we just return that.
    $result;
  },
);

done_testing;
