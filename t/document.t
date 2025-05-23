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

use Test::Deep::UnorderedPairs;
use Test::Fatal;
use Test::Memory::Cycle;
use List::Util 'unpairs';
use lib 't/lib';
use Helper;

# spec version -> vocab classes
my %vocabularies = unpairs(JSON::Schema::Modern->new->__all_metaschema_vocabulary_classes);

my %configs = (
  specification_version => 'draft2020-12',
  vocabularies => $vocabularies{'draft2020-12'},
  configs => {},
);

subtest 'boolean document' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(schema => false),
    listmethods(
      resource_index => [
        '' => {
          path => '',
          canonical_uri => str(''),
          %configs,
        },
      ],
      original_uri => [ str('') ],
      canonical_uri => [ str('') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { '' => 0 } ],
    ),
    'boolean schema with no canonical_uri',
  );

  like(
    exception {
      JSON::Schema::Modern::Document->new(
        canonical_uri => Mojo::URL->new('https://foo.com#/x/y/z'),
        schema => false,
      )
    },
    qr/Reference .*did not pass type constraint/,
    'boolean schema with invalid canonical_uri (fragment)',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => false,
    ),
    listmethods(
      resource_index => [
        'https://foo.com' => {
          path => '',
          canonical_uri => str('https://foo.com'),
          %configs,
        },
      ],
      canonical_uri => [ str('https://foo.com') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { '' => 0 } ],
    ),
    'boolean schema with valid canonical_uri',
  );
};

