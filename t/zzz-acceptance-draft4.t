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
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use List::Util 1.50 'head';
use Config;
use lib 't/lib';
use Helper;
use Acceptance;
use Test::Needs;

BEGIN {
  my @variables = qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING);

  plan skip_all => 'These tests may fail if the test suite continues to evolve! They should only be run with '
      .join(', ', map $_.'=1', head(-1, @variables)).' or '.$variables[-1].'=1'
    if not grep $ENV{$_}, @variables;

  test_needs({ 'Test::JSON::Schema::Acceptance' => '1.036' });  # bad remotes
}

my $version = 'draft4';

my $orig_warn_handler = $SIG{__WARN__};
$SIG{__WARN__} = sub {
  return if $_[0] =~ /^no-longer-supported "id" keyword present \(at location "[^"]+"\): this should be rewritten as "\$id"/;
  goto &$orig_warn_handler if $orig_warn_handler;
};

acceptance_tests(
  acceptance => {
    specification => $version,
    skip_dir => 'optional/format',
  },
  evaluator => {
    specification_version => $version,
    validate_formats => 0,    # not the default for the Format vocabulary for this draft
    collect_annotations => 0,
  },
  output_file => $version.'-acceptance.txt',
  test => {
    $ENV{NO_TODO} ? () : (todo_tests => [
      # various edge cases that are difficult to accomodate
      $Config{ivsize} < 8 ? { file => 'multipleOf.json', group_description => 'small multiple of large integer', test_description => 'any integer is a multiple of 1e-8' } : (),
      # ascii \s only matches [\f\n\r\t] and vertical tab
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 \s matches whitespace', test_description => [
        'latin-1 non-breaking-space matches',
        'zero-width whitespace matches',
        'paragraph separator matches (line terminator)',
        'EM SPACE matches (Space_Separator)',
      ] },
      { file => 'optional/ecmascript-regex.json', group_description => 'ECMA 262 \S matches everything but whitespace', test_description => [
        'latin-1 non-breaking-space does not match',
        'zero-width whitespace does not match',
        'paragraph separator does not match (line terminator)',
        'EM SPACE does not match (Space_Separator)',
      ] },
    ]),
  },
);

END {
diag <<DIAG

###############################

Attention CPANTesters: you do not need to file a ticket when this test fails. I will receive the test reports and act on it soon. thank you!

###############################
DIAG
  if not is_passing;
}

done_testing;
__END__
see t/results/draft4-acceptance.txt for test results
