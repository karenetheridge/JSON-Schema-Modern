# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::Needs;
use List::Util 1.50 'head';
use lib 't/lib';
use Helper;
use Acceptance;

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not grep $ENV{$_}, @variables;
}

if ($ENV{EXTENDED_TESTING}) {
  test_needs {
    'Time::Moment' => 0,
    'DateTime::Format::RFC3339' => 0,
    'Email::Address::XS' => '1.04',
    'Data::Validate::Domain' => 0,
    'Net::IDN::Encode' => 0,
  };
}

if ($ENV{AUTHOR_TESTING}) {
  eval { require Time::Moment; 1 } or fail $@;
  eval { require DateTime::Format::RFC3339; 1 } or fail $@;
  eval { require Email::Address::XS; Email::Address::XS->VERSION(1.04); 1 } or fail $@;
  eval { require Data::Validate::Domain; 1 } or fail $@;
  eval { require Net::IDN::Encode; 1 } or fail $@;
}

my $version = 'draft4';

acceptance_tests(
  acceptance => {
    specification => $version,
    test_subdir => 'optional/format',
  },
  evaluator => {
    specification_version => $version,
    # validate_formats behaviour should default to true for this draft
    collect_annotations => 0,
  },
  output_file => $version.'-acceptance-format.txt',
  test => {
    $ENV{NO_TODO} ? () : ( todo_tests => [
      { file => [
          # these all depend on optional prereqs
          !$ENV{AUTHOR_TESTING} && !eval { require Time::Moment; 1 } ? 'date-time.json' : (),
          !$ENV{AUTHOR_TESTING} && !eval { require DateTime::Format::RFC3339; 1 } ? 'date-time.json' : (),
          !$ENV{AUTHOR_TESTING} && !eval { require Email::Address::XS; Email::Address::XS->VERSION(1.04); 1 } ? 'email.json' : (),
          !$ENV{AUTHOR_TESTING} && !eval { require Data::Validate::Domain; 1 } ? 'hostname.json' : (),
        ] },
      # various edge cases that are difficult to accomodate
      { file => 'hostname.json', test_description => [
          'single label with hyphen',
          'single label with digits',
          'single label ending with digit',
          'single label',
        ] },
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
see t/results/draft4-acceptance-format.txt for test results
