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

use Test::Fatal;
use Test::Deep::UnorderedPairs;
use Test::Warnings qw(warnings :no_end_test had_no_warnings);
use List::Util 'unpairs';
use lib 't/lib';
use Helper;

use constant METASCHEMA => 'https://json-schema.org/draft/2019-09/schema';

# spec version -> vocab classes
my %vocabularies = unpairs(JSON::Schema::Modern->new->__all_metaschema_vocabulary_classes);

subtest 'evaluate a document' => sub {
  my $document = JSON::Schema::Modern::Document->new(
    schema => {
      '$id' => 'https://foo.com',
      allOf => [ false, true ],
    });

  my $js = JSON::Schema::Modern->new;
  $js->add_document($document);
  cmp_result(
    $js->evaluate(1, $document->canonical_uri)->TO_JSON,
    {
      valid => false,
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

  cmp_result(
    { $js->_resource_index },
    {
      'https://foo.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
    },
    'resource index from the document is copied to the main object',
  );

  cmp_result(
    $js->evaluate(1, $document->canonical_uri)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'evaluate a Document object again without error',
  );
};

subtest 'evaluate a uri' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_result(
    $js->evaluate({ '$schema' => 1 }, METASCHEMA)->TO_JSON,
    {
      valid => false,
      errors => my $errors = [
        {
          instanceLocation => '/$schema',
          keywordLocation => '/allOf/0/$ref/properties/$schema/type',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/core#/properties/$schema/type',
          error => 'got integer, not string',
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
    'evaluate with a uri that is not yet loaded',
  );

  cmp_result(
    { $js->_resource_index },
    {
      map +(
        $_ => {
          path => '',
          canonical_uri => str($_),
          document => isa('JSON::Schema::Modern::Document'),
          specification_version => 'draft2019-09',
          vocabularies => $vocabularies{'draft2019-09'},
          configs => {},
        }
      ),
      METASCHEMA,
      map 'https://json-schema.org/draft/2019-09/meta/'.$_,
        qw(core applicator validation meta-data format content)
    },
    'the metaschema is now loaded and its resources are indexed',
  );

  # and again, we can use the same resource without reloading it
  cmp_result(
    $js->evaluate({ '$schema' => 1 }, METASCHEMA)->TO_JSON,
    {
      valid => false,
      errors => $errors,
    },
    'evaluate against the metaschema again',
  );

  # now use a subschema at that url to evaluate with.
  # multiple things are being tested here:
  # - we can load a schema resource, or find an existing one, with a fragment
  # - the json path we used is saved in the state, for correct errors
  cmp_result(
    $js->evaluate(
      1,
      'https://json-schema.org/draft/2019-09/meta/core#/properties/$schema',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          absoluteKeywordLocation => 'https://json-schema.org/draft/2019-09/meta/core#/properties/$schema/type',
          error => 'got integer, not string',
        },
      ],
    },
    'evaluate against the a subschema of the metaschema',
  );

  cmp_result(
    $js->evaluate(
      1,
      METASCHEMA.'#/does/not/exist',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'EXCEPTION: unable to find resource "'.METASCHEMA.'#/does/not/exist"',
        },
      ],
    },
    'evaluate against the a fragment of the metaschema that does not exist',
  );

  cmp_result(
    $js->evaluate(
      1,
      METASCHEMA.'#does_not_exist',
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'EXCEPTION: unable to find resource "'.METASCHEMA.'#does_not_exist"',
        },
      ],
    },
    'evaluate against the a plain-name fragment of the metaschema that does not exist',
  );
};

