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
use JSON::Schema::Modern;
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

  cmp_deeply(
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

  cmp_deeply(
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
};

subtest 'vocabularies used during traversal' => sub {
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

  cmp_deeply(
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
  cmp_deeply(
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
  cmp_deeply(
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
    });
  cmp_deeply(
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

  cmp_deeply(
    $state->{identifiers},
    [
      str($id),
      {
        canonical_uri => str($id),
        path => '',
        specification_version => 'draft2020-12',
        vocabularies => [
          map 'JSON::Schema::Modern::Vocabulary::'.$_,
            qw(Core Applicator),
        ],
        configs => {},
      }
    ],
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
  cmp_deeply(
    [ map $_->TO_JSON, $state->{errors}->@* ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/components/alpha/subid/properties/myprop/allOf/0/properties/foo',
        absoluteKeywordLocation => 'dir/inner_document#/properties/foo',
        error => 'invalid schema type: string',
      },
      {
        instanceLocation => '',
        keywordLocation => '/components/alpha/subid/type',
        absoluteKeywordLocation => 'dir/my_subdocument#/subid/type',
        error => 'unrecognized type "not a valid type"',
      },
    ],
    'identified the overridden location of all errors during traverse',
  );


  cmp_deeply(
    my $identifiers = +{
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
      )->{identifiers}->@*
    },
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
