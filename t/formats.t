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

use Test::Fatal;
use JSON::Schema::Modern::Utilities qw(get_type);

use lib 't/lib';
use Helper;

my ($annotation_result, $validation_result);
subtest 'no validation' => sub {
  cmp_result(
    JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 0)
      ->evaluate('abc', { format => 'uuid' })->TO_JSON,
    $annotation_result = {
      valid => true,
      annotations => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          annotation => 'uuid',
        },
      ],
    },
    'validate_formats=0 disables format assertion behaviour; annotation is still produced',
  );

  cmp_result(
    JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 1)
      ->evaluate('abc', { format => 'uuid' }, { validate_formats => 0 })->TO_JSON,
    $annotation_result,
    'format validation can be turned off in evaluate()',
  );
};

subtest 'simple validation' => sub {
  my $js = JSON::Schema::Modern->new(collect_annotations => 1, validate_formats => 1);

  cmp_result(
    $js->evaluate(123, { format => 'uuid' })->TO_JSON,
    $annotation_result,
    'non-string values are valid, and produce an annotation',
  );

  cmp_result(
    $js->evaluate(
      '2eb8aa08-aa98-11ea-b4aa-73b441d16380',
      { format => 'uuid' },
    )->TO_JSON,
    $annotation_result,
    'simple success',
  );

  cmp_result(
    $js->evaluate('123', { format => 'uuid' })->TO_JSON,
    $validation_result = {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          error => 'not a valid uuid',
        },
      ],
    },
    'simple failure',
  );

  $js = JSON::Schema::Modern->new(collect_annotations => 1);
  ok(!$js->validate_formats, 'format_validation defaults to false');
  cmp_result(
    $js->evaluate('123', { format => 'uuid' }, { validate_formats => 1 })->TO_JSON,
    $validation_result,
    'format validation can be turned on in evaluate()',
  );

  ok(!$js->validate_formats, '...but the value is still false on the object');
};

