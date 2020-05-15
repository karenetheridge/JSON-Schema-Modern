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
use List::Util 1.33 'any';
use Mojo::JSON::Pointer;
use Mojo::URL;
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

  my $state = {
    root_schema => Mojo::JSON::Pointer->new($schema),
  };

  my $result = $self->_eval($data, $schema, $state);
}

sub _eval {
  my ($self, $data, $schema, $state) = @_;

  my $schema_type = $self->_get_type($schema);
  return $schema if $schema_type eq 'boolean';

  die sprintf('unrecognized schema type "%s"', $schema_type) if $schema_type ne 'object';

  $state //= {};
  $state->{root_schema} = Mojo::JSON::Pointer->new($schema) if not exists $state->{root_schema};

  foreach my $keyword (
    # CORE KEYWORDS
    qw($schema $ref $id $anchor $recursiveRef $recursiveAnchor $vocabulary $comment $defs),
    # VALIDATOR KEYWORDS
    qw(type enum const
      multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
      maxLength minLength pattern
      maxItems minItems uniqueItems
      maxProperties minProperties required dependentRequired),
    # APPLICATOR KEYWORDS
    qw(allOf anyOf oneOf not if dependentSchemas
      items unevaluatedItems contains
      properties patternProperties additionalProperties unevaluatedProperties propertyNames),
  ) {
    next if not exists $schema->{$keyword};

    my $method = '_eval_keyword_'.($keyword =~ s/^\$//r);
    die 'unsupported keyword "'.$keyword.'"' if not $self->can($method);
    my $result = $self->$method($data, $schema, $state);

    return 0 if not $result;
  }

  return 1;
}

sub _eval_keyword_comment {
  my ($self, $data, $schema) = @_;
  die '"$comment" value is not a string' if not $self->_is_type('string', $schema->{'$comment'});
  # we do nothing with this keyword, including not collecting its value for annotations.
  return 1;
}

sub _eval_keyword_defs {
  # we do nothing directly with this keyword, including not collecting its value for annotations.
  return 1;
}

sub _eval_keyword_schema {
  my ($self, $data, $schema) = @_;

  die 'custom $schema references are not yet supported'
    if $schema->{'$schema'} ne 'https://json-schema.org/draft/2019-09/schema';
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  die 'only same-document JSON pointers are supported in $ref' if $schema->{'$ref'} !~ m{^#(/|$)};

  my $url = Mojo::URL->new($schema->{'$ref'});
  my $fragment = $url->fragment;

  my $subschema = $state->{root_schema}->get($fragment);
  die sprintf('unable to resolve ref "%s"', $schema->{'$ref'}) if not defined $subschema;
  return $self->_eval($data, $subschema, $state);
}

sub _eval_keyword_type {
  my ($self, $data, $schema) = @_;

  return any { $self->_is_type($_, $data) }
    (ref $schema->{type} eq 'ARRAY' ? @{$schema->{type}} : $schema->{type})
}

sub _eval_keyword_enum {
  my ($self, $data, $schema) = @_;

  return any { $self->_is_equal($data, $_) } @{$schema->{enum}};
}

sub _eval_keyword_const {
  my ($self, $data, $schema) = @_;

  return $self->_is_equal($data, $schema->{const});
}

sub _eval_keyword_multipleOf {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('number', $data);
  die sprintf('%s is not a number', $schema->{multipleOf})
    if not $self->_is_type('number', $schema->{multipleOf});
  die sprintf('%s is not a positive number', $schema->{multipleOf}) if $schema->{multipleOf} <= 0;

  my $quotient = $data / $schema->{multipleOf};
  return int($quotient) == $quotient;
}

sub _eval_keyword_maximum {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('number', $data);
  die sprintf('%s is not a number', $schema->{maximum})
    if not $self->_is_type('number', $schema->{maximum});

  return $data <= $schema->{maximum};
}

sub _eval_keyword_exclusiveMaximum {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('number', $data);
  die sprintf('%s is not a number', $schema->{exclusiveMaximum})
    if not $self->_is_type('number', $schema->{exclusiveMaximum});

  return $data < $schema->{exclusiveMaximum};
}

sub _eval_keyword_minimum {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('number', $data);
  die sprintf('%s is not a number', $schema->{minimum})
    if not $self->_is_type('number', $schema->{minimum});

  return $data >= $schema->{minimum};
}

sub _eval_keyword_exclusiveMinimum {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('number', $data);
  die sprintf('%s is not a number', $schema->{exclusiveMinimum})
    if not $self->_is_type('number', $schema->{exclusiveMinimum});

  return $data > $schema->{exclusiveMinimum};
}

sub _eval_keyword_maxLength {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('string', $data);
  die sprintf('%s is not an integer', $schema->{maxLength})
    if not $self->_is_type('integer', $schema->{maxLength});
  die sprintf('%s is not a non-negative integer', $schema->{maxLength})
    if $schema->{maxLength} < 0;

  return length($data) <= $schema->{maxLength};
}

sub _eval_keyword_minLength {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('string', $data);
  die sprintf('%s is not an integer', $schema->{minLength})
    if not $self->_is_type('integer', $schema->{minLength});
  die sprintf('%s is not a non-negative integer', $schema->{minLength})
    if $schema->{minLength} < 0;

  return length($data) >= $schema->{minLength};
}

sub _eval_keyword_pattern {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('string', $data);
  return $data =~ qr/$schema->{pattern}/;
}

sub _eval_keyword_maxItems {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('array', $data);
  die sprintf('%s is not an integer', $schema->{maxItems})
    if not $self->_is_type('integer', $schema->{maxItems});
  die sprintf('%s is not a non-negative integer', $schema->{maxItems}) if $schema->{maxItems} < 0;

  return @$data <= $schema->{maxItems};
}

sub _eval_keyword_minItems {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('array', $data);
  die sprintf('%s is not an integer', $schema->{minItems})
    if not $self->_is_type('integer', $schema->{minItems});
  die sprintf('%s is not a non-negative integer', $schema->{minItems})
    if $schema->{minItems} < 0;

  return @$data >= $schema->{minItems};
}

sub _eval_keyword_uniqueItems {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('array', $data);
  die sprintf('%s is not a boolean', $schema->{uniqueItems})
    if not $self->_is_type('boolean', $schema->{uniqueItems});

  return 1 if not $schema->{uniqueItems};
  return $self->_is_elements_unique($data);
}

sub _eval_keyword_maxProperties {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('object', $data);
  die sprintf('%s is not an integer', $schema->{maxProperties})
    if not $self->_is_type('integer', $schema->{maxProperties});
  die sprintf('%s is not a non-negative integer', $schema->{maxProperties})
    if $schema->{maxProperties} < 0;

  return keys %$data <= $schema->{maxProperties};
}

sub _eval_keyword_minProperties {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('object', $data);
  die sprintf('%s is not an integer', $schema->{minProperties})
    if not $self->_is_type('integer', $schema->{minProperties});
  die sprintf('%s is not a non-negative integer', $schema->{minProperties})
    if $schema->{minProperties} < 0;

  return keys %$data >= $schema->{minProperties};
}

sub _eval_keyword_required {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('object', $data);
  die '"required" value is not an array' if not $self->_is_type('array', $schema->{required});
  die '"required" element is not a string'
    if any { !$self->_is_type('string', $_) } @{$schema->{required}};

  return 0 if any { !exists $data->{$_} } @{$schema->{required}};
  return 1;
}

sub _eval_keyword_dependentRequired {
  my ($self, $data, $schema) = @_;

  return 1 if not $self->_is_type('object', $data);
  die '"dependentRequired" value is not an object'
    if not $self->_is_type('object', $schema->{dependentRequired});
  die '"dependentRequired" property is not an array'
    if any { !$self->_is_type('array', $schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};
  die '"dependentRequired" property elements are not unique'
    if any { !$self->_is_elements_unique($schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};

  foreach my $property (keys %{$schema->{dependentRequired}}) {
    return 0
      if exists $data->{$property}
        and any { !exists $data->{$_} } @{ $schema->{dependentRequired}{$property} };
  }
  return 1;
}

sub _eval_keyword_allOf {
  my ($self, $data, $schema, $state) = @_;

  die '"allOf" value is not an array' if not $self->_is_type('array', $schema->{allOf});
  die '"allOf" array is empty' if not @{$schema->{allOf}};

  foreach my $subschema (@{$schema->{allOf}}) {
    return 0 if not $self->_eval($data, $subschema, $state);
  }

  return 1;
}

sub _eval_keyword_anyOf {
  my ($self, $data, $schema, $state) = @_;

  die '"anyOf" value is not an array' if not $self->_is_type('array', $schema->{anyOf});
  die '"anyOf" array is empty' if not @{$schema->{anyOf}};

  foreach my $subschema (@{$schema->{anyOf}}) {
    return 1 if $self->_eval($data, $subschema, $state);
  }

  return 0;
}

sub _eval_keyword_oneOf {
  my ($self, $data, $schema, $state) = @_;

  die '"oneOf" value is not an array' if not $self->_is_type('array', $schema->{oneOf});
  die '"oneOf" array is empty' if not @{$schema->{oneOf}};

  my $valid = 0;
  foreach my $subschema (@{$schema->{oneOf}}) {
    ++$valid if $self->_eval($data, $subschema, $state);
    return 0 if $valid > 1;
  }

  return $valid == 1;
}

sub _eval_keyword_not {
  my ($self, $data, $schema, $state) = @_;
  return !$self->_eval($data, $schema->{not}, $state);
}

sub _eval_keyword_if {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $schema->{then} and not exists $schema->{else};
  if ($self->_eval($data, $schema->{if}, $state)) {
    return 1 if not exists $schema->{then};
    return $self->_eval($data, $schema->{then}, $state);
  }
  else {
    return 1 if not exists $schema->{else};
    return $self->_eval($data, $schema->{else}, $state);
  }
}

sub _eval_keyword_dependentSchemas {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  die '"dependentSchemas" value is not an object'
    if not $self->_is_type('object', $schema->{dependentSchemas});

  foreach my $property (keys %{$schema->{dependentSchemas}}) {
    return 0 if exists $data->{$property}
      and not $self->_eval($data, $schema->{dependentSchemas}{$property}, $state);
  }
  return 1;
}

sub _eval_keyword_items {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);

  if (ref $schema->{items} ne 'ARRAY') {
    return ! any { !$self->_eval($data->[$_], $schema->{items}, $state) } 0..$#{$data};
  }

  die '"items" array is empty' if not @{$schema->{items}};

  my $last_index = -1;
  foreach my $idx (0..$#{$data}) {
    last if $idx > $#{$schema->{items}};
    return 0 if not $self->_eval($data->[$idx], $schema->{items}[$idx], $state);
    $last_index = $idx;
  }

  return 1 if not exists $schema->{additionalItems} or $last_index == $#{$data};

  foreach my $idx ($last_index+1 .. $#{$data}) {
    return 0 if not $self->_eval($data->[$idx], $schema->{additionalItems}, $state);
  }

  return 1;
}

sub _eval_keyword_unevaluatedItems {
  my ($self, $data, $schema, $state) = @_;

  die '"unevaluatedItems" keyword present, but annotation collection is not supported';
}

sub _eval_keyword_contains {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);

  my $num_valid = 0;
  foreach my $idx (0.. $#{$data}) {
    if ($self->_eval($data->[$idx], $schema->{contains}, $state)) {
      ++$num_valid;
      return 1 if not exists $schema->{maxContains} and not exists $schema->{minContains};
    }
  }

  if (exists $schema->{maxContains}) {
    die sprintf('%s is not an integer', $schema->{maxContains})
      if not $self->_is_type('integer', $schema->{maxContains});
    die sprintf('%s is not a non-negative integer', $schema->{maxContains})
      if $schema->{maxContains} < 0;

    return 0 if $num_valid > $schema->{maxContains};
  }

  if (exists $schema->{minContains}) {
    die sprintf('%s is not an integer', $schema->{minContains})
      if not $self->_is_type('integer', $schema->{minContains});
    die sprintf('%s is not a non-negative integer', $schema->{minContains})
      if $schema->{minContains} < 0;

    # contains=0 is valid when minContains=0
    return $num_valid >= $schema->{minContains};
  }

  return $num_valid > 0;
}

sub _eval_keyword_properties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  die '"properties" value is not an object' if not $self->_is_type('object', $schema->{properties});

  foreach my $property (keys %{$schema->{properties}}) {
    next if not exists $data->{$property};
    return 0 if not $self->_eval($data->{$property}, $schema->{properties}{$property}, $state);
  }

  return 1;
}

sub _eval_keyword_patternProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  die '"patternProperties" value is not an object'
    if not $self->_is_type('object', $schema->{patternProperties});

  foreach my $property_pattern (keys %{$schema->{patternProperties}}) {
    my @property_matches = grep /$property_pattern/, keys %$data;

    next if not @property_matches;
    my $subschema = $schema->{patternProperties}{$property_pattern};
    return 0 if any { !$self->_eval($data->{$_}, $subschema, $state) } @property_matches;
  }

  return 1;
}

