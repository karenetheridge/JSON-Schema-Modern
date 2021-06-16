use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Base role for JSON Schema vocabulary classes

our $VERSION = '0.513';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::Schema::Modern::Utilities qw(jsonp assert_keyword_type);
use Moo::Role;
use namespace::clean;

requires qw(vocabulary keywords);

sub traverse {
  my ($self, $schema, $state) = @_;
  $state->{evaluator}->_traverse_subschema($schema, $state);
}

sub traverse_subschema {
  my ($self, $schema, $state) = @_;

  $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}},
    +{ %$state, schema_path => $state->{schema_path}.'/'.$state->{keyword} });
}

sub traverse_array_schemas {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '%s array is empty', $state->{keyword}) if not @{$schema->{$state->{keyword}}};

  foreach my $idx (0 .. $#{$schema->{$state->{keyword}}}) {
    $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}[$idx],
      +{ %$state, schema_path => $state->{schema_path}.'/'.$state->{keyword}.'/'.$idx });
  }
}

sub traverse_object_schemas {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'object');

  foreach my $property (sort keys %{$schema->{$state->{keyword}}}) {
    $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}{$property},
      +{ %$state, schema_path => jsonp($state->{schema_path}, $state->{keyword}, $property) });
  }
}

sub traverse_property_schema {
  my ($self, $schema, $state, $property) = @_;

  return if not assert_keyword_type($state, $schema, 'object');

  $state->{evaluator}->_traverse_subschema($schema->{$state->{keyword}}{$property},
    +{ %$state, schema_path => jsonp($state->{schema_path}, $state->{keyword}, $property) });
}

sub eval {
  my ($self, $data, $schema, $state) = @_;
  $state->{evaluator}->_eval_subschema($data, $schema, $state);
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

User-defined custom vocabularies are not supported at this time.

=head1 ATTRIBUTES

=head1 METHODS

=for stopwords schema subschema

=head2 vocabulary

The canonical URI describing the vocabulary, as described in
L<JSON Schema Core Meta-specification, section 8.1.2|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.8.1.2>. Must be implemented by the composing class.

=head2 keywords

The list of keywords defined by the vocabulary. Must be implemented by the composing class.

=head2 traverse

Traverses a subschema.

=head2 traverse_subschema

Recursively traverses the schema at the current keyword.

=head2 traverse_array_schemas

Recursively traverses the list of subschemas at the current keyword.

=head2 traverse_object_schemas

Recursively traverses the (subschema) values of the object at the current keyword.

=head2 traverse_property_schema

Recursively traverses the subschema under one property of the object at the current keyword.

=head2 eval

Evaluates a subschema.

=cut
