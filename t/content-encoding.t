use strict;
use warnings;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Fatal;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

subtest 'unrecognized encoding formats do not result in errors' => sub {
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

  cmp_deeply($js->get_media_type('text/plain')->(\'foo'), \'foo', 'text/plain media_type decoder');

  cmp_deeply($js->get_media_type('tExt/PLaIN')->(\'foo'), \'foo', 'getter uses the casefolded name');

  $js->add_media_type('furble/*' => sub { \1 });
  cmp_deeply($js->get_media_type('furble/bloop')->(\''), \'1', 'getter matches to wildcard entries');

  $js->add_media_type('text/*' => sub { \'wildcard' });
  cmp_deeply($js->get_media_type('TExT/plain')->(\'foo'), \'foo', 'getter prefers case-insensitive matches to wildcard entries');
  cmp_deeply($js->get_media_type('TExT/blop')->(\'foo'), \'wildcard', 'getter matches to wildcard entries');
  cmp_deeply($js->get_media_type('TExT/*')->(\'foo'), \'wildcard', 'text/* matches itself');

  $js->add_media_type('*/*' => sub { \'wildercard' });
  cmp_deeply($js->get_media_type('TExT/plain')->(\'foo'), \'foo', 'getter still prefers case-insensitive matches to wildcard entries');
  cmp_deeply($js->get_media_type('TExT/blop')->(\'foo'), \'wildcard', 'text/* is preferred to */*');
  cmp_deeply($js->get_media_type('*/*')->(\'foo'), \'wildercard', '*/* matches */*');
  cmp_deeply($js->get_media_type('fOO/bar')->(\'foo'), \'wildercard', '*/* is returned as a last resort');

  $js = JSON::Schema::Modern->new;

  cmp_deeply(
    $js->get_media_type('application/json')->($js->get_encoding('base64')->(\'eyJmb28iOiAiYmFyIn0K')),
    \ { foo => 'bar' },
    'base64 encoding decoder + application/json media_type decoder',
  );

  # evaluate some schemas under draft7 and see that they validate
  cmp_deeply(
    $js->evaluate(
      my $data = { encoded_object => 'eyJmb28iOiAiYmFyIn0K' },
      my $schema = {
        properties => {
          encoded_object => {
            contentEncoding => 'base64',
            contentMediaType => 'application/json',
            contentSchema => {
              type => 'object',
              additionalProperties => {
                type => 'number',
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
    $js->evaluate(
      $data,
      $schema,
      {
        specification_version => 'draft7',
        validate_content_schemas => 1,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object/foo',
          keywordLocation => '/properties/encoded_object/contentSchema/additionalProperties/type',
          error => 'got string, not number',
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
    'under draft7, these keywords are assertions',
  );

  cmp_deeply(
    $js->evaluate(
      'a string',
      {
        contentEncoding => 'whargarbl',
        contentMediaType => 'whargarbl',
        contentSchema => false,
      },
      {
        specification_version => 'draft7',
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
        specification_version => 'draft7',
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

  cmp_deeply(
    $js->evaluate(
      { encoded_object => 'eyJmb28iOi%iYmFyIn0K' }, # character outside of the base64 range
      $schema,
      {
        specification_version => 'draft7',
        validate_content_schemas => 1,
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/encoded_object',
          keywordLocation => '/properties/encoded_object/contentEncoding',
          error => re(qr/^invalid characters in base64 string/),
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'under draft7, these keywords are assertions',
  );

  cmp_deeply(
    $js->evaluate(
      # this is a ISO-8601 string that is json-encoded and then base64-encoded
      { encoded_object => MIME::Base64::encode('{"'.chr(0xe9).'clair": 42}', '') },
      $schema,
      {
        specification_version => 'draft7',
        validate_content_schemas => 1,
      },
    )->TO_JSON,
    { valid => true },
    'successfully able to decode a non-UTF-8-encoded string',
  );
};

done_testing;
