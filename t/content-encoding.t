use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8
use utf8;

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Fatal;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

subtest 'unrecognized encoding formats do not result in errors, when not asserting' => sub {
  my $js = JSON::Schema::Modern->new(collect_annotations => 1);

  cmp_deeply(
    my $result = $js->evaluate(
      'hello',
      {
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

subtest 'media_type and encoding handlers' => sub {
  my $js = JSON::Schema::Modern->new;

  like(
    exception { $js->add_media_type('FOO/BAR' => sub { \1 }) },
    qr!Value "FOO/BAR" did not pass type constraint !,
    'upper-cased names are not accepted',
  );

  cmp_deeply(
    $js->get_media_type('application/json')->(\'{"alpha": "a string"}'),
    \ { alpha => 'a string' },
    'application/json media_type decoder',
  );

  cmp_deeply($js->get_media_type('text/plain')->(\'foo'), \'foo', 'default text/plain media_type decoder');

  cmp_deeply($js->get_media_type('tExt/PLaIN')->(\'foo'), \'foo', 'getter uses the casefolded name');

  $js->add_media_type('furble/*' => sub { \1 });
  cmp_deeply($js->get_media_type('furble/bloop')->(\''), \'1', 'getter matches to wildcard entries');

  $js->add_media_type('text/*' => sub { \'wildcard' });
  cmp_deeply($js->get_media_type('TExT/plain')->(\'foo'), \'wildcard', 'getter uses new override entry for wildcard');

  $js->add_media_type('text/plain' => sub { \'plain' });
  cmp_deeply($js->get_media_type('TExT/plain')->(\'foo'), \'plain', 'getter prefers case-insensitive matches to wildcard entries');
  cmp_deeply($js->get_media_type('TExT/blop')->(\'foo'), \'wildcard', 'getter matches to wildcard entries');
  cmp_deeply($js->get_media_type('TExT/*')->(\'foo'), \'wildcard', 'text/* matches itself');

  $js->add_media_type('*/*' => sub { \'wildercard' });
  cmp_deeply($js->get_media_type('TExT/plain')->(\'foo'), \'plain', 'getter still prefers case-insensitive matches to wildcard entries');
  cmp_deeply($js->get_media_type('TExT/blop')->(\'foo'), \'wildcard', 'text/* is preferred to */*');
  cmp_deeply($js->get_media_type('*/*')->(\'foo'), \'wildercard', '*/* matches */*');
  cmp_deeply($js->get_media_type('fOO/bar')->(\'foo'), \'wildercard', '*/* is returned as a last resort');

  cmp_deeply(
    $js->get_media_type('application/x-ndjson')->(\qq!{"foo":1,"bar":2}\n["a","b",3]\r\n"\x{e0}\x{b2}\x{a0}\x{5f}\x{e0}\x{b2}\x{a0}"!),
    \ [ { foo => 1, bar => 2 }, [ 'a', 'b', 3 ], 'ಠ_ಠ' ],
    'application/x-ndjson happy path with unicode',
  );

  like(
    exception { $js->get_media_type('application/x-ndjson')->(\qq!{"foo":1,"bar":2}\n["a","b",]!) },
    qr/^parse error at line 2: malformed JSON string/,
    'application/x-ndjson dies with line number of the bad data',
  );


  $js = JSON::Schema::Modern->new;

  # MIME::Base64::decode("eyJmb28iOiAiYmFyIn0K") -> {"foo": "bar"}
  # JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0)->decode(q!{"foo": "bar"}!) -> { foo => 'bar' }

  cmp_deeply(
    $js->get_media_type('application/json')->($js->get_encoding('base64')->(\'eyJmb28iOiAiYmFyIn0K')),
    \ { foo => 'bar' },
    'base64 encoding decoder + application/json media_type decoder',
  );

  cmp_deeply(
    $js->get_media_type('application/json')->($js->get_encoding('base64url')->(\'eyJmb28iOiJiYXIifQ')),
    \ { foo => 'bar' },
    'base64url encoding decoder + application/json media_type decoder',
  );
};

subtest 'draft2020-12 assertions' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_deeply(
    $js->evaluate(
      my $data = { encoded_object => 'eyJmb28iOiAiYmFyIn0K' },
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
    { valid => true },
    'under the current spec version, content* keywords are not assertions',
  );

  cmp_deeply(
    my $result = $js->evaluate(
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

  cmp_deeply(
    $result = $js->evaluate(
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

  cmp_deeply(
    $result = $js->evaluate(
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
          error => 'value does not match',
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

  cmp_deeply(
    $result = $js->evaluate(
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

  cmp_deeply(
    $result = $js->evaluate(
      { encoded_object => 'eyJoaSI6IuCyoF/gsqAifQ==' }, # base64-encoded, json-encoded { hi => "ಠ_ಠ" }
      $schema,
      { validate_content_schemas => 1 },
    )->TO_JSON,
    { valid => true },
    'contentSchema successfully evaluates the decoded data',
  );
};

subtest 'draft7 assertions' => sub {
  my $js = JSON::Schema::Modern->new(specification_version => 'draft7');

  cmp_deeply(
    my $result = $js->evaluate(
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

  cmp_deeply(
    $result = $js->evaluate(
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

  cmp_deeply(
    $result = $js->evaluate(
      { encoded_object => 'eyJoaSI6MX0=' }, # base64-encoded, json-encoded { hi => 1 }
      $schema,
    )->TO_JSON,
    { valid => true },
    'under draft7, content* are assertions by default, but contentSchema does not exist',
  );
};

subtest 'more assertions' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_deeply(
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

  cmp_deeply(
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

done_testing;
