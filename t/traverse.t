use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use if "$]" >= 5.022, experimental => 're_strict';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use JSON::Schema::Modern::Utilities 'canonical_schema_uri';

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
      '$ref' => sub {
        my ($schema, $state) = @_;
        my $canonical_uri = canonical_schema_uri($state);
        my $ref_uri = Mojo::URL->new($schema->{'$ref'});
        $ref_uri = $ref_uri->to_abs($canonical_uri) if not $ref_uri->is_abs;
        $refs{$state->{traversed_schema_path}.$state->{schema_path}} = $ref_uri->to_string;
      },
      if => sub { $if_callback_called = 1; },
    }});

  cmp_deeply(
    [ map $_->TO_JSON, @{$state->{errors}} ],
    [
      {
        instanceLocation => '',
        keywordLocation => '/if',
        absoluteKeywordLocation => 'https://foo.com#/if',
        error => 'invalid schema type: number',
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
    [ map $_->TO_JSON, @{$state->{errors}} ],
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

done_testing;