subtest 'add a uri resource' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_result(
    my $get_metaschema = scalar $js->get(METASCHEMA),
    my $orig_metaschema = $js->_get_resource(METASCHEMA)->{document}->schema,
    '->get in scalar context on a URI to the head of a document',
  );

  ok($get_metaschema != $orig_metaschema, 'get() did not return a reference to the original data');

  cmp_result(
    [ $js->get(METASCHEMA) ],
    [ $js->_get_resource(METASCHEMA)->{document}->schema,
      all(isa('Mojo::URL'), str(METASCHEMA)) ],
    '->get in list context on a URI to the head of a document',
  );

  cmp_result(
    scalar $js->get(METASCHEMA.'#/properties/definitions/type'),
    'object', # $document->schema->{properties}{definitions}{type}
    '->get in scalar context on a URI to inside of a document',
  );
  cmp_result(
    [ $js->get(METASCHEMA.'#/properties/definitions/type') ],
    [ 'object', all(isa('Mojo::URL'), str(METASCHEMA.'#/properties/definitions/type')) ],
    '->get in list context on a URI to inside of a document',
  );
};

subtest 'add a schema associated with a uri' => sub {
  my $js = JSON::Schema::Modern->new;

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
      isa('JSON::Schema::Modern::Document'),
      listmethods(
        resource_index => unordered_pairs(
          'https://foo.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
            specification_version => 'draft2020-12',
            vocabularies => $vocabularies{'draft2020-12'},
            configs => {},
          },
          'https://bar.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
            specification_version => 'draft2020-12',
            vocabularies => $vocabularies{'draft2020-12'},
            configs => {},
          },
        ),
        canonical_uri => [ str('https://bar.com') ],
      ),
    ),
    'added the schema data with an associated uri',
  );

  cmp_result(
    my $result = $js->evaluate(1, 'https://bar.com#/allOf/0')->TO_JSON,
    {
      valid => false,
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

  cmp_result(
    $js->evaluate(1, 'https://foo.com')->TO_JSON,
    {
      valid => false,
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

  cmp_result(
    $js->add_document('https://bloop.com', $document),
    shallow($document),
    'can add the same document and associate it with another schema',
  );

  my @warnings = warnings {
    cmp_result(
      $js->add_schema('https://bloop.com', $document),
      shallow($document),
      'can add the same document twice, using deprecated interface',
    );
  };

  cmp_result(
    \@warnings,
    [ re(qr/use of deprecated form of add_schema with document/) ],
    'warned when using deprecated form of add_schema',
  );

  cmp_result(
    $js->add_document($document),
    shallow($document),
    'can add the same document again with the proper interface',
  );

  cmp_result(
    { $js->_resource_index },
    {
      map +( $_ => {
        path => '',
        canonical_uri => str('https://bar.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      } ), qw(https://foo.com https://bar.com https://bloop.com)
    },
    'now the document is available as all three uris',
  );
};

subtest 'add a document without associating it with a uri' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_deeply(
    $js->add_document(
      my $document = JSON::Schema::Modern::Document->new(
        schema => { '$id' => 'https://bar.com', allOf => [ false, true ] },
      )),
    all(
      isa('JSON::Schema::Modern::Document'),
      listmethods(
        resource_index => [
          'https://bar.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
            specification_version => 'draft2020-12',
            vocabularies => $vocabularies{'draft2020-12'},
            configs => {},
          },
        ],
        canonical_uri => [ str('https://bar.com') ],
      ),
    ),
    'added the document without an associated uri',
  );

  cmp_result(
    { $js->_resource_index },
    {
      'https://bar.com' => {
        path => '',
        canonical_uri => str('https://bar.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
    },
    'document only added under its canonical uri',
  );
};

subtest 'add a schema without a uri' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_deeply(
    my $document = $js->add_schema(
      { '$id' => 'https://bar.com', allOf => [ false, true ] },
    ),
    all(
      isa('JSON::Schema::Modern::Document'),
      listmethods(
        resource_index => [
          'https://bar.com' => {
            path => '',
            canonical_uri => str('https://bar.com'),
            specification_version => 'draft2020-12',
            vocabularies => $vocabularies{'draft2020-12'},
            configs => {},
          },
        ],
        canonical_uri => [ str('https://bar.com') ],
      ),
    ),
    'added the schema data without an associated uri',
  );

  cmp_result(
    { $js->_resource_index },
    {
      'https://bar.com' => {
        path => '',
        canonical_uri => str('https://bar.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
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

  my $js = JSON::Schema::Modern->new;
  $js->add_schema('http://otherhost:4242/another_uri', $schema);

  cmp_result(
    $js->evaluate({ alpha => 1 }, 'http://otherhost:4242/another_uri')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/alpha',
          keywordLocation => '/properties/alpha',
          absoluteKeywordLocation => 'http://localhost:4242/my_document#/properties/alpha',
          error => 'property not permitted',
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

  cmp_result(
    $js->evaluate({ gamma => 1 }, 'http://otherhost:4242/beta')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => 'EXCEPTION: unable to find resource "http://otherhost:4242/beta"',
        },
      ],
    },
    'non-canonical uri is not used to resolve inner $id keywords',
  );

  cmp_result(
    $js->evaluate({ gamma => 1 }, 'http://localhost:4242/beta')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/gamma',
          keywordLocation => '/properties/gamma/minimum',
          absoluteKeywordLocation => 'http://localhost:4242/beta#/properties/gamma/minimum',
          error => 'value is less than 2',
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

  cmp_result(
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

  cmp_result(
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

  cmp_result(
    $js->evaluate({ gamma => 1 }, 'http://otherhost:4242/another_uri#/properties/beta')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/gamma',
          keywordLocation => '/properties/gamma/minimum',
          absoluteKeywordLocation => 'http://localhost:4242/beta#/properties/gamma/minimum',
          error => 'value is less than 2',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'http://localhost:4242/beta#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'canonical_uri starts out containing a fragment and can be appended to during traversal',
  );
};

subtest 'register a document against multiple uris; do not allow duplicate uris' => sub {
  my $js = JSON::Schema::Modern->new;
  my $document = JSON::Schema::Modern::Document->new(
    schema => {
      '$id' => 'https://foo.com',
      maximum => 1,
      '$defs' => {
        foo => {
          '$anchor' => 'fooanchor',
          allOf => [ true ],
        },
      },
    });
  $js->add_document($document);

  cmp_result(
    { $js->_resource_index },
    {
      'https://foo.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
      'https://foo.com#fooanchor' => {
        path => '/$defs/foo',
        canonical_uri => str('https://foo.com#/$defs/foo'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
    },
    'resource index from the document is copied to the main object',
  );

  $js->add_document('https://uri2.com', $document);

  cmp_result(
    { $js->_resource_index },
    my $main_resource_index = {
      'https://foo.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
      'https://foo.com#fooanchor' => {
        path => '/$defs/foo',
        canonical_uri => str('https://foo.com#/$defs/foo'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
      'https://uri2.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
    },
    'add a secondary uri for the same document',
  );

  cmp_result(
    { $document->resource_index },
    my $doc_resource_index = {
      'https://foo.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
      'https://foo.com#fooanchor' => {
        path => '/$defs/foo',
        canonical_uri => str('https://foo.com#/$defs/foo'),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
    },
    'secondary uri not also added to the document',
  );

  like(
    exception { $js->add_schema('https://uri2.com', { x => 1 }) },
    qr!^\Quri "https://uri2.com" conflicts with an existing schema resource\E!,
    'cannot call add_schema with the same URI as for another schema',
  );

  like(
    exception { $js->add_schema('https://uri3.com', { '$id' => 'https://foo.com', x => 1 }) },
    qr!^\Quri "https://foo.com" conflicts with an existing schema resource\E!,
    'cannot reuse the same $id in another document',
  );

  cmp_result(
    { $js->_resource_index },
    $main_resource_index,
    'resource index remains unchanged after erroneous add_schema calls',
  );

  is(
    $js->add_schema('https://uri4.com', +{ $document->schema->%* }),
    $document,
    'adding the same schema *content* again does not fail, and returns the original document object',
  );

  cmp_result(
    { $document->resource_index },
    $doc_resource_index,
    'original document remains unchanged - the new uri was not added to it',
  );

  cmp_result(
    { $js->_resource_index },
    {
      'https://uri4.com' => {
        path => '',
        canonical_uri => str('https://foo.com'),
        document => shallow($document),
        specification_version => 'draft2020-12',
        vocabularies => $vocabularies{'draft2020-12'},
        configs => {},
      },
      %$main_resource_index,
    },
    'new uri was added against the original document (no new document created)',
  );

  cmp_result(
    scalar $js->get('https://foo.com#fooanchor'),
    $js->_get_resource('https://foo.com#fooanchor')->{document}->schema->{'$defs'}{foo},
    '->get in scalar context on a secondary URI with a plain-name fragment',
  );
  cmp_result(
    [ $js->get('https://foo.com#fooanchor') ],
    [ $js->_get_resource('https://uri2.com')->{document}->schema->{'$defs'}{foo},
      all(isa('Mojo::URL'), str('https://foo.com#/$defs/foo')) ],
    '->get in list context on a URI with a plain-name fragment includes the canonical uri',
  );

  is(
    scalar $js->get('https://foo.com#i_do_not_exist'),
    undef,
    '->get in scalar context for a nonexistent resource returns undef',
  );
  cmp_result(
    [ $js->get('https://foo.com#i_do_not_exist') ],
    [],
    '->get in list context for a nonexistent resource returns empty list',
  );
};

subtest 'external resource with externally-supplied uri; main resource with multiple uris' => sub {
  my $js = JSON::Schema::Modern->new;

  $js->add_schema('http://localhost:1234/integer.json', { type => 'integer' });

  $js->add_schema(
    'https://secondary.com',
    my $schema = {
      '$id' => 'https://main.com',
      '$ref' => 'http://localhost:1234/integer.json',
      type => 'object',
    },
  );

  cmp_result(
    my $result = $js->evaluate('string', 'https://secondary.com')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/type',
          absoluteKeywordLocation => 'http://localhost:1234/integer.json#/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/type',
          absoluteKeywordLocation => 'https://main.com#/type',
          error => 'got string, not object',
        },
      ],
    },
    'all uris in result are correct, using secondary uri as the target',
  );

  cmp_result(
    $js->evaluate('string', 'https://main.com')->TO_JSON,
    $result,
    'all uris in result are correct, using main uri as the target',
  );

  cmp_result(
    $js->evaluate('string', $schema)->TO_JSON,
    $result,
    'all uris in result are correct, using the literal schema as the target',
  );
};

subtest 'document with no canonical URI, but assigned a URI through add_schema' => sub {
  my $js = JSON::Schema::Modern->new;

  # the document itself doesn't know about this URI, but the evaluator does
  $js->add_schema(
    'https://localhost:1234/mydef.json',
    my $def_schema = { '$defs' => { integer => { type => 'integer' } } },
  );

  cmp_result(
    $js->evaluate(
      { foo => 'string' },
      my $schema = {
        # no $id here!
        type => 'object',
        additionalProperties => {
          '$ref' => 'https://localhost:1234/mydef.json#/$defs/integer',
        },
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/$ref/type',
          # the canonical URI is what the evaluator knows it as, even if the document doesn't know
          absoluteKeywordLocation => 'https://localhost:1234/mydef.json#/$defs/integer/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'evaluate a schema referencing a document given an ad-hoc uri',
  );

  # start over with a new evaluator...
  $js = JSON::Schema::Modern->new;

  $js->add_document(
    'https://localhost:1234/mydef.json',
    JSON::Schema::Modern::Document->new(schema => {
      '$id' => 'https://otherhost.com/mydef.json',
      %$def_schema,
    }),
  );

  cmp_result(
    $js->evaluate(
      { foo => 'string' },
      $schema,
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '/foo',
          keywordLocation => '/additionalProperties/$ref/type',
          absoluteKeywordLocation => 'https://otherhost.com/mydef.json#/$defs/integer/type',
          error => 'got string, not integer',
        },
        {
          instanceLocation => '',
          keywordLocation => '/additionalProperties',
          error => 'not all additional properties are valid',
        },
      ],
    },
    'adding a uri to an existing document does not change its canonical uri',
  );
};

had_no_warnings if $ENV{AUTHOR_TESTING};
done_testing;