subtest 'object document' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      defined $_ ? ( canonical_uri => $_ ) : (),
      schema => {},
    ),
    listmethods(
      resource_index => [
        str($_//'') => {
          path => '',
          canonical_uri => str($_//''),
          %configs,
        },
      ],
      original_uri => [ str($_//'') ],
      canonical_uri => [ str($_//'') ],
      _entities => [ { '' => 0 } ],
    ),
    'object schema with originally provided uri = \''.($_//'<undef>').'\' and no root $id',
  )
  foreach (undef, '', '0', Mojo::URL->new, Mojo::URL->new(''), Mojo::URL->new('0'));

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => {},
    ),
    listmethods(
      resource_index => [
        # note: no '' entry!
        'https://foo.com' => {
          path => '',
          canonical_uri => str('https://foo.com'),
          %configs,
        },
      ],
      original_uri => [ str('https://foo.com') ],
      canonical_uri => [ str('https://foo.com') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { '' => 0 } ],
    ),
    'object schema with valid canonical_uri, no root $id',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      defined $_ ? ( canonical_uri => $_ ) : (),
      schema => { '$id' => 'https://foo.com' },
    ),
    listmethods(
      resource_index => [
        # note: no '' entry
        'https://foo.com' => {
          path => '',
          canonical_uri => str('https://foo.com'),
          %configs,
        },
      ],
      original_uri => [ str($_//'') ],
      canonical_uri => [ str('https://foo.com') ], # note canonical_uri has been overwritten
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { '' => 0 } ],
    ),
    'object schema with originally provided uri = \''.($_//'<undef>').'\' and absolute root $id',
  )
  foreach (undef, '', Mojo::URL->new);

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => $_,
      schema => { '$id' => 'https://bar.com' },
    ),
    listmethods(
      resource_index => [
        # note: no '' entry
        'https://bar.com' => {
          path => '',
          canonical_uri => str('https://bar.com'),
          %configs,
        },
      ],
      original_uri => [ str($_) ],
      canonical_uri => [ str('https://bar.com') ], # note canonical_uri has been overwritten
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { '' => 0 } ],
    ),
    'originally provided uri is not indexed when overridden by an absolute root $id',
  )
  foreach ('0', Mojo::URL->new('0'), 'https://foo.com');

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$defs' => { foo => {} },
      },
      canonical_uri => 'https://example.com',
    ),
    listmethods(
      resource_index => [
        'https://example.com' => {
          path => '',
          canonical_uri => str('https://example.com'),
          %configs,
        },
      ],
    ),
    'when canonical_uri provided, the empty uri is not added as a referenceable uri',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => { '$id' => 'https://foo.com' },
    ),
    listmethods(
      resource_index => [
        'https://foo.com' => {
          path => '',
          canonical_uri => str('https://foo.com'),
          %configs,
        },
      ],
      original_uri => [ str('https://foo.com') ],
      canonical_uri => [ str('https://foo.com') ],
      _entities => [ { '' => 0 } ],
    ),
    'object schema with originally provided uri equal to root $id',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
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
        'https://bar.com' => {
          path => '',
          canonical_uri => str('https://bar.com'),
          %configs,
          anchors => {
            my_anchor => {
              path => '/allOf/0',
              canonical_uri => str('https://bar.com#/allOf/0'),
            },
          },
        },
        'https://bar.com/x/y/z.json' => {
          path => '/allOf/1',
          canonical_uri => str('https://bar.com/x/y/z.json'),
          %configs,
        },
      ),
      original_uri => [ str('https://foo.com') ],
      canonical_uri => [ str('https://bar.com') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { map +($_ => 0), '', '/allOf/0', '/allOf/1' } ],
    ),
    'object schema with canonical_uri and root $id, and additional resource schemas as well',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$id' => 'relative',
      },
      canonical_uri => 'https://my-base.com',
    ),
    listmethods(
      resource_index => [
        'https://my-base.com/relative' => {
          path => '',
          canonical_uri => str('https://my-base.com/relative'),
          %configs,
        },
      ],
      original_uri => [ str('https://my-base.com') ],
      canonical_uri => [ str('https://my-base.com/relative') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { '' => 0 } ],
    ),
    'relative $id at root is resolved against provided canonical_id',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
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
        '' => {
          path => '', canonical_uri => str(''),
          %configs,
        },
        'my_foo' => {
          path => '/$defs/foo',
          canonical_uri => str('my_foo'),
          %configs,
        },
      ),
      original_uri => [ str('') ],
      canonical_uri => [ str('') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { map +($_ => 0), '', '/$defs/foo' } ],
    ),
    'relative uri for inner $id',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
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
        '' => {
          path => '', canonical_uri => str(''),
          %configs,
        },
        'http://localhost:4242/my_foo' => {
          path => '/$defs/foo',
          canonical_uri => str('http://localhost:4242/my_foo'),
          %configs,
        },
      ),
      original_uri => [ str('') ],
      canonical_uri => [ str('') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
      _entities => [ { map +($_ => 0), '', '/$defs/foo' } ],
    ),
    'no root $id; absolute uri with path in subschema resource',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$anchor' => 'my_anchor',
      },
    ),
    listmethods(
      resource_index => [
        '' => {
          path => '',
          canonical_uri => str(''),
          %configs,
          anchors => {
            my_anchor => {
              path => '',
              canonical_uri => str(''),
            },
          },
        },
      ],
      original_uri => [ str('') ],
      canonical_uri => [ str('') ],
    ),
    'no root $id or canonical_uri provided; anchor is indexed at the root',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$anchor' => 'my_anchor',
      },
      canonical_uri => 'https://example.com',
    ),
    listmethods(
      resource_index => [
        'https://example.com' => {
          path => '',
          canonical_uri => str('https://example.com'),
          %configs,
          anchors => {
            my_anchor => {
              path => '',
              canonical_uri => str('https://example.com'),
            },
          },
        },
      ],
      original_uri => [ str('https://example.com') ],
      canonical_uri => [ str('https://example.com') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
    ),
    'canonical_uri provided; empty uri not added as a referenceable uri when an anchor exists',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$id' => 'https://my-base.com',
        '$anchor' => 'my_anchor',
      },
    ),
    listmethods(
      resource_index => [
        'https://my-base.com' => {
          path => '',
          canonical_uri => str('https://my-base.com'),
          %configs,
          anchors => {
            my_anchor => {
              path => '',
              canonical_uri => str('https://my-base.com'),
            },
          },
        },
      ],
      original_uri => [ str('') ],
      canonical_uri => [ str('https://my-base.com') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
    ),
    'absolute uri provided at root; adjacent anchor has the same canonical uri',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$id' => 'https://my-base.com',
        '$defs' => {
          foo => {
            '$anchor' => 'my_anchor',
          },
        },
      },
    ),
    listmethods(
      resource_index => [
        'https://my-base.com' => {
          path => '',
          canonical_uri => str('https://my-base.com'),
          %configs,
          anchors => {
            my_anchor => {
              path => '/$defs/foo',
              canonical_uri => str('https://my-base.com#/$defs/foo'),
            },
          },
        },
      ],
      original_uri => [ str('') ],
      canonical_uri => [ str('https://my-base.com') ],
      metaschema_uri => [ str(JSON::Schema::Modern::METASCHEMA_URIS->{'draft2020-12'}) ],
    ),
    'absolute uri provided at root; anchor lower down has its own canonical uri',
  );
};

