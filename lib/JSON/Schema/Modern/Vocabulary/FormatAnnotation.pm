use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::FormatAnnotation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Format-Annotation vocabulary

our $VERSION = '0.627';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use Feature::Compat::Try;
use JSON::Schema::Modern::Utilities qw(A E assert_keyword_type get_type);
use JSON::Schema::Modern::Vocabulary::FormatAssertion;
use if "$]" < 5.041010, 'List::Util' => 'any';
use if "$]" >= 5.041010, experimental => 'keyword_any';
use Scalar::Util 'looks_like_number';
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary ($class) {
  'https://json-schema.org/draft/2019-09/vocab/format' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/format-annotation' => 'draft2020-12';
}

sub evaluation_order ($class) { 2 }

sub keywords ($class, $spec_version) {
  qw(format);
}

sub _traverse_keyword_format ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_format ($class, $data, $schema, $state) {
  A($state, $schema->{format});
  return 1 if not $state->{validate_formats};

  # { type => .., sub => .. }
  my $spec = $state->{evaluator}->_get_format_validation($schema->{format})
    // JSON::Schema::Modern::Vocabulary::FormatAssertion->_get_default_format_validation($state, $schema->{format});

  # §7.2.1 (draft2020-12) "Specifying the Format-Annotation vocabulary and enabling validation in an
  # implementation should not be viewed as being equivalent to specifying the Format-Assertion
  # vocabulary since implementations are not required to provide full validation support when the
  # Format-Assertion vocabulary is not specified."
  # §7.2.3 (draft2019-09) "An implementation MUST NOT fail validation or cease processing due to an
  # unknown format attribute."
  return 1 if not $spec;

  my $type = get_type($data);
  $type = 'number' if $type eq 'integer';

  return 1 if
    not ref $spec->{type} eq 'ARRAY' ? any { $type eq $_ } $spec->{type}->@* : $type eq $spec->{type}
    and not ($state->{stringy_numbers} and $type eq 'string'
      and ref $spec->{type} eq 'ARRAY' ? any { $_ eq 'number' } $spec->{type}->@* : $spec->{type} eq 'number'
      and looks_like_number($data));

  my $valid;
  try {
    $valid = $spec->{sub}->($data);
  }
  catch ($e) {
    # we treat a missing optional prereq as if the format is not implemented, therefore it is valid
    $valid = 1;
  }

  return E($state, 'not a valid %s %s', $schema->{format},
      ref $spec->{type} eq 'ARRAY' ? join(', ', $spec->{type}->@*) : $spec->{type})
    if not $valid;
  return 1;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Format-Annotation" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/format-annotation> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-validation.html#section-7>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keyword, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/format> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-7>.
* the equivalent Draft 7 keyword, as formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-7>.
* the equivalent Draft 6 keyword, as formally specified in
  L<https://json-schema.org/draft-06/draft-wright-json-schema-validation-01#rfc.section.8>.
* the equivalent Draft 4 keyword, as formally specified in
  L<https://json-schema.org/draft-04/draft-fge-json-schema-validation-00#rfc.section.7>.

It also implements format assertion behaviour in a relaxed mode, meaning the
L<JSON::Schema::Modern/validate_formats> option has been enabled, and unknown formats will not
generate errors; this differs from the more strict behaviour in
LJSON::Schema::Modern::Vocabulary::FormatAssertion> which requires all formats used in the schema to
be supported and defined.

When this vocabulary (the Format-Annotation vocabulary) is specified (which is the default for the
draft2020-12 metaschema) and combined with the C<validate_formats> option set to true, unimplemented
formats will silently validate, but implemented formats will validate completely. Note that some
formats require optional module dependencies, and the lack of these modules will generate an error.

When the Format-Assertion vocabulary is specified, unimplemented formats will generate an error on use.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern/Format Validation>
* L<JSON::Schema::Modern::Vocabulary::FormatAssertion>

=cut