subtest 'override a format sub' => sub {
  like(
    exception {
      JSON::Schema::Modern->new(
        validate_formats => 1,
        format_validations => +{ uuid => 1 },
      )
    },
    qr/Reference .* did not pass type constraint /,
    'check syntax of override to existing format via constructor',
  );

  my $js = JSON::Schema::Modern->new(validate_formats => 1);
  like(
    exception { $js->add_format_validation([] => 1) },
    qr/Value .* did not pass type constraint /,
    'check syntax of override format name to existing format via setter',
  );
  like(
    exception { $js->add_format_validation(uuid => 1) },
    qr/Value .* did not pass type constraint /,
    'check syntax of override definition value to existing format via setter',
  );

  like(
    exception { $js->add_format_validation(uuid => { sub => sub { 0 }}) },
    qr/Reference .* did not pass type constraint /,
    'type is required if passing a hashref',
  );

  like(
    exception { $js->add_format_validation(uuid => { type => 'number', sub => sub { 0 }}) },
    qr/Type for override of format uuid does not match original type/,
    'cannot override a core format to support a different data type',
  );

  $js->add_format_validation(uuid => sub { $_[0] =~ /^[a-z0-9-]+$/ });
  cmp_result(
    $js->evaluate(
      [
        0,
        1,
        [],
        {},
        'a',
        'foobie!',
      ],
      { items => { format => 'uuid' } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/5',
          keywordLocation => '/items/format',
          error => 'not a valid uuid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'can override a core format definition, as long as it uses the same type',
  );

  like(
    exception {
      JSON::Schema::Modern->new(
        validate_formats => 1,
        format_validations => +{ mult_5 => 1 },
      )
    },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation for a new format',
  );

  $js = JSON::Schema::Modern->new(
    collect_annotations => 1,
    validate_formats => 1,
    format_validations => +{
      uuid => sub { $_[0] =~ /^[A-Z]+$/ },
      mult_5 => +{ type => 'number', sub => sub { ($_[0] % 5) == 0 } },
    },
  );

  like(
    exception { $js->add_format_validation(uuid_bad => 1) },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation when adding an override to existing format',
  );

  like(
    exception { $js->add_format_validation(mult_5_bad => 1) },
    qr/Value "1" did not pass type constraint "(Dict\[|Ref").../,
    'check syntax of implementation when adding a new format',
  );

  cmp_result(
    $js->evaluate(
      [
        { uuid => '2eb8aa08-aa98-11ea-b4aa-73b441d16380', mult_5 => 3 },
        { uuid => 3, mult_5 => 'abc' },
      ],
      {
        items => {
          properties => {
            uuid => { format => 'uuid' },
            mult_5 => { format => 'mult_5' },
          },
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0/mult_5',
          keywordLocation => '/items/properties/mult_5/format',
          error => 'not a valid mult_5',
        },
        {
          instanceLocation => '/0/uuid',
          keywordLocation => '/items/properties/uuid/format',
          error => 'not a valid uuid',
        },
        {
          instanceLocation => '/0',
          keywordLocation => '/items/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'swapping out format implementation turns success into failure; wrong types are still valid',
  );

  # do allow overriding mult_5 to support a different type than originally defined.
  $js->add_format_validation(mult_5 => +{ type => 'object', sub => sub { keys($_[0]->%*) > 2 } });

  cmp_result(
    $js->evaluate(
      [
        {},
        { a => 1 },
        { a => 1, b => 2 },
        { a => 1, b => 2, c => 3 },
        [],
        'a',
      ],
      { items => { format => 'mult_5' } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        (map +{
          instanceLocation => '/'.$_,
          keywordLocation => '/items/format',
          error => 'not a valid mult_5',
        }, 0, 1, 2),
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'can override a custom format definition to use a different type',
  );
};

subtest 'toggle validate_formats after adding schema' => sub {
  my $js = JSON::Schema::Modern->new;
  my $document = $js->add_schema(my $uri = 'http://localhost:1234/ipv4', { format => 'ipv4' });

  cmp_result(
    $js->evaluate('hello', $uri)->TO_JSON,
    { valid => true },
    'assertion behaviour is off initially',
  );

  cmp_result(
    $js->evaluate('hello', $uri, { validate_formats => 1 })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'http://localhost:1234/ipv4#/format',
          error => 'not a valid ipv4',
        },
      ],
    },
    'assertion behaviour can be enabled later with an already-loaded schema',
  );

  cmp_result(
    $js->evaluate('127.0.0.1', $uri, { validate_formats => 1 })->TO_JSON,
    { valid => true },
    'valid assertion behaviour does not die',
  );

  my $js2 = JSON::Schema::Modern->new(validate_formats => 1);
  cmp_result(
    $js2->evaluate('hello', $document)->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'http://localhost:1234/ipv4#/format',
          error => 'not a valid ipv4',
        },
      ],
    },
    'a schema document can be used with another evaluator with assertion behaviour',
  );

  cmp_result(
    $js2->evaluate('127.0.0.1', $uri)->TO_JSON,
    { valid => true },
    'valid assertion behaviour does not die',
  );
};

subtest 'custom metaschemas' => sub {
  my $js = JSON::Schema::Modern->new;
  $js->add_schema({
    '$id' => 'https://metaschema/format-assertion/false',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/format-assertion' => false,
    },
  });
  $js->add_schema({
    '$id' => 'https://metaschema/format-assertion/true',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      'https://json-schema.org/draft/2020-12/vocab/format-assertion' => true,
    },
  });

  cmp_result(
    $js->evaluate(
      'not-an-ip',
      {
        '$id' => 'https://schema/ipv4/false',
        '$schema' => 'https://metaschema/format-assertion/false',
        type => 'string',
        format => 'ipv4',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'https://schema/ipv4/false#/format',
          error => 'not a valid ipv4',
        },
      ],
    },
    'custom metaschema using format-assertion=true validates formats',
  );

  cmp_result(
    $js->evaluate(
      'not-an-ip',
      {
        '$id' => 'https://schema/ipv4/true',
        '$schema' => 'https://metaschema/format-assertion/true',
        type => 'string',
        format => 'ipv4',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/format',
          absoluteKeywordLocation => 'https://schema/ipv4/true#/format',
          error => 'not a valid ipv4',
        },
      ],
    },
    'custom metaschema using format-assertion=true validates formats',
  );
};

