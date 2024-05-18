use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

my $tests = sub ($char, $test_substr) {
  cmp_result(
    $js->evaluate($char, { pattern => '[a-z]' })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/pattern',
          error => 'pattern does not match',
        },
      ],
    },
    $test_substr.' LATIN SMALL LETTER E WITH ACUTE does not match the ascii range [a-z]',
  );

  cmp_result(
    $js->evaluate($char, { pattern => '\w' })->TO_JSON,
    {
      valid => true,
    },
    $test_substr.' LATIN SMALL LETTER E WITH ACUTE does match the "word" character class, because unicode semantics are used for matching',
  );
};

my $letter = "é";
$tests->($letter, 'unchanged');

utf8::upgrade($letter);
$tests->($letter, 'upgraded');

utf8::downgrade($letter);
$tests->($letter, 'downgraded');


subtest 'empty pattern' => sub {
  # create a "last successful match" in a containing scope
  my $str = "furble" =~ s/fur/meow/r;

  cmp_result(
    $js->evaluate('hello', { pattern => '' })->TO_JSON,
    { valid => true },
    'empty pattern in "pattern" will correctly match',
  );

  # create a new "last successful match"
  $str = "furble" =~ s/fur/meow/r;

  cmp_result(
    $js->evaluate(
      { alpha => 'hello' },
      {
        patternProperties => { '' => true },
        additionalProperties => false,
        unevaluatedProperties => false,
      },
    )->TO_JSON,
    { valid => true },
    'empty pattern in "patternProperties" will correctly match',
  );
};

done_testing;
