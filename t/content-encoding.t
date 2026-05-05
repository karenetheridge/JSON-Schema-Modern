# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
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
use utf8;

use lib 't/lib';
use Helper;
use Test2::Warnings qw(warnings :no_end_test had_no_warnings);

subtest 'unrecognized encoding formats do not result in errors, when not asserting' => sub {
  my $js = JSON::Schema::Modern->new(collect_annotations => 1);

  is_equal(
    $js->evaluate(
      'hello',
      {
        type => 'string',
        contentEncoding => 'base64',
        contentMediaType => 'image/png',
        contentSchema => false,
      },
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/contentEncoding',
          annotation => 'base64',
        },
        {
          instanceLocation => '',
          keywordLocation => '/contentMediaType',
          annotation => 'image/png',
        },
        {
          instanceLocation => '',
          keywordLocation => '/contentSchema',
          annotation => false,
        },
      ],
    },
    'in evaluate(), annotations are collected and no validation is performed',
  );
};

subtest 'media_type and encoding handlers (legacy interfaces)' => sub {
  my $js = JSON::Schema::Modern->new;

  my @warnings = warnings {
    cmp_result(
      $js->get_media_type('application/json')->(\'{"alpha": "a string"}'),
      \ { alpha => 'a string' },
      'application/json media_type decoder',
    );
  };
  cmp_result(
    \@warnings,
    [ re(qr/^\$jsm->get_media_type is deprecated; use the function in JSON::Schema::Modern::Utilities instead/) ],
    'warned once when using deprecated get_media_type',
  );

  cmp_result($js->get_media_type('*/*'), undef, '*/* has no default match');

  cmp_result($js->get_media_type('text/plain')->(\'foo'), \'foo', 'default text/plain media_type decoder');

  cmp_result($js->get_media_type('tExt/PLaIN')->(\'foo'), \'foo', 'getter uses the casefolded name');

  @warnings = warnings {
    $js->add_media_type('furble/*' => sub { \1 });
  };
  cmp_result(
    \@warnings,
    [ re(qr/^\$jsm->add_media_type is deprecated; use the function in JSON::Schema::Modern::Utilities instead/) ],
    'warned once when using deprecated add_media_type',
  );

  cmp_result(
    $js->get_media_type('furble/bloop')->(\''),
    \'1',
    'deprecated getter matches to wildcard entries',
  );
  cmp_result(
    JSON::Schema::Modern::Utilities::decode_media_type('furble/bloop', \''),
    \'1',
    'global decoder matches to wildcard entries',
  );

  $js->add_media_type('mytext/*' => sub { \'wildcard' });
  cmp_result($js->get_media_type('myTExT/plain')->(\'foo'), \'wildcard', 'getter uses new override entry for wildcard');

  $js->add_media_type('mytext/plain' => sub { \'plain' });
  cmp_result($js->get_media_type('MYTExT/plain')->(\'foo'), \'plain', 'getter prefers case-insensitive matches to wildcard entries');
  cmp_result($js->get_media_type('myTExT/blop')->(\'foo'), \'wildcard', 'getter matches to wildcard entries');
  cmp_result($js->get_media_type('myTExT/*')->(\'foo'), \'wildcard', 'text/* matches itself');

  $js->add_media_type('*/*' => sub { \'wildercard' });
  cmp_result($js->get_media_type('myTExT/plain')->(\'foo'), \'plain', 'getter still prefers case-insensitive matches to wildcard entries');
  cmp_result($js->get_media_type('myTExT/blop')->(\'foo'), \'wildcard', 'text/* is preferred to */*');
  cmp_result($js->get_media_type('*/*')->(\'foo'), \'wildercard', '*/* matches */*, once defined');
  cmp_result($js->get_media_type('fOO/bar')->(\'foo'), \'wildercard', '*/* is returned as a last resort');

  cmp_result(
    $js->get_media_type('application/x-www-form-urlencoded')->(\qq!\x{c3}\x{a9}clair=\x{e0}\x{b2}\x{a0}\x{5f}\x{e0}\x{b2}\x{a0}!),
    \ { 'éclair' => 'ಠ_ಠ' },
    'application/x-www-form-urlencoded happy path with unicode',
  );

  cmp_result(
    $js->get_media_type('application/x-ndjson')->(\qq!{"foo":1,"bar":2}\n["a","b",3]\r\n"\x{e0}\x{b2}\x{a0}\x{5f}\x{e0}\x{b2}\x{a0}"!),
    \ [ { foo => 1, bar => 2 }, [ 'a', 'b', 3 ], 'ಠ_ಠ' ],
    'application/x-ndjson happy path with unicode',
  );

  like(
    dies { $js->get_media_type('application/x-ndjson')->(\qq!{"foo":1,"bar":2}\n["a","b",]!) },
    qr/^parse error at line 2: malformed JSON string/,
    'application/x-ndjson dies with line number of the bad data',
  );


  my $js2 = JSON::Schema::Modern->new;

  cmp_result(
    $js2->get_media_type('furble/bloop')->(\''),
    \'1',
    'deprecated getter on second instance finds the right definition',
  );

  cmp_result(
    $js2->get_media_type('fOO/bar')->(\''),
    \'wildercard',
    '*/* definition is visible to the second instance',
  );

  cmp_result(
    JSON::Schema::Modern::Utilities::decode_media_type('myTExT/*', \'foo'),
    \'wildcard',
    'global decoder still exists',
  );

  JSON::Schema::Modern::Utilities::delete_media_type('furble/*');
  JSON::Schema::Modern::Utilities::delete_media_type('*/*');
  is($js->get_media_type('furble/bloop'), undef, 'media-type deletion is global');
  is($js2->get_media_type('furble/bloop'), undef, 'media-type deletion is global');


  # MIME::Base64::decode("eyJmb28iOiAiYmFyIn0K") -> {"foo": "bar"}
  # Cpanel::JSON::XS->new->allow_nonref(1)->utf8(0)->decode(q!{"foo": "bar"}!) -> { foo => 'bar' }

  cmp_result(
    $js->get_media_type('application/json')->($js->get_encoding('base64')->(\'eyJmb28iOiAiYmFyIn0K')),
    \ { foo => 'bar' },
    'base64 encoding decoder + application/json media_type decoder',
  );

  cmp_result(
    $js->get_media_type('application/json')->($js->get_encoding('base64url')->(\'eyJmb28iOiJiYXIifQ')),
    \ { foo => 'bar' },
    'base64url encoding decoder + application/json media_type decoder',
  );


  undef $js;
  cmp_result(
    scalar JSON::Schema::Modern::Utilities::decode_media_type('myTExT/*', \'foo'),
    undef,
    'deleted JSM instances delete their media-types',
  );

  is_equal(
    $js2->get_media_type('fOO/bar'),
    undef,
    '*/* definition was deleted by the evaluator instance that added it',
  );
};

