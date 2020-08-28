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

This class is the base role for all vocabulary classes for L<JSON::Schema::Draft201909>.

User-defined custom vocabularies are not supported at this time.

=for Pod::Coverage evaluator

=cut
