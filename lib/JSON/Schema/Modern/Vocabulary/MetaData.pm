use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::MetaData;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Meta-Data vocabulary

our $VERSION = '0.517';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::Schema::Modern::Utilities qw(assert_keyword_type annotate_self);
use Moo;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  my ($self, $spec_version) = @_;
  return
      $spec_version eq 'draft2019-09' ? 'https://json-schema.org/draft/2019-09/vocab/meta-data'
    : $spec_version eq 'draft2020-12' ? 'https://json-schema.org/draft/2020-12/vocab/meta-data'
    : undef;
}

sub keywords {
  my ($self, $spec_version) = @_;
  return (
    qw(title description default),
    $spec_version ne 'draft7' ? 'deprecated' : (),
    qw(readOnly writeOnly examples),
  );
}

sub _traverse_keyword_title {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_title {
  my ($self, $data, $schema, $state) = @_;
  annotate_self($state, $schema);
}

sub _traverse_keyword_description { goto \&_traverse_keyword_title }

sub _eval_keyword_description { goto \&_eval_keyword_title }

sub _traverse_keyword_default { 1 }

sub _eval_keyword_default { goto \&_eval_keyword_title }

sub _traverse_keyword_deprecated {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'boolean');
  return 1;
}

sub _eval_keyword_deprecated { goto \&_eval_keyword_title }

sub _traverse_keyword_readOnly { goto \&_traverse_keyword_deprecated }

sub _eval_keyword_readOnly { goto \&_eval_keyword_title }

sub _traverse_keyword_writeOnly { goto \&_traverse_keyword_deprecated }

sub _eval_keyword_writeOnly { goto \&_eval_keyword_title }

sub _traverse_keyword_examples {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'array');
  return 1;
}

sub _eval_keyword_examples { goto \&_eval_keyword_title }

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Meta-Data" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/meta-data> and formally specified in
L<https://datatracker.ietf.org/doc/html/draft-bhutton-json-schema-validation-00#section-9>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/meta-data> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-9>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-10>.

=cut
