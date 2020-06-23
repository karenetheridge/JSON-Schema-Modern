use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Fatal;
use Test::Deep::UnorderedPairs;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Draft201909' => 'share' } };

use constant METASCHEMA => 'https://json-schema.org/draft/2019-09/schema';

subtest 'evaluate a document' => sub {
  my $document = JSON::Schema::Draft201909::Document->new(
    schema => {
      '$id' => 'https://foo.com',
      allOf => [ false, true ],
    });

  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(1, $document)->TO_JSON,
    {
      valid => bool(0),
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0',
          absoluteKeywordLocation => 'https://foo.com#/allOf/0',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://foo.com#/allOf',
          error => 'subschema 0 is not valid',
        },
      ],
    },
    'evaluate a Document object',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      'https://foo.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        document => shallow($document),
      },
    },
    'resource index from the document is copied to the main object',
  );

  cmp_deeply(
    $js->evaluate(1, $document)->TO_JSON,
    {
      valid => bool(0),
      errors => $errors,
    },
    'evaluate a Document object again without error',
  );
};

subtest 'evaluate a uri' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    $js->evaluate({ '$schema' => 1 }, METASCHEMA)->TO_JSON,
    {
      valid => bool(0),
      errors => my $errors = [
        {
          instanceLocation => '/$schema',
          keywordLocation => '/allOf/0/$ref/properties/$schema/type',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/core#/properties/$schema/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/properties',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/core#/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => METASCHEMA.'#/allOf',
          error => 'subschema 0 is not valid',
        },
      ],
    },
    'evaluate a uri that is not yet loaded',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      map +(
        $_ => {
          path => '',
          canonical_uri => str($_),
          document => isa('JSON::Schema::Draft201909::Document'),
        }
      ),
      METASCHEMA,
      map 'https://json-schema.org/draft/2019-09/meta/'.$_,
        qw(core applicator validation meta-data format content)
    },
    'the metaschema is now loaded and its resources are indexed',
  );

  # and again, we can use the same resource without reloading it
  cmp_deeply(
    $js->evaluate({ '$schema' => 1 }, METASCHEMA)->TO_JSON,
    {
      valid => bool(0),
      errors => $errors,
    },
    'evaluate against the metaschema again',
  );

  # now use a subschema at that url to evaluate with.
  # multiple things are being tested here:
  # - we can load a schema resource, or find an existing one, with a fragment
  # - the json path we used is saved in the state, for correct errors
  cmp_deeply(
    $js->evaluate(
      1,
      'https://json-schema.org/draft/2019-09/meta/core#/properties/$schema',
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/core#/properties/$schema/type',
          error => 'wrong type (expected string)',
        },
      ],
    },
    'evaluate against the a subschema of the metaschema',
  );

  cmp_deeply(
    $js->evaluate(
      1,
      METASCHEMA.'#/does/not/exist',
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'EXCEPTION: unable to find resource '.METASCHEMA.'#/does/not/exist',
        },
      ],
    },
    'evaluate against the a fragment of the metaschema that does not exist',
  );
};

subtest 'add a uri resource' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->add_schema(METASCHEMA),
    all(
      isa('JSON::Schema::Draft201909::Document'),
      listmethods(
        resource_index => [
          METASCHEMA() => {
            path => '',
            canonical_uri => str(METASCHEMA),
          },
        ],
        canonical_uri => [ str(METASCHEMA) ],
      ),
    ),
    'added the metaschema by uri',
  );

  is(
    $js->add_schema('http://httpbin.org/status/404'),
    undef,
    'attempt to add a resource that does not exist',
  );
};

subtest 'add a schema associated with a uri' => sub {
  my $js = JSON::Schema::Draft201909->new;

  like(
    exception { $js->add_schema('https://foo.com#/x/y/z', {}) },
    qr/^cannot add a schema with a uri with a fragment/,
    'cannot use a uri with a fragment',
  );

  cmp_deeply(
    my $document = $js->add_schema(
      'https://foo.com',
      { '$id' => 'https://bar.com', allOf => [ false, true ] },
    ),
    all(
      isa('JSON::Schema::Draft201909::Document'),
      listmethods(
        resource_index => unordered_pairs(
          'https://foo.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
          },
          'https://bar.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
          },
        ),
        canonical_uri => [ str('https://bar.com') ],
      ),
    ),
    'added the schema data with an associated uri',
  );

  cmp_deeply(
    my $result = $js->evaluate(1, 'https://bar.com#/allOf/0')->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          absoluteKeywordLocation => 'https://bar.com#/allOf/0',
          error => 'subschema is false',
        },
      ],
    },
    'can now evaluate using a uri to a subschema of a resource we loaded earlier',
  );

  cmp_deeply(
    $js->evaluate(1, 'https://foo.com')->TO_JSON,
    {
      valid => bool(0),
      errors => my $errors = [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0',
          absoluteKeywordLocation => 'https://bar.com#/allOf/0',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'https://bar.com#/allOf',
          error => 'subschema 0 is not valid',
        },
      ],
    },
    'can also evaluate using a non-canonical uri',
  );

  cmp_deeply(
    $js->add_schema('https://bloop.com', $document),
    shallow($document),
    'can add the same document and associate it with another schema',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      map +( $_ => {
        path => '',
        canonical_uri => str('https://bar.com'),
        document => shallow($document),
      } ), qw(https://foo.com https://bar.com https://bloop.com)
    },
    'now the document is available as all three uris',
  );
};

