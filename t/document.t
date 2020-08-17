use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use Test::Deep::UnorderedPairs;
use Test::Fatal;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

subtest 'boolean document' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(schema => false),
    listmethods(
      resource_index => [
        '' => {
          path => '',
          canonical_uri => str(''),
        },
      ],
      canonical_uri => [ str('') ],
    ),
    'boolean schema with no canonical_uri',
  );

  like(
    exception {
      JSON::Schema::Draft201909::Document->new(
        canonical_uri => Mojo::URL->new('https://foo.com#/x/y/z'),
        schema => false,
      )
    },
    qr/canonical_uri cannot contain a fragment/,
    'boolean schema with invalid canonical_uri (fragment)',
  );

  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => false,
    ),
    listmethods(
      resource_index => [
        'https://foo.com' => {
          path => '',
          canonical_uri => str('https://foo.com'),
        },
      ],
      canonical_uri => [ str('https://foo.com') ],
    ),
    'boolean schema with valid canonical_uri',
  );
};

subtest 'object document' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(schema => {}),
    listmethods(
      resource_index => [
        '' => {
          path => '',
          canonical_uri => str(''),
        },
      ],
      canonical_uri => [ str('') ],
    ),
    'object schema with no canonical_uri, no root $id',
  );

  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => {},
    ),
    listmethods(
      resource_index => [
        # note: no '' entry!
        'https://foo.com' => {
          path => '',
          canonical_uri => str('https://foo.com'),
        },
      ],
      canonical_uri => [ str('https://foo.com') ],
    ),
    'object schema with valid canonical_uri, no root $id',
  );

  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      defined $_ ? ( canonical_uri => $_ ) : (),
      schema => { '$id' => 'https://bar.com' },
    ),
    listmethods(
      resource_index => [
        # note: no '' entry!
        'https://bar.com' => {
          path => '',
          canonical_uri => str('https://bar.com'),
        },
      ],
      canonical_uri => [ str('https://bar.com') ], # note canonical_uri has been overwritten
    ),
    'object schema with no canonical_uri, and absolute root $id',
  )
  foreach (undef, '', Mojo::URL->new);

  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => {
        '$id' => 'https://bar.com',
        allOf => [
          { '$anchor' => 'my_anchor' },
          { '$id' => 'x/y/z.json' },
        ],
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        'https://foo.com' => {  # the originally-provided uri is only used for the root schema
          path => '',
          canonical_uri => str('https://bar.com'),
        },
        'https://bar.com' => {
          path => '',
          canonical_uri => str('https://bar.com'),
        },
        'https://bar.com#my_anchor' => {
          path => '/allOf/0',
          canonical_uri => str('https://bar.com#/allOf/0'),
        },
        'https://bar.com/x/y/z.json' => {
          path => '/allOf/1',
          canonical_uri => str('https://bar.com/x/y/z.json'),
        },
      ),
      canonical_uri => [ str('https://bar.com') ],
    ),
    'object schema with canonical_uri and root $id, and additional resource schemas as well',
  );

  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        '$defs' => {
          foo => {
            '$id' => 'my_foo',
            const => 'foo value',
          },
        },
        '$ref' => 'my_foo',
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        '' => { path => '', canonical_uri => str('') },
        'my_foo' => {
          path => '/$defs/foo',
          canonical_uri => str('my_foo'),
        },
      ),
    ),
    'relative uri for root $id',
  );

  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        '$defs' => {
          foo => {
            '$id' => 'http://localhost:4242/my_foo',
            const => 'foo value',
          },
        },
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        '' => { path => '', canonical_uri => str('') },
        'http://localhost:4242/my_foo' => {
          path => '/$defs/foo',
          canonical_uri => str('http://localhost:4242/my_foo'),
        },
      ),
    ),
    'no root $id; absolute uri with path in subschema resource',
  );
};

subtest '$id and $anchor as properties' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        type => 'object',
        properties => {
          '$id' => { type => 'string' },
          '$anchor' => { type => 'string' },
        },
      },
    ),
    listmethods(
      resource_index => [
        '' => { path => '', canonical_uri => str('') },
      ],
    ),
    'did not index the $id and $anchor properties as if they were identifier keywords',
  );
};

subtest '$id with an empty fragment' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        '$defs' => {
          foo => {
            '$id' => 'http://localhost:4242/my_foo#',
            type => 'string',
          },
        },
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        '' => { path => '', canonical_uri => str('') },
        'http://localhost:4242/my_foo' => {
          path => '/$defs/foo',
          canonical_uri => str('http://localhost:4242/my_foo'),
        },
      ),
    ),
    '$id is stored with the empty fragment stripped',
  );
};

subtest '$id with a non-empty fragment' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        '$defs' => {
          foo => {
            '$id' => 'http://localhost:4242/my_foo#hello',
            properties => {
              bar => {
                '$id' => 'my_bar',
                '$anchor' => 'my_anchor',
              },
            },
          },
        },
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        '' => { path => '', canonical_uri => str('') },
        'my_bar' => { path => '/$defs/foo/properties/bar', canonical_uri => str('my_bar') },
        'my_bar#my_anchor' => { path => '/$defs/foo/properties/bar', canonical_uri => str('my_bar') },
      ),
    ),
    'did not index the $id with a non-empty fragment, nor use it as the base for other identifiers',
  );
};

