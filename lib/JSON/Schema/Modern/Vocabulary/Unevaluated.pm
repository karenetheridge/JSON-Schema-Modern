use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Unevaluated;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Unevaluated vocabulary

our $VERSION = '0.617';

use 5.020;
use Moo;
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
use List::Util 'max';
use if "$]" < 5.041010, 'List::Util' => 'any';
use if "$]" >= 5.041010, experimental => 'keyword_any';
use JSON::Schema::Modern::Utilities qw(is_type jsonp local_annotations E A abort true);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary ($class) {
  'https://json-schema.org/draft/2020-12/vocab/unevaluated' => 'draft2020-12';
}

sub evaluation_order ($class) { 7 }

# This vocabulary should be evaluated after the Applicator vocabulary.
sub keywords ($class, $spec_version) {
  die 'Unevaluated not implemented in '.$spec_version if $spec_version =~ /^draft(?:[467]|2019-09)$/;
  qw(unevaluatedItems unevaluatedProperties);
}

sub _traverse_keyword_unevaluatedItems ($class, $schema, $state) {
  $class->traverse_subschema($schema, $state);
}

sub _eval_keyword_unevaluatedItems ($class, $data, $schema, $state) {
  # these should never happen
  die '"unevaluatedItems" keyword present, but annotation collection is disabled'
    if not $state->{collect_annotations};
  die '"unevaluatedItems" keyword present, but short_circuit is enabled: results unreliable'
    if $state->{short_circuit};

  return 1 if not is_type('array', $data);

  my @annotations = local_annotations($state);

  # a relevant keyword already produced a 'true' annotation at this location
  my @boolean_annotation_keywords =
    $state->{specification_version} eq 'draft2019-09' ? qw(items additionalItems unevaluatedItems)
      : qw(prefixItems items contains unevaluatedItems);
  my %bools; @bools{@boolean_annotation_keywords} = (1)x@boolean_annotation_keywords;
  return 1
    if any { $bools{$_->{keyword}} && is_type('boolean', $_->{annotation}) && $_->{annotation} }
      @annotations;

  # otherwise, evaluate at every instance item greater than the max of all 'prefixItems'/numeric
  # 'items' annotations that isn't in a 'contains' annotation
  my $max_index_annotation_keyword = $state->{specification_version} eq 'draft2019-09' ? 'items' : 'prefixItems';
  my $last_index = max(-1, grep is_type('integer', $_),
    map +($_->{keyword} eq $max_index_annotation_keyword ? $_->{annotation} : ()), @annotations);

  return 1 if $last_index == $data->$#*;

  my @contains_annotation_indexes = $state->{specification_version} eq 'draft2019-09' ? ()
    : map +($_->{keyword} eq 'contains' ? $_->{annotation}->@* : ()), @annotations;

  my $valid = 1;
  foreach my $idx ($last_index+1 .. $data->$#*) {
    next if any { $idx == $_ } @contains_annotation_indexes;
    if (is_type('boolean', $schema->{unevaluatedItems})) {
      next if $schema->{unevaluatedItems};
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx },
          'additional item not permitted')
    }
    else {
      if ($class->eval($data->[$idx], $schema->{unevaluatedItems},
          +{ %$state, data_path => $state->{data_path}.'/'.$idx,
            schema_path => $state->{schema_path}.'/unevaluatedItems',
            collect_annotations => $state->{collect_annotations} & ~1 })) {
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  A($state, true);
  return E($state, 'subschema is not valid against all additional items') if not $valid;
  return 1;
}

sub _traverse_keyword_unevaluatedProperties ($class, $schema, $state) {
  $class->traverse_subschema($schema, $state);
}

sub _eval_keyword_unevaluatedProperties ($class, $data, $schema, $state) {
  # these should never happen
  die '"unevaluatedProperties" keyword present, but annotation collection is disabled'
    if not $state->{collect_annotations};
  die '"unevaluatedProperties" keyword present, but short_circuit is enabled: results unreliable'
    if $state->{short_circuit};

  return 1 if not is_type('object', $data);

  my @evaluated_properties = map {
    my $keyword = $_->{keyword};
    (grep $keyword eq $_, qw(properties additionalProperties patternProperties unevaluatedProperties))
      ? $_->{annotation}->@* : ();
  } local_annotations($state);

  my $valid = 1;
  my @properties;
  foreach my $property (sort keys %$data) {
    next if any { $_ eq $property } @evaluated_properties;
    push @properties, $property;

    if (is_type('boolean', $schema->{unevaluatedProperties})) {
      next if $schema->{unevaluatedProperties};
      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property) },
        'additional property not permitted');
    }
    else {
      if ($class->eval($data->{$property}, $schema->{unevaluatedProperties},
          +{ %$state, data_path => jsonp($state->{data_path}, $property),
            schema_path => $state->{schema_path}.'/unevaluatedProperties',
            collect_annotations => $state->{collect_annotations} & ~1 })) {
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  A($state, \@properties);
  return E($state, 'not all additional properties are valid') if not $valid;
  return 1;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Unevaluated" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/unevaluated> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-core.html#section-11>.

Support is also provided for the equivalent Draft 2019-09 keywords in the
JSON Schema Draft 2019-09 "Applicator" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/applicator> and formally specified in
L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-02#section-9>.

=cut
