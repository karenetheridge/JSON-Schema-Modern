use strict;
use warnings;
package JSON::Schema::Draft201909::Error;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains a single error from a JSON Schema evaluation

our $VERSION = '0.018';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use Moo;
use strictures 2;
use MooX::TypeTiny;
use Types::Standard qw(Str Undef);
use namespace::clean;

has [qw(
  instance_location
  keyword_location
  error
)] => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has absolute_keyword_location => (
  is => 'ro',
  isa => Str, # always a uri (absolute uri or uri reference)
  coerce => sub { "$_[0]" },
);

has keyword => (
  is => 'ro',
  isa => Str|Undef,
  required => 1,
);

sub TO_JSON {
  my $self = shift;
  return +{
    instanceLocation => $self->instance_location,
    keywordLocation => $self->keyword_location,
    !defined($self->absolute_keyword_location) ? ()
      : ( absoluteKeywordLocation => $self->absolute_keyword_location ),
    error => $self->error,  # TODO: allow localization
  };
}

1;
__END__

=pod

=for :header
=for stopwords schema fragmentless

=head1 SYNOPSIS

  use JSON::Schema::Draft201909;
  my $js = JSON::Schema::Draft201909->new;
  my $result = $js->evaluate($data, $schema);
  my @errors = $result->errors;

  my $message = $errors[0]->error;
  my $instance_location = $errors[0]->instance_location;

  my $errors_encoded = encode_json(\@errors);

=head1 DESCRIPTION

An instance of this class holds one error from evaluating a JSON Schema with
L<JSON::Schema::Draft201909>.

=head1 ATTRIBUTES

=head2 keyword

The keyword that produced the error; might be C<undef>.

=head2 instance_location

The path in the instance where the error occurred; encoded as per the JSON Pointer specification
(L<RFC 6901|https://tools.ietf.org/html/rfc6901>).

=head2 keyword_location

The schema path taken during evaluation to arrive at the error; encoded as per the JSON Pointer
specification (L<RFC 6901|https://tools.ietf.org/html/rfc6901>).

=head2 absolute_keyword_location

The canonical URI or URI reference of the location in the schema where the error occurred; not
defined, if there is no base URI for the schema and no C<$ref> was followed. Note that this is not
a fragmentless URI in most cases, as the indicated error will occur at a path
below the position where the most recent identifier had been declared in the schema. Further, if the
schema never declared an absolute base URI (containing a scheme), this URI won't be absolute either.

=head2 error

The actual error string.

=head1 METHODS

=head2 TO_JSON

Returns a data structure suitable for serialization. Corresponds to one output unit as specified in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.2> and
L<https://json-schema.org/draft/2019-09/output/schema>.

=cut
