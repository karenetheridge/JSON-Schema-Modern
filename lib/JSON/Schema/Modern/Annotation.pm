use strict;
use warnings;
package JSON::Schema::Modern::Annotation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains a single annotation from a JSON Schema evaluation

our $VERSION = '0.541';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Safe::Isa;
use MooX::TypeTiny;
use Types::Standard qw(Str InstanceOf Bool);
use namespace::clean;

has [qw(
  keyword
  instance_location
  keyword_location
)] => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has absolute_keyword_location => (
  is => 'ro',
  isa => InstanceOf['Mojo::URL'],
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

# https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.7.7.1
has annotation => (
  is => 'ro',
  required => 1,
);

has unknown => (
  is => 'ro',
  isa => Bool,
  default => 0,
);

sub TO_JSON ($self) {
  return +{
    # note that locations are JSON pointers, not uri fragments!
    instanceLocation => $self->instance_location,
    keywordLocation => $self->keyword_location,
    !defined($self->absolute_keyword_location) ? ()
      : ( absoluteKeywordLocation => $self->absolute_keyword_location->to_string ),
    annotation => $self->annotation,
  };
}

1;
__END__

=pod

=for :header
=for stopwords schema fragmentless

=head1 SYNOPSIS

  use JSON::Schema::Modern;
  my $js = JSON::Schema::Modern->new;
  my $result = $js->evaluate($data, $schema);
  my @annotations = $result->annotations;

  my $value = $annotations[0]->annotation;
  my $instance_location = $annotations[0]->instance_location;

  my $annotations_encoded = encode_json(\@annotations);

=head1 DESCRIPTION

An instance of this class holds one annotation from evaluating a JSON Schema with
L<JSON::Schema::Modern>.

=head1 ATTRIBUTES

=head2 keyword

The keyword that produced the annotation.

=head2 instance_location

The path in the instance where the annotation was produced; encoded as per the JSON Pointer
specification (L<RFC 6901|https://tools.ietf.org/html/rfc6901>).

=head2 keyword_location

The schema path taken during evaluation to arrive at the annotation; encoded as per the JSON Pointer
specification (L<RFC 6901|https://tools.ietf.org/html/rfc6901>).

=head2 absolute_keyword_location

The canonical URI or URI reference of the location in the schema where the error occurred; not
defined, if there is no base URI for the schema and no C<$ref> was followed. Note that this is not
actually fragmentless URI in most cases, as the indicated error will occur at a path
below the position where the most recent identifier had been declared in the schema. Further, if the
schema never declared an absolute base URI (containing a scheme), this URI won't be absolute either.

=head2 unknown

A boolean flag, indicating whether the keyword is a known vocabulary keyword or unknown.

=head2 annotation

The actual annotation value (which may or may not be a string).

=head1 METHODS

=head2 TO_JSON

Returns a data structure suitable for serialization. Corresponds to one output unit as specified in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.2> and
L<https://json-schema.org/draft/2019-09/output/schema>, except that C<instanceLocation> and
C<keywordLocation> are JSON pointers, B<not> URI fragments. (See the
C<strict_basic> L<JSON::Schema::Modern/output_format>
if the distinction is important to you.)

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
