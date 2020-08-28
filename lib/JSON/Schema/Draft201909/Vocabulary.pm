use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Base role for JSON Schema vocabulary classes

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use Moo::Role;
use strictures 2;
use Types::Standard 1.010002 'InstanceOf';
use namespace::clean;

has evaluator => (
  is => 'ro',
  isa => InstanceOf['JSON::Schema::Draft201909'],
  required => 1,
  weak_ref => 1,
);

requires qw(vocabulary keywords);

1;
__END__

=pod

=head1 SYNOPSIS

  package MyApp::Vocabulary::Awesome;
  use Moo::Role;
  with 'JSON::Schema::Draft201909::Vocabulary';

=head1 DESCRIPTION

This package is the role which all all vocabulary classes for L<JSON::Schema::Draft201909>
must compose, describing the basic structure expected of a vocabulary class.

User-defined custom vocabularies are not supported at this time.

=head1 ATTRIBUTES

=head2 evaluator

The L<JSON::Schema::Draft201909> evaluator object, used for implementing C<_eval_keyword_*>.

=head1 METHODS

=head2 vocabulary

The canonical URI describing the vocabulary, as described in
L<JSON Schema Core Meta-specification, section 8.1.2|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.8.1.2>. Must be implemented by the composing class.

=head2 keywords

The list of keywords defined by the vocabulary. Must be implemented by the composing class.

=cut
