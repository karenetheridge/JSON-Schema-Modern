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
use JSON::Schema::Draft201909;

my $accepter = Test::JSON::Schema::Acceptance->new(
  $ENV{TEST_DIR} ? (test_dir => $ENV{TEST_DIR}) : (specification => 'draft2019-09'),
  include_optional => 1,
  verbose => 1,
);

my %options = (validate_formats => 1, collect_annotations => 1);
my $js = JSON::Schema::Draft201909->new(%options);
my $js_short_circuit = JSON::Schema::Draft201909->new(%options, short_circuit => 1);

my $add_resource = sub {
  my ($uri, $data) = @_;
  $js->add_schema($uri => $data);
  $js_short_circuit->add_schema($uri => $data);
};

# TODO: moving into TJSA 1.000
my $base = Mojo::URL->new('http://localhost:1234');
$accepter->additional_resources->visit(
  sub {
    my ($path) = @_;
    return if not $path->is_file or $path !~ /\.json$/;
    my $data = $accepter->_json_decoder->decode($path->slurp_raw);
    my $file = $path->relative($accepter->additional_resources);
    my $uri = Mojo::URL->new($file)->base($base)->to_abs;
    $add_resource->($uri => $data);
  },
  { recurse => 1 },
);

my $encoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0, convert_blessed => 1, canonical => 1, pretty => 1);
$encoder->indent_length(2) if $encoder->can('indent_length');

$accepter->acceptance(
  validate_data => sub {
    my ($schema, $instance_data) = @_;
    my $result = $js->evaluate($instance_data, $schema);
    my $result_short = $js_short_circuit->evaluate($instance_data, $schema);

    note $encoder->encode($result);
    note $encoder->encode($result_short) if $result xor $result_short;

    die 'results inconsistent between short_circuit = false and true'
      if ($result xor $result_short)
        and not grep $_->error =~ /but short_circuit is enabled/, $result_short->errors;

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
        'optional/bignum.json',                     # TODO: see issue #10
        'optional/content.json',                    # per spec, should not be validated by default
        'optional/ecmascript-regex.json',           # TODO: see issue #27
        'optional/format/iri-reference.json',       # not yet implemented
        'optional/format/uri-template.json',        # not yet implemented
        $ENV{AUTOMATED_TESTING} ? (                 # these all depend on optional prereqs
        qw(
          optional/format/date-time.json
          optional/format/date.json
          optional/format/time.json
          optional/format/email.json
          optional/format/hostname.json
          optional/format/idn-hostname.json
          optional/format/idn-email.json
        ) ) : (),
      ] },
    { file => 'refRemote.json', group_description => [      # TODO: waiting for test suite PR 360
        'base URI change - change folder', 'base URI change - change folder in subschema',
      ] },
    # various edge cases that are difficult to accomodate
    { file => 'optional/format/date-time.json', group_description => 'validation of date-time strings',
      test_description => 'case-insensitive T and Z' },
    { file => 'optional/format/date.json', group_description => 'validation of date strings',
      test_description => 'only RFC3339 not all of ISO 8601 are valid' },
    { file => 'optional/format/iri.json', group_description => 'validation of IRIs',  # see test suite issue 395
      test_description => 'an invalid IRI based on IPv6' },
    { file => 'optional/format/idn-hostname.json',
      group_description => 'validation of internationalized host names',
      test_description => [
        'contains illegal char U+302E Hangul single dot tone mark', # IDN decoder likes this
        'valid Chinese Punycode',                     # Data::Validate::Domain doesn't like this
      ] },
    $Config{ivsize} < 8 || $Config{nvsize} < 8 ?            # see issue #10
      { file => 'const.json',
        group_description => 'float and integers are equal up to 64-bit representation limits',
        test_description => 'float is valid' }
      : (),
  ] ),
);

# date        Test::JSON::Schema::Acceptance version
#                    result count of running *all* tests (with no TODOs)
# ----        -----  --------------------------------------
# 2020-05-02  0.991  Looks like you failed 272 tests of 739.
# 2020-05-05  0.991  Looks like you failed 211 tests of 739.
# 2020-05-05  0.992  Looks like you failed 225 tests of 775.
# 2020-05-06  0.992  Looks like you failed 193 tests of 775.
# 2020-05-06  0.992  Looks like you failed 190 tests of 775.
# 2020-05-06  0.992  Looks like you failed 181 tests of 775.
# 2020-05-07  0.992  Looks like you failed 177 tests of 775.
# 2020-05-07  0.992  Looks like you failed 163 tests of 775.
# 2020-05-07  0.992  Looks like you failed 161 tests of 775.
# 2020-05-07  0.992  Looks like you failed 150 tests of 775.
# 2020-05-08  0.993  Looks like you failed 150 tests of 776.
# 2020-05-08  0.993  Looks like you failed 117 tests of 776.
# 2020-05-08  0.993  Looks like you failed 107 tests of 776.
# 2020-05-08  0.993  Looks like you failed 116 tests of 776.
# 2020-05-08  0.993  Looks like you failed 110 tests of 776.
# 2020-05-08  0.993  Looks like you failed 97 tests of 776.
# 2020-05-11  0.993  Looks like you failed 126 tests of 776.
# 2020-05-11  0.993  Looks like you failed 98 tests of 776.
# 2020-05-12  0.994  Looks like you failed 171 tests of 959.
# 2020-05-13  0.995  Looks like you failed 171 tests of 959.
# 2020-05-14  0.996  Looks like you failed 171 tests of 992.
# 2020-05-19  0.997  Looks like you failed 171 tests of 994.
# 2020-05-22  0.997  Looks like you failed 163 tests of 994.
# 2020-06-01  0.997  Looks like you failed 159 tests of 994.
# 2020-06-08  0.999  Looks like you failed 176 tests of 1055.
# 2020-06-09  0.999  Looks like you failed 165 tests of 1055.
# 2020-06-10  0.999  Looks like you failed 104 tests of 1055.
# 2020-07-07  0.999  Looks like you failed 31 tests of 1055.


END {
diag <<DIAG

###############################

Attention CPANTesters: you do not need to file a ticket when this test fails. I will receive the test reports and act on it soon. thank you!

###############################
DIAG
  if not Test::Builder->new->is_passing;
}

done_testing;
