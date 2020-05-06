use strict;
use warnings;
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use JSON::MaybeXS 1.004001 'is_bool';
use Syntax::Keyword::Try;
use Carp 'croak';
use Moo;
use MooX::TypeTiny 0.002002;
use Types::Standard 1.010002 'HasMethods';
use namespace::clean;

has _json_decoder => (
  is => 'ro',
  isa => HasMethods[qw(encode decode)],
  lazy => 1,
  default => sub { JSON::MaybeXS->new(allow_nonref => 1, utf8 => 1) },
);

sub evaluate_json_string {
  my ($self, $json_data, $schema) = @_;
  my ($data, $exception);
  try { $data = $self->_json_decoder->decode($json_data) }
  catch { $exception = $@ }

  # TODO: turn exception into an error to be returned
  return 0 if defined $exception;
  return $self->evaluate($data, $schema);
}

sub evaluate {
  my ($self, $data, $schema) = @_;

  if (is_bool($schema)) {
    return $schema;
  }

  # TODO: die 'unrecognized schema format ', ref $schema
  return 0 if ref $schema ne 'HASH';

  return 1;
}

sub _is_type {
  my ($self, $type, $value) = @_;

  if ($type eq 'null') {
    return !(defined $value);
  }
  if ($type eq 'boolean') {
    return is_bool($value);
  }
  if ($type eq 'object') {
    return ref $value eq 'HASH';
  }
  if ($type eq 'array') {
    return ref $value eq 'ARRAY';
  }

  if ($type eq 'string' or $type eq 'number' or $type eq 'integer') {
    return 0 if not defined $value or ref $value;
    my $flags = B::svref_2object(\$value)->FLAGS;

    if ($type eq 'string') {
      return $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'number') {
      return !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'integer') {
      return !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK))
        && int($value) == $value;
    }
  }

  croak sprintf('unknown type "%s"', $type);
}

# only the core six types are reported (integers are numbers)
# use _is_type('integer') to differentiate numbers from integers.
sub _get_type {
  my ($self, $value) = @_;

  return 'null' if not defined $value;
  return 'object' if ref $value eq 'HASH';
  return 'array' if ref $value eq 'ARRAY';
  return 'boolean' if is_bool($value);

  if (not ref $value) {
    my $flags = B::svref_2object(\$value)->FLAGS;
    return 'string' if $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
    return 'number' if !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));
  }

  croak sprintf('ambiguous type for %s', $self->_json_decoder->encode($value));
}

1;
__END__

=pod

=for :header
=for stopwords schema subschema metaschema validator evaluator

=head1 SYNOPSIS

  use JSON::Schema::Draft201909;

  $js = JSON::Schema::Draft2019->new;
  $result = $js->evaluate($instance_data, $schema_data);

=head1 DESCRIPTION

This module aims to be a fully-compliant L<JSON Schema|https://json-schema.org/> evaluator and
validator, targeting the currently-latest
L<Draft 2019-09|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>
version of the specification.

=head1 CONFIGURATION OPTIONS

None are supported at this time.

=head1 METHODS

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema_data);

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://tools.ietf.org/html/rfc8259>. B<The string is expected to be UTF-8 encoded.>

The schema is in the form of a Perl data structure, representing a JSON Schema
that respects the Draft 2019-09 meta-schema at L<https://json-schema.org/draft/2019-09/schema>.

The result is a boolean.

=head2 evaluate

  $result = $js->evaluate($instance_data, $schema_data);

Evaluates the provided instance data against the known schema document.

The data is in the form of an unblessed nested Perl data structure representing any type that JSON
allows (null, boolean, string, number, object, array).

The schema is in the form of a Perl data structure, representing a JSON Schema
that respects the Draft 2019-09 meta-schema at L<https://json-schema.org/draft/2019-09/schema>.

The result is a boolean.

=head2 CAVEATS

=head3 TYPES

Perl is a more loosely-typed language than JSON. This module delves into a value's internal
representation in an attempt to derive the true "intended" type of the value. However, if a value is
used in another context (for example, a numeric value is concatenated into a string, or a numeric
string is used in an arithmetic operation), additional flags can be added onto the variable causing
it to resemble the other type. This should not be an issue if data validation is occurring
immediately after decoding a JSON payload, or if the JSON string itself is passed to this module.

For more information, see L<Cpanel::JSON::XS/MAPPING>.

=head2 LIMITATIONS

Until version 1.000 is released, this implementation is not fully specification-compliant.

The minimum extensible JSON Schema implementation requirements involve:

=for :list
* identifying, organizing, and linking schemas (with keywords such as C<$ref>, C<$id>, C<$schema>,
  C<$anchor>, C<$defs>)
* providing an interface to evaluate assertions
* providing an interface to collect annotations
* applying subschemas to instances and combining assertion results and annotation data accordingly.
* support for all vocabularies required by the Draft 2019-09 metaschema,
  L<https://json-schema.org/draft/2019-09/schema>

To date, missing components include most of these. More specifically, features to be added include:

=for :list
* recognition of C<$id> and C<$ref>
* loading multiple schema documents, and registration of a schema against a canonical base URI
* collection of validation errors (as opposed to a short-circuited true/false result)
* collection of annotations
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.7.7>
* multiple output formats
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>)
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* use of C<$recursiveRef> and C<$recursiveAnchor>
* use of plain-name fragments with C<$anchor>

=head1 SEE ALSO

=for :list
* L<https://json-schema.org/>
* L<RFC8259|https://tools.ietf.org/html/rfc8259>
* L<Test::JSON::Schema::Acceptance>
* L<JSON::Validator>

=cut