subtest '$id and $anchor as properties' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
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
        '' => {
          path => '',
          canonical_uri => str(''),
          %configs,
        },
      ],
      _entities => [ { map +($_ => 0), '', '/properties/$id', '/properties/$anchor' } ],
    ),
    'did not index the $id and $anchor properties as if they were identifier keywords',
  );
};

subtest '$id with an empty fragment' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
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
        '' => {
          path => '', canonical_uri => str(''), specification_version => 'draft2020-12',
          vocabularies => $vocabularies{'draft2020-12'},
          configs => {},
        },
        'http://localhost:4242/my_foo' => {
          path => '/$defs/foo',
          canonical_uri => str('http://localhost:4242/my_foo'),
          %configs,
        },
      ),
      _entities => [ { map +($_ => 0), '', '/$defs/foo' } ],
    ),
    '$id is stored with the empty fragment stripped',
  );
};

subtest '$id with a non-empty fragment' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$id' => 'http://main.com',
        '$defs' => {
          foo => {
            '$id' => 'http://secondary.com',
            properties => {
              bar => {
                '$id' => 'http://localhost:4242/my_foo#hello',
              },
            },
          },
        },
      },
    ),
    all(
      methods(canonical_uri => str('http://main.com')),
      listmethods(
        resource_index => [],
        errors => [
          methods(TO_JSON => {
            instanceLocation => '',
            keywordLocation => '/$defs/foo/properties/bar/$id',
            absoluteKeywordLocation => 'http://secondary.com#/properties/bar/$id',
            error => '$id value "http://localhost:4242/my_foo#hello" cannot have a non-empty fragment',
          }),
        ],
      ),
    ),
    'did not index the $id with a non-empty fragment, nor use it as the base for other identifiers',
  );
};

subtest '$anchor not conforming to syntax' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => {
        '$defs' => {
          foo => {
            '$anchor' => 'my_#bad_anchor',
          },
        },
      },
    ),
    listmethods(
      resource_index => [],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/$defs/foo/$anchor',
          error => '$anchor value "my_#bad_anchor" does not match required syntax',
        }),
      ],
    ),
    'did not index an $anchor with invalid characters',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      specification_version => 'draft7',
      schema => {
        definitions => {
          foo => {
            '$id' => '#my_$bad_anchor',
          },
          qux => {
            '$id' => 'https://foo.com#my_bad_id',
          },
        },
      },
    ),
    listmethods(
      resource_index => [],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/definitions/foo/$id',
          error => '$id value "#my_$bad_anchor" does not match required syntax',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/definitions/qux/$id',
          error => '$id cannot change the base uri at the same time as declaring an anchor',
        }),
      ],
    ),
    'did not index a draft7 fragment-only $id with invalid characters, or non-fragment-only $id',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      specification_version => 'draft4',
      schema => {
        definitions => {
          foo => {
            id => '#my_$bad_anchor',
          },
          qux => {
            id => 'https://foo.com#my_bad_id',
          },
        },
      },
    ),
    listmethods(
      resource_index => [],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/definitions/foo/id',
          error => 'id value "#my_$bad_anchor" does not match required syntax',
        }),
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/definitions/qux/id',
          error => 'id cannot change the base uri at the same time as declaring an anchor',
        }),
      ],
    ),
    'did not index a draft4 fragment-only $id with invalid characters, or non-fragment-only id',
  );
};

subtest '$schema not conforming to syntax' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      schema => { '$schema' => 'foo' },
    ),
    listmethods(
      canonical_uri => [ str('') ],
      metaschema_uri => [ str('https://json-schema.org/draft/2020-12/schema') ],
      resource_index => [],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => '"foo" is not a valid URI',
        }),
      ],
    ),
    'invalid $schema is detected',
  );
};

subtest '$anchor and $id below an $id that is not at the document root' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
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
          specification_version => 'draft2020-12',
          vocabularies => $vocabularies{'draft2020-12'},
          configs => {},
        },
        'https://bar.com' => {
          path => '/allOf/0', canonical_uri => str('https://bar.com'),
          %configs,
          anchors => {
            my_anchor => {
              path => '/allOf/0',
              canonical_uri => str('https://bar.com'),
            },
            my_not => {
              path => '/allOf/0/not',
              canonical_uri => str('https://bar.com#/not'),
            },
          },
        },
        'https://bar.com/inner_id' => {
          path => '/allOf/0/not/not', canonical_uri => str('https://bar.com/inner_id'),
          %configs,
        },
      ),
      _entities => [ { map +($_ => 0), '', '/allOf/0', '/allOf/0/not', '/allOf/0/not/not' } ],
    ),
    'canonical_uri uses the path from the innermost $id, not document root $id',
  );
};

