use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
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
      my $schema = {
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

subtest 'invalid $id and $anchor' => sub {
  my $js = JSON::Schema::Draft201909->new;

  cmp_deeply(
    $js->evaluate(
      1,
      my $schema = {
        '$id' => 'foo.json',
        '$defs' => {
          bad_id => {
            '$id' => 'foo.json#/foo/bar',
          },
          bad_anchor => {
            '$anchor' => 'my$foo',
          },
          const_not_id => {
            const => {
              '$id' => 'not_a_real_id',
            },
          },
          const_not_anchor => {
            const => {
              '$anchor' => 'not_a_real_anchor',
            },
          },
        },
        allOf => [
          {
            if => { const => 'check id' },
            then => { '$ref' => 'foo.json#/$defs/bad_id' },
            else => {
              if => { const => 'check anchor' },
              then => { '$ref' => '#/$defs/bad_anchor' },
            },
          },
          { '$ref' => '#/$defs/const_not_id' },
          { '$ref' => '#/$defs/const_not_anchor' },
        ],
      },
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/1/$ref/const',
          absoluteKeywordLocation => 'foo.json#/$defs/const_not_id/const',
          error => 'value does not match',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf/2/$ref/const',
          absoluteKeywordLocation => 'foo.json#/$defs/const_not_anchor/const',
          error => 'value does not match',
        },
        {
          instanceLocation => '',
          keywordLocation => '/allOf',
          absoluteKeywordLocation => 'foo.json#/allOf',
          error => 'subschemas 1, 2 are not valid',
        },
      ],
    },
    'schema is evaluatable if bad definitions are not traversed',
  );

  cmp_deeply(
    $js->evaluate(
      'check anchor',
      $schema,
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/else/then/$ref/$anchor',
          absoluteKeywordLocation => 'foo.json#/$defs/bad_anchor/$anchor',
          error => 'EXCEPTION: $anchor value "my$foo" does not match required syntax',
        }
      ],
    },
    'evaluation gives an error if bad $anchor is traversed',
  );

  cmp_deeply(
    $js->evaluate(
      'check id',
      $schema,
    )->TO_JSON,
    {
      valid => bool(0),
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/allOf/0/then/$ref/$id',
          absoluteKeywordLocation => 'foo.json#/$defs/bad_id/$id',
          error => 'EXCEPTION: $id value "foo.json#/foo/bar" cannot have a non-empty fragment',
        }
      ],
    },
    'evaluation gives an error if bad $id is traversed',
  );
};

subtest 'nested $ids' => sub {
  my $js = JSON::Schema::Draft201909->new(short_circuit => 0);
  my $schema = {
    '$id' => '/foo/bar/baz.json',
    '$ref' => '/foo/bar/baz.json#/properties/alpha',  # not the canonical URI for this location
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
          error => 'not all properties are valid',
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
      { '$id' => 'subschema1.json', type => 'string' },
      { '$id' => 'subschema3.json', type => 'number' },
    ],
  };
  $js->evaluate(1, $schema1);

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

  $js->evaluate(1, $schema2);

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
        path => '/anyOf/0',
        canonical_uri => str('subschema1.json'),
        document => shallow($document2),    # same uri as earlier, but now points to document2
      },
      # and subschema2.json is gone also
      'subschema3.json' => {
        path => '/anyOf/1',
        canonical_uri => str('subschema3.json'),
        document => shallow($document2),
      },
    },
    'resources in second schema are indexed; all resources from first schema are removed',
  );
};

done_testing;
