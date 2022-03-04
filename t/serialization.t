use strict;
use warnings;
use 5.020;
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
use lib 't/lib';
use Helper;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };

my $js = JSON::Schema::Modern->new(
  validate_formats => 1,
  collect_annotations => 1,
  scalarref_booleans => 1,
  max_traversal_depth => 42,
  specification_version => 'draft2019-09',
);

my $metaschema = {
  '$id' => 'https://mymetaschema',
  '$schema' => 'https://json-schema.org/draft/2019-09/schema',
  '$vocabulary' => {
    'https://json-schema.org/draft/2019-09/vocab/core' => true,
  },
};
my $schema = {
  '$id' => 'https://myschema',
  '$schema' => 'https://mymetaschema',
  type => 'number',
  format => 'ipv4',
  unknown => 1,
  properties => { hello => {} },
  contentMediaType => 'application/json',
  contentSchema => {},
};

$js->add_schema($metaschema);
$js->add_schema($schema);
ok($js->evaluate($schema, {}), 'evaluated against an empty schema');

my @serialized_attributes = sort qw(
  specification_version
  output_format
  short_circuit
  max_traversal_depth
  validate_formats
  validate_content_schemas
  collect_annotations
  scalarref_booleans
  _resource_index
  _vocabulary_classes
  _metaschema_vocabulary_classes
);

my $frozen = $js->FREEZE(undef);

cmp_deeply(
  [ sort keys %$frozen ],
  [ sort @serialized_attributes ],
  'frozen object contains all the right keys',
);

my $thawed = JSON::Schema::Modern->THAW(undef, $frozen);

cmp_deeply(
  [ sort keys %$thawed ],
  [ sort @serialized_attributes ],
  'thawed object contains all the right keys',
);

ok($js->evaluate($schema, {}), 'evaluate again against an empty schema');

done_testing;
