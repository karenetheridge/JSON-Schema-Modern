use strict;
use warnings;
package JSON::Schema::Draft201909::Dialect;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: An object representing a JSON Schema dialect (a metaschema and a collection of vocabularies)

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Moo;
use strictures 2;
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(ArrayRef ConsumerOf Str);
use Mojo::URL;
use Module::Runtime 'use_module';
use Carp 'carp';
use JSON::Schema::Draft201909::Utilities 'canonical_schema_uri';
use namespace::clean;

has vocabularies => (
  is => 'bare',
  isa => ArrayRef[ConsumerOf['JSON::Schema::Draft201909::Vocabulary']],
  required => 1,
  handles_via => 'Array',
  handles => {
    num_vocabularies => 'count',
    get_vocabulary => 'get',
  },
);

# URI of $schema property that represents this metaschema
has uri => (
  is => 'ro',
  isa => Str,
  required => 1,
);

sub dialect_for_schema {
  my ($class, $schema) = @_;

  # for now, this is hardcoded, but in the future the dialect will start off just with the Core
  # vocabulary and then fetch and parse the document to determine the actual vocabularies from the
  # '$vocabulary' keyword at its root.
  return $class->default_dialect;
}

sub default_dialect {
  my $class = shift;

  $class->new(
    vocabularies => [
      map use_module('JSON::Schema::Draft201909::Vocabulary::'.$_)
          ->new(required => ($_ eq 'Format' ? 0 : 1)),
        qw(Core Validation Applicator Format Content MetaData),
    ],
    uri => 'https://json-schema.org/draft/2019-09/schema',
  );
}

sub post_evaluate {
  my ($self, $data, $schema, $state) = @_;

  if (exists $schema->{definitions}) {
    carp 'no-longer-supported "definitions" keyword present (at '.canonical_schema_uri($state)
      .'): this should be rewritten as "$defs"';
  }

  if (exists $schema->{dependencies}) {
    carp 'no-longer-supported "dependencies" keyword present (at '.canonical_schema_uri($state)
      .'): this should be rewritten as "dependentSchemas" or "dependentRequired"';
  }
}

1;
__END__

=pod

=for :header
=for stopwords metaschema

=head1 DESCRIPTION

This module represents the schema and vocabularies used by a I<dialect>, which is denoted by a
schema's C<$schema> keyword: see
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.8.1>.

=head1 ATTRIBUTES

=head2 vocabularies

The list of vocabulary objects used by this dialect. Required.

=head2 uri

The URI of the metaschema which defines this dialect. Required.

=head1 METHODS

=for Pod::Coverage post_evaluate

=head2 dialect_for_schema

A class method that examines the provided schema (boolean or hashref, i.e. corresponding to a JSON
boolean or object) and returns an instance representing the dialect used in the schema.

=head2 default_dialect

A class method that returns an instance representing the default dialect for this version
of the JSON Schema specification (L<https://json-schema.org/draft/2019-09/schema>), which implements the vocabularies:

=for :list
* Core
* Validation
* Applicator
* Format
* Content
* MetaData

=cut
