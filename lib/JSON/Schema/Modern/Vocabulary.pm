use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Base role for JSON Schema vocabulary classes

our $VERSION = '0.549';

use 5.020;
use Moo::Role;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Ref::Util 0.100 'is_plain_arrayref';
use JSON::Schema::Modern::Utilities qw(jsonp assert_keyword_type abort);
use Carp ();
use namespace::clean;

our @CARP_NOT = qw(JSON::Schema::Modern);

requires qw(vocabulary keywords);

sub evaluation_order { 999 }  # override, if needed

sub traverse ($self, $schema, $state) {
  $state->{evaluator}->_traverse_subschema($schema, $state);
}

sub traverse_subschema ($self, $schema, $state) {
  $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}},
    +{ %$state, schema_path => $state->{schema_path}.'/'.$state->{keyword} });
}

sub traverse_array_schemas ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '%s array is empty', $state->{keyword}) if not $schema->{$state->{keyword}}->@*;

  my $valid = 1;
  foreach my $idx (0 .. $schema->{$state->{keyword}}->$#*) {
    $valid = 0 if not $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}[$idx],
      +{ %$state, schema_path => $state->{schema_path}.'/'.$state->{keyword}.'/'.$idx });
  }
  return $valid;
}

sub traverse_object_schemas ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys $schema->{$state->{keyword}}->%*) {
    $valid = 0 if not $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}{$property},
      +{ %$state, schema_path => jsonp($state->{schema_path}, $state->{keyword}, $property) });
  }
  return $valid;
}

sub traverse_property_schema ($self, $schema, $state, $property) {
  return if not assert_keyword_type($state, $schema, 'object');

  $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}{$property},
    +{ %$state, schema_path => jsonp($state->{schema_path}, $state->{keyword}, $property) });
}

sub eval ($self, $data, $schema, $state) {
  $state->{evaluator}->_eval_subschema($data, $schema, $state);
}

sub eval_subschema_at_uri ($self, $data, $schema, $state, $uri) {
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;

  return $state->{evaluator}->_eval_subschema($data, $schema_info->{schema},
    +{
      $schema_info->{configs}->%*,
      %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}
        .jsonp('', $state->{keyword}, exists $state->{_schema_path_suffix}
          ? (is_plain_arrayref($state->{_schema_path_suffix}) ? $state->{_schema_path_suffix}->@* : $state->{_schema_path_suffix})
          : ()),
      initial_schema_uri => $schema_info->{canonical_uri},
      document => $schema_info->{document},
      document_path => $schema_info->{document_path},
      spec_version => $schema_info->{specification_version},
      schema_path => '',
      vocabularies => $schema_info->{vocabularies}, # reference, not copy
    });
}

1;
__END__

=pod

=head1 SYNOPSIS

  package MyApp::Vocabulary::Awesome;
  use Moo::Role;
  with 'JSON::Schema::Modern::Vocabulary';

=head1 DESCRIPTION

This package is the role which all all vocabulary classes for L<JSON::Schema::Modern>
must compose, describing the basic structure expected of a vocabulary class.

=head1 ATTRIBUTES

=head1 METHODS

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

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
