# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use JSON::Schema::Modern::Utilities 'canonical_uri';
use lib 't/lib';
use Helper;

subtest 'traversal with callbacks' => sub {
  my $schema = {
    '$id' => 'https://foo.com',
    '$defs' => {
      foo => {
        '$id' => 'recursive_subschema',
        type => [ 'integer', 'object' ],
        additionalProperties => { '$ref' => 'recursive_subschema' },
      },
      bar => {
        properties => {
          description => {
            '$ref' => '#/$defs/foo',
            const => { '$ref' => 'this is not a real ref' },
          },
        },
      },
    },
    if => 1,  # bad subschema
    allOf => [
      {},
      { '$ref' => '#/$defs/foo' },
      { '$ref' => '#/$defs/bar' },
    ],
  };

  my %refs;
  my $if_callback_called;
  my $js = JSON::Schema::Modern->new;
  my $state = $js->traverse($schema, { callbacks => {
      '$ref' => sub ($schema, $state) {
        my $canonical_uri = canonical_uri($state);
        my $ref_uri = Mojo::URL->new($schema->{'$ref'});
        $ref_uri = $ref_uri->to_abs($canonical_uri) if not $ref_uri->is_abs;
        $refs{$state->{traversed_schema_path}.$state->{schema_path}} = $ref_uri->to_string;
      },
      if => sub { $if_callback_called = 1; },
    }});

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/if',
        absoluteKeywordLocation => 'https://foo.com#/if',
        error => 'invalid schema type: integer',
      },
    ],
    'errors encountered during traversal are returned',
  );

  ok(!$if_callback_called, 'callback for erroneous keyword was not called');

  cmp_result(
    \%refs,
    {
      '/$defs/foo/additionalProperties' => 'https://foo.com/recursive_subschema',
      '/$defs/bar/properties/description' => 'https://foo.com#/$defs/foo',
      # no entry for 'if' -- callbacks are not called for keywords with errors
      '/allOf/1' => 'https://foo.com#/$defs/foo',
      '/allOf/2' => 'https://foo.com#/$defs/bar',
    },
    'extracted all the real $refs out of the schema, with locations and canonical targets',
  );

  cmp_result(
    $state->{subschemas},
    bag(
      '',
      '/$defs/bar',
      '/$defs/bar/properties/description',
      '/$defs/foo',
      '/$defs/foo/additionalProperties',
      '/allOf/0',
      '/allOf/1',
      '/allOf/2',
      '/if',
    ),
    'identified all subschemas',
  );
};

subtest 'errors when parsing $schema keyword' => sub {
  my $js = JSON::Schema::Modern->new;

  my $state = $js->traverse({ '$schema' => true });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/$schema',
        error => '$schema value is not a string',
      },
    ],
    '$schema is not a string',
  );

  $state = $js->traverse({ '$schema' => 'whargarbl' });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/$schema',
        error => '"whargarbl" is not a valid URI',
      },
    ],
    '$schema is not a URI',
  );
};

subtest 'default metaschema' => sub {
  my $js = JSON::Schema::Modern->new;
  my $state = $js->traverse(
    {
      '$defs' => {
        foo => {
          properties => 'not an object',
        },
      },
    },
  );

  cmp_result(
    $state,
    superhashof({
      spec_version => 'draft2020-12',
      vocabularies => [
        map 'JSON::Schema::Modern::Vocabulary::'.$_,
          qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated),
      ],
    }),
    'dialect is properly determined',
  );

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/$defs/foo/properties',
        error => 'properties value is not an object',
      },
    ],
    'error within $defs is found, showing both Core and Applicator vocabularies are used',
  );
};

