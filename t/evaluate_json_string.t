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

use Test::Fatal;

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

like(ref($js->_json_decoder), qr/^(?:Cpanel::JSON::XS|JSON::PP)$/, 'we have a JSON decoder');

is(
  exception {
    ok($js->evaluate_json_string('true', {})->valid, 'json data "true" is evaluated successfully');
  },
  undef,
  'no exceptions in evaluate_json_string on good json',
);

is(
  exception {
    cmp_result(
      $js->evaluate_json_string('blargh', {})->TO_JSON,
      {
        valid => false,
        errors => [
          {
            instanceLocation => '',
            keywordLocation => '',
            error => re(qr/malformed JSON string/),
          },
        ],
      },
      'evaluating bad json data returns false, with error',
    );
  },
  undef,
  'no exceptions in evaluate_json_string on bad json',
);

done_testing;
