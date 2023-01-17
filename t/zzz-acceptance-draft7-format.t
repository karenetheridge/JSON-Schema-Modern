# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use Test::Needs;
use List::Util 1.50 'head';
use lib 't/lib';
use Acceptance;

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not -d '.git' and not grep $ENV{$_}, @variables;
}

if ($ENV{EXTENDED_TESTING}) {
  test_needs 'Time::Moment';
  test_needs 'DateTime::Format::RFC3339';
  test_needs 'Email::Address::XS', 1.04;
  test_needs 'Data::Validate::Domain';
  test_needs 'Net::IDN::Encode';
}

if (-d '.git' or $ENV{AUTHOR_TESTING}) {
  eval { require Time::Moment; 1 } or fail $@;
  eval { require DateTime::Format::RFC3339; 1 } or fail $@;
  eval { require Email::Address::XS; Email::Address::XS->VERSION(1.04); 1 } or fail $@;
  eval { require Data::Validate::Domain; 1 } or fail $@;
  eval { require Net::IDN::Encode; 1 } or fail $@;
}

my $version = 'draft7';

acceptance_tests(
  acceptance => {
    specification => $version,
    test_subdir => 'optional/format',
  },
  evaluator => {
    specification_version => $version,
    validate_formats => 1,
    collect_annotations => 0,
  },
  output_file => $version.'-acceptance-format.txt',
  test => {
    $ENV{NO_TODO} ? () : ( todo_tests => [
      { file => [
          'iri-reference.json',                       # all strings are considered valid
          'uri-template.json',                        # not yet implemented
          # these all depend on optional prereqs
          $ENV{AUTOMATED_TESTING} && !eval { require Time::Moment; 1 } ? qw(date-time.json date.json time.json) : (),
          $ENV{AUTOMATED_TESTING} && !eval { require DateTime::Format::RFC3339; 1 } ? 'date-time.json' : (),
          $ENV{AUTOMATED_TESTING} && !eval { require Email::Address::XS; Email::Address::XS->VERSION(1.04); 1 } ? qw(email.json idn-email.json) : (),
          $ENV{AUTOMATED_TESTING} && !eval { require Data::Validate::Domain; 1 } ? 'hostname.json' : (),
          $ENV{AUTOMATED_TESTING} && !eval { require Net::IDN::Encode; 1 } ? 'idn-hostname.json' : (),
        ] },
      # various edge cases that are difficult to accomodate
      { file => 'iri.json', group_description => 'validation of IRIs',  # see test suite issue 395
        test_description => 'an invalid IRI based on IPv6' },
      { file => 'idn-hostname.json',
        group_description => 'validation of internationalized host names' }, # IDN decoder, Data::Validate::Domain both have issues
      { file => 'uri.json',
        test_description => 'validation of URIs',
        test_description => 'an invalid URI with comma in scheme' },  # Mojo::URL does not fully validate
    ] ),
  },
);

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
see t/results/draft7-acceptance-format.txt for test results