subtest 'traversing a dialect with different core keywords' => sub {
  my $js = JSON::Schema::Modern->new;

  my $state = $js->traverse(
    {
      '$id' => 'http://localhost:1234/root',
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      definitions => {
        alpha => 1,
      },
    },
  );
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/definitions/alpha',
        absoluteKeywordLocation => 'http://localhost:1234/root#/definitions/alpha',
        error => 'invalid schema type: integer',
      },
    ],
    'dialect changes at root, with $id - dialect is switched in time to get a new keyword list for the core vocabulary',
  );

  $state = $js->traverse(
    {
      '$id' => '#hello',
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      definitions => {
        bloop => {
          '$id' => '/bloop',
          type => 'object',
        },
      },
    },
  );

  cmp_result($state->{errors}, [], 'no errors when parsing this schema');
  cmp_result(
    $state->{identifiers},
    {
      '#hello' => {
        path => '',
        canonical_uri => str(''),
        specification_version => 'draft7',
        configs => {},
        vocabularies => [
          map 'JSON::Schema::Modern::Vocabulary::'.$_,
            qw(Core Validation FormatAnnotation Applicator Content MetaData),
        ],
      },
      '/bloop' => {
        path => '/definitions/bloop',
        canonical_uri => str('/bloop'),
        specification_version => 'draft7',
        configs => {},
        vocabularies => [
          map 'JSON::Schema::Modern::Vocabulary::'.$_,
            qw(Core Validation FormatAnnotation Applicator Content MetaData),
        ],
      },
    },
    'switched dialect in time to extract all identifiers, from root and definition',
  );

  $state = $js->traverse(
    {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      definitions => {
        alpha => 1,
      },
    },
  );
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/definitions/alpha',
        error => 'invalid schema type: integer',
      },
    ],
    'dialect changes at root, no $id - dialect is switched in time to get a new keyword list for the core vocabulary',
  );

  $state = $js->traverse(
    {
      '$defs' => {
        alpha => {
          '$id' => 'http://localhost:1234/inner',
          '$schema' => 'http://json-schema.org/draft-07/schema#',
          definitions => {
            alpha => 1,
          },
        },
      },
    },
  );
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/$defs/alpha/definitions/alpha',
        absoluteKeywordLocation => 'http://localhost:1234/inner#/definitions/alpha',
        error => 'invalid schema type: integer',
      },
    ],
    'dialect changes below root - dialect is switched in time to get a new keyword list for the core vocabulary',
  );
};

subtest '$schema without an $id, below the root' => sub {
  my $js = JSON::Schema::Modern->new;

  my $state = $js->traverse(
    {
      '$defs' => {
        alpha => {
          '$schema' => 'https://json-schema.org/draft/2019-09/schema',
          minimum => 2,
        },
      },
    },
  );
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/$defs/alpha/$schema',
        error => '$schema can only appear at the schema resource root',
      },
    ],
    '$schema cannot exist without an $id, or at the root',
  );
};

subtest 'duplicate identifiers' => sub {
  my $js = JSON::Schema::Modern->new;
  my $state = $js->traverse({
    '$id' => 'https://base.com',
    allOf => [
      { '$id' => 'https://foo.com' },
      { '$id' => 'https://foo.com' },
    ],
  });

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/allOf/1/$id',
        absoluteKeywordLocation => 'https://base.com#/allOf/1/$id',
        error => 'duplicate canonical uri "https://foo.com" found (original at path "/allOf/0")',
      },
    ],
    'detected colliding $ids within a single schema',
  );

  $state = $js->traverse({
    '$id' => 'https://base.com',
    allOf => [
      { '$id' => 'dir1', '$anchor' => 'foo' },
      { '$id' => 'dir2', '$anchor' => 'foo' },
    ],
  });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [],
    'two anchors with different base uris are acceptable',
  );

  $state = $js->traverse({
    '$id' => 'https://base.com',
    allOf => [
      { '$anchor' => 'foo' },
      { '$anchor' => 'foo' },
    ],
  });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/allOf/1/$anchor',
        absoluteKeywordLocation => 'https://base.com#/allOf/1/$anchor',
        error => 'duplicate anchor uri "https://base.com#foo" found (original at path "/allOf/0")',
      },
    ],
    'detected colliding $anchors within a single schema',
  );
};

