use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::MetaData;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use Ref::Util 0.100 'is_ref';
use Storable 'dclone';
use JSON::Schema::Draft201909::Utilities qw(A assert_keyword_type);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/meta-data' }

sub keywords {
  qw(title description default deprecated readOnly writeOnly examples);
}

sub _eval_keyword_title {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');
  return A($state, $schema->{$state->{keyword}});
}

sub _eval_keyword_description {
  goto \&_eval_keyword_title;
}

sub _eval_keyword_default {
  my ($self, $data, $schema, $state) = @_;
  return A($state, is_ref($schema->{default}) ? dclone($schema->{default}) : $schema->{default});
}

sub _eval_keyword_deprecated {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'boolean');
  return A($state, $schema->{$state->{keyword}});
}

sub _eval_keyword_readOnly {
  goto \&_eval_keyword_deprecated;
}

sub _eval_keyword_writeOnly {
  goto \&_eval_keyword_deprecated;
}

sub _eval_keyword_examples {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'array');
  return A($state, is_ref($schema->{examples}) ? dclone($schema->{examples}) : $schema->{examples});
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=cut
