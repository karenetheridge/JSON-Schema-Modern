use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;

my $DUMP = shift;

# regenerate this by running the test file with argument '1'
use constant KEYWORDS => {
  # draft7 -> http://json-schema.org/draft-07/schema#
  'draft7' => {
    Core => [qw(
      $id
      $schema
      $ref
      definitions
      $comment
    )],
    Validation => [qw(
      type
      enum
      const
      multipleOf
      maximum
      exclusiveMaximum
      minimum
      exclusiveMinimum
      maxLength
      minLength
      pattern
      maxItems
      minItems
      uniqueItems
      maxProperties
      minProperties
      required
    )],
    FormatAnnotation => [qw(
      format
    )],
    Applicator => [qw(
      allOf
      anyOf
      oneOf
      not
      if
      then
      else
      dependencies
      items
      additionalItems
      contains
      properties
      patternProperties
      additionalProperties
      propertyNames
    )],
    Content => [qw(
      contentEncoding
      contentMediaType
    )],
    MetaData => [qw(
      title
      description
      default
      readOnly
      writeOnly
      examples
    )],
  },
  # draft2019-09 -> https://json-schema.org/draft/2019-09/schema
  'draft2019-09' => {
    Core => [qw(
      $id
      $schema
      $anchor
      $recursiveAnchor
      $ref
      $recursiveRef
      $vocabulary
      $defs
      $comment
    )],
    Validation => [qw(
      type
      enum
      const
      multipleOf
      maximum
      exclusiveMaximum
      minimum
      exclusiveMinimum
      maxLength
      minLength
      pattern
      maxItems
      minItems
      uniqueItems
      maxContains
      minContains
      maxProperties
      minProperties
      required
      dependentRequired
    )],
    FormatAnnotation => [qw(
      format
    )],
    Applicator => [qw(
      allOf
      anyOf
      oneOf
      not
      if
      then
      else
      dependentSchemas
      items
      additionalItems
      contains
      maxContains
      minContains
      properties
      patternProperties
      additionalProperties
      propertyNames
      unevaluatedItems
      unevaluatedProperties
    )],
    Content => [qw(
      contentEncoding
      contentMediaType
      contentSchema
    )],
    MetaData => [qw(
      title
      description
      default
      deprecated
      readOnly
      writeOnly
      examples
    )],
  },
  # draft2020-12 -> https://json-schema.org/draft/2020-12/schema
  'draft2020-12' => {
    Core => [qw(
      $id
      $schema
      $anchor
      $dynamicAnchor
      $ref
      $dynamicRef
      $vocabulary
      $defs
      $comment
    )],
    Validation => [qw(
      type
      enum
      const
      multipleOf
      maximum
      exclusiveMaximum
      minimum
      exclusiveMinimum
      maxLength
      minLength
      pattern
      maxItems
      minItems
      uniqueItems
      maxContains
      minContains
      maxProperties
      minProperties
      required
      dependentRequired
    )],
    FormatAnnotation => [qw(
      format
    )],
    Applicator => [qw(
      allOf
      anyOf
      oneOf
      not
      if
      then
      else
      dependentSchemas
      prefixItems
      items
      contains
      maxContains
      minContains
      properties
      patternProperties
      additionalProperties
      propertyNames
    )],
    Content => [qw(
      contentEncoding
      contentMediaType
      contentSchema
    )],
    MetaData => [qw(
      title
      description
      default
      deprecated
      readOnly
      writeOnly
      examples
    )],
    Unevaluated => [qw(
      unevaluatedItems
      unevaluatedProperties
    )],
  },
};

subtest 'valid keywords' => sub {
  if ($DUMP) {
    my $js = JSON::Schema::Modern->new;
    print STDERR "{\n";
    foreach my $spec_version (sort { length($a) <=> length($b) || $a cmp $b } $js->SPECIFICATION_VERSIONS_SUPPORTED->@*) {
      # spec_version -> metaschema uri
      my $metaschema_uri = $js->METASCHEMA_URIS->{$spec_version};
      print STDERR "  # $spec_version -> $metaschema_uri\n";

      # metaschema uri -> vocab list:  [ spec_version, [ vocab classes ] ]
      foreach my $metaschema_info ($js->_get_metaschema_vocabulary_classes($metaschema_uri)) {
        print STDERR "  '$spec_version' => {\n";
        foreach my $class (sort $metaschema_info->[1]->@*) {
          my ($short_class) = $class =~ /::([^:]+)$/;
          print STDERR "    $short_class => [qw(\n";
          print STDERR "      $_\n" foreach $class->keywords($spec_version);
          print STDERR "    )],\n";
        }
        print STDERR "  },\n";
      }
    }

    print STDERR "};\n\n";
    pass('table dumped');
    return;
  }

  my @classes =
    grep Module::Runtime::use_module($_)->does('JSON::Schema::Modern::Vocabulary'),
    map 'JSON::Schema::Modern::Vocabulary::'.$_,
    map $_->basename =~ s/\.pm$//r,
    grep /\.pm$/,
    Path::Tiny::path('lib/JSON/Schema/Modern/Vocabulary/')->children;

  my $table = {
    map {
      my $spec_version = $_;
      $spec_version => {
        map {
          my $class = $_;
          my @keywords = eval { $class->keywords($spec_version) };
          @keywords ? (($class =~ /::([^:]+)$/) => \@keywords) : ();
        } @classes,
      };
    }
    JSON::Schema::Modern->SPECIFICATION_VERSIONS_SUPPORTED->@*
  };

  foreach my $spec_version (sort { length($a) <=> length($b) || $a cmp $b } keys KEYWORDS->%*) {
    foreach my $short_class (sort keys KEYWORDS->{$spec_version}->%*) {
      my $class = 'JSON::Schema::Modern::Vocabulary::'.$short_class;
      cmp_result(
        [ $class->keywords($spec_version) ],
        KEYWORDS->{$spec_version}{$short_class},
        "$spec_version, $short_class: calculated keyword list matches hardcoded table",
      );
    }
  }
};

done_testing;
