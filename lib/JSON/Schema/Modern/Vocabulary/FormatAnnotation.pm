use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::FormatAnnotation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Format-Annotation vocabulary

our $VERSION = '0.517';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::Schema::Modern::Utilities qw(is_type E A assert_keyword_type);
use Moo;
use Feature::Compat::Try;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  my ($self, $spec_version) = @_;
  return
      $spec_version eq 'draft2019-09' ? 'https://json-schema.org/draft/2019-09/vocab/format'
    : $spec_version eq 'draft2020-12' ? 'https://json-schema.org/draft/2020-12/vocab/format-annotation'
    : undef;
}

sub keywords {
  qw(format);
}

sub _traverse_keyword_format {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_format {
  my ($self, $data, $schema, $state) = @_;
  return A($state, $schema->{format});
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Format-Annotation" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/format-annotation> and formally specified in
L<https://datatracker.ietf.org/doc/html/draft-bhutton-json-schema-validation-00#section-7>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keyword, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/format> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-7>.
* the equivalent Draft 7 keyword, as formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-7>.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern/Format Validation>

=cut