use strict;
use warnings;
package JSON::Schema::Draft201909::Error;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains a single error from a JSON Schema evaluation

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use Moo;
use MooX::TypeTiny;
use Types::Standard 'Str';
use namespace::clean;

has [qw(
  instance_location
  keyword_location
  absolute_keyword_location
  error
)] => ( is => 'ro', isa => Str );

sub TO_JSON {
  my $self = shift;
  return +{
    instanceLocation => $self->instance_location,
    keywordLocation => $self->keyword_location,
    !$self->absolute_keyword_location ? ()
      : ( absoluteKeywordLocation => $self->absolute_keyword_location ),
    error => $self->error,  # TODO: allow localization
  };
}

1;
__END__

=pod

=for :header
=for stopwords schema

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

=head2 instance_location

The path in the instance where the error occurred.

=head2 keyword_location

The schema path taken during evaluation to arrive at the error.

=head2 absolute_keyword_location

The path in the schema where the error occurred (may be different from keyword_location, if a
C<$ref> was followed).  This is supposed to be an absolute URI (as per
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.3.2>) but
this implementation does not yet track the absolute URIs of schemas, so it is just the fragment
portion of a URI for now.

=head2 error

The actual error string.

=head1 METHODS

=head2 TO_JSON

Returns a data structure suitable for serialization. Corresponds to one output unit as specified in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.2> and
L<https://json-schema.org/draft/2019-09/output/schema>.

=cut