subtest 'add a document without associating it with a uri' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    $js->add_schema(
      my $document = JSON::Schema::Draft201909::Document->new(
        schema => { '$id' => 'https://bar.com', allOf => [ false, true ] },
      )),
    all(
      isa('JSON::Schema::Draft201909::Document'),
      listmethods(
        resource_index => [
          'https://bar.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
          },
        ],
        canonical_uri => [ str('https://bar.com') ],
      ),
    ),
    'added the document without an associated uri',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      'https://bar.com' => {
        path => '', canonical_uri => str('https://bar.com'), document => shallow($document),
      },
    },
    'document only added under its canonical uri',
  );
};

subtest 'add a schema without a uri' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    my $document = $js->add_schema(
      { '$id' => 'https://bar.com', allOf => [ false, true ] },
    ),
    all(
      isa('JSON::Schema::Draft201909::Document'),
      listmethods(
        resource_index => [
          'https://bar.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
          },
        ],
        canonical_uri => [ str('https://bar.com') ],
      ),
    ),
    'added the schema data without an associated uri',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      'https://bar.com' => {
        path => '', canonical_uri => str('https://bar.com'), document => shallow($document),
      },
    },
    'document only added under its canonical uri',
  );
};

subtest '$ref to non-canonical uri' => sub {
  my $schema = {
    '$id' => 'http://localhost:4242/my_document', # the canonical_uri
    properties => {
      alpha => false,
      beta => {
        '$id' => 'beta',
        properties => {
          gamma => {
            minimum => 2,
          },
        },
      },
      delta => {
        '$ref' => 'http://otherhost:4242/another_uri#/properties/alpha',
      },
    },
  };

  my $js = JSON::Schema::Draft201909->new;
  $js->add_schema('http://otherhost:4242/another_uri', $schema);

  cmp_deeply(
    $js->evaluate({ alpha => 1 }, 'http://otherhost:4242/another_uri')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/alpha',
          keywordLocation => '/properties/alpha',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties/alpha',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'errors use the canonical uri, not the uri used to evaluate against',
  );

  cmp_deeply(
    $js->evaluate({ gamma => 1 }, 'http://otherhost:4242/beta')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'EXCEPTION: unable to find resource http://otherhost:4242/beta',
        },
      ],
    },
    'non-canonical uri is not used to resolve inner $id keywords',
  );

  cmp_deeply(
    $js->evaluate({ gamma => 1 }, 'http://localhost:4242/beta')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/gamma',
          keywordLocation => '/properties/gamma/minimum',
          absoluteKeywordLocation => 'http://localhost:4242/beta#/properties/gamma/minimum',
          error => 'value is smaller than 2',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'http://localhost:4242/beta#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'the canonical uri is updated when use the canonical uri, not the uri used to evaluate against',
  );

  cmp_deeply(
    $js->evaluate({ delta => 1 }, 'http://otherhost:4242/another_uri')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/delta',
          keywordLocation => '/properties/delta/$ref',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties/alpha',
          error => 'subschema is false',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'canonical_uri is not always what was in the $ref, even when no local $id is present',
  );

  cmp_deeply(
    $js->evaluate(1, 'http://otherhost:4242/another_uri#/properties/alpha')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties/alpha',
          error => 'subschema is false',
        },
      ],
    },
    'canonical_uri fragment also needs to be adjusted',
  );

  delete $schema->{properties}{beta}{'$id'};

  cmp_deeply(
    $js->evaluate({ gamma => 1 }, 'http://otherhost:4242/another_uri#/properties/beta')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/gamma',
          keywordLocation => '/properties/gamma/minimum',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties/beta/properties/gamma/minimum',
          error => 'value is smaller than 2',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties/beta/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'canonical_uri starts out containing a fragment and can be appended to during traversal',
  );
};

done_testing;
