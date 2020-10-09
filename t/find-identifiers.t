use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

subtest '$id sets canonical uri' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(
      1,
      my $schema = {
        '$defs' => {
          foo => my $foo_definition = {
            '$id' => 'http://localhost:4242/my_foo',
            const => 'foo value',
          },
        },
        '$ref' => 'http://localhost:4242/my_foo',
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/const',
          absoluteKeywordLocation => 'http://localhost:4242/my_foo#/const',
          error => 'value does not match',
        },
      ],
    },
    '$id was recognized - $ref was successfully traversed',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      '' => { path => '', canonical_uri => str(''), document => ignore },
      'http://localhost:4242/my_foo' => {
        path => '/$defs/foo',
        canonical_uri => str('http://localhost:4242/my_foo'),
        document => methods(canonical_uri => str('')),
      },
    },
    'resources indexed; document canonical_uri is still unset',
  );

  my $doc1 = $js->{_resource_index}{''}{document};
  my $doc2 = $js->{_resource_index}{'http://localhost:4242/my_foo'}{document};
  ok($doc1 == $doc2, 'the same document object is indexed under both URIs');

  sub _find_all_values {
      my $data = shift;
      if (ref $data eq 'ARRAY') {
          return map __SUB__->($_), @$data;
      }
      elsif (ref $data eq 'HASH') {
          return map __SUB__->($_), values %$data;
      }
      return $data;
  }

  my @blessed_values = grep ref($_), _find_all_values($doc1->schema);
  ok(!@blessed_values, 'the schema contains no blessed leaf nodes')
    or diag 'found blessed values: ', explain [ map ref, @blessed_values ];
};

subtest 'anchors' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(
      1,
      my $schema = {
        '$defs' => {
          foo => my $foo_definition = {
            '$anchor' => 'my_foo',
            const => 'foo value',
          },
          bar => my $bar_definition = {
            '$anchor' => 'my_bar',
            not => true,
          },
        },
        '$id' => 'http://localhost:4242',
        allOf => [
          { '$ref' => '#my_foo' },
          { '$ref' => '#my_bar' },
          { not => my $not_definition = {
              '$anchor' => 'my_not',
              not => false,
            },
          },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/$ref/const',
          absoluteKeywordLocation => 'http://localhost:4242#/$defs/foo/const',
          error => 'value does not match',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$ref/not',
          absoluteKeywordLocation => 'http://localhost:4242#/$defs/bar/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/not',
          absoluteKeywordLocation => 'http://localhost:4242#/allOf/2/not',
          error => 'subschema is valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'http://localhost:4242#/allOf',
          error => 'subschemas 0, 1, 2 are not valid',
        },
      ],
    },
    '$id was recognized - absolute locations use json paths, not anchors',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      'http://localhost:4242' => {
        path => '',
        canonical_uri => str('http://localhost:4242'),
        document => methods(canonical_uri => str('http://localhost:4242')),
      },
      'http://localhost:4242#my_foo' => {
        path => '/$defs/foo',
        canonical_uri => str('http://localhost:4242#/$defs/foo'),
        document => shallow($js->_get_resource('http://localhost:4242')->{document}),
      },
      'http://localhost:4242#my_bar' => {
        path => '/$defs/bar',
        canonical_uri => str('http://localhost:4242#/$defs/bar'),
        document => shallow($js->_get_resource('http://localhost:4242')->{document}),
      },
      'http://localhost:4242#my_not' => {
        path => '/allOf/2/not',
        canonical_uri => str('http://localhost:4242#/allOf/2/not'),
        document => shallow($js->_get_resource('http://localhost:4242')->{document}),
      },
    },
    'internal resource index is correct',
  );
};

subtest '$anchor at root without $id' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$anchor' => 'root',
        '$defs' => {
          foo => {
            '$anchor' => 'my_foo',
            const => 'foo value',
          },
        },
        '$ref' => '#my_foo',
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$ref/const',
          absoluteKeywordLocation => '#/$defs/foo/const',
          error => 'value does not match',
        },
      ],
    },
    '$id without anchor was recognized - absolute locations use json paths, not anchors',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      '' => { path => '', canonical_uri => str(''), document => ignore },
      '#root' => { path => '', canonical_uri => str(''), document => ignore },
      '#my_foo' => {
        path => '/$defs/foo',
        canonical_uri => str('#/$defs/foo'),
        document => ignore,
      },
    },
    'internal resource index is correct',
  );
};

