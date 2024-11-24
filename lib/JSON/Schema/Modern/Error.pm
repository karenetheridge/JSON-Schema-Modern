use strict;
use warnings;
package JSON::Schema::Modern::Error;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains a single error from a JSON Schema evaluation

our $VERSION = '0.597';

use 5.020;
use Moo;
with 'JSON::Schema::Modern::ResultNode';
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use MooX::TypeTiny;
use Types::Standard qw(Str Bool Enum Tuple);
use Types::Common::Numeric qw(PositiveInt);
use builtin::compat 'refaddr';
use namespace::clean;

use overload
  '0+' => sub { refaddr($_[0]) },
  '""' => sub { $_[0]->stringify },
  fallback => 1;

has error => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has exception => (
  is => 'ro',
  isa => Bool,
);

has mode => (
  is => 'rw',
  isa => Enum[qw(traverse evaluate)],
);

has recommended_response => (
  is => 'ro',
  isa => Tuple[PositiveInt, Str],
);

sub stringify ($self) {
  ($self->mode//'evaluate') eq 'traverse'
    ? '\''.$self->keyword_location.'\': '.$self->error
    : '\''.$self->instance_location.'\': '.$self->error;
}

sub __thing { 'error' }

1;
__END__

=pod

=for :header
=for stopwords schema fragmentless subschemas

=head1 SYNOPSIS

  use JSON::Schema::Modern;
  my $js = JSON::Schema::Modern->new;
  my $result = $js->evaluate($data, $schema);
  my @errors = $result->errors;

  my $message = $errors[0]->error;
  my $instance_location = $errors[0]->instance_location;

  my $errors_encoded = encode_json(\@errors);

=head1 DESCRIPTION

An instance of this class holds one error from evaluating a JSON Schema with
L<JSON::Schema::Modern>.

=head1 ATTRIBUTES

=head2 keyword

The keyword that produced the error; might be C<undef>.

=head2 instance_location

The path in the instance where the error occurred; encoded as per the JSON Pointer specification
(L<RFC 6901|https://datatracker.ietf.org/doc/html/rfc6901>).

=head2 keyword_location

The schema path taken during evaluation to arrive at the error; encoded as per the JSON Pointer
specification (L<RFC 6901|https://datatracker.ietf.org/doc/html/rfc6901>).

=head2 absolute_keyword_location

The canonical URI or URI reference of the location in the schema where the error occurred; not
defined, if there is no base URI for the schema and no C<$ref> was followed. Note that this is not
a fragmentless URI in most cases, as the indicated error will occur at a path
below the position where the most recent identifier had been declared in the schema. Further, if the
schema never declared an absolute base URI (containing a scheme), this URI won't be absolute either.

=head2 error

The actual error string.

=head2 exception

Indicates the error's severity is sufficient to stop evaluation.

=head2 recommended_response

=for stopwords OpenAPI

A tuple, consisting of C<[ integer, string ]>, indicating the recommended HTTP response code and
string to use for this error (if validating an HTTP request). This could exist for things like a
failed authentication check in OpenAPI validation, in which case it would contain
C<[ 401, 'Unauthorized' ]>.

=head2 depth

An integer which indicates how many subschemas deep this error was generated from. Can be used to
construct a tree-like structure of errors.

=head1 METHODS

=for Pod::Coverage stringify mode BUILDARGS

=head2 TO_JSON

Returns a data structure suitable for serialization. Corresponds to one output unit as specified in
L<https://json-schema.org/draft/2020-12/json-schema-core#section-12.3> and
L<https://json-schema.org/draft/2020-12/output/schema>,
except that C<instanceLocation> and
C<keywordLocation> are JSON pointers, B<not> URI fragments, even in draft2019-09. (See the
C<strict_basic> L<JSON::Schema::Modern/output_format>, only available in that version,
if the distinction is important to you.)

=head2 dump

Returns a JSON string representing the error object, according to
the L<specification|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>.

=cut