subtest 'core formats added after draft7' => sub {
  my $js = JSON::Schema::Modern->new(specification_version => 'draft7', validate_formats => 1);

  cmp_result(
    $js->evaluate('123', { format => 'duration' })->TO_JSON,
    { valid => true },
    'duration is not implemented in draft7',
  );

  cmp_result(
    $js->evaluate('123', { format => 'uuid' })->TO_JSON,
    { valid => true },
    'uuid is not implemented in draft7',
  );
};

subtest 'unimplemented core formats' => sub {
  foreach my $spec_version (JSON::Schema::Modern::SPECIFICATION_VERSIONS_SUPPORTED->@*) {
    my $js = JSON::Schema::Modern->new(specification_version => $spec_version, validate_formats => 1);
    cmp_result(
      my $res = $js->evaluate(
        'hello',
        {
          format => 'uri-template',
        },
      )->TO_JSON,
      { valid => true },
      $spec_version . ' with validate_formats = 1, no error when an unimplemented core format is used',
    );
  }

  foreach my $spec_version (JSON::Schema::Modern::SPECIFICATION_VERSIONS_SUPPORTED->@*) {
    next if $spec_version eq 'draft7' or $spec_version eq 'draft2019-09';
    my $js = JSON::Schema::Modern->new(specification_version => $spec_version);
    $js->add_schema({
      '$id' => 'https://my_metaschema',
      '$schema' => JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version},
      '$vocabulary' => {
        JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/core}r => true,
        JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/applicator}r => true,
        JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/format-assertion}r => true,
      },
      '$ref' => JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version},
    });

    cmp_result(
      $js->evaluate(
        'hello',
        {
          '$schema' => 'https://my_metaschema',
          format => 'uri-template',
        },
      )->TO_JSON,
      {
        valid => false,
        errors => [
          {
            instanceLocation => '',
            keywordLocation => '/format',
            error => 'unimplemented format "uri-template"',
          },
        ],
      },
      $spec_version . ' with Format-Assertion vocabulary: error when an unimplemented core format is used',
    );

    cmp_result(
      $js->evaluate(
        'hello',
        {
          '$schema' => 'https://my_metaschema',
          anyOf => [
            { minLength => 1 },
            { format => 'uri-template' },
          ],
        },
      )->TO_JSON,
      {
        valid => false,
        errors => [
          {
            instanceLocation => '',
            keywordLocation => '/anyOf/1/format',
            error => 'unimplemented format "uri-template"',
          },
        ],
      },
      $spec_version . ' with Format-Assertion vocabulary: error is seen even when containing subschema would be true',
    );
  }
};