subtest '$ids and $anchors in subschemas after $id changes' => sub {
  my $js = JSON::Schema::Draft201909->new;
  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'https://foo.com/a/alpha',
        properties => {
          b => {
            '$id' => 'beta',
            properties => {
              d => {
                '$anchor' => 'my_d',
              },
            },
          },
          f => {
            '$id' => 'zeta',
            properties => {
              h => {
                '$anchor' => 'my_h',
              },
            },
          },
        },
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    '$anchor is legal in a subschema',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      'https://foo.com/a/alpha' => {
        path => '', canonical_uri => str('https://foo.com/a/alpha'), document => ignore,
      },
      'https://foo.com/a/beta' => {
        path => '/properties/b', canonical_uri => str('https://foo.com/a/beta'), document => ignore,
      },
      'https://foo.com/a/zeta' => {
        path => '/properties/f', canonical_uri => str('https://foo.com/a/zeta'), document => ignore,
      },
      'https://foo.com/a/beta#my_d' => {
        path => '/properties/b/properties/d',
        canonical_uri => str('https://foo.com/a/beta#/properties/d'),
        document => ignore,
      },
      'https://foo.com/a/zeta#my_h' => {
        path => '/properties/f/properties/h',
        canonical_uri => str('https://foo.com/a/zeta#/properties/h'),
        document => ignore,
      },
    },
    'internal resource index is correct',
  );
};

subtest 'invalid $id and $anchor' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'foo.json',
        '$defs' => {
          bad_id => {
            '$id' => 'foo.json#/foo/bar',
          },
          bad_anchor => {
            '$anchor' => 'my$foo',
          },
        },
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$defs/bad_anchor/$anchor',
          absoluteKeywordLocation => 'foo.json#/$defs/bad_anchor/$anchor',
          error => '$anchor value "my$foo" does not match required syntax',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$defs/bad_id/$id',
          absoluteKeywordLocation => 'foo.json#/$defs/bad_id/$id',
          error => '$id value "foo.json#/foo/bar" cannot have a non-empty fragment',
        },
      ],
    },
    'bad $id and $anchor are detected, even if bad definitions are not traversed',
  );

  cmp_deeply(
    $js->evaluate(
      1,
      {
        '$id' => 'foo.json',
        '$defs' => {
          const_not_id => {
            const => {
              '$id' => 'not_a_real_id',
            },
          },
          const_not_anchor => {
            enum => [
              '$anchor' => 'not_a_real_anchor',
            ],
          },
        },
        anyOf => [
          { '$ref' => '#/$defs/const_not_id' },
          { '$ref' => '#/$defs/const_not_anchor' },
          true,
        ],
      },
    )->TO_JSON,
    {
      valid => bool(1),
    },
    '"bad" $ids and $anchors that are not actually keywords are not reported as errors',
  );
};

