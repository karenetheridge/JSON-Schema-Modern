use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test2::V0;
use Test::Needs qw(Sereal::Encoder Sereal::Decoder);
use Test::Warnings qw(:no_end_test had_no_warnings);
use Test::Deep qw(cmp_deeply);
use IPC::Open3;
use JSON::Schema::Modern;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };
use JSON::PP ();
use constant { true => JSON::PP::true, false => JSON::PP::false };

my $js = JSON::Schema::Modern->new(
  collect_annotations => 1,
  scalarref_booleans => 1,
  stringy_numbers => 1,
  strict => 0,
  max_traversal_depth => 42,
  specification_version => 'draft2019-09',
);

my $metaschema = {
  '$id' => 'https://my_metaschema',
  '$schema' => 'https://json-schema.org/draft/2020-12/schema',
  '$vocabulary' => {
    'https://json-schema.org/draft/2020-12/vocab/core' => true,
    'https://json-schema.org/draft/2020-12/vocab/format-annotation' => true,
  },
};
my $schema = {
  '$id' => 'https://my_schema',
  '$schema' => 'https://my_metaschema',
  type => 'number',
  format => 'ipv4',
  unknown => 1,
  properties => { hello => false },
  contentMediaType => 'application/json',
  contentSchema => {},
};

$js->add_schema($metaschema);
$js->add_schema($schema);
ok($js->evaluate($schema, {}), 'evaluated against an empty schema');

cmp_deeply(
  $js->evaluate(1, 'https://my_schema')->TO_JSON,
  my $result = {
    valid => true,
    annotations => [
      map +{
        instanceLocation => '',
        keywordLocation => '/'.$_,
        absoluteKeywordLocation => 'https://my_schema#/'.$_,
        annotation => $schema->{$_},
      }, 'format', sort qw(type unknown properties contentMediaType contentSchema),
    ],
  },
  'evaluate data against schema with custom dialect; format and unknown keywords are collected as annotations',
);

cmp_deeply(
  $js->evaluate('foo', 'https://my_schema')->TO_JSON,
  $result,
  'evaluate data against schema with custom dialect; format-annotation is used',
);

my @serialized_attributes = sort qw(
  specification_version
  output_format
  short_circuit
  max_traversal_depth
  validate_formats
  validate_content_schemas
  collect_annotations
  scalarref_booleans
  stringy_numbers
  strict
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

ok($thawed->evaluate($schema, {}), 'evaluate again against an empty schema');

cmp_deeply(
  $js->evaluate('hi', 'https://my_schema')->TO_JSON,
  {
    valid => true,
    annotations => [
      map +{
        instanceLocation => '',
        keywordLocation => '/'.$_,
        absoluteKeywordLocation => 'https://my_schema#/'.$_,
        annotation => $schema->{$_},
      }, 'format', sort qw(type unknown properties contentMediaType contentSchema),
    ],
  },
  'in thawed object, evaluate data against schema with custom dialect; format and unknown keywords are collected as annotations',
);


$frozen = Sereal::Encoder->new({ freeze_callbacks => 1 })->encode($js);
$thawed = Sereal::Decoder->new->decode($frozen);
ok($thawed->evaluate($schema, {}), 'evaluate again against an empty schema');

ok($thawed->_get_vocabulary_class('https://json-schema.org/draft/2020-12/vocab/core'), 'core vocabulary_class for a different spec version works in a thawed object');
ok($thawed->_get_vocabulary_class('https://json-schema.org/draft/2020-12/vocab/format-assertion'), 'format-assertion vocabulary_class works in a thawed object');
ok($thawed->_get_metaschema_vocabulary_classes('https://json-schema.org/draft/2020-12/schema'), 'metaschema_vocabulary_classes works in a thawed object');
ok($thawed->get_media_type('application/json'), 'media_type works in a thawed object');
ok($thawed->get_encoding('base64'), 'encoding works in a thawed object');

# now try to thaw the file in a new process and run some more tests
if ("$]" >= '5.022' or $^O ne 'MSWin32') {
  open my $child_in, '|-:raw', $^X, (-d 'blib' ? '-Mblib' : '-Ilib'), 't/read_serialized_file';
  print $child_in $frozen;
  close $child_in;

  my $hub = Test2::API::test2_stack->top;
  $hub->set_count($hub->count + ($ENV{AUTHOR_TESTING} ? 2 : 1));

  is($? >> 8, 0, 'child process finished successfully');
}

had_no_warnings() if $ENV{AUTHOR_TESTING};
done_testing;
