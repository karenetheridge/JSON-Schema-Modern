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
use if "$]" >= 5.022, experimental => 're_strict';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $js = JSON::Schema::Modern->new;

cmp_result(
  $js->validate_schema({ type => 'bloop' })->TO_JSON,
  {
    valid => false,
    errors => supersetof(
      {
        instanceLocation => '/type',
        keywordLocation => re(qr{/enum$}),
        absoluteKeywordLocation => 'https://json-schema.org/draft/2020-12/meta/validation#/$defs/simpleTypes/enum',
        error => 'value does not match',
      },
    ),
  },
  'validate_schema on simple schema with no $schema keyword',
);

cmp_result(
  $js->validate_schema({
    '$schema' => 'https://json-schema.org/draft/2019-09/schema',
    type => 'bloop',
  })->TO_JSON,
  {
    valid => false,
    errors => supersetof(
      {
        instanceLocation => '/type',
        keywordLocation => re(qr{/enum$}),
        absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/validation#/$defs/simpleTypes/enum',
        error => 'value does not match',
      },
    ),
  },
  'validate_schema on schema with metaschema $schema keyword',
);

$js->add_schema('http://example.com/myschema', { '$id' => 'http://example.com/myschema', type => 'boolean' });

cmp_result(
  $js->validate_schema({
    '$schema' => 'http://example.com/myschema',
    type => 'bloop',
  })->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/type',
        absoluteKeywordLocation => 'http://example.com/myschema#/type',
        error => 'got object, not boolean',
      },
    ],
  },
  'validate_schema with custom metaschema',
);

cmp_result(
  $js->validate_schema({
    '$id' => '#/$defs/foo',
    '$schema' => 'http://json-schema.org/draft-07/schema#',
  })->TO_JSON,
  {
    valid => false,
    errors => [
      {
        instanceLocation => '',
        keywordLocation => '/$id',
        error => '$id value "#/$defs/foo" does not match required syntax',
      },
    ],
  },
  'validate_schema with schema that validates against the metaschema, but fails in extra traverse checks',
);

done_testing;