subtest 'nested $ids' => sub {
  my $js = JSON::Schema::Draft201909->new(short_circuit => 0);
  my $schema = {
    '$id' => '/foo/bar/baz.json',
    '$ref' => '/foo/bar/baz.json#/properties/alpha',  # not the canonical URI for that location
    properties => {
      alpha => my $alpha = {
        '$id' => 'alpha.json',
        additionalProperties => false,
        properties => {
          beta => my $beta = {
            '$id' => '/beta/hello.json',
            properties => {
              gamma => my $gamma = {
                '$id' => 'gamma.json',
                const => 'hello',
              },
            },
          },
        },
      },
    },
  };

  cmp_deeply(
    $js->evaluate(
      {
        alpha => {
          beta => {
            gamma => 'not hello',
          },
        },
      },
      $schema,
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '/alpha',
          keywordLocation => '/$ref/additionalProperties',
          absoluteKeywordLocation => '/foo/bar/alpha.json#/additionalProperties',
          error => 'additional property not permitted',
        },
        {
          instanceLocation => '',
          keywordLocation => '/$ref/additionalProperties',
          absoluteKeywordLocation => '/foo/bar/alpha.json#/additionalProperties',
          error => 'not all additional properties are valid',
        },
        {
          instanceLocation => '/alpha/beta/gamma',
          keywordLocation => '/properties/alpha/properties/beta/properties/gamma/const',
          absoluteKeywordLocation => '/beta/gamma.json#/const',
          error => 'value does not match',
        },
        {
          instanceLocation => '/alpha/beta',
          keywordLocation => '/properties/alpha/properties/beta/properties',
          absoluteKeywordLocation => '/beta/hello.json#/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '/alpha',
          keywordLocation => '/properties/alpha/properties',
          absoluteKeywordLocation => '/foo/bar/alpha.json#/properties',
          error => 'not all properties are valid',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => '/foo/bar/baz.json#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'errors have the correct location',
  );

  cmp_deeply(
    { $js->_resource_index },
    {
      '/foo/bar/baz.json' => {
        path => '',
        canonical_uri => str('/foo/bar/baz.json'),
        document => methods(canonical_uri => str('/foo/bar/baz.json')),
      },
      '/foo/bar/alpha.json' => {
        path => '/properties/alpha',
        canonical_uri => str('/foo/bar/alpha.json'),
        document => shallow($js->_get_resource('/foo/bar/baz.json')->{document}),
      },
      '/beta/hello.json' => {
        path => '/properties/alpha/properties/beta',
        canonical_uri => str('/beta/hello.json'),
        document => shallow($js->_get_resource('/foo/bar/baz.json')->{document}),
      },
      '/beta/gamma.json' => {
        path => '/properties/alpha/properties/beta/properties/gamma',
        canonical_uri => str('/beta/gamma.json'),
        document => shallow($js->_get_resource('/foo/bar/baz.json')->{document}),
      },
    },
    'properly resolved all the nested $ids',
  );
};

subtest 'multiple documents, each using canonical_uri = ""' => sub {
  my $js = JSON::Schema::Draft201909->new;
  my $schema1 = {
    allOf => [
      { '$id' => 'subschema1.json', type => 'string' },
      { '$id' => 'subschema2.json', type => 'number' },
    ],
  };
  my $schema2 = {
    anyOf => [
      { '$id' => 'subschema3.json', type => 'string' },
      { '$id' => 'subschema4.json', type => 'number' },
    ],
  };

  cmp_deeply(
    $js->evaluate(1, $schema1)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/type',
          absoluteKeywordLocation => 'subschema1.json#/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          error => 'subschema 0 is not valid',
        },
      ],
    },
    'evaluation of schema1',
  );

  my $resource_index1 = +{ $js->_resource_index };
  my $document1 = $resource_index1->{''}{document};

  cmp_deeply(
    $resource_index1,
    {
      '' => {
        path => '',
        canonical_uri => str(''),
        document => shallow($document1),
      },
      'subschema1.json' => {
        path => '/allOf/0',
        canonical_uri => str('subschema1.json'),
        document => shallow($document1),
      },
      'subschema2.json' => {
        path => '/allOf/1',
        canonical_uri => str('subschema2.json'),
        document => shallow($document1),
      },
    },
    'resources in initial schema are indexed',
  );

  cmp_deeply(
    $js->evaluate(1, $schema2)->TO_JSON,
    {
      valid => bool(1),
    },
    'successful evaluation of schema2',
  );

  my $resource_index2 = +{ $js->_resource_index };
  my $document2 = $resource_index2->{'subschema3.json'}{document};

  cmp_deeply(
    $resource_index2,
    {
      '' => {
        path => '',
        canonical_uri => str(''),
        document => shallow($document2),    # same uri as earlier, but now points to document2
      },
      'subschema1.json' => {
        path => '/allOf/0',
        canonical_uri => str('subschema1.json'),
        document => shallow($document1),    # still here! there is no reason to forget about it
      },
      'subschema2.json' => {
        path => '/allOf/1',
        canonical_uri => str('subschema2.json'),
        document => shallow($document1),    # still here! there is no reason to forget about it
      },
      'subschema3.json' => {
        path => '/anyOf/0',
        canonical_uri => str('subschema3.json'),
        document => shallow($document2),
      },
      'subschema4.json' => {
        path => '/anyOf/1',
        canonical_uri => str('subschema4.json'),
        document => shallow($document2),
      },
    },
    'resources in second schema are indexed; all resources from first schema are preserved except uri=""',
  );
};

