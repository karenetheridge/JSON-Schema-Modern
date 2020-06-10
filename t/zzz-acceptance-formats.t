# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use List::Util 1.50 'head';
use Config;

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not -d '.git' and not grep $ENV{$_}, @variables;
}

use Test::Warnings 0.027 ':fail_on_warning';
use Test::JSON::Schema::Acceptance 0.999;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Draft201909' => 'share' } };
use File::ShareDir 'dist_dir';
use Path::Tiny;
use JSON::Schema::Draft201909;

my $accepter = Test::JSON::Schema::Acceptance->new(
  test_dir => path(dist_dir('Test-JSON-Schema-Acceptance'), qw(tests draft2019-09 optional format)),
  include_optional => 1,
  verbose => 1,
);

my %options = (validate_formats => 1);
my $js = JSON::Schema::Draft201909->new(%options);
my $js_short_circuit = JSON::Schema::Draft201909->new(%options, short_circuit => 1);

my $encoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0, convert_blessed => 1, canonical => 1, pretty => 1);
$encoder->indent_length(2) if $encoder->can('indent_length');

$accepter->acceptance(
  validate_data => sub {
    my ($schema, $instance_data) = @_;
    my $result = $js->evaluate($instance_data, $schema);
    my $result_short = $js_short_circuit->evaluate($instance_data, $schema);

    note $encoder->encode($result);

    die 'results inconsistent between short_circuit = false and true'
      if $result xor $result_short;

    # if any errors contain an exception, propage at that upwards as an exception so we can be sure
    # to count that as a failure.
    # (This might change if tests are added that are expected to produce exceptions.)
    if (my ($e) = grep $_->error =~ /^EXCEPTION/, $result->errors) {
      die $e->error;
    }

    $result;
  },
  @ARGV ? (tests => { file => \@ARGV }) : (),
  $ENV{NO_TODO} ? () : ( todo_tests => [
    { file => [
        eval { require Email::Valid; 1 } ? () : 'email.json',
        qw(
          date-time.json
          date.json
          duration.json
          idn-email.json
          idn-hostname.json
          iri-reference.json
          time.json
          uri-template.json
        ),
      ] },
  ] ),
);

# date        Test::JSON::Schema::Acceptance version
#                    result count of running *all* tests (with no TODOs)
# ----        -----  --------------------------------------
# 2020-06-09  0.999  ...


END {
diag <<DIAG

###############################

Attention CPANTesters: you do not need to file a ticket when this test fails. I will receive the test reports and act on it soon. thank you!

###############################
DIAG
  if not Test::Builder->new->is_passing;
}

done_testing;
