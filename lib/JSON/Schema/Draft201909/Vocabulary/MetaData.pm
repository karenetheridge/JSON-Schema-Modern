use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::MetaData;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Draft 2019-09 Meta-Data vocabulary

our $VERSION = '0.018';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(assert_keyword_type);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/meta-data' }

sub keywords {
  qw(title description default deprecated readOnly writeOnly examples);
}

sub _traverse_keyword_title {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
}

sub _eval_keyword_title { shift->annotate_self(@_) }

sub _traverse_keyword_description { goto \&_traverse_keyword_title }

sub _eval_keyword_description { shift->annotate_self(@_) }

sub _eval_keyword_default { shift->annotate_self(@_) }

sub _traverse_keyword_deprecated {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'boolean');
}

sub _eval_keyword_deprecated { shift->annotate_self(@_) }

sub _traverse_keyword_readOnly { goto \&_traverse_keyword_deprecated }

sub _eval_keyword_readOnly { shift->annotate_self(@_) }

sub _traverse_keyword_writeOnly { goto \&_traverse_keyword_deprecated }

sub _eval_keyword_writeOnly { shift->annotate_self(@_) }

sub _traverse_keyword_examples {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'array');
}

sub _eval_keyword_examples { shift->annotate_self(@_) }

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2019-09 "Meta-Data" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/meta-data> and formally specified in
L<https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.9>.

=cut
