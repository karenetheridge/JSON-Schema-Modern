use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Base role for JSON Schema vocabulary classes

our $VERSION = '0.623';

use 5.020;
use Moo::Role;
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
use Ref::Util 0.100 'is_plain_arrayref';
use JSON::Schema::Modern::Utilities qw(jsonp assert_keyword_type abort);
use Carp ();
use namespace::clean;

our @CARP_NOT = qw(JSON::Schema::Modern);

requires qw(vocabulary keywords);

sub evaluation_order { 999 }  # override, if needed

sub BUILD { die 'these classes are never instantiated' }

sub traverse ($class, $schema, $state) {
  $state->{evaluator}->_traverse_subschema($schema, $state);
}

sub traverse_subschema ($class, $schema, $state) {
  $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}},
    +{ %$state, keyword_path => $state->{keyword_path}.'/'.$state->{keyword} });
}

sub traverse_array_schemas ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '%s array is empty', $state->{keyword}) if not $schema->{$state->{keyword}}->@*;

  my $valid = 1;
  foreach my $idx (0 .. $schema->{$state->{keyword}}->$#*) {
    $valid = 0 if not $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}[$idx],
      +{ %$state, keyword_path => $state->{keyword_path}.'/'.$state->{keyword}.'/'.$idx });
  }
  return $valid;
}

sub traverse_object_schemas ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys $schema->{$state->{keyword}}->%*) {
    $valid = 0 if not $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}{$property},
      +{ %$state, keyword_path => jsonp($state->{keyword_path}, $state->{keyword}, $property) });
  }
  return $valid;
}

sub traverse_property_schema ($class, $schema, $state, $property) {
  return if not assert_keyword_type($state, $schema, 'object');

  $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}{$property},
    +{ %$state, keyword_path => jsonp($state->{keyword_path}, $state->{keyword}, $property) });
}

sub eval ($class, $data, $schema, $state) {
  $state->{evaluator}->_eval_subschema($data, $schema, $state);
}

sub eval_subschema_at_uri ($class, $data, $schema, $state, $uri) {
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource "%s"', $uri) if not $schema_info;
  abort($state, 'EXCEPTION: bad reference to "%s": not a schema', $schema_info->{canonical_uri})
    if $schema_info->{document}->get_entity_at_location($schema_info->{document_path}) ne 'schema';

  return $state->{evaluator}->_eval_subschema($data, $schema_info->{schema},
    +{
      %$state,
      # keyword is assumed to be json pointer-encoded (if a suffix path is needed), so we just concat
      traversed_keyword_path => $state->{traversed_keyword_path}.$state->{keyword_path}.'/'.$state->{keyword},
      initial_schema_uri => $schema_info->{canonical_uri},
      $schema_info->%{qw(document specification_version vocabularies)},
      keyword_path => '',
    });
}

1;
__END__

=pod

=head1 SYNOPSIS

  package MyApp::Vocabulary::Awesome;
  use Moo;
  with 'JSON::Schema::Modern::Vocabulary';

=head1 DESCRIPTION

This package is the role which all all vocabulary classes for L<JSON::Schema::Modern>
must compose, describing the basic structure expected of a vocabulary class and defining some basic
methods which are useful for traversing or evaluating various keywords.

=head1 ATTRIBUTES

=head1 METHODS

=for Pod::Coverage BUILD

=for stopwords schema subschema

=head2 vocabulary

Returns the canonical URI(s) describing the vocabulary for each draft specification version, as described in
L<JSON Schema Core Meta-specification, section 8.1.2|https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.8.1.2>.
Must be implemented by the composing class.

=head2 evaluation_order

Returns a positive integer, used as a sort key for determining the evaluation order of this vocabulary. If
not overridden in a custom vocabulary class, its evaluation order will be after all built-in
vocabularies. You probably don't need to define this.

=head2 keywords

Returns the list of keywords defined by the vocabulary. Must be implemented by the composing class.

=head2 traverse

Traverses a subschema. Callers are expected to establish a new C<$state> scope.

=head2 traverse_subschema

Recursively traverses the schema at the current keyword, as in the C<not> keyword.

=head2 traverse_array_schemas

Recursively traverses the list of subschemas at the current keyword, as in the C<allOf> keyword.

=head2 traverse_object_schemas

Recursively traverses the (subschema) values of the object at the current keyword, as in the C<$defs> keyword.

=head2 traverse_property_schema

Recursively traverses the subschema under one property of the object at the current keyword.

=head2 eval

Evaluates a subschema. Callers are expected to establish a new C<$state> scope.

=head2 eval_subschema_at_uri

Resolves a URI to a subschema, then evaluates that subschema (essentially the C<$ref> keyword).

=cut
