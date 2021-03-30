# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
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

use if $ENV{AUTHOR_TESTING}, 'Test::Warnings' => ':fail_on_warning';
use Test::JSON::Schema::Acceptance 1.004;
use Test::Memory::Cycle;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Draft201909' => 'share' } };
use JSON::Schema::Draft201909;

foreach my $env (qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING NO_TODO TEST_DIR NO_SHORT_CIRCUIT)) {
  note $env.': '.($ENV{$env} // '');
}
note '';

my $accepter = Test::JSON::Schema::Acceptance->new(
  test_dir => $ENV{TEST_DIR} ? $ENV{TEST_DIR}
    : Test::JSON::Schema::Acceptance->new(specification => 'draft2019-09')->test_dir->child('optional/format'),
  include_optional => 1,
  verbose => 1,
);

my %options = (validate_formats => 1);
my $js = JSON::Schema::Draft201909->new(%options);
my $js_short_circuit = JSON::Schema::Draft201909->new(%options, short_circuit => 1);

my $add_resource = sub {
  my ($uri, $schema) = @_;
  $js->add_schema($uri => $schema);
  $js_short_circuit->add_schema($uri => $schema);
};

my $encoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0, convert_blessed => 1, canonical => 1, pretty => 1);
$encoder->indent_length(2) if $encoder->can('indent_length');

$accepter->acceptance(
  validate_data => sub {
    my ($schema, $instance_data) = @_;
    my $result = $js->evaluate($instance_data, $schema);
    my $result_short = $ENV{NO_SHORT_CIRCUIT} || $js_short_circuit->evaluate($instance_data, $schema);

    note 'result: ', $encoder->encode($result);
    note 'short-circuited result: ', $encoder->encode($result_short)
      if not $ENV{NO_SHORT_CIRCUIT} and ($result xor $result_short);

    die 'results inconsistent between short_circuit = false and true'
      if not $ENV{NO_SHORT_CIRCUIT}
        and ($result xor $result_short)
        and not grep $_->error =~ /but short_circuit is enabled/, $result_short->errors;

    # if any errors contain an exception, generate a warning so we can be sure
    # to count that as a failure (an exception would be caught and perhaps TODO'd).
    # (This might change if tests are added that are expected to produce exceptions.)
    foreach my $r ($result, ($ENV{NO_SHORT_CIRCUIT} ? () : $result_short)) {
      warn 'evaluation generated an exception'
        if grep $_->{error} =~ /^EXCEPTION/
            && $_->{error} !~ /but short_circuit is enabled/,
          @{$r->TO_JSON->{errors}};
    }

    $result;
  },
  add_resource => $add_resource,
  @ARGV ? (tests => { file => \@ARGV }) : (),
  $ENV{NO_TODO} ? () : ( todo_tests => [
    { file => [
        'iri-reference.json',                       # not yet implemented
        'uri-template.json',                        # not yet implemented
        # these all depend on optional prereqs
        $ENV{AUTOMATED_TESTING} && !eval { +require 'Time::Moment'; 1 } ? qw(date-time.json date.json time.json) : (),
        $ENV{AUTOMATED_TESTING} && !eval { +require 'Email::Address::XS'; Email::Address::XS->VERSION(1.01); 1 } ? qw(email.json idn-email.json) : (),
        $ENV{AUTOMATED_TESTING} && !eval { +require 'Data::Validate::Domain'; 1 } ? 'hostname.json' : (),
        $ENV{AUTOMATED_TESTING} && !eval { +require 'Net::IDN::Encode'; 1 } ? 'idn-hostname.json' : (),
      ] },
    # various edge cases that are difficult to accomodate
    { file => 'date-time.json', group_description => 'validation of date-time strings',
      test_description => 'case-insensitive T and Z' },
    { file => 'date.json', group_description => 'validation of date strings',
      test_description => 'only RFC3339 not all of ISO 8601 are valid' },
    { file => 'iri.json', group_description => 'validation of IRIs',  # see test suite issue 395
      test_description => 'an invalid IRI based on IPv6' },
    { file => 'idn-hostname.json',
      group_description => 'validation of internationalized host names' }, # IDN decoder, Data::Validate::Domain both have issues
    { file => 'uri.json',
      test_description => 'validation of URIs',
      test_description => 'an invalid URI with comma in scheme' },  # Mojo::URL does not fully validate
  ] ),
);

memory_cycle_ok($js, 'no leaks in the main evaluator object');
memory_cycle_ok($js_short_circuit, 'no leaks in the short-circuiting evaluator object');


# date        Test::JSON::Schema::Acceptance version
#                    JSON::Schema::Draft201909 version
#                           result count of running *all* tests (with no TODOs)
# ----        -----  -----  --------------------------------------
# 2020-12-04  1.003  0.018  Looks like you failed 40 tests of 1265.
# 2021-03-17  1.004  0.024  Looks like you failed 23 tests of 242. <-- manually edited to only include optional/format
# 2021-03-23  1.005  0.024  Looks like you failed 23 tests of 245.


END {
diag <<DIAG

###############################

Attention CPANTesters: you do not need to file a ticket when this test fails. I will receive the test reports and act on it soon. thank you!

###############################
DIAG
  if not Test::Builder->new->is_passing;
}

done_testing;
__END__

# Results using Test::JSON::Schema::Acceptance 1.005
# with commit cd73775f22d4cae64587486c0ee7efca9131643c (2.0.0-311-gcd73775)
# from git://github.com/json-schema-org/JSON-Schema-Test-Suite.git:
# using custom test directory: /Volumes/amaretto/Users/ether/.perlbrew/libs/33.8@std/lib/perl5/auto/share/dist/Test-JSON-Schema-Acceptance/tests/draft2019-09/optional/format
# optional tests included: yes
#
# filename                    pass  todo-fail  fail
# -------------------------------------------------
# date-time.json                10          1     0
# date.json                      4          1     0
# duration.json                 17          0     0
# email.json                     9          0     0
# hostname.json                 12          0     0
# idn-email.json                 4          0     0
# idn-hostname.json             29         16     0
# ipv4.json                      6          0     0
# ipv6.json                     29          0     0
# iri-reference.json             5          2     0
# iri.json                       8          1     0
# json-pointer.json             32          0     0
# regex.json                     2          0     0
# relative-json-pointer.json     9          0     0
# time.json                      3          0     0
# uri-reference.json             7          0     0
# uri-template.json              3          1     0
# uri.json                      19          1     0
# uuid.json                     12          0     0
# -------------------------------------------------
# TOTAL                        220         23     0
