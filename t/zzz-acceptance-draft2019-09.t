# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
no autovivification warn => qw(fetch store exists delete);
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

use List::Util 1.50 'head';
use Config;
use lib 't/lib';
use Helper;
use Acceptance;

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not grep $ENV{$_}, @variables;
}

my $version = 'draft2019-09';

my $orig_warn_handler = $SIG{__WARN__};
$SIG{__WARN__} = sub {
  return if $_[0] =~ /^no-longer-supported "dependencies" keyword present \(at location ""\): this should be rewritten as "dependentSchemas" or "dependentRequired"/;
  goto &$orig_warn_handler if $orig_warn_handler;
};

acceptance_tests(
  acceptance => {
    specification => $version,
    skip_dir => 'optional/format',
  },
  evaluator => {
    specification_version => $version,
    # validate_formats behaviour should default to false for this draft
    collect_annotations => 0,
  },
  output_file => $version.'-acceptance.txt',
  test => {
    $ENV{NO_TODO} ? () : ( todo_tests => [
      # I am not interested in back-supporting "dependencies"
      { file => 'optional/dependencies-compatibility.json' },
      # various edge cases that are difficult to accomodate
      $Config{ivsize} < 8 ? { file => 'multipleOf.json', group_description => 'small multiple of large integer', test_description => 'any integer is a multiple of 1e-8' } : (),
      { file => 'optional/ecmascript-regex.json', group_description => '\w in patterns matches [A-Za-z0-9_], not unicode letters', test_description => [ 'literal unicode character in json string', 'unicode character in hex format in string' ] },
      { file => 'optional/ecmascript-regex.json', group_description => '\d in pattern matches [0-9], not unicode digits', test_description => 'non-ascii digits (BENGALI DIGIT FOUR, BENGALI DIGIT TWO)' },
      { file => 'optional/ecmascript-regex.json', group_description => '\w in patternProperties matches [A-Za-z0-9_], not unicode letters', test_description => [ 'literal unicode character in json string', 'unicode character in hex format in string' ] },
      { file => 'optional/ecmascript-regex.json', group_description => '\d in patternProperties matches [0-9], not unicode digits', test_description => 'non-ascii digits (BENGALI DIGIT FOUR, BENGALI DIGIT TWO)' },
      { file => 'optional/ecmascript-regex.json', group_description => [ 'ECMA 262 \d matches ascii digits only', 'ECMA 262 \D matches everything but ascii digits', 'ECMA 262 \w matches ascii letters only', 'ECMA 262 \W matches everything but ascii letters' ] }, # TODO, see test suite PR#505
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 \s matches whitespace', test_description => 'zero-width whitespace matches' },
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 \S matches everything but whitespace', test_description => 'zero-width whitespace does not match' },
      # things we will never do
      { file => 'optional/refOfUnknownKeyword.json' },
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
see t/results/draft2019-09-acceptance.txt for test results
