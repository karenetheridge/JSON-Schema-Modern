use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Base role for JSON Schema vocabulary classes

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(jsonp assert_keyword_type);
use Moo::Role;
use strictures 2;
use Types::Standard 1.010002 'InstanceOf';
use namespace::clean;

has evaluator => (
  is => 'ro',
  isa => InstanceOf['JSON::Schema::Draft201909'],
  required => 1,
  weak_ref => 1,
);

requires qw(vocabulary keywords);

sub traverse_schema {
  my ($self, $schema, $state) = @_;

  $self->evaluator->_traverse($schema->{$state->{keyword}},
    +{ %$state, schema_path => $state->{schema_path}.'/'.$state->{keyword} });
}

sub traverse_array_schemas {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '"%s" array is empty') if not @{$schema->{$state->{keyword}}};

  foreach my $idx (0 .. $#{$schema->{$state->{keyword}}}) {
    $self->evaluator->_traverse($schema->{$state->{keyword}}[$idx],
      +{ %$state, schema_path => $state->{schema_path}.'/'.$state->{keyword}.'/'.$idx });
  }
}

sub traverse_object_schemas {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'object');

  foreach my $property (sort keys %{$schema->{$state->{keyword}}}) {
    $self->evaluator->_traverse($schema->{$state->{keyword}}{$property},
      +{ %$state, schema_path => jsonp($state->{schema_path}, $state->{keyword}, $property) });
  }
}

1;
__END__

=pod

=head1 SYNOPSIS

  package MyApp::Vocabulary::Awesome;
  use Moo::Role;
  with 'JSON::Schema::Draft201909::Vocabulary';

=head1 DESCRIPTION

This package is the role which all all vocabulary classes for L<JSON::Schema::Draft201909>
must compose, describing the basic structure expected of a vocabulary class.

User-defined custom vocabularies are not supported at this time.

=head1 ATTRIBUTES

=head2 evaluator

The L<JSON::Schema::Draft201909> evaluator object, used for implementing C<_traverse_keyword_*> and
C<_eval_keyword_*>.

=head1 METHODS

=for stopwords schema subschema

=head2 vocabulary

The canonical URI describing the vocabulary, as described in
L<JSON Schema Core Meta-specification, section 8.1.2|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.8.1.2>. Must be implemented by the composing class.

=head2 keywords

The list of keywords defined by the vocabulary. Must be implemented by the composing class.

=head2 traverse_schema

Recursively traverses the schema at the current keyword.

=head2 traverse_array_schemas

Recursively traverses the list of subschemas at the current keyword.

=head2 traverse_object_schemas

Recursively traverses the (subschema) values of the object at the current keyword.

=cut
