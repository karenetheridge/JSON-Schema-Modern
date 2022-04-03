use strictures 2;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

my $tests = sub ($char, $test_substr) {
  cmp_deeply(
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

  cmp_deeply(
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

done_testing;