subtest 'JSON pointer and URI escaping' => sub {
  cmp_deeply(
    my $doc = JSON::Schema::Modern::Document->new(
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
        '' => {
          path => '', canonical_uri => str(''), specification_version => 'draft2020-12',
          vocabularies => $vocabularies{'draft2020-12'},
          configs => {},
        },
        'http://localhost:4242/~username' => {
          path => '/$defs/foo/patternProperties/~0',
          canonical_uri => str('http://localhost:4242/~username'),
          %configs,
          anchors => {
            tilde => {
              path => '/$defs/foo/patternProperties/~0/properties/~0~1',
              canonical_uri => str('http://localhost:4242/~username#/properties/~0~1'),
            },
          },
        },
        'http://localhost:4242/my_slash' => {
          path => '/$defs/foo/patternProperties/~1',
          canonical_uri => str('http://localhost:4242/my_slash'),
          %configs,
          anchors => {
            slash => {
              path => '/$defs/foo/patternProperties/~1/properties/~0~1',
              canonical_uri => str('http://localhost:4242/my_slash#/properties/~0~1'),
            },
          },
        },
        'http://localhost:4242/~username/my_slash' => {
          path => '/$defs/foo/patternProperties/[~0~1]',
          canonical_uri => str('http://localhost:4242/~username/my_slash'),
          %configs,
          anchors => {
            tildeslash => {
              path => '/$defs/foo/patternProperties/[~0~1]/properties/~0~1',
              canonical_uri => str('http://localhost:4242/~username/my_slash#/properties/~0~1'),
            },
          },
        },
      ),
      _entities => [ { map +($_ => 0),
        my @locations = (
          '',
          '/$defs/foo',
          '/$defs/foo/patternProperties/~0',
          '/$defs/foo/patternProperties/~0/properties/~0~1',
          '/$defs/foo/patternProperties/~1',
          '/$defs/foo/patternProperties/~1/properties/~0~1',
          '/$defs/foo/patternProperties/[~0~1]',
          '/$defs/foo/patternProperties/[~0~1]/properties/~0~1',
        )
      }],
    ),
    'properly escaped special characters in JSON pointers and URIs',
  );
  is($doc->get_entity_at_location('/$defs/foo/patternProperties/~0'), 'schema', 'schema locations are tracked');
  is($doc->get_entity_at_location('/$defs/foo/patternProperties'), '', 'non-schema locations are also tracked');

  cmp_deeply(
    [ $doc->get_entity_locations('schema') ],
    bag(@locations),
    'schema locations can be queried',
  );
};

subtest 'resource collisions' => sub {
  is(
    exception {
      JSON::Schema::Modern::Document->new(
        canonical_uri => Mojo::URL->new('https://foo.com/x/y/z'),
        schema => { '$id' => '/x/y/z' },
      );
    },
    undef,
    'no collision when adding an identical resource (after resolving with base uri)',
  );

  like(
    exception {
      JSON::Schema::Modern::Document->new(
        canonical_uri => Mojo::URL->new('https://foo.com/x/y/z'),
        schema => {
          allOf => [
            { '$id' => '/x/y/z' },
            { '$id' => '/a/b/c' },
          ],
        },
      );
    },
    qr{^\Quri "https://foo.com/x/y/z" conflicts with an existing schema resource\E},
    'detected collision between document\'s initial uri and a subschema\'s uri',
  );

  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => Mojo::URL->new('https://foo.com'),
      schema => {
        allOf => [
          { '$id' => '/x/y/z' },
          { '$id' => '/x/y/z' },
        ],
      },
    ),
    all(
      listmethods(
        resource_index => [],
        errors => [
          methods(TO_JSON => {
            instanceLocation => '',
            keywordLocation => '/allOf/1/$id',
            absoluteKeywordLocation => 'https://foo.com#/allOf/1/$id',
            error => 'duplicate canonical uri "https://foo.com/x/y/z" found (original at path "/allOf/0")',
          }),
        ],
      ),
    ),
    'detected collision between two subschema uris in a document',
  );


  my $doc1 = JSON::Schema::Modern::Document->new(schema => { '$id' => 'a/b' });
  my $doc2 = JSON::Schema::Modern::Document->new(schema => { '$id' => 'b' });
  my $js = JSON::Schema::Modern->new;

  is(
    # id resolves to https://foo.com/a/b
    exception { $js->add_document('https://foo.com' => $doc1) },
    undef,
    'add first document, resolving resources to a base uri',
  );

  like(
    # id resolves to https://foo.com/a/b
    exception { $js->add_document('https://foo.com/a/' => $doc2) },
    qr{^uri "https://foo.com/a/b" conflicts with an existing schema resource},
    'the resource in the second document resolves to the same uri as from the first document',
  );


  is(
    exception {
      JSON::Schema::Modern::Document->new(
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
};

subtest 'create document with explicit canonical_uri set to the same as root $id' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => 'https://foo.com/x/y/z',
      schema => { '$id' => 'https://foo.com/x/y/z' },
    ),
    listmethods(
      resource_index => [
        'https://foo.com/x/y/z' => {
          path => '',
          canonical_uri => str('https://foo.com/x/y/z'),
          %configs,
        },
      ],
      canonical_uri => [ str('https://foo.com/x/y/z') ],
    ),
    'there is one single uri indexed to the document',
  );
};