subtest 'traverse with overridden metaschema_uri' => sub {
  my $js = JSON::Schema::Modern->new;
  $js->add_schema({
    '$id' => 'https://metaschema/with/wrong/spec',
    '$vocabulary' => {
      'https://unknown' => true,
      'https://unknown2' => false,
    },
  });
  my $state = $js->traverse(true, { metaschema_uri => 'https://metaschema/with/wrong/spec' });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    my $errors = [
      {
        instanceLocation => '',
        keywordLocation => '/$vocabulary/https:~1~1unknown',
        absoluteKeywordLocation => 'https://metaschema/with/wrong/spec#/$vocabulary/https:~1~1unknown',
        error => '"https://unknown" is not a known vocabulary',
      },
      {
        instanceLocation => '',
        keywordLocation => '/$vocabulary',
        absoluteKeywordLocation => 'https://metaschema/with/wrong/spec#/$vocabulary',
        error => 'the first vocabulary (by evaluation_order) must be Core',
      },
      {
        instanceLocation => '',
        keywordLocation => '',
        error => '"https://metaschema/with/wrong/spec" is not a valid metaschema',
      },
    ],
    'metaschema_uri is overridden with a bad schema: same errors are returned',
  );

  $state = $js->traverse(
    { '$id' => 'https://my-poor-schema/foo.json' },
    { metaschema_uri => 'https://metaschema/with/wrong/spec' });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      $errors->@[0..1],
      {
        $errors->[2]->%*,
        absoluteKeywordLocation => 'https://my-poor-schema/foo.json',
      },
    ],
    'metaschema_uri is overridden with a bad schema: errors contain the right locations',
  );


  $state = $js->traverse(
    true,
    {
      metaschema_uri => 'https://metaschema/with/wrong/spec',
      initial_schema_uri => 'https://my-poor-schema/foo.json#/$my_dialect_is',
      traversed_schema_path => '/$my_dialect_is',
    });
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        $errors->[0]->%*,
        keywordLocation => '/$my_dialect_is'.$errors->[0]{keywordLocation},
      },
      {
        $errors->[1]->%*,
        keywordLocation => '/$my_dialect_is'.$errors->[1]{keywordLocation},
      },
      {
        $errors->[2]->%*,
        keywordLocation => '/$my_dialect_is'.$errors->[2]{keywordLocation},
        absoluteKeywordLocation => 'https://my-poor-schema/foo.json#/$my_dialect_is',
      },
    ],
    'metaschema_uri is overridden with a bad schema and there is a traversal path: errors contain the right locations',
  );


  $js->add_schema({
    '$id' => 'https://my/first/metaschema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      # note: no validation!
    },
  });

  $state = $js->traverse(
    {
      '$id' => my $id = 'https://my/first/schema/with/custom/metaschema',
      # note: no $schema keyword!
      allOf => [ { minimum => 'not even an integer' } ],
    },
    { metaschema_uri => 'https://my/first/metaschema' },
  );

  cmp_result(
    $state->{identifiers},
    {
      $id => {
        canonical_uri => str($id),
        path => '',
        specification_version => 'draft2020-12',
        vocabularies => [
          map 'JSON::Schema::Modern::Vocabulary::'.$_,
            qw(Core Applicator),
        ],
        configs => {},
      }
    },
    'determined vocabularies to use for this schema',
  );
};

subtest 'start traversing below the document root' => sub {
  my $js = JSON::Schema::Modern->new;

  # Remember: by this point the $document object exists, but we have no idea where in the document we are.
  # It might not even be a JSON Schema.
  # Let's say the document actually looks like:
  # {
  #   $id => 'my_document.yaml',
  #   components => {
  #     alpha => {
  #       $id => 'my_subdocument.yaml',
  #       subid => {
  #         *** SUBSCHEMA BELOW ***
  #       },
  #     },
  #   },
  # }
  my $state = $js->traverse(
    {
      properties => {
        myprop => {
          allOf => [
            {
              '$id' => 'inner_document',
              properties => {
                foo => 'not a valid schema',
              },
            },
          ],
        },
      },
      type => 'not a valid type',
    },
    {
      initial_schema_uri => 'dir/my_subdocument#/subid',
      traversed_schema_path => '/components/alpha/subid',
    },
  );
  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/components/alpha/subid/type',
        absoluteKeywordLocation => 'dir/my_subdocument#/subid/type',
        error => 'unrecognized type "not a valid type"',
      },
      {
        instanceLocation => '',
        keywordLocation => '/components/alpha/subid/properties/myprop/allOf/0/properties/foo',
        absoluteKeywordLocation => 'dir/inner_document#/properties/foo',
        error => 'invalid schema type: string',
      },
    ],
    'identified the overridden location of all errors during traverse',
  );


  cmp_result(
    $js->traverse(
      {
        properties => {
          alpha => {
            '$id' => 'alpha_id',
            properties => {
              alpha_one => {
                '$id' => 'alpha_one_id',
              },
              alpha_two => {
                '$anchor' => 'alpha_two_anchor',
              },
            },
          },
          beta => {
            '$anchor' => 'beta_anchor',
          },
        },
      },
      {
        initial_schema_uri => 'dir/my_subdocument#/subid',
        traversed_schema_path => '/components/alpha/subid',
      },
    )->{identifiers},
    {
      'dir/alpha_id' => {
        canonical_uri => str('dir/alpha_id'),
        path => '/components/alpha/subid/properties/alpha',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
      },
      'dir/alpha_one_id' => {
        canonical_uri => str('dir/alpha_one_id'),
        path => '/components/alpha/subid/properties/alpha/properties/alpha_one',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
      },
      'dir/alpha_id#alpha_two_anchor'=> {
        canonical_uri => str('dir/alpha_id#/properties/alpha_two'),
        path => '/components/alpha/subid/properties/alpha/properties/alpha_two',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
      },
      'dir/my_subdocument#beta_anchor'=> {
        canonical_uri => str('dir/my_subdocument#/subid/properties/beta'),
        path => '/components/alpha/subid/properties/beta',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
      },
    },
    'identifiers are correctly extracted when traversing below the document root',
  );
};

done_testing;