subtest 'multiple documents, each using canonical_uri = "", collisions in other resources' => sub {
  my $js = JSON::Schema::Draft201909->new;
  my $schema1 = {
    allOf => [
      { '$id' => 'subschema1.json', type => 'string' },
      { '$id' => 'subschema2.json', type => 'number' },
    ],
  };
  my $schema2 = {
    anyOf => [
      { '$id' => 'subschema1.json', type => 'string' },
      { '$id' => 'subschema3.json', type => 'number' },
    ],
  };

  cmp_deeply(
    $js->evaluate(1, $schema1)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/type',
          absoluteKeywordLocation => 'subschema1.json#/type',
          error => 'wrong type (expected string)',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          error => 'subschema 0 is not valid',
        },
      ],
    },
    'evaluation of schema1',
  );

  my $resource_index1 = +{ $js->_resource_index };
  my $document1 = $resource_index1->{''}{document};

  cmp_deeply(
    $resource_index1,
    {
      '' => {
        path => '',
        canonical_uri => str(''),
        document => shallow($document1),
      },
      'subschema1.json' => {
        path => '/allOf/0',
        canonical_uri => str('subschema1.json'),
        document => shallow($document1),
      },
      'subschema2.json' => {
        path => '/allOf/1',
        canonical_uri => str('subschema2.json'),
        document => shallow($document1),
      },
    },
    'resources in initial schema are indexed',
  );

  cmp_deeply(
    $js->evaluate(1, $schema2)->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          error => re(qr/^EXCEPTION: uri "subschema1.json" conflicts with an existing schema resource/),
          instanceLocation => '',
          keywordLocation => '',
        },
      ],
    },
    'schema2 cannot be evaluated - an internal $id collides with an existing resource',
  );
};

subtest 'resource collisions in canonical uris' => sub {
  my $js = JSON::Schema::Draft201909->new;
  $js->add_schema({ '$id' => 'https://foo.com/x/y/z' });

  cmp_deeply(
    $js->evaluate(1, { '$id' => 'https://foo.com', anyOf => [ { '$id' => '/x/y/z' } ] })->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => re(qr{^EXCEPTION: uri "https://foo.com/x/y/z" conflicts with an existing schema resource}),
        }
      ],
    },
    'detected collision between a document\'s initial uri and a document\'s subschema\'s uri',
  );

  $js = JSON::Schema::Draft201909->new;
  $js->add_schema({
    '$id' => 'https://foo.com',
    anyOf => [ { '$id' => '/x/y/z' } ],
  });

  cmp_deeply(
    $js->evaluate(1, { allOf => [ { '$id' => 'https://foo.com/x/y/z' } ] })->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => re(qr{^EXCEPTION: uri "https://foo.com/x/y/z" conflicts with an existing schema resource}),
        }
      ],
    },
    'detected collision between two document subschema uris',
  );
};

subtest 'relative uri in $id' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate(
      1,
      {
        '$id' => 'foo/bar/baz.json',
        type => 'object',
      },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/type',
          absoluteKeywordLocation => 'foo/bar/baz.json#/type',
          error => 'wrong type (expected object)',
        },
      ],
    },
    'root schema location is correctly identified',
  );

  cmp_deeply(
    JSON::Schema::Draft201909->new->evaluate(
      [ 1, [ 2, 3 ] ],
      {
        '$id' => 'foo/bar/baz.json',
        type => [ 'integer', 'array' ],
        items => { '$ref' => '#' },
      },
    )->TO_JSON,
    {
      valid => true,
    },
    'properly able to traverse a recursive schema using a relative $id',
  );
};

done_testing;