subtest '$anchor not conforming to syntax' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        '$defs' => {
          foo => {
            '$anchor' => 'my_#bad_anchor',
          },
        },
      },
    ),
    listmethods(
      resource_index => [
        '' => { path => '', canonical_uri => str('') },
      ],
    ),
    'did not index an $anchor with invalid characters',
  );
};

subtest '$anchor and $id below an $id that is not at the document root' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => {
        allOf => [
          {
            '$id' => 'https://bar.com',
            '$anchor' => 'my_anchor',
            not => {
              '$anchor' => 'my_not',
              not => { '$id' => 'inner_id' },
            },
          },
        ],
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        'https://foo.com' => {
          path => '', canonical_uri => str('https://foo.com'),
        },
        'https://bar.com' => {
          path => '/allOf/0', canonical_uri => str('https://bar.com'),
        },
        'https://bar.com#my_anchor' => {
          path => '/allOf/0', canonical_uri => str('https://bar.com'),
        },
        'https://bar.com#my_not' => {
          path => '/allOf/0/not', canonical_uri => str('https://bar.com#/not'),
        },
        'https://bar.com/inner_id' => {
          path => '/allOf/0/not/not', canonical_uri => str('https://bar.com/inner_id'),
        },
      ),
    ),
    'canonical_uri uses the path from the innermost $id, not document root $id',
  );
};

subtest 'JSON pointer and URI escaping' => sub {
  cmp_deeply(
    JSON::Schema::Draft201909::Document->new(
      schema => {
        '$defs' => {
          foo => {
            patternProperties => {
              '~' => {
                '$id' => 'http://localhost:4242/~username',
                properties => {
                  '~/' => {
                    '$anchor' => 'tilde',
                  },
                },
              },
              '/' => {
                '$id' => 'http://localhost:4242/my_slash',
                properties => {
                  '~/' => {
                    '$anchor' => 'slash',
                  },
                },
              },
              '[~/]' => {
                '$id' => 'http://localhost:4242/~username/my_slash',
                properties => {
                  '~/' => {
                    '$anchor' => 'tildeslash',
                  },
                },
              },
            },
          },
        },
      },
    ),
    listmethods(
      resource_index => unordered_pairs(
        '' => { path => '', canonical_uri => str('') },
        'http://localhost:4242/~username' => {
          path => '/$defs/foo/patternProperties/~0',
          canonical_uri => str('http://localhost:4242/~username'),
        },
        'http://localhost:4242/my_slash' => {
          path => '/$defs/foo/patternProperties/~1',
          canonical_uri => str('http://localhost:4242/my_slash'),
        },
        'http://localhost:4242/~username/my_slash' => {
          path => '/$defs/foo/patternProperties/[~0~1]',
          canonical_uri => str('http://localhost:4242/~username/my_slash'),
        },
        'http://localhost:4242/~username#tilde' => {
          path => '/$defs/foo/patternProperties/~0/properties/~0~1',
          canonical_uri => str('http://localhost:4242/~username#/properties/~0~1'),
        },
        'http://localhost:4242/my_slash#slash' => {
          path => '/$defs/foo/patternProperties/~1/properties/~0~1',
          canonical_uri => str('http://localhost:4242/my_slash#/properties/~0~1'),
        },
        'http://localhost:4242/~username/my_slash#tildeslash' => {
          path => '/$defs/foo/patternProperties/[~0~1]/properties/~0~1',
          canonical_uri => str('http://localhost:4242/~username/my_slash#/properties/~0~1'),
        },
      ),
    ),
    'properly escaped special characters in JSON pointers and URIs',
  );
};

subtest 'resource collisions' => sub {
  like(
    exception {
      JSON::Schema::Draft201909::Document->new(
        canonical_uri => Mojo::URL->new('https://foo.com/x/y/z'),
        schema => {
          allOf => [
            { '$id' => '/x/y/z' },
            { '$id' => '/a/b/c' },
          ],
        },
      );
    },
    qr{\Quri "https://foo.com/x/y/z" conflicts with an existing schema resource\E},
    'detected collision between document\'s initial uri and a subschema\'s uri',
  );

  like(
    exception {
      JSON::Schema::Draft201909::Document->new(
        canonical_uri => Mojo::URL->new('https://foo.com'),
        schema => {
          allOf => [
            { '$id' => '/x/y/z' },
            { '$id' => '/x/y/z' },
          ],
        },
      );
    },
    qr{\Quri "https://foo.com/x/y/z" conflicts with an existing schema resource\E},
    'detected collision between two subschema uris in a document',
  );

  TODO: {
    local $TODO = 'we need a more sophisticated traverser to detect non-schemas';
    is(
      exception {
        JSON::Schema::Draft201909::Document->new(
          canonical_uri => Mojo::URL->new('https://foo.com/x/y/z'),
          schema => {
            examples => [
              { '$id' => '/x/y/z' },
              { '$id' => 'https://foo.com/x/y/z' },
            ],
            default => {
              allOf => [
                { '$id' => '/x/y/z' },
                { '$id' => 'https://foo.com/x/y/z' },
              ],
            },
          },
        );
      },
      undef,
      'ignored "duplicate" uris embedded in non-schemas',
    );
  }
};

done_testing;