subtest 'canonical_uri identification from a document with errors' => sub {
  cmp_deeply(
    JSON::Schema::Modern::Document->new(
      canonical_uri => 'https://foo.com/x/y/z',
      schema => {
        '$id' => 'https://bar.com',
        allOf => [
          {
            '$id' => 'https://baz.com',
            oneOf => [
              { '$id' => 'https://quux.com' },
              [ 'not a subschema' ],
            ],
          },
        ],
      },
    ),
    listmethods(
      canonical_uri => [ str('https://bar.com') ],
      errors => [
        methods(TO_JSON => {
          instanceLocation => '',
          keywordLocation => '/allOf/0/oneOf/1',
          absoluteKeywordLocation => 'https://baz.com#/oneOf/1',
          error => 'invalid schema type: array',
        }),
      ],
    ),
    'error lower down in document does not result in an inner identifier being used as canonical_uri',
  );
};

subtest 'custom metaschema_uri' => sub {
  my $js = JSON::Schema::Modern->new;
  $js->add_schema({
    '$id' => 'https://my/first/metaschema',
    '$vocabulary' => {
      'https://json-schema.org/draft/2020-12/vocab/applicator' => true,
      'https://json-schema.org/draft/2020-12/vocab/core' => true,
      # note: no validation!
    },
  });

  my $doc = $js->add_document(JSON::Schema::Modern::Document->new(
    schema => {
      '$id' => my $id = 'https://my/first/schema/with/custom/metaschema',
      # note: no $schema keyword!
      allOf => [ { minimum => 'not even an integer' } ],
    },
    metaschema_uri => 'https://my/first/metaschema',
    evaluator => $js,  # needed in order to find the metaschema
  ));

  cmp_deeply(
    $js->{_resource_index}{$id}{document},
    methods(
      canonical_uri => str($id),
      metaschema_uri => str('https://my/first/metaschema'),
    ),
    'document contains correct values',
  );

  cmp_result(
    $js->{_resource_index}{$id},
    {
      canonical_uri => str($id),
      path => '',
      specification_version => 'draft2020-12',
      document => $doc,
      vocabularies => [
        map 'JSON::Schema::Modern::Vocabulary::'.$_,
          qw(Core Applicator),
      ],
      configs => {},
    },
    'determined vocabularies to use for this schema',
  );

  cmp_result(
    $js->evaluate(1, $id)->TO_JSON,
    { valid => true },
    'validation succeeds because "minimum" never gets run',
  );
  cmp_result(
    $js->evaluate(1, Mojo::URL->new($id)->fragment('/allOf/0'))->TO_JSON,
    { valid => true },
    'can evaluate at a subschema as well, with the same vocabularies',
  );

  cmp_result(
    $doc->validate->TO_JSON,
    { valid => true },
    'schema validates against its metaschema, and "minimum" is ignored',
  );

  memory_cycle_ok($js, 'no leaks in the evaluator object');
};