subtest 'draft2020-12 assertions' => sub {
  my $js = JSON::Schema::Modern->new;

  is_equal(
    $js->evaluate(
      my $data = { encoded_object => 'eyJmb28iOiAiYmFyIn0K' },
      my $schema = {
        type => 'object',
        properties => {
          encoded_object => my $subschema = {
            type => 'string',
            contentEncoding => 'base64',
            contentMediaType => 'application/json',
            contentSchema => {
              type => 'object',
              properties => {
                x => {
                  type => 'string',
                  default => 'default value',
                },
              },
              additionalProperties => {
                const => 'ಠ_ಠ',
              },
            },
          },
        },
      },
    )->TO_JSON,
    { valid => true },
    'under the current spec version, content* keywords are not assertions',
  );

  is_equal(
    $js->evaluate(
      { encoded_object => 'blur^p=' },  # invalid base64
      $schema,
      { validate_content_schemas => 1 },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentEncoding',
          error => 'could not decode base64 string: invalid characters',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'contentEncoding first decodes the string, erroring if it can\'t',
  );

  cmp_result(
    $js->evaluate(
      { encoded_object => 'bm90IGpzb24=' }, # base64-encoded "not json"
      $schema,
      { validate_content_schemas => 1 },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentMediaType',
          error => re(qr!could not decode application/json string: \'null\' expected, at character offset 0!),
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'then contentMediaType parses the decoded string, erroring if it can\'t, and does not continue with the schema',
  );

  is_equal(
    $js->evaluate(
      { encoded_object => 'eyJoaSI6MX0=' }, # base64-encoded, json-encoded { hi => 1 }
      $schema,
      { validate_content_schemas => 1 },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object/hi',
          keywordLocation => '/properties/encoded_object/contentSchema/additionalProperties/const',
          error => 'value does not match (wrong type: integer vs string)',
        },
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentSchema/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentSchema',
          error => 'subschema is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'contentSchema evaluates the decoded data',
  );

  is_equal(
    $js->evaluate(
      { encoded_object => 'bnVsbA==' }, # base64-encoded, json-encoded undef
      $schema,
      { validate_content_schemas => 1 },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentSchema/type',
          error => 'got null, not object',
        },
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentSchema',
          error => 'subschema is not valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'null data is handled properly',
  );

  is_equal(
    (my $result = $js->evaluate(
      { encoded_object => 'eyJoaSI6IuCyoF/gsqAifQ==' }, # base64-encoded, json-encoded { hi => "ಠ_ಠ" }
      $schema,
      {
        validate_content_schemas => 1,
        with_defaults => 1,
        callbacks => {
          type => sub ($self, $schema, $state) {
            return 1 if $state->{data_path} ne '/properties/encoded_object';
            is_equal(
              $state->{data},
              'eyJoaSI6IuCyoF/gsqAifQ==',
              'before the content* keywords are evaluated, the instance data is still a string',
            );
          },
        },
      },
    ))->TO_JSON,
    {
      valid => true,
      defaults => {
        '/encoded_object/x' => 'default value',
      },
    },
    'contentSchema successfully evaluates the decoded data',
  );

  is_equal(
    $result->data,
    {
      encoded_object => {
        hi => 'ಠ_ಠ',
        x => 'default value',
      },
    },
    'result object contains the instance data with the encoded data fully deserialized',
  );


  is_equal(
    ($result = $js->evaluate(
      'eyJoaSI6IuCyoF/gsqAifQ==', # base64-encoded, json-encoded { hi => 'ಠ_ಠ' }
      $subschema,
      {
        validate_content_schemas => 1,
        callbacks => {
          contentEncoding => sub ($self, $schema, $state) {
            is_equal(
              $state->{data},
              qq!{"hi":"\xe0\xb2\xa0\x5f\xe0\xb2\xa0"}!,
              'after contentEncoding, the instance data is a decoded string',
            );
          },
          contentMediaType => sub ($self, $schema, $state) {
            is_equal(
              $state->{data},
              { hi => 'ಠ_ಠ' },
              'after contentMediaType, the instance data is a decoded object',
            );
          },
        },
      }))->TO_JSON,
    { valid => true },
    'decode and populate content into the top level of the result data',
  );

  is_equal(
    $result->data,
    { hi => 'ಠ_ಠ' },
    'result object contains the instance data with the encoded data fully deserialized into he root',
  );
};

subtest 'draft7 assertions' => sub {
  my $js = JSON::Schema::Modern->new(specification_version => 'draft7');

  is_equal(
    $js->evaluate(
      { encoded_object => 'blur^p=' },  # invalid base64
      my $schema = {
        type => 'object',
        properties => {
          encoded_object => {
            contentEncoding => 'base64',
            contentMediaType => 'application/json',
            contentSchema => {
              type => 'object',
              additionalProperties => {
                const => 'ಠ_ಠ',
              },
            },
          },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentEncoding',
          error => 'could not decode base64 string: invalid characters',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'in draft7, assertion behaviour is the default',
  );

  cmp_result(
    $js->evaluate(
      { encoded_object => 'bm90IGpzb24=' }, # base64-encoded "not json"
      $schema,
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentMediaType',
          error => re(qr!could not decode application/json string: \'null\' expected, at character offset 0!),
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'in draft7, then contentMediaType parses the decoded string, erroring if it can\'t, and does not continue with the schema',
  );

  is_equal(
    $js->evaluate(
      { encoded_object => 'eyJoaSI6MX0=' }, # base64-encoded, json-encoded { hi => 1 }
      $schema,
    )->TO_JSON,
    { valid => true },
    'under draft7, content* are assertions by default, but contentSchema does not exist',
  );
};

subtest 'more assertions' => sub {
  my $js = JSON::Schema::Modern->new;

  is_equal(
    $js->evaluate(
      'a string',
      {
        contentEncoding => 'whargarbl',
        contentMediaType => 'whargarbl',
        contentSchema => false,
      },
      {
        validate_content_schemas => 1,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/contentEncoding',
          error => 'cannot find decoder for contentEncoding "whargarbl"',
        },
      ],
    },
    'evaluation aborts with an unrecognized contentEncoding',
  );

  is_equal(
    $js->evaluate(
      'a string',
      {
        contentMediaType => 'whargarbl',
        contentSchema => false,
      },
      {
        validate_content_schemas => 1,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/contentMediaType',
          error => 'cannot find decoder for contentMediaType "whargarbl"',
        },
      ],
    },
    'evaluation aborts with an unrecognized contentMediaType',
  );
};

subtest 'use of an absolute URI and different dialect within contentSchema' => sub {
  my $js = JSON::Schema::Modern->new(
    validate_content_schemas => 1,
    collect_annotations => 1,
  );

  $js->add_schema({
    '$id' => 'https://my_metaschema',
    '$schema' => 'https://json-schema.org/draft/2020-12/schema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/validation' => true,
    },
  });

  my $subschema;
  is_equal(
    $js->evaluate(
      { foo => '{"bar":1}' },
      {
        '$id' => 'https://example.com',
        additionalProperties => {
          contentMediaType => 'application/json',
          contentSchema => $subschema = {
            '$id' => 'https://foo.com',
            '$schema' => 'https://my_metaschema',
            '$defs' => {
              my_def => { type => 'object', blah => 1 },
            },
            '$ref' => '#/$defs/my_def',
            bloop => 2,
            properties => { bar => false }, # this keyword should only annotate
          },
        },
      },
    )->TO_JSON,
    {
      valid => true,
      annotations => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/contentMediaType',
          absoluteKeywordLocation => 'https://example.com#/additionalProperties/contentMediaType',
          annotation => 'application/json',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/contentSchema/$ref/blah',
          absoluteKeywordLocation => 'https://foo.com#/$defs/my_def/blah',
          annotation => 1,
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/contentSchema/bloop',
          absoluteKeywordLocation => 'https://foo.com#/bloop',
          annotation => 2,
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/contentSchema/properties',
          absoluteKeywordLocation => 'https://foo.com#/properties',
          annotation => { bar => false },
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/contentSchema',
          absoluteKeywordLocation => 'https://example.com#/additionalProperties/contentSchema',
          annotation => $subschema,
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          absoluteKeywordLocation => 'https://example.com#/additionalProperties',
          annotation => [ 'foo' ],
        },
      ],
    },
    'evaluation of the subschema correctly uses the new $id and $schema',
  );
};

had_no_warnings if $ENV{AUTHOR_TESTING};
done_testing;
