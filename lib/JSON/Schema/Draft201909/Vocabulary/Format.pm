use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Format;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(is_type E A assert_keyword_type);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/format' }

sub keywords {
  qw(format);
}

sub _traverse_keyword_format {
  my ($self, $schema, $state) = @_;
  assert_keyword_type($state, $schema, 'string');
}

sub _eval_keyword_format {
  my ($self, $data, $schema, $state) = @_;

  if ($state->{validate_formats}
      and my $spec = $self->evaluator->_get_format_validation($schema->{format})) {
    return E($state, 'not a%s %s', $schema->{format} =~ /^[aeio]/ ? 'n' : '', $schema->{format})
      if is_type($spec->{type}, $data) and not $spec->{sub}->($data);
  }

  return A($state, $schema->{format});
}

1;
__END__

=pod

=for Pod::Coverage keywords

=cut
