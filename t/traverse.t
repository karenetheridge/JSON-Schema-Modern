use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Draft201909;
use JSON::Schema::Draft201909::Utilities 'canonical_schema_uri';

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
    allOf => [
      {},
      { '$ref' => '#/$defs/foo' },
      { '$ref' => '#/$defs/bar' },
    ],
  };

  my %refs;
  my $ref_callback = sub {
    my ($schema, $state) = @_;
    my $canonical_uri = canonical_schema_uri($state);
    my $ref_uri = Mojo::URL->new($schema->{'$ref'});
    $ref_uri = $ref_uri->to_abs($canonical_uri) if not $ref_uri->is_abs;

    $refs{$state->{traversed_schema_path}.$state->{schema_path}} = $ref_uri->to_string;
  };
  my $js = JSON::Schema::Draft201909->new;
  my $state = $js->traverse($schema, { callbacks => { '$ref' => $ref_callback }});

  cmp_deeply(
    $state->{errors},
    [],
    'no errors encountered during traversal',
  );

  cmp_deeply(
    \%refs,
    {
      '/$defs/foo/additionalProperties' => 'https://foo.com/recursive_subschema',
      '/$defs/bar/properties/description' => 'https://foo.com#/$defs/foo',
      '/allOf/1' => 'https://foo.com#/$defs/foo',
      '/allOf/2' => 'https://foo.com#/$defs/bar',
    },
    'extracted all the real $refs out of the schema, with locations and canonical targets',
  );
};

done_testing;
