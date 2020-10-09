use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Content;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(is_type A assert_keyword_type);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/content' }

sub keywords {
  qw(contentEncoding contentMediaType contentSchema);
}

sub _traverse_keyword_contentEncoding {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
}

sub _eval_keyword_contentEncoding {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  return A($state, $schema->{$state->{keyword}});
}

sub _traverse_keyword_contentMediaType { goto \&_traverse_keyword_contentEncoding }

sub _eval_keyword_contentMediaType { goto \&_eval_keyword_contentEncoding }

sub _traverse_keyword_contentSchema {
  my ($self, $schema, $state) = @_;

  return if not exists $schema->{contentMediaType};
  $self->evaluator->_traverse($schema->{contentSchema},
    +{ %$state, schema_path => $state->{schema_path}.'/contentSchema' });
}

sub _eval_keyword_contentSchema {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $schema->{contentMediaType};
  return 1 if not is_type('string', $data);

  return A($state, dclone($schema->{contentSchema}));
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=cut