subtest 'multiple uris used for resolution and identification, and original_uri' => sub {
  my $js = JSON::Schema::Modern->new;
  my $doc = $js->add_document(
    'https://example.com/api/' => JSON::Schema::Modern::Document->new(
      canonical_uri => 'staging/',
      schema => {
        '$id' => 'alpha.json',  # https://example.com/staging/alpha.json
        properties => {
          foo => { '$id' => 'beta', not => true }, # https://example.com/staging/beta
        },
        not => true,
      },
      evaluator => $js,
    )
  );

  cmp_deeply(
    $doc,
    listmethods(
      original_uri => [ str('staging/') ],
      canonical_uri => [ str('staging/alpha.json') ],
      resource_index => unordered_pairs(
        'staging/alpha.json' => {
          path => '',
          canonical_uri => str('staging/alpha.json'),
          %configs,
        },
        'staging/beta' => {
          canonical_uri => str('staging/beta'),
          path => '/properties/foo',
          %configs,
        },
      ),
    ),
    'document has correct resources, resolved against the provided base uri',
  );

  cmp_deeply(
    $js->{_resource_index},
    my $resource_index = {
      'https://example.com/api/' => {
        path => '',
        canonical_uri => str('https://example.com/api/staging/alpha.json'),
        document => $doc,
        %configs,
      },
      'https://example.com/api/staging/alpha.json' => {
        path => '',
        canonical_uri => str('https://example.com/api/staging/alpha.json'),
        document => $doc,
        %configs,
      },
      'https://example.com/api/staging/beta' => {
        path => '/properties/foo',
        canonical_uri => str('https://example.com/api/staging/beta'),
        document => $doc,
        %configs,
      },
    },
    'evaluator has correct resources, resolved against the provided base uri',
  );

  cmp_deeply(
    $js->evaluate({ foo => 1 }, 'https://example.com/api/staging/alpha.json')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          absoluteKeywordLocation => 'https://example.com/api/staging/alpha.json#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/not',
          absoluteKeywordLocation => 'https://example.com/api/staging/beta#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'https://example.com/api/staging/alpha.json#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'when evaluating the document using the canonical uri, error locations use the canonical uri',
  );

  cmp_deeply(
    $js->evaluate({ foo => 1 }, 'https://example.com/api/')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          absoluteKeywordLocation => 'https://example.com/api/staging/alpha.json#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/not',
          absoluteKeywordLocation => 'https://example.com/api/staging/beta#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'https://example.com/api/staging/alpha.json#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'when evaluating the document using a retrieval uri, error locations still use the canonical uri',
  );

  my $doc2 = $js->add_document('file:///usr/local/share/api.json' => $doc);
  is($doc2, $doc, 'same document is added a second time');

  cmp_deeply(
    $js->{_resource_index},
    {
      %$resource_index, # original entries

      'file:///usr/local/share/api.json' => {
        path => '',
        canonical_uri => str('file:///usr/local/share/staging/alpha.json'),
        document => $doc,
        %configs,
      },
      'file:///usr/local/share/staging/alpha.json' => {
        path => '',
        canonical_uri => str('file:///usr/local/share/staging/alpha.json'),
        document => $doc,
        %configs,
      },
      'file:///usr/local/share/staging/beta' => {
        path => '/properties/foo',
        canonical_uri => str('file:///usr/local/share/staging/beta'),
        document => $doc,
        %configs,
      },
    },
    'document resources are added using the new base, which appears in their canonical_uri values',
  );

  cmp_deeply(
    $js->evaluate({ foo => 1 }, 'https://example.com/api/')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          absoluteKeywordLocation => 'https://example.com/api/staging/alpha.json#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/not',
          absoluteKeywordLocation => 'https://example.com/api/staging/beta#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'https://example.com/api/staging/alpha.json#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'when evaluating using the first base uri, error locations are relative to the provided base uri',
  );

  # there are multiple resources mapped to the same document+path locations, but we want error
  # locations to be using the set that we used in the evaluation call.
  cmp_deeply(
    $js->evaluate({ foo => 1 }, 'file:///usr/local/share/api.json')->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/not',
          absoluteKeywordLocation => 'file:///usr/local/share/staging/alpha.json#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '/foo',
          keywordLocation => '/properties/foo/not',
          absoluteKeywordLocation => 'file:///usr/local/share/staging/beta#/not',
          error => 'subschema is true',
        },
        {
          instanceLocation => '',
          keywordLocation => '/properties',
          absoluteKeywordLocation => 'file:///usr/local/share/staging/alpha.json#/properties',
          error => 'not all properties are valid',
        },
      ],
    },
    'when evaluating using the second base uri, error locations are relative to the original evaluation location',
  );
};

done_testing;
