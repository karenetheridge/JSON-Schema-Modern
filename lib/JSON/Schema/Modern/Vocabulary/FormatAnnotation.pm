use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::FormatAnnotation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Format-Annotation vocabulary

our $VERSION = '0.586';

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
use JSON::Schema::Modern::Utilities qw(A E assert_keyword_type get_type);
use JSON::Schema::Modern::Vocabulary::FormatAssertion;
use List::Util 'any';
use Ref::Util 0.100 'is_plain_arrayref';
use Scalar::Util 'looks_like_number';
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2019-09/vocab/format' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/format-annotation' => 'draft2020-12';
}

sub evaluation_order { 2 }

sub keywords {
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
  my $spec = JSON::Schema::Modern::Vocabulary::FormatAssertion->_get_format_definition($schema, $state);

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
    not is_plain_arrayref($spec->{type}) ? any { $type eq $_ } $spec->{type}->@* : $type eq $spec->{type}
    and not ($state->{stringy_numbers} and $type eq 'string'
      and is_plain_arrayref($spec->{type}) ? any { $_ eq 'number' } $spec->{type}->@* : $spec->{type} eq 'number'
      and looks_like_number($data));

  return E($state, 'not a valid %s', $schema->{format}) if not $spec->{sub}->($data);
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

It also implements format assertion behaviour in a relaxed mode, meaning the
L<JSON::Schema::Modern/validate_formats> option has been enabled, and unknown formats will not
generate errors; this differs from the more strict behaviour in
LJSON::Schema::Modern::Vocabulary::FormatAssertion> which requires all formats used in the schema to
be supported and defined.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern/Format Validation>

=cut