subtest 'unknown custom formats' => sub {
  # see https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.7.2.3
  # "An implementation MUST NOT fail validation or cease processing due to an unknown format
  # attribute."
  foreach my $spec_version (JSON::Schema::Modern::SPECIFICATION_VERSIONS_SUPPORTED->@*) {
    my $js = JSON::Schema::Modern->new(
      specification_version => $spec_version,
      $spec_version ne 'draft7' ? ( collect_annotations => 1 ) : (),
      validate_formats => 1,
    );

    cmp_result(
      $js->evaluate('hello', { format => 'whargarbl' })->TO_JSON,
      {
        valid => true,
        $spec_version eq 'draft7' ? () : (annotations => [
          {
            instanceLocation => '',
            keywordLocation => '/format',
            annotation => 'whargarbl',
          },
        ]),
      },
      $spec_version . ': for format validation with the Format-Annotation vocabulary, unrecognized format attributes do not cause validation failure'
        . ($spec_version ne 'draft7' ? '; annotation is still produced' : ''),
    );
  }

  foreach my $spec_version (JSON::Schema::Modern::SPECIFICATION_VERSIONS_SUPPORTED->@*) {
    next if $spec_version eq 'draft7' or $spec_version eq 'draft2019-09';

    my $js = JSON::Schema::Modern->new(specification_version => $spec_version);
    $js->add_schema({
      '$id' => 'https://my_metaschema',
      '$schema' => JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version},
      '$vocabulary' => {
        JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/core}r => true,
        JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/format-assertion}r => true,
      },
      '$ref' => JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version},
    });

    cmp_result(
      JSON::Schema::Modern::Document->new(
        evaluator => $js,
        schema => { '$schema' => 'https://my_metaschema', format => 'bloop' },
      ),
      listmethods(
        errors => [
          methods(TO_JSON => {
            instanceLocation => '',
            keywordLocation => '/format',
            error => 'unimplemented custom format "bloop"',
          }),
        ],
      ),
      $spec_version . ': for format validation with the Format-Assertion vocabulary, unrecognized format attributes are detected at traverse time',
    );
  }
};

