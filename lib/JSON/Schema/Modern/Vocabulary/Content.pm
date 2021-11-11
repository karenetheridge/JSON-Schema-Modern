use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Content;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Content vocabulary

our $VERSION = '0.525';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Storable 'dclone';
use JSON::Schema::Modern::Utilities qw(is_type A assert_keyword_type);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2019-09/vocab/content' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/content' => 'draft2020-12';
}

sub evaluation_order { 4 }

sub keywords ($self, $spec_version) {
  return (
    qw(contentEncoding contentMediaType),
    $spec_version ne 'draft7' ? 'contentSchema' : (),
  );
}

sub _traverse_keyword_contentEncoding ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_contentEncoding ($self, $data, $schema, $state) {
  return 1 if not is_type('string', $data);
  return A($state, $schema->{$state->{keyword}});
}

sub _traverse_keyword_contentMediaType { goto \&_traverse_keyword_contentEncoding }

sub _eval_keyword_contentMediaType { goto \&_eval_keyword_contentEncoding }

sub _traverse_keyword_contentSchema ($self, $schema, $state) {
  # since contentSchema should never be evaluated in the context of the containing schema, it is
  # not appropriate to gather identifiers found therein -- but we can still validate the subschema.
  $self->traverse_subschema($schema, +{ %$state, identifiers => [] });
}

sub _eval_keyword_contentSchema ($self, $data, $schema, $state) {
  return 1 if not exists $schema->{contentMediaType};
  return 1 if not is_type('string', $data);

  return A($state, dclone($schema->{contentSchema}));
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Content" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/content> and formally specified in
L<https://datatracker.ietf.org/doc/html/draft-bhutton-json-schema-validation-00#section-8>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/content> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-8>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-8>.

=cut
