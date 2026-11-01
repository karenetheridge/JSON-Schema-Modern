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
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

my $tests = sub ($char, $test_substr) {
  is_equal(
    $js->evaluate($char, { pattern => '[a-z]' })->TO_JSON,
    my $result = {
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

  is_equal(
    $js->evaluate($char, { pattern => '\w' })->TO_JSON,
    $result,
    $test_substr.' LATIN SMALL LETTER E WITH ACUTE does not match the "word" character class, because \w is ascii-only in ECMA-262',
  );

  is_equal(
    $js->evaluate($char, { pattern => '(?u:\w)' })->TO_JSON,
    {
      valid => true,
    },
    $test_substr.' LATIN SMALL LETTER E WITH ACUTE does match the "word" character class when explicitly enabling unicode semantics in the pattern',
  );

  is_equal(
    $js->evaluate($char, { pattern => 'é' })->TO_JSON,
    {
      valid => true,
    },
    $test_substr.' LATIN SMALL LETTER E WITH ACUTE matches itself, even though /a is applied to the pattern',
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

  is_equal(
    $js->evaluate('hello', { pattern => '' })->TO_JSON,
    { valid => true },
    'empty pattern in "pattern" will correctly match',
  );

  # create a new "last successful match"
  $str = "furble" =~ s/fur/meow/r;

  is_equal(
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

subtest 'bad regex in schema' => sub {
  cmp_result(
    $js->evaluate(
      {
        my_pattern => 'foo',
        my_patternProperties => { foo => 1 },
      },
      my $schema = {
        type => 'object',
        properties => {
          my_pattern => {
            type => 'string',
            pattern => '(',
          },
          my_patternProperties => {
            type => 'object',
            patternProperties => { '(' => true },
            additionalProperties => false,
          },
          my_runtime_pattern => {
            type => 'string',
            pattern => '\p{main::IsFoo}', # qr/$pattern/ will not find this error, but m/$pattern/ will
          },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          keywordLocation => '/properties/my_pattern/pattern',
          error => re(qr/^Unmatched \( in regex/),
        },
        {
          keywordLocation => '/properties/my_patternProperties/patternProperties/(',
          error => re(qr/^Unmatched \( in regex/),
        },
        # Note no error for missing IsFoo
      ],
    },
    'bad "pattern" and "patternProperties" regexes are properly noted in error',
  );

  cmp_result(
    $js->evaluate(
      { my_runtime_pattern => 'foo' },
      $schema = {
        $schema->%{type},
        properties => +{ $schema->{properties}->%{my_runtime_pattern} },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/my_runtime_pattern',
          keywordLocation => '/properties/my_runtime_pattern/pattern',
          # in 5.28 and earlier: Can't find Unicode property definition "IsFoo"
          # in 5.30 and later:   Unknown user-defined property name \p{main::IsFoo}
          error => re(qr/^EXCEPTION: .*property.*IsFoo/),
        },
      ],
    },
    'bad "pattern" regex is properly noted in error',
  );

  no warnings 'once';
  *IsFoo = sub { "0066\n006F\n" }; # accepts 'f', 'o'

  is_equal(
    $js->evaluate(
      { my_runtime_pattern => 'foo' },
      $schema,
    )->TO_JSON,
    {
      valid => true,
    },
    '"pattern" regex is now valid, due to the Unicode property becoming defined',
  );
};

subtest 'embedded code in regexes' => sub {
  cmp_result(
    $js->evaluate(
      'foo',
      {
        type => 'string',
        pattern => q!^(?{ die 'we should never execute this' })$!,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          keywordLocation => '/pattern',
          error => re(qr/^Eval-group not allowed at runtime/),
        },
      ],
    },
    'code embedded in a regex in the schema is rejected at traverse time, preventing execution',
  );

  cmp_result(
    $js->evaluate(
      q!^(?{ die 'we should never execute this' })$!,
      {
        type => 'string',
        format => 'regex',
      },
    )->TO_JSON,
    { valid => true },
    'code embedded in a regex in the data is accepted, but not executed',
  );
};

done_testing;
