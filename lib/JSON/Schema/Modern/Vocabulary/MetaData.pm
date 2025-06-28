use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::MetaData;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Meta-Data vocabulary

our $VERSION = '0.615';

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
use JSON::Schema::Modern::Utilities qw(assert_keyword_type annotate_self);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary ($class) {
  'https://json-schema.org/draft/2019-09/vocab/meta-data' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/meta-data' => 'draft2020-12';
}

sub evaluation_order ($class) { 5 }

sub keywords ($class, $spec_version) {
  return (
    qw(title description default),
    $spec_version !~ /^draft[467]$/ ? 'deprecated' : (),
    $spec_version !~ /^draft[46]$/ ? qw(readOnly writeOnly) : (),
    $spec_version ne 'draft4' ? 'examples' : (),
  );
}

sub _traverse_keyword_title ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_title ($class, $data, $schema, $state) {
  annotate_self($state, $schema);
}

*_traverse_keyword_description = \&_traverse_keyword_title;

*_eval_keyword_description = \&_eval_keyword_title;

sub _traverse_keyword_default { 1 }

*_eval_keyword_default = \&_eval_keyword_title;

sub _traverse_keyword_deprecated ($class, $schema, $state) {
  return assert_keyword_type($state, $schema, 'boolean');
}

*_eval_keyword_deprecated = \&_eval_keyword_title;

*_traverse_keyword_readOnly = \&_traverse_keyword_deprecated;

*_eval_keyword_readOnly = \&_eval_keyword_title;

*_traverse_keyword_writeOnly = \&_traverse_keyword_deprecated;

*_eval_keyword_writeOnly = \&_eval_keyword_title;

sub _traverse_keyword_examples ($class, $schema, $state) {
  return assert_keyword_type($state, $schema, 'array');
}

*_eval_keyword_examples = \&_eval_keyword_title;

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Meta-Data" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/meta-data> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-validation.html#section-9>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/meta-data> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-9>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-10>.
* the equivalent Draft 6 keywords that correspond to this vocabulary and are formally specified in
  L<https://json-schema.org/draft-06/draft-wright-json-schema-validation-01#rfc.section.7>.
* the equivalent Draft 4 keywords that correspond to this vocabulary and are formally specified in
  L<https://json-schema.org/draft-04/draft-fge-json-schema-validation-00#rfc.section.6>.

=cut
