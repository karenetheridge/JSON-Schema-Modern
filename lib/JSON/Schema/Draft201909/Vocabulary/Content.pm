use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Content;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use List::Util 'any';
use Storable 'dclone';
use JSON::Schema::Draft201909::Utilities qw(is_type A abort assert_keyword_type);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/content' }

sub keywords {
  qw(contentEncoding contentMediaType contentSchema);
}

sub _eval_keyword_contentEncoding {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  assert_keyword_type($state, $schema, 'string');
  return A($state, $schema->{$state->{keyword}});
}

sub _eval_keyword_contentMediaType {
  goto \&_eval_keyword_contentEncoding;
}

sub _eval_keyword_contentSchema {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $schema->{contentMediaType};
  return 1 if not is_type('string', $data);

  abort($state, 'contentSchema value is not an object or boolean')
    if not any { is_type($_, $schema->{contentSchema}) } qw(object boolean);
  return A($state, dclone($schema->{contentSchema}));
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 SYNOPSIS

Implementation of the JSON Schema Draft 2019-09 "content" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/content> and formally specified in
L<https://json-schema.org/draft/2019-09/json-schema-validation.html>.

=cut