subtest 'format: pure_integer' => sub {
  my $js = JSON::Schema::Modern->new(
    validate_formats => 1,
    format_validations => +{
      pure_integer => +{ type => 'number', sub => sub ($value) {
        B::svref_2object(\$value)->FLAGS & B::SVf_IOK
      } },
    },
  );

  my $decoder = JSON::Schema::Modern::_JSON_BACKEND()->new->allow_nonref(1)->utf8(0);
  my $int = 5;
  cmp_result(
    $js->evaluate(
      [
        (map $decoder->decode($_),
          '"hello"',
          '3.1',
          '3.0',
          '3',
        ),
        bless(\$int, 'Local::MyInteger'),
      ],
      {
        items => {
          type => 'integer',
          format => 'pure_integer',
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '/1',
          keywordLocation => '/items/type',
          error => 'got number, not integer',
        },
        {
          instanceLocation => '/1',
          keywordLocation => '/items/format',
          error => 'not a valid pure_integer',
        },
        {
          instanceLocation => '/2',
          keywordLocation => '/items/format',
          error => 'not a valid pure_integer',
        },
        {
          instanceLocation => '/4',
          keywordLocation => '/items/type',
          error => 'got Local::MyInteger, not integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'pure_integer format with type',
  );

  cmp_result(
    $js->evaluate(
      [
        (map $decoder->decode($_),
          '"hello"',  # string, will not apply format
          '3.1',      # number, will apply format
          '3.0',      # ""
          '3',        # ""
        ),
        bless(\$int, 'Local::MyInteger'), # blessed type, will not apply format
      ],
      {
        items => {
          format => 'pure_integer',
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        # strings are not applied to the format
        {
          instanceLocation => '/1',
          keywordLocation => '/items/format',
          error => 'not a valid pure_integer',
        },
        {
          instanceLocation => '/2',
          keywordLocation => '/items/format',
          error => 'not a valid pure_integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'pure_integer format without type',
  );
};

subtest 'formats supporting multiple core types' => sub {
  # this is int64 from the OAI format registry: https://spec.openapis.org/registry/format/
  my $js = JSON::Schema::Modern->new(
    validate_formats => 1,
    format_validations => +{
      # a signed 64-bit integer; see https://spec.openapis.org/api/format.json
      int64 => +{ type => ['number', 'string'], sub => sub ($value) {
        my $type = get_type($value);
        return if not grep $type eq $_, qw(integer number string);
        $value = Math::BigInt->new($value) if $type eq 'string';
        return if $value eq 'NaN';
        # using the literal numbers rather than -2**63, 2**63 -1 to maintain precision
        $value >= Math::BigInt->new('-9223372036854775808') && $value <= Math::BigInt->new('9223372036854775807');
      } },
    },
  );

  my @values = (
    '{}',     # object is valid
    '[]',     # array is valid
    'true',   # boolean is valid
    'null',   # null is valid

    # string
    '"-9223372036854775809"', # 4: out of bounds
    '"-9223372036854775808"', # minimum value
    '"-9223372036854775807"', # within bounds
    '"0"',
    '"9223372036854775806"',  # within bounds
    '"9223372036854775807"',  # maximum value
    '"9223372036854775808"',  # out of bounds
    '"Inf"',
    '"NaN"',

    # number
    '-9223372036854775809',   # 13: out of bounds
    '-9223372036854775808',   # minimum value; difficult to use on most architectures without Math::BigInt
    '-9223372036854775807',   # within bounds
    '0',
    '9223372036854775806',    # within bounds
    '9223372036854775807',    # maximum value
    '9223372036854775808',    # 19: out of bounds
    # numeric Inf and NaN are not valid JSON
  );

  # note: results may vary on 32-bit architectures when not using Math::BigFloat
  foreach my $decoder (
      JSON::Schema::Modern::_JSON_BACKEND()->new->allow_nonref(1)->utf8(0),
      JSON::Schema::Modern::_JSON_BACKEND()->new->allow_nonref(1)->utf8(0)->allow_bignum(1)) {
    cmp_result(
      my $result = $js->evaluate(
        [ map $decoder->decode($_), @values ],
        {
          items => {
            format => 'int64',
          },
        },
      )->TO_JSON,
      {
        valid => false,
        errors => [
          (map +{
            instanceLocation => "/$_",
            keywordLocation => '/items/format',
            error => 'not a valid int64',
          },
          4, 10, 11, 12, 13, 19),
          {
            instanceLocation => '',
            keywordLocation => '/items',
            error => 'subschema is not valid against all items',
          },
        ],
      },
      'int64 format without type - accepts both numbers and strings',
    );
  }
};

subtest 'stringy numbers with a numeric format' => sub {
  my $js = JSON::Schema::Modern->new(
    validate_formats => 1,
    stringy_numbers => 1,
    format_validations => +{
      mult_5 => +{ type => 'number', sub => sub { ($_[0] % 5) == 0 } },
    },
  );

  cmp_result(
    my $res = $js->evaluate(
      [
        3,
        '3',
        5,
        '5',
        'abc',
      ],
      { items => { format => 'mult_5' } },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/format',
          error => 'not a valid mult_5',
        },
        {
          instanceLocation => '/1',
          keywordLocation => '/items/format',
          error => 'not a valid mult_5',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'FormatAnnotation+validate_formats: strings that look like numbers can be validated against a numeric format when stringy_numbers=1',
  );

  $js = JSON::Schema::Modern->new(
    stringy_numbers => 1,
    format_validations => +{
      mult_5 => +{ type => 'number', sub => sub { ($_[0] % 5) == 0 } },
    },
  );
  my $spec_version = $js->SPECIFICATION_VERSION_DEFAULT;
  $js->add_schema({
    '$id' => 'https://my_metaschema',
    '$schema' => JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version},
    '$vocabulary' => {
      JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/core}r => true,
      JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/applicator}r => true,
      JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version} =~ s{schema$}{vocab/format-assertion}r => true,
    },
    '$ref' => JSON::Schema::Modern::METASCHEMA_URIS->{$spec_version},
  });

  cmp_result(
    $js->evaluate(
      [
        3,
        '3',
        5,
        '5',
        'abc',
      ],
      {
        '$schema' => 'https://my_metaschema',
        items => { format => 'mult_5' },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/0',
          keywordLocation => '/items/format',
          error => 'not a valid mult_5',
        },
        {
          instanceLocation => '/1',
          keywordLocation => '/items/format',
          error => 'not a valid mult_5',
        },
        {
          instanceLocation => '',
          keywordLocation => '/items',
          error => 'subschema is not valid against all items',
        },
      ],
    },
    'FormatAssertion: strings that look like numbers can be validated against a numeric format when stringy_numbers=1',
  );
};

done_testing;