sub _eval_keyword_additionalProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);

  foreach my $property (keys %$data) {
    next if exists $schema->{properties} and exists $schema->{properties}{$property};
    next if exists $schema->{patternProperties}
      and any { $property =~ /$_/ } keys %{$schema->{patternProperties}};

    return 0 if not $self->_eval($data->{$property}, $schema->{additionalProperties}, $state);
  }

  return 1;
}

sub _eval_keyword_unevaluatedProperties {
  my ($self, $data, $schema, $state) = @_;

  die '"unevaluatedProperties" keyword present, but annotation collection is not supported';
}

sub _eval_keyword_propertyNames {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  return 0 if any { !$self->_eval($_, $schema->{propertyNames}, $state) } keys %$data;
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

# compares two arbitrary data payloads for equality, as per
# https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.4.2.3
sub _is_equal {
  my ($self, $x, $y) = @_;

  my @types = map $self->_get_type($_), $x, $y;
  return 0 if $types[0] ne $types[1];
  return 1 if $types[0] eq 'null';
  return $x eq $y if $types[0] eq 'string';
  return $x == $y if $types[0] eq 'boolean' or $types[0] eq 'number';

  if ($types[0] eq 'object') {
    return 0 if keys %$x != keys %$y;
    return 0 if not $self->_is_equal([ sort keys %$x ], [ sort keys %$y ]);
    foreach my $property (keys %$x) {
      return 0 if not $self->_is_equal($x->{$property}, $y->{$property});
    }
    return 1;
  }

  if ($types[0] eq 'array') {
    return 0 if @$x != @$y;
    foreach my $idx (0..$#{$x}) {
      return 0 if not $self->_is_equal($x->[$idx], $y->[$idx]);
    }
    return 1;
  }

  return 0; # should never get here
}

# checks array elements for uniqueness
sub _is_elements_unique {
  my ($self, $array) = @_;
  foreach my $idx0 (0..$#{$array}-1) {
    foreach my $idx1 ($idx0+1 .. $#{$array}) {
      return 0 if $self->_is_equal($array->[$idx0], $array->[$idx1]);
    }
  }
  return 1;
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
* recognition of C<$id>
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
