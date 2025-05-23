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
      metaschema_uri => str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}),
      initial_schema_uri => str(''),
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

  cmp_deeply(
    $state,
    superhashof({
      metaschema_uri => 'http://json-schema.org/draft-07/schema',
      spec_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'other $state information is correct',
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
    $state,
    superhashof({
      identifiers => {
        '' => {
          path => '',
          canonical_uri => str(''),
          specification_version => 'draft7',
          configs => {},
          vocabularies => [
            map 'JSON::Schema::Modern::Vocabulary::'.$_,
              qw(Core Validation FormatAnnotation Applicator Content MetaData),
          ],
          anchors => {
            hello => {
              path => '',
              canonical_uri => str(''),
            },
          },
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
      metaschema_uri => 'http://json-schema.org/draft-07/schema',
      spec_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
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

subtest '$anchor without $id' => sub {
  my $js = JSON::Schema::Modern->new;

  my $state = $js->traverse({
    '$anchor' => 'root_anchor',
  });
  cmp_result(
    $state->{identifiers},
    {
      '' => {
        path => '',
        canonical_uri => str(''),
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
        anchors => {
          root_anchor => {
            path => '',
            canonical_uri => str(''),
          },
        },
      },
    },
    'found anchor at root, without an $id to pre-populate the identifiers hash',
  );

  $state = $js->traverse({
    properties => {
      foo => {
        '$anchor' => 'foo_anchor',
      },
    },
  });
  cmp_result(
    $state->{identifiers},
    {
      '' => {
        path => '',
        canonical_uri => str(''),
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
        anchors => {
          foo_anchor => {
            path => '/properties/foo',
            canonical_uri => str('#/properties/foo'),
          },
        },
      },
    },
    'found anchor within schema, without an $id to pre-populate the identifiers hash',
  );
};

subtest 'traverse with overridden specification_version' => sub {
  my $js = JSON::Schema::Modern->new(specification_version => 'draft7');

  my $state = $js->traverse({});
  cmp_deeply(
    $state,
    superhashof({
      errors => [],
      metaschema_uri => 'http://json-schema.org/draft-07/schema',
      spec_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    '$state is correct with no $schema keyword, no overrides'
  );

  $state = $js->traverse({ '$schema' => 'https://json-schema.org/draft/2020-12/schema'});
  cmp_deeply(
    $state,
    superhashof({
      errors => [],
      metaschema_uri => 'https://json-schema.org/draft/2020-12/schema',
      spec_version => 'draft2020-12',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated) ],
    }),
    '$state is correct with a $schema keyword, no overrides'
  );

  $state = $js->traverse({}, { specification_version => 'draft2019-09' });
  cmp_deeply(
    $state,
    superhashof({
      errors => [],
      metaschema_uri => 'https://json-schema.org/draft/2019-09/schema',
      spec_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    '$state is correct with no $schema keyword, and an overridden specification_version'
  );

  $state = $js->traverse(
    { '$schema' => 'http://json-schema.org/draft-04/schema#' },
    { specification_version => 'draft2020-12' });
  cmp_deeply(
    $state,
    superhashof({
      errors => [],
      metaschema_uri => 'http://json-schema.org/draft-04/schema',
      spec_version => 'draft4',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator MetaData) ],
    }),
    '$state is correct with a $schema keyword, and an overridden specification_version'
  );
};

subtest 'traverse with overridden metaschema_uri' => sub {
  my $js = JSON::Schema::Modern->new;

  my $state = $js->traverse({}, { metaschema_uri => 'https://unknown/metaschema' });

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    my $errors = [
      {
        instanceLocation => '',
        keywordLocation => '',
        error => 'EXCEPTION: unable to find resource "https://unknown/metaschema"',
      },
    ],
    'metaschema_uri is not a known uri',
  );


  $js->add_schema({
    '$id' => 'https://metaschema/with/wrong/spec',
    '$vocabulary' => {
      'https://unknown' => true,
      'https://unknown2' => false,
    },
  });


  $state = $js->traverse(true, { metaschema_uri => 'https://metaschema/with/wrong/spec' });

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    $errors = [
      {
        instanceLocation => '',
        keywordLocation => jsonp(qw(/$vocabulary https://unknown)),
        absoluteKeywordLocation => 'https://metaschema/with/wrong/spec#'.jsonp(qw(/$vocabulary https://unknown)),
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
    'boolean schema: metaschema_uri is overridden with a bad schema: same errors are returned',
  );


  $state = $js->traverse(
    { '$id' => 'https://my/bad/schema' },
    { metaschema_uri => 'https://metaschema/with/wrong/spec' });

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    $errors,
    'object schema: metaschema_uri is overridden with a bad schema: same errors are returned',
  );


  # simulation of parsing a schema with a custom keyword that sets the metaschema uri
  # (see OpenAPI's jsonSchemaDialect keyword)
  $state = $js->traverse(
    true,
    {
      metaschema_uri => 'https://metaschema/with/wrong/spec',
      initial_schema_uri => 'https://my-poor-schema/foo.json#/$my_dialect_is',
      traversed_schema_path => '/$ref/$ref/some_keyword/$ref/$my_dialect_is',
    });

  cmp_result(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        $errors->[0]->%*,
        keywordLocation => '/$ref/$ref/some_keyword/$ref/$my_dialect_is'.$errors->[0]{keywordLocation},
      },
      {
        $errors->[1]->%*,
        keywordLocation => '/$ref/$ref/some_keyword/$ref/$my_dialect_is'.$errors->[1]{keywordLocation},
      },
      {
        $errors->[2]->%*,
        keywordLocation => '/$ref/$ref/some_keyword/$ref/$my_dialect_is'.$errors->[2]{keywordLocation},
        absoluteKeywordLocation => 'https://my-poor-schema/foo.json#/$my_dialect_is',
      },
    ],
    'metaschema_uri is overridden with a bad schema and there is a traversal path: errors contain the right locations',
  );


  $js->add_schema({
    '$id' => 'https://my/first/metaschema',
    '$schema' => 'https://json-schema.org/draft/2019-09/schema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2019-09/vocab/applicator' => true,
      'https://json-schema.org/draft/2019-09/vocab/core' => true,
      # note: no validation!
    },
  });

  $state = $js->traverse(
    {
      '$id' => my $id = 'https://my/first/schema/with/custom/metaschema',
      # note: no $schema keyword!
    },
    { metaschema_uri => 'https://my/first/metaschema' },
  );

  cmp_result(
    $state,
    superhashof({
      identifiers => {
        $id => {
          canonical_uri => str($id),
          path => '',
          specification_version => 'draft2019-09',
          vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_, qw(Core Applicator) ],
          configs => {},
        },
      },
      metaschema_uri => 'https://my/first/metaschema',
      spec_version => 'draft2019-09',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_, qw(Core Applicator) ],
    }),
    'determined specification version and vocabularies to use for this schema from override',
  );


  $state = $js->traverse(
    {
      '$id' => $id = 'https://my/second/schema/with/custom/metaschema',
      '$schema' => 'http://json-schema.org/draft-07/schema',
    },
    { metaschema_uri => 'https://my/first/metaschema' },
  );

  cmp_result(
    my $state_copy = $state,
    superhashof({
      identifiers => {
        $id => {
          canonical_uri => str($id),
          path => '',
          specification_version => 'draft7',
          vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
            qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
          configs => {},
        },
      },
      metaschema_uri => 'http://json-schema.org/draft-07/schema',
      spec_version => 'draft7',
      vocabularies => [ map 'JSON::Schema::Modern::Vocabulary::'.$_,
        qw(Core Validation FormatAnnotation Applicator Content MetaData) ],
    }),
    'determined specification version and vocabularies to use for this schema from $schema keyword',
  );


  $state = $js->traverse(
    {
      '$id' => my $third_id = 'https://my/third/schema/with/custom/metaschema',
      '$schema' => 'http://json-schema.org/draft-07/schema',
    },
    { metaschema_uri => 'https://metaschema/with/wrong/spec' },
  );

  cmp_result(
    $state,
    superhashof({
        identifiers => {
          $third_id => { $state_copy->{identifiers}{$id}->%*, canonical_uri => str($third_id) },
        },
        $state_copy->%{qw(metaschema_uri spec_version vocabularies)},
      }),
    'when $schema keyword is used, custom metaschema_uri is never parsed, so there are no errors',
  );
};

subtest 'start traversing below the document root' => sub {
  my $js = JSON::Schema::Modern->new;

  # Remember: at this point the $document object may exist, but its constructor hasn't finished yet
  # (until traverse() returns), and we have no idea where in the document we are, and the evaluator
  # isn't provided the document object yet.
  # The document data might not even be a JSON Schema.
  # Let's say the document actually looks like:
  # {
  #   $self => 'my_document.yaml',
  #   openapi => '3.1.1',
  #   components => {
  #     schemas => {
  #       alpha => {
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


  $state = $js->traverse(
    {
      properties => {
        myprop => {
          allOf => [
            {
              '$id' => 'inner_document',      # resolves to dir/inner_document
              properties => { foo => true },
            },
          ],
        },
      },
    },
    {
      initial_schema_uri => 'dir/my_subdocument#/subid',
      traversed_schema_path => '/components/alpha/subid',
    },
  );

  cmp_result(
    $state->{identifiers},
    {
      'dir/inner_document' => {
        canonical_uri => str('dir/inner_document'),
        path => '/components/alpha/subid/properties/myprop/allOf/0',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
      },
    },
    'identifiers are correctly extracted when traversing below the document root',
  );

  $state = $js->traverse(
    {
      # the path at this position is /components/alpha/subid
      properties => {
        alpha => {
          '$id' => 'alpha_id',          # resolves to dir/alpha_id
          properties => {
            alpha_one => {
              '$id' => 'alpha_one_id',  # resolves to dir/alpha_one_id
            },
            alpha_two => {
              '$anchor' => 'alpha_two_anchor',    # resolves to dir/alpha_id#alpha_two_anchor
            },
            alpha_three => {
              '$anchor' => 'alpha_three_anchor',  # resolves to dir/alpha_id#alpha_three_anchor
            },
          },
        },
        beta => {
          # produces anchor definition:
          # base uri is dir/my_subdocument,
          # canonical uri is dir/my_subdocument#/subid/properties/beta
          # path is /components/alpha/subid/properties/beta
          '$anchor' => 'beta_anchor',   # resolves to dir/my_subdocument#beta_anchor
        },
      },
    },
    {
      # this is used for adjusting canonical_uri in extracted 'identifiers'; and for errors.
      # we can infer that there is an identifier 'dir/mysubdocument' at path '/components/alpha'
      initial_schema_uri => 'dir/my_subdocument#/subid',
      traversed_schema_path => '/components/alpha/subid',
    },
  );

  cmp_result(
    $state->{identifiers},
    {
      'dir/alpha_id' => {
        canonical_uri => str('dir/alpha_id'),
        path => '/components/alpha/subid/properties/alpha',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
        anchors => {
          alpha_two_anchor => {
            canonical_uri => str('dir/alpha_id#/properties/alpha_two'),
            path => '/components/alpha/subid/properties/alpha/properties/alpha_two',
          },
          alpha_three_anchor => {
            canonical_uri => str('dir/alpha_id#/properties/alpha_three'),
            path => '/components/alpha/subid/properties/alpha/properties/alpha_three',
          },
        },
      },
      'dir/alpha_one_id' => {
        canonical_uri => str('dir/alpha_one_id'),
        path => '/components/alpha/subid/properties/alpha/properties/alpha_one',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
      },
      'dir/my_subdocument' => {   # this is inferred when we process "$anchor": "beta_anchor"
        canonical_uri => str('dir/my_subdocument'),
        path => '/components/alpha',
        specification_version => 'draft2020-12',
        vocabularies => ignore,
        configs => {},
        anchors => {
          beta_anchor => {
            canonical_uri => str('dir/my_subdocument#/subid/properties/beta'),
            path => '/components/alpha/subid/properties/beta',
          },
        },
      },
    },
    'identifiers are correctly extracted when traversing below the document root, with anchor',
  );
};

done_testing;
